// Game of Splits keeper: one idempotent pass per scheduled run (hourly).
//   1. settle ended Last Arrow rounds and past Seat days that hold a Purse (permissionless, harmless)
//   2. finalize due Alms votes and release (or carry) their Alms (permissionless)
//   3. buybacks: Bonfire, Vault burn, Vault buy, ONE LEDGER AT A TIME (a fill can raise the shared anchor)
// DRY_RUN is on unless DRY_RUN=0.
import { arrowAbi, seatAbi, almsAbi, coreAbi, routeAbi, quotePoolFor } from "./abi.mjs";
import { loadConfig } from "./config.mjs";
import { makeClients, simulateSwap, priceRouteA, send } from "./chain.mjs";
import { makeAlerter } from "./alerts.mjs";
import { fetchPriceSamples } from "./sendlog.mjs";
import { redact, errText } from "./redact.mjs";
import {
  LEDGERS, PROBE_USDG, MIN_CHUNK, IMPACT_MAX_BPS, SKIP_ERRORS,
  floorMin, planAmount, minOutFor, impactBps, priceCheck, bestRoute, rateOf, driftCheck, aboveAverage,
} from "./logic.mjs";

const CAP_ERRORS = new Set(["FeeCap", "GasCap"]); // M6: skip, never send

const ARROW_LOOKBACK = 24n; // rounds
const SEAT_LOOKBACK = 14n; // days
const NO_WINDOWS_GRACE = 7n * 86400n;
const MAX_ROUTES = 4n; // route indexes scanned for one that delivers the buy token
const ZERO = "0x0000000000000000000000000000000000000000";

