// A2-13 residual: the lockPairing watcher. A revealed (or fallback) pairing seed only counts once someone calls
// lockPairing from a later L2 block, within 256 L2 blocks of the reveal (about 26 seconds) and before T_r + 8m. The
// keeper's own pair() call locks it too, but if the keeper is slow this watcher makes sure the lock still lands.
// L-1: once the seed is locked it also calls pair(r, PAIR_STEPS) until the round leaves Open, so a locked pairing is
// finished even if the keeper declines to pair it, and it alerts if a locked round is cancelled anyway.
// Optional: with FALLBACK=1 it also calls fallbackSeed after T_r + 3m when the keeper withheld its seed.
//
// Anyone may run it, with its own funded key (LOCKWATCH_KEY). It is not the keeper key and holds no role.
// DRY_RUN is on unless DRY_RUN=0. Nothing here logs a secret. Not deployed or run live from this repo.
//
//   RPC_URL=... CHAIN_ID=4663 RAT=0x... node src/lockwatch.mjs            (dry run, prints the plan)
//   RPC_URL=... CHAIN_ID=4663 RAT=0x... LOCKWATCH_KEY=... PUSHOVER_TOKEN=... PUSHOVER_GROUP=... DRY_RUN=0 node src/lockwatch.mjs
//   (a live run needs an alert channel, or NO_ALERTS=1 to opt out)

import { createPublicClient, createWalletClient, http, defineChain, isAddress, isHex, parseAbi } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { pathToFileURL } from "node:url";
import { makeAlerter } from "./alerts.mjs";

export const PAIR_DEADLINE = 180n; // T_r + 3m: the keeper's reveal window ends, fallbackSeed opens
export const FALLBACK_END = 420n; // T_r + 7m: fallbackSeed closes (PAIR_LATE_DEADLINE - MIN_LOCK_WINDOW)
export const PAIR_LATE_DEADLINE = 480n; // T_r + 8m: lockPairing closes, the round can be cancelled
export const HASH_WINDOW = 256n; // L2 blocks the reveal block's hash stays readable
export const PAIR_STEPS = 256n; // pair() steps per call; repeated every tick until the round is no longer Open
export const STATUS = { Open: 0, Paired: 1, Settled: 2, Finalized: 3, Cancelled: 4 };

export const ratAbi = parseAbi([
  "function currentRound() view returns (uint256)",
  "function closeTime(uint256 roundId) view returns (uint256)",
  "function rounds(uint256) view returns (bytes32 entrantsAcc, bytes32 pairingSeed, uint32 entrants, uint32 houseEntrants, uint32 cursor, uint32 shuffled, uint32 matches, uint32 settled, uint32 eligible, uint32 bonusCursor, uint8 status, bool waiting, bool bonusFixed, uint64 seedL2Block, uint256 waitingId, uint128 bonusPerPlayer, uint128 paidTotal, bool seedMixed)",
  "function lockPairing(uint256 roundId)",
  "function fallbackSeed(uint256 roundId)",
  "function pair(uint256 roundId, uint256 maxSteps)",
]);

export const ZERO = "0x" + "0".repeat(64);

/**
 * What to do for one round now. Pure.
 * round: { status, entrants, pairingSeed, seedMixed, seedL2Block } as read from rounds(r).
 * Returns { action: "lockPairing" | "pair" | "fallbackSeed" | "wait" | "none" | "lapsed", why }.
 */
