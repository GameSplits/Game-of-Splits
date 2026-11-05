// Robin Among Thieves keeper runner: reveals each closed round's seed from the keeper's hash chain, locks the pairing
// from the next L2 block, and pairs the round until it leaves Open. It also commits the next seed chain before the
// current one runs out (that call needs the keeper key). Every send is simulated first, retried with backoff while it
// still makes sense, and every failure that leaves a round undone raises an alert.
//
// Seed chain: generation g uses secret_g = keccak256(abi.encode(SEED_SECRET, g)) and links s_{i-1} = keccak256(s_i)
// for i = CHAIN_LEN..1, so the committed tip is s_0 and each reveal is the preimage of the current onchain tip.
// The runner is stateless: it finds the next preimage by looking the onchain tip up in generations 0..MAX_GEN.
//
// DRY_RUN is on unless DRY_RUN=0. Nothing here logs a secret (RPC URLs, keys, seeds, webhook URLs are redacted).
//
//   RPC_URL=... CHAIN_ID=46630 RAT=0x... node src/ratrunner.mjs                 (dry run, prints the plan)
//   ... KEEPER_KEY=<masked> SEED_SECRET=<masked> DRY_RUN=0 ALERT_WEBHOOK_URL=... node src/ratrunner.mjs
//   ONCE=1 runs a single tick and exits (cron style).

