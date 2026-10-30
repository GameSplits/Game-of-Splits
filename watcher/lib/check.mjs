// One watcher pass (Vercel cron every 2 minutes). Detectors, from RUNBOOK_KEEPER.md "Detect":
//   price sample  route-A price for 10 USDG (V4Quoter), kept 26h; the keeper's 30-min average reads these
//   D1 nonce      every keeper nonce maps to a logged tx that is an allowed call (re-checked onchain)
//   D2 fill       every buyback fill, two independent checks, queued and retried until verified (fails closed):
//                   a) the same call simulated at the block before (archive RPC; TooSoon/DailyCap overridden)
//                   b) the fill's rate vs the watcher's own 30-min route-A average (catches a push one block earlier)
//   D3 floor gap  floor more than 10% below market, on ledgers with daily room, 2 checks in a row (V4Quoter)
//   D4 owner      owner-level events on GameConfig, FairCore, AlmsVote, LocksleyVault, FairPass
//   D5 ETH        keeper ETH balance falling faster than its schedule
//   D8 NotSeeded  no anchor in the current GameConfig epoch (never seeded, or the tokens changed since)
//   D9 stall      quote below the floor, 2 checks in a row
//   heartbeat     pending work with daily room but no keeper swap for 3h (from GO_LIVE_AT before the first swap)
// Each detector runs in its own try/catch; a failing detector raises a high alert and the others still run (H4).
// Alerts are merged: one Pushover per cause per pass, listing every ledger/item (M4). A pass holds a lock (M8).
// Prices are in the current buy token (FairCore.buyToken()); samples carry their GameConfig epoch and token, and the
// stored samples reset when the epoch changes, so no average ever mixes two epochs.
import { randomUUID } from "node:crypto";
import { createPublicClient, http, defineChain, BaseError, ContractFunctionRevertedError, keccak256, encodeAbiParameters } from "viem";
import {
  coreAbi, almsAbi, vaultAbi, passAbi, configAbi, ratAbi, rakeBuyerAbi, feeSplitterAbi, routeAbi, v4QuoterAbi, testRouteAbi, routeErrorsAbi, MAINNET, FAIRCORE_SLOTS,
  SHORTFILL_SELECTORS, quotePoolFor,
} from "./abi.mjs";
import {
  LEDGERS, floorMin, verifyKeeperTx, fillShortfallBps, fillVsAverage, floorGapBps, gapAmount, strike, ethDropLastHour, OWNER_EVENTS,
} from "./detectors.mjs";
import { entriesFor } from "./sendlog.mjs";
import { errText } from "./redact.mjs";

const PROBE = 10_000_000n;
const PRICE_KEEP_S = 26 * 3600; // long enough to judge a fill that waited in the queue
const FILL_RETRY_S = 24 * 3600;
const LOG_CHUNK = 100_000n;
const MAX_NONCES_PER_PASS = 100n;
const MAX_FILLS_PER_PASS = 30;
const DEDUPE_CAP_S = 30 * 86400; // L5
const TIP_WINDOW = 10_000n; // newest blocks scanned first while a backlog drains (N3)
const ZERO = "0x0000000000000000000000000000000000000000";
const ZERO32 = `0x${"0".repeat(64)}`;
const LEVELS = { normal: 0, high: 1, emergency: 2 };
const MAX_ROUTES = 4n;
const FILL_EVENTS = new Set(["Burned", "BoughtForVault"]);
const RAKE_BUY = 50_000_000n; // RakeBuyer.MAX_BUY_USDG

function clients(cfg) {
  const chain = defineChain({
    id: cfg.chainId, name: "Robinhood Chain", nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
    rpcUrls: { default: { http: [cfg.rpcUrl] } },
  });
  return {
    pub: createPublicClient({ chain, transport: http(cfg.rpcUrl) }),
    archive: createPublicClient({ chain, transport: http(cfg.archiveRpcUrl) }),
  };
}

/**
 * What the price checks price right now: GameConfig's address and epoch, the buy token, whether the anchor is stale,
 * and the first route that delivers the buy token (its TestRoute rate is the testnet price).
 */
export async function market(pub, cfg) {
  const read = (address, abi, functionName, args = []) => pub.readContract({ address, abi, functionName, args });
  const config = await read(cfg.core, coreAbi, "config");
  const epoch = await read(config, configAbi, "epoch");
  const buyToken = await read(cfg.core, coreAbi, "buyToken");
  const stale = await read(cfg.core, coreAbi, "anchorStale");
  let route = null;
  for (let i = 0n; i < MAX_ROUTES && route === null; i++) {
    const a = await read(cfg.core, coreAbi, "routes", [i]);
    if (a !== ZERO && (await read(a, routeAbi, "tokenOut")).toLowerCase() === buyToken.toLowerCase()) route = a;
  }
  return { config, epoch: Number(epoch), buyToken, stale, route };
}