export function planRound({ round, closeTime, now, nowL2, fallback }) {
  const status = Number(round.status);
  if (status === STATUS.Cancelled && round.seedMixed) return { action: "lapsed", why: "a locked pairing was cancelled" };
  if (status !== STATUS.Open) return { action: "none", why: "not open" };
  if (Number(round.entrants) === 0) return { action: "none", why: "no entrants" };
  if (now < closeTime) return { action: "none", why: "entries still open" };
  if (now >= closeTime + PAIR_LATE_DEADLINE) {
    if (round.seedMixed) return { action: "lapsed", why: "locked but not paired by T+8m, it will cancel" };
    return { action: "none", why: "past T+8m, cancel path" };
  }
  if (round.pairingSeed === ZERO) {
    if (!fallback) return { action: "wait", why: "no seed yet" };
    if (now < closeTime + PAIR_DEADLINE) return { action: "wait", why: "keeper reveal window" };
    if (now >= closeTime + FALLBACK_END) return { action: "lapsed", why: "no seed and fallback closed" };
    return { action: "fallbackSeed", why: "keeper missed T+3m" };
  }
  if (round.seedMixed) return { action: "pair", why: "locked, not yet paired" };
  const at = BigInt(round.seedL2Block);
  if (nowL2 <= at) return { action: "wait", why: "same L2 block as the reveal" };
  // I-1: the tx lands in a later block than nowL2, so at distance 256 it would already be 257 (RAT reverts > 256)
  if (nowL2 - at >= HASH_WINDOW) return { action: "lapsed", why: "reveal block hash gone" };
  return { action: "lockPairing", why: "seed revealed, not locked" };
}

export function loadLockwatchConfig(env) {
  const need = (k) => {
    if (!env[k]) throw new Error(`missing env ${k}`);
    return env[k];
  };
  const cfg = {
    rpcUrl: need("RPC_URL"),
    chainId: Number(need("CHAIN_ID")),
    rat: need("RAT"),
    key: env.LOCKWATCH_KEY ?? "",
    dryRun: env.DRY_RUN !== "0",
    fallback: env.FALLBACK === "1",
    pollMs: Number(env.POLL_MS || 2000),
    maxFeeWei: BigInt(Math.round(Number(env.MAX_FEE_GWEI || 1) * 1e9)),
    // ALERT lines go to Pushover (or ALERT_FILE). A live run needs one unless NO_ALERTS=1 (someone else's watcher).
    pushoverToken: env.PUSHOVER_TOKEN ?? "",
    pushoverGroup: env.PUSHOVER_GROUP ?? "",
    alertFile: env.ALERT_FILE ?? "",
    noAlerts: env.NO_ALERTS === "1",
  };
  if (!isAddress(cfg.rat)) throw new Error("env RAT is not an address");
  if (![4663, 46630].includes(cfg.chainId)) throw new Error("CHAIN_ID must be 4663 or 46630");
  if (cfg.key && !(isHex(cfg.key) && cfg.key.length === 66)) throw new Error("LOCKWATCH_KEY must be a 32-byte hex key");
  if (!cfg.dryRun && !cfg.key) throw new Error("live run needs LOCKWATCH_KEY");
  const canAlert = cfg.alertFile || (cfg.pushoverToken && cfg.pushoverGroup);
  if (!cfg.dryRun && !canAlert && !cfg.noAlerts) throw new Error("live run needs PUSHOVER_TOKEN / PUSHOVER_GROUP or ALERT_FILE (or NO_ALERTS=1)");
  if (!(cfg.pollMs >= 500)) throw new Error("POLL_MS must be at least 500");
  if (!(cfg.maxFeeWei > 0n)) throw new Error("MAX_FEE_GWEI must be a positive number");
  return cfg;
}

const asRound = (t) => ({ pairingSeed: t[1], entrants: t[2], status: t[10], seedL2Block: t[13], seedMixed: t[17] });

/** After a reverted send: was the job done by another caller (lost a race), or is it still undone? */
export function afterRevert(action, round) {
  if (action === "lockPairing") return round.seedMixed ? "raced" : "failed";
  // L-3: pairingSeed is a bytes32 hex string from viem, never a bigint
  if (action === "fallbackSeed") return round.pairingSeed !== ZERO ? "raced" : "failed";
  if (action === "pair") return Number(round.status) !== STATUS.Open ? "raced" : "failed";
  return "failed";
}

/**
 * One pass over the previous and current round. Simulates before any send.
 * c.alert (optional) pages each ALERT; c.seen (optional Set) makes each round's ALERT fire once, not every tick.
 */