import {
  createPublicClient, createWalletClient, http, defineChain, isAddress, isHex, parseAbi, keccak256,
  encodeAbiParameters, encodeFunctionData,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { pathToFileURL } from "node:url";
import { redact } from "./redact.mjs";
import { logSend } from "./sendlog.mjs";
import { planRound, PAIR_DEADLINE, STATUS, ZERO } from "./lockwatch.mjs";
import { feePlan, GAS_CAP } from "./logic.mjs";

export const PAIR_STEPS = 256n;
export const DEFAULT_CHAIN_LEN = 2048; // 48 rounds a day: about 42 days per generation
export const DEFAULT_ROTATE_AT = 96; // commit the next chain when fewer than 2 days of links remain

export const ratRunnerAbi = parseAbi([
  "function currentRound() view returns (uint256)",
  "function closeTime(uint256 roundId) view returns (uint256)",
  "function keeper() view returns (address)",
  "function seedTip() view returns (bytes32)",
  "function nextSeedTip() view returns (bytes32)",
  "function nextSeedFrom() view returns (uint64)",
  "function lastSeedRound() view returns (uint64)",
  "function rounds(uint256) view returns (bytes32 entrantsAcc, bytes32 pairingSeed, uint32 entrants, uint32 houseEntrants, uint32 cursor, uint32 shuffled, uint32 matches, uint32 settled, uint32 eligible, uint32 bonusCursor, uint8 status, bool waiting, bool bonusFixed, uint64 seedL2Block, uint256 waitingId, uint128 bonusPerPlayer, uint128 paidTotal, bool seedMixed)",
  "function commitSeedChain(bytes32 tip, uint64 fromRound)",
  "function revealSeed(uint256 roundId, bytes32 seed)",
  "function lockPairing(uint256 roundId)",
  "function pair(uint256 roundId, uint256 maxSteps)",
]);

// ------------------------------------------------------------------ seed chain (pure)

export const link = (s) => keccak256(encodeAbiParameters([{ type: "bytes32" }], [s]));
export const genSecret = (master, g) =>
  keccak256(encodeAbiParameters([{ type: "bytes32" }, { type: "uint256" }], [master, BigInt(g)]));

/** Chain of one generation: arr[0] is the tip, arr[len] the secret. */
export function buildChain(secret, len) {
  const arr = new Array(len + 1);
  arr[len] = secret;
  for (let i = len; i > 0; --i) arr[i - 1] = link(arr[i]);
  return arr;
}

export function makeSeedBook(master, len = DEFAULT_CHAIN_LEN, maxGen = 8) {
  const cache = new Map();
  const chainOf = (g) => {
    if (!cache.has(g)) {
      const arr = buildChain(genSecret(master, g), len);
      cache.set(g, { arr, index: new Map(arr.map((h, i) => [h.toLowerCase(), i])) });
    }
    return cache.get(g);
  };
  return {
    len,
    tipOf: (g) => chainOf(g).arr[0],
    /** { gen, pos, seed, remaining } for the preimage of `tip`, or null if no generation has it. */
    next(tip) {
      for (let g = 0; g <= maxGen; ++g) {
        const c = chainOf(g);
        const pos = c.index.get(String(tip).toLowerCase());
        if (pos === undefined) continue;
        if (pos >= len) return { gen: g, pos, seed: null, remaining: 0 }; // chain used up
        return { gen: g, pos, seed: c.arr[pos + 1], remaining: len - pos - 1 };
      }
      return null;
    },
  };
}

// ------------------------------------------------------------------ planning (pure)

/** The tip a reveal for round r must hash to (revealSeed switches to the next chain at nextSeedFrom). */
export function tipFor(r, { seedTip, nextSeedTip, nextSeedFrom }) {
  if (nextSeedTip !== ZERO && BigInt(r) >= BigInt(nextSeedFrom)) return nextSeedTip;
  return seedTip;
}

/**
 * What to do for one round now. Pure. Extends lockwatch's planRound with the keeper's reveal.
 * Returns { action: "revealSeed" | "lockPairing" | "pair" | "wait" | "none" | "lapsed", why }.
 */
export function planKeeperRound({ r, round, closeTime, now, nowL2, lastSeedRound }) {
  const status = Number(round.status);
  if (status === STATUS.Open && Number(round.entrants) > 0 && round.pairingSeed === ZERO && now >= closeTime) {
    if (now >= closeTime + PAIR_DEADLINE) return { action: "lapsed", why: "keeper reveal window (T+3m) missed" };
    if (BigInt(r) <= BigInt(lastSeedRound)) return { action: "lapsed", why: "round is behind lastSeedRound" };
    return { action: "revealSeed", why: "closed, no seed yet" };
  }
  return planRound({ round, closeTime, now, nowL2, fallback: false });
}

/** Should the next seed chain be committed now? Returns { gen, fromRound }, { refuse, nextGen }, or null. */
export function planRotation({ found, cur, nextSeedTip, rotateAt, maxGen = 8 }) {
  if (!found || nextSeedTip !== ZERO) return null;
  if (found.remaining >= rotateAt) return null;
  const nextGen = found.gen + 1;
  if (nextGen > maxGen) return { refuse: true, nextGen };
  return { gen: nextGen, fromRound: BigInt(cur) + 2n };
}

// ------------------------------------------------------------------ retries and alerts

/** Exponential backoff with jitter. fn(attempt) may return { stop: true } to end early (job already done). */
export async function withRetry(fn, { tries = 4, baseMs = 250, maxMs = 4000, sleep = defaultSleep, onRetry } = {}) {
  let last;
  for (let a = 0; a < tries; ++a) {
    try {
      return await fn(a);
    } catch (e) {
      last = e;
      if (e?.fatal || a === tries - 1) break;
      const wait = Math.min(maxMs, baseMs * 2 ** a) * (0.75 + Math.random() * 0.5);
      onRetry?.(a + 1, e, Math.round(wait));
      await sleep(wait);
    }
  }
  throw last;
}
const defaultSleep = (ms) => new Promise((res) => setTimeout(res, ms));

/**
 * Alert hook: always a log line (redacted); optionally a JSON POST to ALERT_WEBHOOK_URL. A webhook failure is
 * logged and reported to the caller (returns false) so the same alert is tried again next tick.
 */
export function makeAlertHook(cfg, log = console.log, fetchImpl = globalThis.fetch) {
  const secrets = [cfg.rpcUrl, cfg.key, cfg.seedSecret, cfg.webhookUrl, cfg.sendlogSecret];
  return async function alert(level, title, message) {
    const t = redact(title, secrets);
    const m = redact(message, secrets);
    log(`ALERT ${level}: ${t} | ${m}`);
    if (!cfg.webhookUrl) return true;
    try {
      const r = await fetchImpl(cfg.webhookUrl, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ source: "rat-runner", chainId: cfg.chainId, level, title: t, message: m, t: Math.floor(Date.now() / 1000) }),
        signal: AbortSignal.timeout(10_000),
      });
      if (!r.ok) throw new Error(`HTTP ${r.status}`);
      return true;
    } catch (e) {
      log(`alert webhook failed: ${redact(e.message, secrets)}`);
      return false;
    }
  };
}