/** Route A's price for `usdgIn` in the buy token (wei per USDG unit, x1e18). Throws if it can't be priced. */
export async function priceRouteA(pub, cfg, usdgIn, mkt) {
  if (cfg.priceMode === "testroute") {
    if (!mkt.route) throw new Error(`no route delivers the buy token ${mkt.buyToken}`);
    const rate = await pub.readContract({ address: mkt.route, abi: testRouteAbi, functionName: "RATE" });
    return rate * 10n ** 18n;
  }
  const pool = quotePoolFor(mkt.buyToken); // a buy token with no quote pool: the price checks fail (alerted)
  const q = async (poolKey, zeroForOne, amt) => (await pub.simulateContract({
    address: MAINNET.quoter, abi: v4QuoterAbi, functionName: "quoteExactInputSingle",
    args: [{ poolKey, zeroForOne, exactAmount: amt, hookData: "0x" }],
  })).result[0];
  const eth = await q(MAINNET.usdgPool, false, usdgIn);
  const out = await q(pool, true, eth);
  return (out * 10n ** 18n) / usdgIn;
}

/** The revert's error name, matched by selector too (L6). null if the error isn't a revert. */
export function revertName(e) {
  if (!(e instanceof BaseError)) return null;
  const rev = e.walk((x) => x instanceof ContractFunctionRevertedError);
  if (!rev) return null;
  const sel = (rev.raw ?? "").slice(0, 10).toLowerCase();
  if (SHORTFILL_SELECTORS.has(sel)) return "ShortFill";
  return rev.data?.errorName ?? rev.signature ?? "revert";
}

/** Storage slots of FairCore's per-ledger guards, for the fill check's stateOverride. */
export function guardSlots(ledger, day) {
  const enc = (a, b) => keccak256(encodeAbiParameters([{ type: "uint256" }, { type: "uint256" }], [a, b]));
  return {
    lastSwapAt: enc(BigInt(ledger), FAIRCORE_SLOTS.lastSwapAt),
    swappedOnDay: enc(BigInt(day), BigInt(enc(BigInt(ledger), FAIRCORE_SLOTS.swappedOnDay))),
  };
}

export async function runCheck(cfg, store, alert, deps = {}) {
  const lockId = randomUUID();
  if (!(await store.lock("w:lock", lockId, 110))) return { skipped: "another pass holds the lock", alerts: [], notes: [], errors: [] };
  try {
    return await pass(cfg, store, alert, deps);
  } finally {
    await store.unlock("w:lock", lockId).catch(() => {});
  }
}