export async function tick(c, cfg, log = console.log) {
  const warn = async (r, msg) => {
    const k = `${r}:${msg}`;
    if (c.seen?.has(k)) return;
    c.seen?.add(k);
    log(`round ${r}: ALERT ${msg}`);
    if (c.alert) {
      try {
        await c.alert("high", `lockwatch round ${r}`, msg);
      } catch (e) {
        c.seen?.delete(k); // retried next tick
        log(`round ${r}: alert not delivered (${e.message})`);
      }
    }
  };
  const block = await c.pub.getBlock();
  const now = block.timestamp;
  const nowL2 = block.number; // on Robinhood Chain (Arbitrum Orbit) RPC block numbers are L2 blocks
  const cur = await c.pub.readContract({ address: cfg.rat, abi: ratAbi, functionName: "currentRound" });
  for (const r of [cur - 1n, cur]) {
    if (r < 1n) continue;
    const [raw, closeTime] = await Promise.all([
      c.pub.readContract({ address: cfg.rat, abi: ratAbi, functionName: "rounds", args: [r] }),
      c.pub.readContract({ address: cfg.rat, abi: ratAbi, functionName: "closeTime", args: [r] }),
    ]);
    const plan = planRound({ round: asRound(raw), closeTime, now, nowL2, fallback: cfg.fallback });
    if (plan.action === "lapsed") await warn(r, plan.why);
    if (!["lockPairing", "pair", "fallbackSeed"].includes(plan.action)) continue;
    const from = c.account?.address;
    const args = plan.action === "pair" ? [r, PAIR_STEPS] : [r];
    try {
      await c.pub.simulateContract({ address: cfg.rat, abi: ratAbi, functionName: plan.action, args, account: from });
    } catch (e) {
      log(`round ${r}: ${plan.action} would revert (${e.shortMessage ?? "revert"}), skipping`);
      continue;
    }
    if (cfg.dryRun) {
      log(`round ${r}: dry run, would call ${plan.action} (${plan.why})`);
      continue;
    }
    const hash = await c.wallet.writeContract({
      address: cfg.rat, abi: ratAbi, functionName: plan.action, args, maxFeePerGas: cfg.maxFeeWei,
    });
    log(`round ${r}: sent ${plan.action} ${hash}`);
    const rcpt = await c.pub.waitForTransactionReceipt({ hash });
    if (rcpt.status !== "success") {
      const again = asRound(await c.pub.readContract({ address: cfg.rat, abi: ratAbi, functionName: "rounds", args: [r] }));
      const how = afterRevert(plan.action, again);
      if (how === "raced") log(`round ${r}: ${plan.action} reverted, another caller already did it`);
      else await warn(r, `${plan.action} reverted and the round is still not done`);
    }
  }
}

async function main() {
  const cfg = loadLockwatchConfig(process.env);
  const chain = defineChain({
    id: cfg.chainId, name: "Robinhood Chain", nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
    rpcUrls: { default: { http: [cfg.rpcUrl] } },
  });
  const pub = createPublicClient({ chain, transport: http(cfg.rpcUrl) });
  const account = cfg.key ? privateKeyToAccount(cfg.key) : undefined;
  const wallet = account ? createWalletClient({ account, chain, transport: http(cfg.rpcUrl) }) : null;
  const alert = cfg.alertFile || (cfg.pushoverToken && cfg.pushoverGroup) ? makeAlerter(cfg, "lockwatch") : null;
  const seen = new Set();
  console.log(`lockwatch on chain ${cfg.chainId}, ${cfg.dryRun ? "dry run" : "live"}, fallback ${cfg.fallback ? "on" : "off"}, alerts ${alert ? "on" : "stdout only"}`);
  for (;;) {
    if (seen.size > 1000) seen.clear();
    try {
      await tick({ pub, wallet, account, alert, seen }, cfg);
    } catch (e) {
      console.log(`tick failed: ${e.shortMessage ?? e.message}`); // no secrets in viem errors for reads/sends
    }
    await new Promise((res) => setTimeout(res, cfg.pollMs));
  }
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? "").href) main();