// ------------------------------------------------------------------ config

export function loadRunnerConfig(env) {
  const need = (k) => {
    if (!env[k]) throw new Error(`missing env ${k}`);
    return env[k];
  };
  const cfg = {
    rpcUrl: need("RPC_URL"),
    chainId: Number(need("CHAIN_ID")),
    rat: need("RAT"),
    key: env.KEEPER_KEY ?? "",
    seedSecret: env.SEED_SECRET ?? "",
    dryRun: env.DRY_RUN !== "0",
    once: env.ONCE === "1",
    pollMs: Number(env.POLL_MS || 2000),
    chainLen: Number(env.CHAIN_LEN || DEFAULT_CHAIN_LEN),
    rotateAt: Number(env.ROTATE_AT || DEFAULT_ROTATE_AT),
    maxGen: Number(env.MAX_GEN || 8),
    tries: Number(env.RETRIES || 4),
    blockWaits: Number(env.BLOCK_WAITS || 10), // re-plans while waiting for the L2 block after a reveal
    blockWaitMs: Number(env.BLOCK_WAIT_MS || 300),
    maxFeeWei: BigInt(Math.round(Number(env.MAX_FEE_GWEI || 1) * 1e9)),
    rpcFailAlertAfter: Number(env.RPC_FAIL_ALERT_AFTER || 3),
    webhookUrl: env.ALERT_WEBHOOK_URL ?? "",
    watcherUrl: env.WATCHER_URL ?? "",
    sendlogSecret: env.SENDLOG_SECRET ?? "",
    noSendlog: env.NO_SENDLOG === "1",
    allowLocal: env.ALLOW_LOCAL_CHAIN === "1", // anvil tests only
  };
  if (!isAddress(cfg.rat)) throw new Error("env RAT is not an address");
  const chains = cfg.allowLocal ? [4663, 46630, 31337] : [4663, 46630];
  if (!chains.includes(cfg.chainId)) throw new Error("CHAIN_ID must be 4663 or 46630");
  if (cfg.key && !(isHex(cfg.key) && cfg.key.length === 66)) throw new Error("KEEPER_KEY must be a 32-byte hex key");
  if (cfg.seedSecret && !(isHex(cfg.seedSecret) && cfg.seedSecret.length === 66)) throw new Error("SEED_SECRET must be 32-byte hex");
  if (!cfg.dryRun && !cfg.key) throw new Error("live run needs KEEPER_KEY");
  if (!cfg.dryRun && !cfg.seedSecret) throw new Error("live run needs SEED_SECRET");
  if (!cfg.dryRun && !(cfg.watcherUrl && cfg.sendlogSecret) && !cfg.noSendlog) {
    throw new Error("live run needs WATCHER_URL and SENDLOG_SECRET (or NO_SENDLOG=1)");
  }
  if (!(cfg.chainLen >= 16 && cfg.chainLen <= 100_000)) throw new Error("CHAIN_LEN out of range");
  if (!(cfg.rotateAt >= 1 && cfg.rotateAt < cfg.chainLen)) throw new Error("ROTATE_AT out of range");
  if (!(cfg.pollMs >= 500)) throw new Error("POLL_MS must be at least 500");
  if (!(cfg.tries >= 1 && cfg.tries <= 10)) throw new Error("RETRIES must be 1..10");
  if (!(cfg.rpcFailAlertAfter >= 1 && cfg.rpcFailAlertAfter <= 100)) throw new Error("RPC_FAIL_ALERT_AFTER must be 1..100");
  return cfg;
}

// ------------------------------------------------------------------ chain

const asRound = (t) => ({ pairingSeed: t[1], entrants: t[2], status: t[10], seedL2Block: t[13], seedMixed: t[17] });

const read = (c, cfg, functionName, args = []) =>
  c.pub.readContract({ address: cfg.rat, abi: ratRunnerAbi, functionName, args });