export async function runKeeper(env = process.env, deps = {}) {
  const cfg = loadConfig(env);
  const c = deps.clients ?? makeClients(cfg); // tests inject a mocked client
  const secrets = [cfg.rpcUrl, cfg.watcherUrl, cfg.sendlogSecret];
  const summary = { dryRun: cfg.dryRun, keeper: c.address, settles: [], alms: [], swaps: [], skips: [], errors: [] };
  // N1: a push that isn't delivered fails the job (exit 1), so GitHub's failed-run email is the backup channel
  const pushover = makeAlerter(cfg, "keeper");
  const alert = async (...a) => {
    try {
      await pushover(...a);
    } catch (e) {
      summary.alertFailed = errText(e, secrets);
      console.log(`ALERT DELIVERY FAILED: ${summary.alertFailed}`);
    }
  };
  const log = (o) => console.log(JSON.stringify(o));

  const id = await c.pub.getChainId();
  if (id !== cfg.chainId) throw new Error(`RPC is chain ${id}, expected ${cfg.chainId}`);

  if (cfg.startDelayMaxS > 0) {
    const s = Math.floor(Math.random() * cfg.startDelayMaxS);
    log({ event: "start-delay", seconds: s });
    await new Promise((r) => setTimeout(r, s * 1000));
  }

  const read = (address, abi, functionName, args = []) => c.pub.readContract({ address, abi, functionName, args });
  const nowOf = async () => (await c.pub.getBlock()).timestamp;

  const tryCall = async (kind, address, abi, functionName, args) => {
    try {
      const r = await send(c, cfg, log, { address, abi, functionName, args });
      summary[kind].push({ functionName, args: args.map(String), hash: r.hash ?? "dry" });
    } catch (e) {
      if (e.revert && SKIP_ERRORS.has(e.revert.name)) return summary.skips.push({ functionName, args: args.map(String), reason: e.revert.name });
      summary.errors.push({ functionName, args: args.map(String), error: errText(e, secrets) });
    }
  };

  // ---------------------------------------------------------------- 1. settles
  let now = await nowOf();
  const cr = await read(cfg.arrow, arrowAbi, "currentRound");
  for (let r = cr > ARROW_LOOKBACK ? cr - ARROW_LOOKBACK + 1n : 1n; r <= cr; r++) {
    const R = await read(cfg.arrow, arrowAbi, "roundState", [r]);
    if (R.start === 0n || R.settled) continue;
    if (now >= (await read(cfg.arrow, arrowAbi, "effectiveDeadline", [r]))) await tryCall("settles", cfg.arrow, arrowAbi, "settle", [r]);
  }
  const today = await read(cfg.seat, seatAbi, "today");
  for (let d = today > SEAT_LOOKBACK ? today - SEAT_LOOKBACK : 0n; d < today; d++) {
    if (await read(cfg.seat, seatAbi, "isSettled", [d])) continue;
    if ((await read(cfg.core, coreAbi, "pot", [cfg.seat, d])) === 0n) continue; // an empty day has nothing to pay
    await tryCall("settles", cfg.seat, seatAbi, "settle", [d]);
  }

  // ---------------------------------------------------------------- 2. Alms
  const fairCount = await read(cfg.core, coreAbi, "fairCount");
  for (let f = 0n; f < fairCount; f++) {
    let res = await read(cfg.alms, almsAbi, "results", [f]);
    if (!res[4]) {
      const [, , voteEnd] = await read(cfg.alms, almsAbi, "windows", [f]);
      const [, end] = await read(cfg.core, coreAbi, "fairs", [f]);
      const due = voteEnd !== 0n ? now >= voteEnd : end !== 0n && now >= end + NO_WINDOWS_GRACE;
      if (due) await tryCall("alms", cfg.alms, almsAbi, "finalize", [f]);
      res = await read(cfg.alms, almsAbi, "results", [f]);
    }
    if (res[4] && (await read(cfg.core, coreAbi, "almsByFair", [f])) > 0n) {
      await tryCall("alms", cfg.alms, almsAbi, "releaseAlms", [f]);
    }
  }

  // ---------------------------------------------------------------- 3. buybacks
  // Not-the-keeper and NotSeeded are logged, not pushed: the watcher already alerts on both (D4 KeeperSet, D8), and an
  // hourly repeat from here would be spam (review M4). Stalls are left to the watcher's D9 for the same reason.
  const onchainKeeper = await read(cfg.core, coreAbi, "keeper");
  if (onchainKeeper.toLowerCase() !== c.address.toLowerCase()) {
    summary.skips.push({ buybacks: "this address is not FairCore's keeper (revoked or rotated)", onchainKeeper });
    return finish();
  }
  // No anchor in the current GameConfig epoch (never seeded, or the tokens changed since): FairCore would refuse every
  // buyback with NotSeeded until the Safe re-seeds. Stand down; the watcher's D8 alerts.
  if (await read(cfg.core, coreAbi, "anchorStale")) {
    summary.skips.push({ buybacks: "NotSeeded" });
    return finish();
  }
  const epoch = await read(cfg.core, coreAbi, "anchorEpoch"); // == GameConfig's epoch, since the anchor isn't stale
  const buyToken = await read(cfg.core, coreAbi, "buyToken");
  // Only routes that deliver the buy token (any other reverts RouteTokenMismatch onchain).
  const routes = [];
  const routeAddr = {};
  for (let i = 0n; i < MAX_ROUTES; i++) {
    const a = await read(cfg.core, coreAbi, "routes", [i]);
    if (a === ZERO) continue;
    if ((await read(a, routeAbi, "tokenOut")).toLowerCase() !== buyToken.toLowerCase()) continue;
    routes.push(Number(i));
    routeAddr[Number(i)] = a;
  }
  if (!routes.length) {
    summary.errors.push({ buybacks: `no route delivers the buy token ${buyToken}` });
    return finish();
  }
  if (cfg.priceMode === "v4quoter") {
    try {
      quotePoolFor(buyToken);
    } catch (e) {
      summary.errors.push({ buybacks: e.message }); // an unknown buy token: refuse to buy, and say so
      return finish();
    }
  }
  const priceCtx = { buyToken, route: routeAddr[routes[0]] };

  // 30-minute price check: route A's probe against the watcher's samples taken AFTER the keeper's last fill (before
  // it, the samples hold the pre-buy price). Fails closed.
  now = await nowOf();
  let lastFill = 0n;
  for (const L of LEDGERS) {
    const t = await read(cfg.core, coreAbi, "lastSwapAt", [L.id]);
    if (t > lastFill) lastFill = t;
  }
  const probe = async () => {
    try {
      return await priceRouteA(c, cfg, PROBE_USDG, priceCtx);
    } catch (e) {
      summary.skips.push({ buybacks: "probe failed", error: errText(e, secrets) }); // M5: fail closed
      return null;
    }
  };
  const firstProbe = await probe();
  if (firstProbe === null) return finish();
  let samples = [];
  try {
    // only samples from this epoch: an earlier epoch may have priced a different token
    samples = (await fetchPriceSamples(cfg)).filter((x) => x.e === epoch);
  } catch (e) {
    summary.errors.push({ priceHistory: errText(e, secrets) });
  }
  const pc = priceCheck(samples, Number(now), firstProbe, Number(lastFill));
  if (!pc.ok) {
    summary.skips.push({ buybacks: pc.skip, devBps: pc.devBps?.toString(), samples: pc.count });
    // Only "no history at all" alerts (the watcher may be down: a second dead-man). A single price skip is silent;
    // the watcher's 6h heartbeat covers repeated skips (review L10, recorded in the runbook).
    const fresh = samples.filter((x) => x.t > Number(now) - 1800).length;
    if (pc.skip === "no-price-history" && fresh < 4) await alert("high", "no price history", `Only ${fresh} watcher price samples in the last 30 min; buybacks skipped (fail closed). Is the watcher running?`);
    return finish();
  }

  let bought = 0n; // USDG this run, for the drift allowance
  for (const L of LEDGERS) {
    try {
      if (await buyLedger(L)) break; // true = stop the run
    } catch (e) {
      // RPC trouble mid-ledger: record it (redacted) and move on; never crash the run without an alert
      summary.errors.push({ ledger: L.name, error: errText(e, secrets) });
    }
  }
  return finish();

  async function buyLedger(L) {
    now = await nowOf();
    const day = now / 86400n;
    const plan = planAmount({
      pending: await read(cfg.core, coreAbi, L.pending),
      swappedToday: await read(cfg.core, coreAbi, "swappedOnDay", [L.id, day]),
      lastSwapAt: await read(cfg.core, coreAbi, "lastSwapAt", [L.id]),
      now,
    });
    if (plan.skip) {
      summary.skips.push({ ledger: L.name, reason: plan.skip });
      return false;
    }
    let amt = plan.amt;
    let shortFillRetries = 0;
    let stopRun = false;
    for (let attempt = 0; attempt < 6; attempt++) {
      // M5: re-probe before every ledger and every retry
      const p = await probe();
      if (p === null) {
        stopRun = true;
        break;
      }
      const drift = driftCheck(p, firstProbe, bought);
      if (!drift.ok) {
        summary.skips.push({ ledger: L.name, reason: "price moved during the run", driftBps: drift.bps.toString() });
        stopRun = true;
        break;
      }
      const floorRate = await read(cfg.core, coreAbi, "ratchetFloorRate");
      if (floorRate === 0n) {
        summary.skips.push({ ledger: L.name, reason: "NotSeeded" });
        stopRun = true;
        break;
      }
      const floor = floorMin(amt, floorRate);
      const sims = [];
      for (const r of routes) sims.push(await simulateSwap(c, cfg, L, r, amt, floor));
      const best = bestRoute(sims);
      if (!best) {
        if (sims.every((s) => s.revert?.name === "ShortFill")) summary.skips.push({ ledger: L.name, reason: "stall: floor above quote" }); // D9 alerts
        else if (sims.every((s) => SKIP_ERRORS.has(s.revert?.name))) summary.skips.push({ ledger: L.name, reason: sims[0].revert.name });
        else summary.errors.push({ ledger: L.name, sims: sims.map((s) => s.revert?.name) });
        break;
      }
      // L11: never buy at a rate far ABOVE the average (a pumped route would drag the anchor up into a stall)
      if (aboveAverage(rateOf(best.out, amt), pc.avg)) {
        summary.skips.push({ ledger: L.name, reason: "route above the 30-min average", route: best.route });
        break;
      }
      // Impact: the full amount against a 10 USDG probe on the same route. A failed probe skips (M5: fail closed).
      const pr = await simulateSwap(c, cfg, L, best.route, PROBE_USDG, floorMin(PROBE_USDG, floorRate));
      if (!pr.ok) {
        summary.skips.push({ ledger: L.name, reason: `impact probe failed: ${pr.revert?.name}` });
        break;
      }
      const imp = impactBps(rateOf(best.out, amt), rateOf(pr.out, PROBE_USDG));
      if (imp > IMPACT_MAX_BPS) {
        if (amt / 2n >= MIN_CHUNK) {
          amt = amt / 2n;
          continue; // halve and re-quote
        }
        summary.skips.push({ ledger: L.name, reason: "impact", bps: imp.toString() });
        break;
      }
      const mo = minOutFor(best.out, floor);
      if (mo.stall) continue; // can't happen (the simulation filled at >= floor); re-quote defensively
      const call = { ...best.call, args: [...best.call.args.slice(0, -1), mo.minOut] };
      try {
        const r = await send(c, cfg, log, { address: cfg.core, abi: coreAbi, ...call });
        summary.swaps.push({ ledger: L.name, route: best.route, token: buyToken, usdgIn: amt.toString(), quote: best.out.toString(), minOut: mo.minOut.toString(), hash: r.hash ?? "dry" });
        bought += amt;
        break;
      } catch (e) {
        // ShortFill (either selector, simulated or onchain, M2): the price moved between quote and inclusion.
        // Re-quote once (with a fresh probe and drift check), then skip. Never an error.
        if (e.revert?.name === "ShortFill") {
          if (shortFillRetries === 0) {
            shortFillRetries++;
            summary.retries = (summary.retries ?? 0) + 1;
            continue;
          }
          summary.skips.push({ ledger: L.name, reason: "ShortFill twice" });
        } else if (e.revert && (SKIP_ERRORS.has(e.revert.name) || CAP_ERRORS.has(e.revert.name))) {
          summary.skips.push({ ledger: L.name, reason: e.revert.name, ...(CAP_ERRORS.has(e.revert.name) ? { detail: errText(e, secrets) } : {}) });
        } else summary.errors.push({ ledger: L.name, error: errText(e, secrets) });
        break;
      }
    }
    return stopRun;
  }

  async function finish() {
    if (summary.errors.length) {
      await alert("normal", "keeper errors", redact(JSON.stringify(summary.errors), secrets).slice(0, 900));
    }
    log({ event: "summary", ...summary });
    return summary;
  }
}

if (import.meta.url === `file://${process.argv[1]}`) {
  runKeeper()
    .then((s) => process.exit(s.errors.length || s.alertFailed ? 1 : 0))
    .catch((e) => {
      console.log(`keeper failed: ${errText(e, [process.env.RPC_URL, process.env.WATCHER_URL])}`);
      process.exit(1);
    });
}
