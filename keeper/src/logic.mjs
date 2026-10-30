// Pure decision logic for the keeper (no network). Every rule here is from RUNBOOK_KEEPER.md "Keeper script
// requirements" and the FairCore v3.7 constants. Unit-tested in test/logic.test.mjs.

export const MIN_CHUNK = 5_000_000n; // 5 USDG: below this, skip rather than dribble
export const MAX_CALL = 250_000_000n; // FairCore.MAX_SWAP_USDG
export const DAILY_CAP = 3_000_000_000n; // FairCore.DAILY_SWAP_CAP, per ledger per UTC day
export const MIN_GAP_S = 50n * 60n; // FairCore.MIN_SWAP_GAP, per ledger
export const SLIPPAGE_BPS = 150n; // minOut = quote - 1.5%
export const IMPACT_MAX_BPS = 100n; // skip (or halve) when the buy itself moves the price more than 1%
export const PRICE_DEV_MAX_BPS = 200n; // skip when the price is more than 2% off its 30-minute average
export const PRICE_WINDOW_S = 1800; // 30 minutes
export const PRICE_MIN_SAMPLES = 4;
export const PRICE_MIN_SPAN_S = 1200; // the samples must cover at least 20 of the 30 minutes // the average needs at least this many samples in the window, or we skip
export const PROBE_USDG = 10_000_000n; // 10 USDG probe for the impact check and price samples
export const BPS = 10_000n;
export const DRIFT_PER_CALL_BPS = 100n; // the keeper's own buys move the price about 1% per 250 USDG (fork e2e: 2.87% for 750)
export const GAS_CAP = 3_000_000n;

export const LEDGERS = [
  { id: 0, name: "Bonfire", pending: "bonfirePending", call: "burn", source: 0 },
  { id: 1, name: "Vault burn", pending: "vaultBurnPending", call: "burn", source: 1 },
  { id: 2, name: "Vault buy", pending: "vaultBuyPending", call: "buy" },
];

/** FairCore's own floor math: usdgIn * floorRate / 1e18 (integer division). A minOut 1 wei lower would revert. */
export function floorMin(usdgIn, floorRate) {
  return (usdgIn * floorRate) / 10n ** 18n;
}

/**
 * How much this ledger may swap right now, or why it skips. Mirrors FairCore's guards so the keeper never sends a
 * call that would revert TooSoon / DailyCap / OverLedger / OverCap.
 */
export function planAmount({ pending, swappedToday, lastSwapAt, now }) {
  if (pending < MIN_CHUNK) return { skip: "below-min" };
  if (lastSwapAt !== 0n && now < lastSwapAt + MIN_GAP_S) return { skip: "too-soon", next: lastSwapAt + MIN_GAP_S };
  const room = swappedToday >= DAILY_CAP ? 0n : DAILY_CAP - swappedToday;
  let amt = pending < MAX_CALL ? pending : MAX_CALL;
  if (amt > room) amt = room;
  if (amt < MIN_CHUNK) return { skip: "daily-cap" };
  return { amt };
}

/** Buy-token output per USDG unit, scaled by 1e18 (the anchor's units). */
export function rateOf(out, usdgIn) {
  return (out * 10n ** 18n) / usdgIn;
}

/**
 * minOut for a quote: quote - 1.5%, never below the onchain floor. Returns { stall: true } when the quote itself is
 * below the floor (the anchor is above market): the keeper must skip and alert, never send.
 */
export function minOutFor(quote, floor) {
  if (quote < floor) return { stall: true };
  const m = (quote * (BPS - SLIPPAGE_BPS)) / BPS;
  return { minOut: m < floor ? floor : m };
}

/** Price impact of the full buy versus the probe, in bps (0 if the full buy is no worse). */
export function impactBps(rateFull, rateProbe) {
  if (rateProbe === 0n || rateFull >= rateProbe) return 0n;
  return ((rateProbe - rateFull) * BPS) / rateProbe;
}

/**
 * The current probe rate against the 30-minute average of samples. samples = [{ t: seconds, rate: bigint }].
 * Fails closed: too few samples in the window means skip.
 */
export function priceCheck(samples, now, current, after = 0) {
  // only samples taken after the keeper's last fill count: before it, the price was the pre-buy price (review tweak)
  const win = samples.filter((s) => s.t <= now && s.t > now - PRICE_WINDOW_S && s.t > after);
  if (win.length < PRICE_MIN_SAMPLES) return { skip: "no-price-history", count: win.length };
  // review N5: at least 20 minutes of spread, and the median (one odd sample can't move it)
  if (Math.min(...win.map((s) => s.t)) > now - PRICE_MIN_SPAN_S) return { skip: "no-price-history", count: win.length, reason: "samples span under 20 min" };
  const avg = median(win.map((s) => s.rate));
  if (avg === 0n) return { skip: "no-price-history", count: win.length };
  const diff = current > avg ? current - avg : avg - current;
  const devBps = (diff * BPS) / avg;
  if (devBps > PRICE_DEV_MAX_BPS) return { skip: "price-off-average", devBps, avg };
  return { ok: true, devBps, avg };
}

/** Pick the route with the larger simulated output among those that filled. */
export function bestRoute(results) {
  let best = null;
  for (const r of results) if (r.ok && (best === null || r.out > best.out)) best = r;
  return best;
}

/** Errors that mean "nothing to do here this run", not a failure. */
export const SKIP_ERRORS = new Set(["TooSoon", "DailyCap", "OverLedger", "NotEnded", "AlreadySettled", "DayNotOver", "WrongWindow", "AlreadyFinalized"]);

/**
 * Re-probe inside a run (review M5): the price before each ledger and each retry must stay within 2% of the run's first
 * probe, plus 1% (downward only) per 250 USDG the keeper itself has bought so far this run.
 */
export function driftCheck(probe, firstProbe, boughtSoFar) {
  if (firstProbe === 0n) return { ok: false, bps: null };
  const allowDown = PRICE_DEV_MAX_BPS + (DRIFT_PER_CALL_BPS * boughtSoFar) / MAX_CALL;
  if (probe >= firstProbe) {
    const up = ((probe - firstProbe) * BPS) / firstProbe;
    return { ok: up <= PRICE_DEV_MAX_BPS, bps: up };
  }
  const down = ((firstProbe - probe) * BPS) / firstProbe;
  return { ok: down <= allowDown, bps: -down, allowDown };
}

/** L11: the chosen route's rate must not sit more than 2% ABOVE the 30-minute average (a pumped route B would drag the
 * anchor up and stall the buybacks). */
export function aboveAverage(rate, avg) {
  return avg > 0n && rate > (avg * (BPS + PRICE_DEV_MAX_BPS)) / BPS;
}

/** M6: fee and gas caps. Arbitrum-style chains ignore tips, so priority is 0 and maxFee is 2x the base fee. */
export function feePlan(baseFee, maxFeeWei) {
  const maxFeePerGas = baseFee * 2n;
  if (maxFeePerGas > maxFeeWei) return { skip: `fee cap: base fee ${baseFee} wei, cap ${maxFeeWei}` };
  return { maxFeePerGas, maxPriorityFeePerGas: 0n };
}

/** Median of bigints (the mean of the two middle values for an even count). */
export function median(xs) {
  const v = [...xs].sort((a, b) => (a < b ? -1 : a > b ? 1 : 0));
  const m = Math.floor(v.length / 2);
  return v.length % 2 ? v[m] : (v[m - 1] + v[m]) / 2n;
}