/** Refuse to sign if the RPC (or anything else) tried to change chainId, gas or fees. */
export function assertPinnedRequest(req, cfg) {
  if (Number(req.chainId) !== cfg.chainId) throw new Error(`refusing to sign: chainId ${req.chainId}`);
  if (req.gas === undefined || req.gas > GAS_CAP) throw new Error(`refusing to sign: gas ${req.gas}`);
  if (req.maxFeePerGas === undefined || req.maxFeePerGas > cfg.maxFeeWei) throw new Error(`refusing to sign: maxFee ${req.maxFeePerGas}`);
  if ((req.maxPriorityFeePerGas ?? 0n) > cfg.maxFeeWei) throw new Error(`refusing to sign: tip ${req.maxPriorityFeePerGas}`);
  if (req.nonce === undefined || req.nonce === null) throw new Error("refusing to sign: missing nonce");
}

/** Simulate, then (live) pin chainId/nonce/gas/fees, assert, sign, optionally send-log, broadcast, wait. */
export async function send(c, cfg, functionName, args, log) {
  try {
    await c.pub.simulateContract({ address: cfg.rat, abi: ratRunnerAbi, functionName, args, account: c.address });
  } catch (e) {
    const err = new Error(`${functionName} would revert (${e.shortMessage ?? "revert"})`);
    err.simRevert = true;
    throw err;
  }
  if (cfg.dryRun) {
    // never print a reveal seed, even after the round is closed
    const shown = functionName === "revealSeed" ? `${args[0]}, <seed>` : args.map(String).join(", ");
    log(`dry run, would call ${functionName}(${shown})`);
    return { dry: true };
  }
  const data = encodeFunctionData({ abi: ratRunnerAbi, functionName, args });
  const base = (await c.pub.getBlock()).baseFeePerGas ?? 0n;
  const fees = feePlan(base, cfg.maxFeeWei);
  if (fees.skip) throw new Error(fees.skip);
  const nonce = await c.pub.getTransactionCount({ address: c.address });
  let gas = await c.pub.estimateGas({ account: c.address, to: cfg.rat, data });
  if (gas > GAS_CAP) throw new Error(`gas cap: estimate ${gas} > ${GAS_CAP}`);
  // pass every field explicitly so viem never asks the RPC to fill chainId or gas
  const req = await c.wallet.prepareTransactionRequest({
    account: c.account,
    to: cfg.rat,
    data,
    value: 0n,
    chainId: cfg.chainId,
    nonce,
    gas,
    maxFeePerGas: fees.maxFeePerGas,
    maxPriorityFeePerGas: fees.maxPriorityFeePerGas,
  });
  assertPinnedRequest(req, cfg);
  const raw = await c.account.signTransaction(req);
  const hash = keccak256(raw);
  if (cfg.watcherUrl && cfg.sendlogSecret) {
    await logSend(cfg, { chainId: cfg.chainId, nonce: req.nonce, hash, to: cfg.rat, selector: data.slice(0, 10), sentAt: Math.floor(Date.now() / 1000) });
  }
  await c.pub.sendRawTransaction({ serializedTransaction: raw });
  const rcpt = await c.pub.waitForTransactionReceipt({ hash, timeout: 60_000 });
  if (rcpt.status !== "success") throw new Error(`${functionName} reverted onchain ${hash}`);
  log(`sent ${functionName} ${hash}`);
  return { hash };
}

/** Is the job for `action` on round r already done (by us earlier or by someone else)? */
function done(action, round) {
  if (action === "revealSeed") return round.pairingSeed !== ZERO;
  if (action === "lockPairing") return round.seedMixed || Number(round.status) !== STATUS.Open;
  if (action === "pair") return Number(round.status) !== STATUS.Open;
  return false;
}

/**
 * One pass. Rounds cur-1 and cur. Every action is re-planned from fresh chain state on each retry, so a retry never
 * repeats work someone else (lockwatch, a player) already did.
 */