async function pass(cfg, store, alert, deps) {
  const { pub, archive } = deps.clients ?? clients(cfg); // tests inject a mocked client
  const secrets = [cfg.rpcUrl, cfg.archiveRpcUrl];
  const report = { alerts: [], scanned: null, notes: [], errors: [], fills: [] };

  let st = await store.get("w:state");
  const stateMissing = st === null;
  st ??= {};
  st.alerted ??= {};
  st.strikes ??= {};
  st.eth ??= [];
  // The scan position and the fill queue live together in their own key (w:scan), so losing w:state (dedupe, strikes)
  // can neither drop queued fills nor rescan and re-alert every owner event since START_BLOCK.
  const scanStored = await store.get("w:scan");
  const scan = scanStored ?? {};
  scan.pendingFills ??= [];
  scan.pendingRake ??= []; // RakeBuyer Bought logs not yet judged (kept in w:scan so a failed check is retried)
  scan.fillLog ??= [];
  // F2 (review N2): w:scan and w:nonce are only written AFTER every alert of this pass was delivered. If a push fails,
  // nothing advances, so the next pass finds the same events / nonces / fills and raises them again.
  const commit = new Map();
  let deliveryFailed = false;

  const head = await pub.getBlockNumber();
  const now = Number((await pub.getBlock({ blockNumber: head })).timestamp); // dedupe windows run on chain time

  // ---------------------------------------------------------------- merged alerts (M4)
  const out = new Map(); // cause -> { level, title, listInTitle, items: [{ member, line, ttl }] }
  const raise = (cause, level, title, { member = "-", line = "", ttl = 1e9, listInTitle = false } = {}) => {
    const c = out.get(cause) ?? { level, title, listInTitle, items: [] };
    if (LEVELS[level] > LEVELS[c.level]) c.level = level;
    c.items.push({ member: String(member), line, ttl: Math.min(ttl, DEDUPE_CAP_S) });
    out.set(cause, c);
  };
  const flush = async () => {
    for (const [cause, c] of out) {
      const fresh = c.items.filter((i) => !((st.alerted[`${cause}|${i.member}`] ?? 0) > now));
      if (!fresh.length) continue; // nothing new in this cause
      const title = c.listInTitle ? `${c.title}: ${[...new Set(c.items.map((i) => i.member).filter((m) => m !== "~"))].join(", ")}` : c.title;
      const lines = (c.listInTitle ? c.items : fresh).map((i) => i.line).filter(Boolean);
      const message = lines.join("\n");
      try {
        await alert(c.level, title, message);
      } catch (e) {
        deliveryFailed = true;
        if (cause === "state-missing") st.__dontSave = true; // its only trigger is w:state being absent
        report.errors.push(`alert delivery failed (${cause}): ${errText(e, secrets)}`); // -> /fail ping (N1)
        continue;
      }
      for (const i of c.items) st.alerted[`${cause}|${i.member}`] = now + i.ttl; // marked only once delivered
      report.alerts.push({ cause, level: c.level, title, message });
    }
  };
  const guard = async (name, fn) => {
    try {
      await fn();
    } catch (e) {
      const t = errText(e, secrets);
      report.errors.push(`${name}: ${t}`);
      raise("detector-failed", "high", "watcher detector failed", { member: name, line: `${name}: ${t}`, ttl: 1800, listInTitle: true });
    }
  };

  if (scanStored === null && (!stateMissing || (await store.get("w:nonce")) !== null)) {
    // review N3: w:scan gone while other state survived. The scan restarts at START_BLOCK (dedupe hides re-found
    // events); the newest blocks are scanned first every pass while the backlog drains.
    raise("scan-missing", "high", "scan position missing", { line: "w:scan was empty while w:state/w:nonce exist: the event scan restarts from START_BLOCK (newest blocks first) and the fill queue was lost. Check fills by hand for the gap; find out why the key vanished." });
  }
  if (stateMissing) {
    raise("state-missing", "high", "watcher state not found", {
      line: "w:state was empty: first pass, or the store was wiped/evicted. Dedupe and fill history start over; the nonce check keeps its own baseline (w:nonce). If this isn't the first pass, find out why.",
    });
  }

  // ---------------------------------------------------------------- market: buy token, epoch, route
  let mkt = null;
  await guard("market", async () => {
    mkt = await market(pub, cfg);
  });

  // ---------------------------------------------------------------- price sample
  // Samples from an earlier GameConfig epoch are dropped: they may price another token, and the keeper's 30-min check
  // and the fill check must never average across epochs. (Samples from before epochs were recorded count as epoch 0.)
  let prices = ((await store.get("w:price")) ?? []).filter((s) => s.t > now - PRICE_KEEP_S);
  if (mkt) {
    const kept = prices.filter((s) => (s.e ?? 0) === mkt.epoch);
    if (kept.length < prices.length) report.notes.push(`GameConfig epoch ${mkt.epoch}: price samples from earlier epochs dropped`);
    prices = kept;
  }
  await guard("price sample", async () => {
    if (!mkt) throw new Error("no market data this pass");
    const rate = await priceRouteA(pub, cfg, PROBE, mkt);
    prices.push({ t: now, rate: rate.toString(), e: mkt.epoch, k: mkt.buyToken });
    await store.set("w:price", prices);
  });

  // ---------------------------------------------------------------- D4 events + queue fills (up to head - confirmations)
  await guard("event scan", async () => {
    const safeHead = head > cfg.confirmations ? head - cfg.confirmations : 0n;
    const from = scan.lastBlock !== undefined ? BigInt(scan.lastBlock) + 1n : cfg.startBlock;
    if (from > safeHead) return;
    // Backlog (catching up after a restart or a lost w:scan): scan the newest TIP_WINDOW blocks first, every pass, so
    // new events never wait behind the catch-up (N3). Overlaps are harmless: alerts dedupe by tx#log, fills by tx#log.
    const ranges = [];
    let to;
    if (safeHead - from + 1n > cfg.maxRange) {
      const lo = [from, safeHead - TIP_WINDOW + 1n, scan.tipDone !== undefined ? BigInt(scan.tipDone) + 1n : 0n].reduce((x, y) => (x > y ? x : y));
      if (lo <= safeHead) ranges.push([lo, safeHead]);
      to = from + cfg.maxRange - 1n;
      ranges.push([from, to]);
    } else {
      to = safeHead;
      ranges.push([from, to]);
    }
    report.scanned = ranges.map(([x, y]) => [x.toString(), y.toString()]);
    for (const [rf, rt] of ranges) await scanRange(rf, rt);
    if (ranges.length === 2) scan.tipDone = safeHead.toString();
    else delete scan.tipDone;
    scan.lastBlock = to.toString(); // only after every chunk and group was read
    commit.set("w:scan", scan);
  });

  async function scanRange(from, to) {
    if (!mkt) throw new Error("no GameConfig address this pass"); // retried next pass; the scan position doesn't move
    const groups = [["config", mkt.config, configAbi], ["core", cfg.core, coreAbi], ["alms", cfg.alms, almsAbi], ["vault", cfg.vault, vaultAbi], ["pass", cfg.pass, passAbi],
      ["rat", cfg.rat, ratAbi], ["rakeBuyer", cfg.rakeBuyer, rakeBuyerAbi]];
    if (cfg.feeSplitter) groups.push(["feeSplitter", cfg.feeSplitter, feeSplitterAbi]);
    const maintenance = now < cfg.maintenanceUntil;
    for (let a = from; a <= to; a += LOG_CHUNK) {
      const b = a + LOG_CHUNK - 1n < to ? a + LOG_CHUNK - 1n : to;
      for (const [name, address, abi] of groups) {
        const events = abi.filter((x) => x.type === "event" && (OWNER_EVENTS[name][x.name] || (name === "core" && FILL_EVENTS.has(x.name)) || (name === "rakeBuyer" && x.name === "Bought") || (name === "rat" && x.name === "RoundCancelled")));
        const logs = await pub.getLogs({ address, events, fromBlock: a, toBlock: b });
        for (const l of logs) {
          const where = `${l.transactionHash}#${l.logIndex}`;
          if (name === "core" && FILL_EVENTS.has(l.eventName)) {
            if (!scan.pendingFills.some((f) => f.where === where)) {
              scan.pendingFills.push({
                where, tx: l.transactionHash, blockNumber: l.blockNumber.toString(), eventName: l.eventName, token: l.args.token,
                source: l.args.source !== undefined ? Number(l.args.source) : null, route: l.args.route.toString(),
                usdgIn: l.args.usdgIn.toString(), out: l.args.out.toString(), queuedAt: now, d2a: null, d2b: null,
              });
            }
            continue;
          }
          if (name === "rakeBuyer" && l.eventName === "Bought") {
            // judged after this pass's FairCore fills are in fillLog, so its size allowance counts them
            if (!scan.pendingRake.some((f) => f.where === where)) {
              scan.pendingRake.push({ where, tx: l.transactionHash, blockNumber: l.blockNumber.toString(), token: l.args.token, usdgIn: l.args.usdgIn.toString(), out: l.args.out.toString() });
            }
            continue;
          }
          if (name === "rat" && l.eventName === "RoundCancelled") {
            // a cancel after the pairing was locked is the A2-13 veto shape (nobody called pair by T+8m)
            // read at latest: seedMixed is only ever set and Cancelled is final, so the answer is the same, and RPC_URL
            // may not serve past state (a failing read must not freeze the scan)
            let rd = null;
            try {
              rd = await pub.readContract({ address: cfg.rat, abi: ratAbi, functionName: "rounds", args: [l.args.roundId] });
            } catch (e) {
              raise("rat-cancel-unread", "high", "RAT round cancelled, lock state unread", { member: where, line: `round ${l.args.roundId} cancelled | block ${l.blockNumber} tx ${l.transactionHash}. Could not read rounds(): check by hand whether it was locked.` });
            }
            if (rd && rd[17]) raise("rat-locked-cancel", "high", "locked RAT round cancelled", { member: where, line: `round ${l.args.roundId} was locked but cancelled unpaired | block ${l.blockNumber} tx ${l.transactionHash}. Check lockwatch is running and the keeper is pairing.` });
            continue;
          }
          let level = OWNER_EVENTS[name][l.eventName];
          if (!level) continue;
          if (l.eventName === "KeeperSet" && l.args.keeper === ZERO) level = "high"; // a revoke
          const args = Object.entries(l.args ?? {}).map(([k, v]) => `${k}=${v}`).join(" ");
          const line = `${name}.${l.eventName} ${args} | block ${l.blockNumber} tx ${l.transactionHash}`;
          if (maintenance) raise("owner-digest", "high", "owner events (planned maintenance window)", { member: where, line });
          else raise(`owner:${name}.${l.eventName}`, level, `${name}.${l.eventName}`, { member: where, line: `${line}. If this was planned, acknowledge; if not, start Respond.` });
        }
      }
    }
  }

  // M-4: a RakeBuyer fill against the watcher's own 30-min route-A median (same check as D2b; no prior-block re-sim).
  // Run after the D2 step so FairCore fills from this pass count toward the size allowance, and logged in fillLog.
  async function rakeFill(f) {
    const where = f.where;
    const usdgIn = BigInt(f.usdgIn);
    const out = BigInt(f.out);
    const fillT = Number((await pub.getBlock({ blockNumber: BigInt(f.blockNumber) })).timestamp);
    const samples = prices.filter((s) => !s.k || s.k.toLowerCase() === String(f.token).toLowerCase());
    const recentUsdg = scan.fillLog.filter((x) => x.where !== where && x.t <= fillT && x.t > fillT - 600).reduce((a, x) => a + BigInt(x.usdgIn), 0n);
    if (!scan.fillLog.some((x) => x.where === where)) scan.fillLog.push({ where, t: fillT, usdgIn: usdgIn.toString() });
    const v = fillVsAverage({ out, usdgIn, fillT, samples, recentUsdg, alertBps: cfg.fillAvgAlertBps, sizeAllowBps: cfg.fillSizeAllowBps });
    const what = `rakeBuyer.Bought ${Number(usdgIn) / 1e6} USDG -> ${out} | block ${f.blockNumber} tx ${f.tx}`;
    if (!v.ok) raise("fill-thin", "high", "RakeBuyer fill not checked", { member: where, line: `${what}: ${v.reason}. Check it by hand.` });
    else if (v.bad) raise("bad-fill", "emergency", "bad buyback fill", { member: `${where}:avg`, line: `${what}: rate ${v.shortBps} bps below the watcher's 30-min average (allowed ${v.allowBps}). Possible stolen key or price push: check now; revoke if not ours.` });
  }

  // ---------------------------------------------------------------- D2: verify queued fills (fails closed, H2)
  await guard("fill check", async () => {
    const blockTime = new Map();
    const timeOf = async (bn) => {
      if (!blockTime.has(bn)) blockTime.set(bn, Number((await pub.getBlock({ blockNumber: BigInt(bn) })).timestamp));
      return blockTime.get(bn);
    };
    const keep = [];
    for (const f of scan.pendingFills) {
      if (report.fills.length >= MAX_FILLS_PER_PASS) {
        keep.push(f);
        continue;
      }
      const r = await verifyFill(f, await timeOf(f.blockNumber));
      report.fills.push({ where: f.where, ...r });
      if (!r.done) keep.push(f);
    }
    scan.pendingFills = keep;
    // drop each entry only once judged, so an RPC failure here leaves it queued for the next pass
    while (scan.pendingRake.length) {
      await rakeFill(scan.pendingRake[0]);
      scan.pendingRake.shift();
    }
    scan.fillLog = scan.fillLog.filter((x) => x.t > now - 3600);
    commit.set("w:scan", scan);
  });

  async function verifyFill(f, fillT) {
    const usdgIn = BigInt(f.usdgIn);
    const out = BigInt(f.out);
    if (!scan.fillLog.some((x) => x.where === f.where)) scan.fillLog.push({ where: f.where, t: fillT, usdgIn: f.usdgIn });
    const what = `${f.eventName} ${Number(usdgIn) / 1e6} USDG -> ${out} of ${f.token}, tx ${f.tx}`;

    // (b) vs the watcher's own 30-min average
    if (f.d2b === null) {
      const recentUsdg = scan.fillLog.filter((x) => x.where !== f.where && x.t <= fillT && x.t > fillT - 600).reduce((a, x) => a + BigInt(x.usdgIn), 0n);
      // only samples that priced the token this fill bought
      const samples = prices.filter((s) => !s.k || s.k.toLowerCase() === String(f.token).toLowerCase());
      const v = fillVsAverage({ out, usdgIn, fillT, samples, recentUsdg, alertBps: cfg.fillAvgAlertBps, sizeAllowBps: cfg.fillSizeAllowBps });
      if (v.ok) {
        f.d2b = v.bad ? "bad" : "ok";
        if (v.bad) raise("bad-fill", "emergency", "bad buyback fill", { member: `${f.where}:avg`, line: `${what}: rate ${v.shortBps} bps below the watcher's 30-min average (allowed ${v.allowBps}). Possible stolen key or price push: check now; revoke if not ours.` });
      } else f.d2bWhy = v.reason;
    }

    // (a) the same call at the block before, with the 50-min gap and daily cap switched off (they say nothing about price)
    if (f.d2a === null) {
      const bn = BigInt(f.blockNumber) - 1n;
      try {
        const tx = await pub.getTransaction({ hash: f.tx });
        const ledger = f.eventName === "Burned" ? f.source : 2;
        const day = (await pub.getBlock({ blockNumber: bn })).timestamp / 86400n;
        const slots = guardSlots(ledger, day);
        const floorRate = await archive.readContract({ address: cfg.core, abi: coreAbi, functionName: "ratchetFloorRate", blockNumber: bn });
        const floor = floorMin(usdgIn, floorRate);
        const minOut = floor > 0n ? floor : 1n;
        const call = f.eventName === "Burned"
          ? { functionName: "burnBuyToken", args: [f.source, BigInt(f.route), usdgIn, minOut] }
          : { functionName: "buyForVault", args: [BigInt(f.route), usdgIn, minOut] };
        let quoted = null;
        try {
          quoted = (await archive.simulateContract({
            address: cfg.core, abi: [...coreAbi, ...routeErrorsAbi], account: tx.from, blockNumber: bn, ...call,
            stateOverride: [{ address: cfg.core, stateDiff: [{ slot: slots.lastSwapAt, value: ZERO32 }, { slot: slots.swappedOnDay, value: ZERO32 }] }],
          })).result;
        } catch (e) {
          const n = revertName(e);
          if (!n) throw e; // RPC trouble: retry next pass
          if (n === "ShortFill") {
            f.d2a = "bad";
            raise("bad-fill", "high", "bad buyback fill", { member: `${f.where}:prior`, line: `${what}: the same call at the block before was below the floor, yet it filled. Check the fill.` });
          } else {
            f.d2aWhy = `prior-block simulation reverted ${n}`;
            f.d2a = "unusable";
          }
        }
        if (quoted !== null) {
          const short = fillShortfallBps(out, quoted);
          f.d2a = short > cfg.fillAlertBps ? "bad" : "ok";
          if (f.d2a === "bad") raise("bad-fill", "emergency", "bad buyback fill", { member: `${f.where}:prior`, line: `${what}: the same call at the block before would have got ${quoted} (${short} bps more). Possible stolen key or sandwich: check now; revoke if not ours.` });
        }
      } catch (e) {
        f.d2aWhy = errText(e, secrets);
        raise("archive", "high", "fill check: archive RPC failing", { member: "archive", line: `Can't simulate at a past block (${f.d2aWhy}). Fills are queued and retried; the 30-min average check still runs. Check ARCHIVE_RPC_URL.`, ttl: 6 * 3600 });
      }
    }

    const a = f.d2a === "ok" || f.d2a === "bad";
    const b = f.d2b === "ok" || f.d2b === "bad";
    if (a && b) return { done: true, d2a: f.d2a, d2b: f.d2b };
    if (a && f.d2bWhy) {
      // review N4: the honest keeper can't fill without >= 4 samples spanning 20 min, so a fill without them is either
      // not the honest keeper or lost price data. The exact check ran, but say so.
      raise("fill-thin", "high", "fill checked by prior-block only (no 30-min samples)", { member: f.where, line: `${what}: ${f.d2bWhy}. The honest keeper doesn't fill without price history: check who sent it, and the watcher's price samples.` });
      return { done: true, d2a: f.d2a, d2b: `skipped: ${f.d2bWhy}` };
    }
    if (b && f.d2a === "unusable") return { done: true, d2a: f.d2aWhy, d2b: f.d2b };
    if (f.d2a === "unusable" && f.d2bWhy) { // neither check can ever run for this fill
      raise("fill-unverified", "high", "fill can't be verified", { member: f.where, line: `${what}: ${f.d2aWhy}; ${f.d2bWhy}. Check it by hand.` });
      return { done: true, d2a: f.d2aWhy, d2b: f.d2bWhy, unverifiable: true };
    }
    if (now - f.queuedAt > FILL_RETRY_S) {
      raise("fill-unverified", "high", "gave up verifying a fill", { member: f.where, line: `${what}: unverified for 24h (${f.d2aWhy ?? "-"}; ${f.d2bWhy ?? "-"}). Check it by hand.` });
      return { done: true, d2a: f.d2a, d2b: f.d2b, gaveUp: true };
    }
    if (!a && !b) raise("fill-unverified", "high", "fill not verified yet", { member: f.where, line: `${what}: neither check could run (${f.d2aWhy ?? "-"}; ${f.d2bWhy ?? "-"}). Retrying every pass.`, ttl: 86400 });
    return { done: false, d2a: f.d2a, d2b: f.d2b };
  }

  // ---------------------------------------------------------------- D1: keeper nonce vs the send log
  await guard("nonce check", async () => {
    const nonce = BigInt(await pub.getTransactionCount({ address: cfg.keeper, blockTag: "latest" }));
    let base = await store.get("w:nonce");
    if (base === null) {
      base = cfg.nonceStart.toString();
      raise("nonce-baseline", "high", "nonce baseline missing", { line: `w:nonce was empty; re-checking every keeper tx from NONCE_START=${cfg.nonceStart} (now ${nonce}). Expected once at go-live; otherwise the store was wiped.` });
    }
    let n = BigInt(base);
    const stop = nonce < n + MAX_NONCES_PER_PASS ? nonce : n + MAX_NONCES_PER_PASS;
    for (; n < stop; n++) {
      const entries = await entriesFor(store, cfg.chainId, n);
      let problems;
      if (!entries.length) problems = verifyKeeperTx(null, null, n, cfg);
      else {
        // any logged entry for this nonce that is mined counts (an honest re-sign logs a second entry, M1)
        let mined = null;
        let entry = null;
        for (const e of entries) {
          const tx = await pub.getTransaction({ hash: e.hash }).catch((err) => {
            if (err?.name === "TransactionNotFoundError") return null; // not mined: fine, try the next entry
            throw err; // RPC trouble is a detector failure, never a false "not accounted for"
          });
          if (tx && tx.blockNumber !== null && BigInt(tx.nonce) === n) {
            mined = tx;
            entry = e;
            break;
          }
        }
        problems = mined ? verifyKeeperTx(mined, entry, n, cfg) : [`none of the ${entries.length} logged tx(s) for nonce ${n} is mined: another, unlogged tx used that nonce`];
      }
      if (problems.length) raise("nonce", "emergency", "keeper tx not accounted for", { member: n, line: `nonce ${n}: ${problems.join("; ")}` });
      commit.set("w:nonce", (n + 1n).toString());
    }
    commit.set("w:nonce", n.toString()); // also when there was nothing to check: the baseline must exist
    if (nonce > stop) report.notes.push(`nonce check catching up: ${stop}/${nonce}`);
    if (out.has("nonce")) out.get("nonce").items.at(-1).line += ". Possible stolen key: check now; revoke if not ours.";
  });

  // ---------------------------------------------------------------- D8, D3, D9, heartbeat
  await guard("keeper state", async () => {
    const read = (address, abi, functionName, args = []) => pub.readContract({ address, abi, functionName, args });
    const onchainKeeper = await read(cfg.core, coreAbi, "keeper");
    if (!mkt) throw new Error("no market data this pass");
    const stale = mkt.stale;
    if (stale) raise("notseeded", "emergency", "NotSeeded", { line: `No anchor in GameConfig epoch ${mkt.epoch}: no buyback can run until the Safe re-seeds (resetRatchet at the market price of ${mkt.buyToken}). Check anchorRate, anchorEpoch and GameConfig.`, ttl: 3600 });
    // M-5: one keeper key on all three contracts (a zero keeper there is a revoke and is reported by its event).
    // Read before the FairCore early returns, so a rotation or revoke on FairCore alone doesn't hide the other two.
    const otherKeepers = {};
    for (const [label, address, abi] of [["RobinAmongThieves", cfg.rat, ratAbi], ["RakeBuyer", cfg.rakeBuyer, rakeBuyerAbi]]) {
      const k = await read(address, abi, "keeper");
      otherKeepers[label] = k;
      if (k !== ZERO && k.toLowerCase() !== cfg.keeper.toLowerCase()) raise("keeper-changed", "high", "keeper address changed", { member: `${label}:${k}`, line: `${label}.keeper() is ${k}, the watcher expects ${cfg.keeper}.` });
    }
    if (onchainKeeper === ZERO) {
      report.notes.push("keeper revoked: gap/stall/heartbeat checks idle");
      return;
    }
    if (onchainKeeper.toLowerCase() !== cfg.keeper.toLowerCase()) {
      raise("keeper-changed", "high", "keeper address changed", { member: onchainKeeper, line: `FairCore.keeper() is ${onchainKeeper}, the watcher expects ${cfg.keeper}. Update KEEPER if this was the planned rotation.` });
      return;
    }
    // M-4: RakeBuyer floor gap, priced for one 50 USDG buy when it has that much waiting. RAT sends rake without a
    // sync(), so count half of any unsynced USDG (what the next sync() would add); skip when its keeper isn't ours
    // or today's 500 USDG cap has no room for a buy (buy() would revert DailyCap, no keeper fault).
    const buyPending = await read(cfg.rakeBuyer, rakeBuyerAbi, "buyPending");
    const legPending = await read(cfg.rakeBuyer, rakeBuyerAbi, "legPending");
    const rakeBal = await read(await read(cfg.rakeBuyer, rakeBuyerAbi, "usdg"), rakeBuyerAbi, "balanceOf", [cfg.rakeBuyer]);
    const owed = buyPending + legPending;
    const rakePending = buyPending + (rakeBal > owed ? (rakeBal - owed) / 2n : 0n);
    const rakeRoom = (await read(cfg.rakeBuyer, rakeBuyerAbi, "boughtOnDay", [BigInt(now) / 86400n])) + RAKE_BUY <= 500_000_000n;
    const rakeOurs = otherKeepers.RakeBuyer.toLowerCase() === cfg.keeper.toLowerCase();
    if (!stale && rakeOurs && rakeRoom && rakePending >= RAKE_BUY) {
      const rq = ((await priceRouteA(pub, cfg, RAKE_BUY, mkt)) * RAKE_BUY) / 10n ** 18n;
      const rfr = await read(cfg.rakeBuyer, rakeBuyerAbi, "ratchetFloorRate");
      const rf = floorMin(RAKE_BUY, rfr);
      const rg = floorGapBps(rq, rf);
      if (rfr === 0n) raise("rake-unseeded", "high", "RakeBuyer anchor not seeded", { member: "RakeBuyer", ttl: 6 * 3600, line: "RakeBuyer.ratchetFloorRate() is 0 (stale epoch or never seeded): its buys revert NotSeeded until the Safe re-seeds it." });
      const sr = strike(st.strikes["gap:rake"], rfr !== 0n && rg !== null && rg > cfg.gapAlertBps);
      st.strikes["gap:rake"] = sr.strikes;
      if (sr.strikes >= 2) raise("gap", "high", "floor gap above 10%", { member: "RakeBuyer", listInTitle: true, ttl: 6 * 3600, line: `RakeBuyer: floor ${rg} bps below the route-A quote` });
      const ss = strike(st.strikes["stall:rake"], rfr !== 0n && rg === null);
      st.strikes["stall:rake"] = ss.strikes;
      if (ss.strikes >= 2) raise("stall", "high", "stall: anchor above market", { member: "RakeBuyer", listInTitle: true, ttl: 6 * 3600, line: `RakeBuyer: route-A quote ${rq} < floor ${rf} for 50 USDG` });
    } else {
      st.strikes["gap:rake"] = 0;
      st.strikes["stall:rake"] = 0;
    }
    if (stale) return;
    const floorRate = await read(cfg.core, coreAbi, "ratchetFloorRate");
    const day = BigInt(now) / 86400n;
    let anyWork = false;
    let lastSwap = 0n;
    for (const L of LEDGERS) {
      const pending = await read(cfg.core, coreAbi, L.pending);
      const swapped = await read(cfg.core, coreAbi, "swappedOnDay", [L.id, day]);
      const ls = await read(cfg.core, coreAbi, "lastSwapAt", [L.id]);
      if (ls > lastSwap) lastSwap = ls;
      const amt = gapAmount(pending, swapped); // 0 = doesn't count (too little, or no daily room left)
      if (amt === 0n) {
        st.strikes[`gap:${L.id}`] = 0;
        st.strikes[`stall:${L.id}`] = 0;
        continue;
      }
      anyWork = true;
      const quote = ((await priceRouteA(pub, cfg, amt, mkt)) * amt) / 10n ** 18n; // V4Quoter, never a keeper simulation
      const floor = floorMin(amt, floorRate);
      const gap = floorGapBps(quote, floor);
      const s9 = strike(st.strikes[`stall:${L.id}`], gap === null);
      st.strikes[`stall:${L.id}`] = s9.strikes;
      if (s9.strikes >= 2) raise("stall", "high", "stall: anchor above market", { member: L.name, listInTitle: true, ttl: 6 * 3600, line: `${L.name}: route-A quote ${quote} < floor ${floor} for ${Number(amt) / 1e6} USDG` });
      const s3 = strike(st.strikes[`gap:${L.id}`], gap !== null && gap > cfg.gapAlertBps);
      st.strikes[`gap:${L.id}`] = s3.strikes;
      if (s3.strikes >= 2) raise("gap", "high", "floor gap above 10%", { member: L.name, listInTitle: true, ttl: 6 * 3600, line: `${L.name}: floor ${gap} bps below the route-A quote` });
    }
    if (out.has("stall")) out.get("stall").items.push({ member: "~", line: "Buybacks wait. Let the anchor decay, or the Safe resets it (Respond step 4). Route A only: check route B before resetting.", ttl: 6 * 3600 });
    if (out.has("gap")) out.get("gap").items.push({ member: "~", line: "The keeper isn't keeping the anchor fresh: check it's running (route A only).", ttl: 6 * 3600 });
    const since = lastSwap !== 0n ? lastSwap : cfg.goLiveAt; // M9: before the first swap, count from go-live
    if (anyWork && since !== 0n && BigInt(now) - since > cfg.heartbeatS) {
      raise("heartbeat", "high", "keeper not buying", { ttl: 6 * 3600, line: `Ledgers have work and daily room, but no keeper swap for ${(BigInt(now) - since) / 3600n}h${lastSwap === 0n ? " since GO_LIVE_AT (never swapped)" : ""}. Check the keeper workflow, DRY_RUN and its vars.` });
    }
  });

  // ---------------------------------------------------------------- D5: ETH drain
  await guard("eth balance", async () => {
    const bal = await pub.getBalance({ address: cfg.keeper });
    const drop = ethDropLastHour(st.eth, now, bal);
    if (drop > cfg.ethDropMaxWei) raise("eth", "emergency", "keeper ETH dropping fast", { member: Math.floor(now / 3600), line: `Keeper balance fell ${drop} wei in about an hour (now ${bal}). Possible stolen key: check now.` });
    st.eth = [...st.eth.filter((s) => s.t > now - 7200), { t: now, bal: bal.toString() }];
  });

  // the "~" footer lines carry member "~": keep them out of "new member" decisions
  for (const c of out.values()) if (c.items.every((i) => i.member === "~")) c.items = [];
  for (const [k, c] of out) if (!c.items.length) out.delete(k);
  await flushWithFooters();
  for (const [k, exp] of Object.entries(st.alerted)) if (exp < now - 86400 || exp > now + DEDUPE_CAP_S) delete st.alerted[k];
  if (deliveryFailed) report.notes.push("an alert wasn't delivered: scan position and nonce baseline not advanced, so the next pass raises it again");
  else for (const [k, v] of commit) await store.set(k, v);
  if (!st.__dontSave) await store.set("w:state", st);
  return report;

  async function flushWithFooters() {
    // footers ("~") shouldn't make a cause look new, so pre-mark them as seen
    for (const [cause, c] of out) for (const i of c.items) if (i.member === "~") st.alerted[`${cause}|~`] = now + i.ttl;
    await flush();
  }
}