export async function tick(c, cfg, { book, alert, seen = new Set(), log = console.log, sleep } = {}) {
  const warn = async (key, level, title, msg) => {
    if (seen.has(key)) return;
    seen.add(key);
    const ok = await alert(level, title, msg);
    if (!ok) seen.delete(key); // retried next tick
  };
  const cur = await read(c, cfg, "currentRound");
  const tips = {
    seedTip: await read(c, cfg, "seedTip"),
    nextSeedTip: await read(c, cfg, "nextSeedTip"),
    nextSeedFrom: await read(c, cfg, "nextSeedFrom"),
  };
  const results = [];

  // seed chain health and rotation
  if (book) {
    if (tips.seedTip === ZERO && tips.nextSeedTip === ZERO) {
      const fromRound = cur + 2n;
      await warn(`boot:${fromRound}`, "normal", "seed chain", `no chain committed, committing generation 0 from round ${fromRound}`);
      await guarded("commitSeedChain", () => send(c, cfg, "commitSeedChain", [book.tipOf(0), fromRound], log));
      results.push({ action: "commitSeedChain", gen: 0 });
    } else {
      const activeTip = tips.seedTip !== ZERO ? tips.seedTip : tips.nextSeedTip;
      const found = book.next(activeTip);
      if (!found) await warn(`unknown:${activeTip}`, "emergency", "seed chain", "onchain seed tip is not from this SEED_SECRET, reveals will fail");
      else {
        const rot = planRotation({ found, cur, nextSeedTip: tips.nextSeedTip, rotateAt: cfg.rotateAt, maxGen: cfg.maxGen });
        if (rot?.refuse) {
          await warn(`maxgen:${rot.nextGen}`, "emergency", "seed chain", `cannot rotate past MAX_GEN (${cfg.maxGen})`);
        } else if (rot) {
          await guarded("commitSeedChain", () => send(c, cfg, "commitSeedChain", [book.tipOf(rot.gen), rot.fromRound], log));
          results.push({ action: "commitSeedChain", gen: rot.gen });
        }
      }
    }
  }

  async function guarded(name, fn) {
    try {
      await withRetry(fn, {
        tries: cfg.tries, sleep,
        onRetry: (n, e, ms) => log(`${name} attempt ${n} failed (${redact(e.message, [cfg.rpcUrl])}), retry in ${ms} ms`),
      });
    } catch (e) {
      await warn(`${name}:${cur}`, "high", name, redact(e.message, [cfg.rpcUrl]));
    }
  }

  for (const r of [cur - 1n, cur]) {
    if (r < 1n) continue;
    // reveal, lock, pair in one tick (each re-planned from fresh state). The lock needs a later L2 block than the
    // reveal, so a "wait" right after our reveal sleeps briefly and re-plans (the hash is only readable ~26 s).
    let waits = 0;
    for (let step = 0; step < 3 + waits; ++step) {
      const [raw, closeTime, block, lastSeedRound] = await Promise.all([
        read(c, cfg, "rounds", [r]), read(c, cfg, "closeTime", [r]), c.pub.getBlock(), read(c, cfg, "lastSeedRound"),
      ]);
      const round = asRound(raw);
      const plan = planKeeperRound({ r, round, closeTime, now: block.timestamp, nowL2: block.number, lastSeedRound });
      if (plan.action === "lapsed") {
        await warn(`lapsed:${r}:${plan.why}`, "high", `rat round ${r}`, plan.why);
        break;
      }
      if (plan.action === "wait" && round.pairingSeed !== ZERO && waits < cfg.blockWaits) {
        ++waits;
        await (sleep ?? defaultSleep)(cfg.blockWaitMs);
        continue;
      }
      if (!["revealSeed", "lockPairing", "pair"].includes(plan.action)) break;
      let args;
      if (plan.action === "revealSeed") {
        if (!book) {
          log(`round ${r}: needs a reveal but SEED_SECRET is not set`);
          break;
        }
        const f = book.next(tipFor(r, tips));
        if (!f?.seed) {
          await warn(`noseed:${r}`, "emergency", `rat round ${r}`, "no preimage for the onchain seed tip (chain used up or unknown)");
          break;
        }
        args = [r, f.seed];
      } else args = plan.action === "pair" ? [r, PAIR_STEPS] : [r];

      let outcome = "ok";
      try {
        await withRetry(async (a) => {
          if (a > 0) {
            const again = asRound(await read(c, cfg, "rounds", [r]));
            if (done(plan.action, again)) {
              outcome = "raced";
              return;
            }
          }
          // a sim revert is retried too (same L2 block as the reveal, RPC lag); done work is skipped above
          return await send(c, cfg, plan.action, args, (m) => log(`round ${r}: ${m}`));
        }, {
          tries: cfg.tries, sleep,
          onRetry: (n, e, ms) => log(`round ${r}: ${plan.action} attempt ${n} failed (${redact(e.message, [cfg.rpcUrl])}), retry in ${ms} ms`),
        });
      } catch (e) {
        const again = asRound(await read(c, cfg, "rounds", [r]));
        if (done(plan.action, again)) outcome = "raced";
        else {
          outcome = "failed";
          await warn(`fail:${r}:${plan.action}`, "high", `rat round ${r}`, `${plan.action} failed after ${cfg.tries} tries, ${redact(e.message, [cfg.rpcUrl])}`);
        }
      }
      results.push({ r, action: plan.action, outcome });
      if (outcome === "failed" || cfg.dryRun) break;
    }
  }
  return results;
}

export function makeClients(cfg) {
  const chain = defineChain({
    id: cfg.chainId, name: "Robinhood Chain", nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
    rpcUrls: { default: { http: [cfg.rpcUrl] } },
  });
  const pub = createPublicClient({ chain, transport: http(cfg.rpcUrl) });
  let account;
  if (cfg.key) {
    try {
      account = privateKeyToAccount(cfg.key);
    } catch {
      throw new Error("invalid KEEPER_KEY");
    }
  }
  const wallet = account ? createWalletClient({ account, chain, transport: http(cfg.rpcUrl) }) : null;
  return { pub, wallet, account, address: account?.address, chain };
}

async function main() {
  const cfg = loadRunnerConfig(process.env);
  const c = makeClients(cfg);
  const book = cfg.seedSecret ? makeSeedBook(cfg.seedSecret, cfg.chainLen, cfg.maxGen) : null;
  const alert = makeAlertHook(cfg);
  try {
    const rpcChainId = Number(await c.pub.getChainId());
    if (rpcChainId !== cfg.chainId) throw new Error(`RPC chainId ${rpcChainId} != configured ${cfg.chainId}`);
  } catch (e) {
    const msg = redact(e.shortMessage ?? e.message, [cfg.rpcUrl, cfg.webhookUrl]);
    console.log(`startup failed: ${msg}`);
    await alert("high", "rat runner", `startup RPC/chain check failed: ${msg}`);
    throw e;
  }
  if (!cfg.dryRun) {
    const k = await read(c, cfg, "keeper");
    if (k.toLowerCase() !== c.address.toLowerCase()) throw new Error("KEEPER_KEY is not the onchain keeper");
  }
  const seen = new Set();
  let fails = 0;
  console.log(`rat runner on chain ${cfg.chainId}, ${cfg.dryRun ? "dry run" : "live"}, webhook ${cfg.webhookUrl ? "on" : "off"}`);
  for (;;) {
    if (seen.size > 1000) seen.clear();
    let tickOk = true;
    try {
      await tick(c, cfg, { book, alert, seen });
      fails = 0;
      seen.delete("rpc-fail");
    } catch (e) {
      tickOk = false;
      fails += 1;
      const msg = redact(e.shortMessage ?? e.message, [cfg.rpcUrl, cfg.webhookUrl]);
      console.log(`tick failed: ${msg}`);
      if (fails >= cfg.rpcFailAlertAfter) {
        if (!seen.has("rpc-fail")) {
          seen.add("rpc-fail");
          const ok = await alert("high", "rat runner", `RPC/tick failed ${fails} times in a row: ${msg}`);
          if (!ok) seen.delete("rpc-fail");
        }
      }
    }
    if (cfg.once) {
      if (!tickOk) process.exit(1);
      return;
    }
    await new Promise((res) => setTimeout(res, cfg.pollMs));
  }
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? "").href) main().catch((e) => {
  console.error(redact(e.message));
  process.exit(1);
});
