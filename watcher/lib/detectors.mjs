// Pure detector logic for the watcher (no network). Unit-tested.
import { KEEPER_SELECTORS } from "./abi.mjs";

export const BPS = 10_000n;
export const MIN_CHUNK = 5_000_000n;
export const MAX_CALL = 250_000_000n;
export const DAILY_CAP = 3_000_000_000n;
export const LEDGERS = [
  { id: 0, name: "Bonfire", pending: "bonfirePending" },
  { id: 1, name: "Vault burn", pending: "vaultBurnPending" },
  { id: 2, name: "Vault buy", pending: "vaultBuyPending" },
];

export function floorMin(usdgIn, floorRate) {
  return (usdgIn * floorRate) / 10n ** 18n;
}

/** The only (target -> selectors) the keeper ever sends. Used by the nonce check and by the send log at write time. */
export function allowedCalls(cfg) {
  return {
    [cfg.core.toLowerCase()]: [KEEPER_SELECTORS.burnBuyToken, KEEPER_SELECTORS.buyForVault],
    [cfg.arrow.toLowerCase()]: [KEEPER_SELECTORS.settle],
    [cfg.seat.toLowerCase()]: [KEEPER_SELECTORS.settle],
    [cfg.alms.toLowerCase()]: [KEEPER_SELECTORS.finalize, KEEPER_SELECTORS.releaseAlms],
    // M-5: one keeper key for all three; the RAT seed chain and rounds, and RakeBuyer buys and forwards
    [cfg.rat.toLowerCase()]: [KEEPER_SELECTORS.commitSeedChain, KEEPER_SELECTORS.revealSeed, KEEPER_SELECTORS.pair, KEEPER_SELECTORS.ratSettle],
    [cfg.rakeBuyer.toLowerCase()]: [KEEPER_SELECTORS.rakeBuy, KEEPER_SELECTORS.forwardToken],
  };
}

/**
 * Detector 1 (nonce + send log): is this mined keeper tx one the keeper logged, and is it a call the keeper is allowed
 * to make? Returns a list of problems (empty = fine).
 */
export function verifyKeeperTx(tx, entry, nonce, cfg) {
  const p = [];
  if (!entry) return [`no send-log entry for keeper nonce ${nonce}`];
  if (!tx) return [`logged tx ${entry.hash} for nonce ${nonce} isn't on chain (another tx used the nonce?)`];
  if (tx.hash.toLowerCase() !== entry.hash.toLowerCase()) p.push(`nonce ${nonce} was used by ${tx.hash}, but the log says ${entry.hash}`);
  if (tx.from.toLowerCase() !== cfg.keeper.toLowerCase()) p.push(`tx ${tx.hash} isn't from the keeper`);
  if (BigInt(tx.nonce) !== BigInt(nonce)) p.push(`tx ${tx.hash} has nonce ${tx.nonce}, logged as ${nonce}`);
  if (BigInt(tx.value) !== 0n) p.push(`keeper tx ${tx.hash} moved ETH (${tx.value} wei)`);
  const to = (tx.to ?? "").toLowerCase();
  const sel = (tx.input ?? "0x").slice(0, 10).toLowerCase();
  const allowed = allowedCalls(cfg);
  if (!(to in allowed)) p.push(`keeper tx ${tx.hash} went to ${tx.to ?? "contract creation"}, not a game contract`);
  else if (!allowed[to].includes(sel)) p.push(`keeper tx ${tx.hash} called ${sel} on ${tx.to}, which the keeper never sends`);
  return p;
}

/** Detector 2 (fill quality): bps the actual fill fell short of the prior-block simulated quote (0 if it didn't). */
export function fillShortfallBps(actual, quoted) {
  if (quoted === 0n || actual >= quoted) return 0n;
  return ((quoted - actual) * BPS) / quoted;
}

/**
 * Detector 2b (fill vs the watcher's own 30-minute route-A average, review H1). Independent of the prior-block
 * simulation, so a price push one block earlier can't hide a bad fill. samples: [{ t, rate }] (rate as string/bigint,
 * buy-token wei per USDG unit x1e18, all of the token the fill bought). recentUsdg: keeper buys (any ledger) in the 10 minutes before this fill, which have
 * moved the price legitimately. Returns { ok: false, reason } if it can't judge, else { ok: true, shortBps, allowBps, bad }.
 */
export const MIN_SPAN_S = 1200;

/** Median of bigints (the mean of the two middle values for an even count). */
export function median(xs) {
  const v = [...xs].sort((a, b) => (a < b ? -1 : a > b ? 1 : 0));
  const m = Math.floor(v.length / 2);
  return v.length % 2 ? v[m] : (v[m - 1] + v[m]) / 2n;
}

export function fillVsAverage({ out, usdgIn, fillT, samples, recentUsdg = 0n, alertBps = 200n, sizeAllowBps = 100n, minSamples = 4 }) {
  const win = samples.filter((s) => s.t <= fillT && s.t > fillT - 1800);
  if (win.length < minSamples) return { ok: false, reason: `only ${win.length} price samples in the 30 min before the fill` };
  // review N5: the samples must span at least 20 of the 30 minutes, and the reference is the MEDIAN, so neither a
  // short burst of samples after a gap nor one manipulated sample sets it
  const oldest = Math.min(...win.map((s) => s.t));
  if (oldest > fillT - MIN_SPAN_S) return { ok: false, reason: `price samples span only ${Math.round((fillT - oldest) / 60)} min of the 30 before the fill` };
  const avg = median(win.map((s) => BigInt(s.rate)));
  if (avg === 0n || usdgIn === 0n) return { ok: false, reason: "zero average" };
  const rate = (out * 10n ** 18n) / usdgIn;
  const shortBps = rate >= avg ? 0n : ((avg - rate) * BPS) / avg;
  const allowBps = alertBps + (sizeAllowBps * (usdgIn + recentUsdg)) / MAX_CALL;
  return { ok: true, shortBps, allowBps, avg, rate, bad: shortBps > allowBps };
}

/** Detector 3 (floor gap): how far the floor sits below market, in bps; null means a stall (quote below floor). */
export function floorGapBps(quote, floor) {
  if (quote === 0n || quote < floor) return null;
  return ((quote - floor) * BPS) / quote;
}

/** The amount a ledger could swap now (for the gap check), or 0 if it doesn't count (too little, or no daily room). */
export function gapAmount(pending, swappedToday) {
  if (pending < MIN_CHUNK) return 0n;
  const room = swappedToday >= DAILY_CAP ? 0n : DAILY_CAP - swappedToday;
  let amt = pending < MAX_CALL ? pending : MAX_CALL;
  if (amt > room) amt = room;
  return amt < MIN_CHUNK ? 0n : amt;
}

/** Two checks in a row before alerting. Returns { strikes, fire }. */
export function strike(prev, bad) {
  const strikes = bad ? (prev ?? 0) + 1 : 0;
  return { strikes, fire: strikes === 2 };
}

/** Detector 5: ETH drop over roughly the last hour. samples = [{ t, bal }] (bal as string or bigint). */
export function ethDropLastHour(samples, now, bal) {
  const old = samples.filter((s) => s.t <= now - 3300).sort((a, b) => b.t - a.t)[0]; // newest sample >= 55 min old
  if (!old) return 0n;
  const prev = BigInt(old.bal);
  return prev > bal ? prev - bal : 0n;
}

/** Owner-level events and how loud they are. A planned action still alerts: whoever did it acknowledges it. */
export const OWNER_EVENTS = {
  // GameConfig: every queue and every execute goes to all signers at once (they have the 7-day delay to object)
  config: {
    CoreBound: "high",
    TokensQueued: "emergency",
    TokensCancelled: "high",
    TokensExecuted: "emergency",
    SplitQueued: "emergency",
    SplitCancelled: "high",
    SplitExecuted: "high",
    OwnershipTransferStarted: "emergency",
    OwnershipTransferred: "high",
  },
  core: {
    KeeperSet: "emergency", // a revoke (keeper = 0) is downgraded to high in the check
    OpQueued: "emergency",
    OpExecuted: "high",
    OpCancelled: "high",
    RatchetReset: "emergency",
    SalesPaused: "high",
    FairSet: "high",
    TollWithdrawn: "normal",
    ExcessSwept: "emergency",
    AlmsEscrowed: "high", // the alms Safe refused the transfer; the USDG waits in FairCore (M-4)
    OwnershipTransferStarted: "emergency",
    OwnershipTransferred: "high",
  },
  // M-4: Robin Among Thieves
  rat: {
    KeeperSet: "emergency", // a revoke (keeper = 0) is downgraded to high in the check
    OpQueued: "emergency",
    OpExecuted: "high",
    OpCancelled: "high",
    EntriesPaused: "high",
    SeedChainCommitted: "high", // the keeper's seed commits: expected at launch and at rotation only
    PairingLapsed: "high", // pairingLapses went up: nobody locked a revealed seed in time
    HouseSet: "high",
    BondsQueued: "emergency",
    BondsExecuted: "high",
    BondsCancelled: "high",
    ExcessSwept: "emergency",
    OwnershipTransferStarted: "emergency",
    OwnershipTransferred: "high",
  },
  // M-4: RakeBuyer (Bought fills are checked separately against the 30-min average)
  rakeBuyer: {
    KeeperSet: "emergency",
    OpQueued: "emergency", // SetForwardTo, ResetRatchet, SetRoute, SetKeeper
    OpExecuted: "high",
    OpCancelled: "high",
    RatchetReset: "emergency",
    ForwardToSet: "emergency", // forwards leave the vault path (M-3)
    ForwardFailed: "high", // K-C01: a leg stays ledgered
    RouteSet: "high",
    ExcessSwept: "emergency",
    OwnershipTransferStarted: "emergency",
    OwnershipTransferred: "high",
  },
  feeSplitter: {
    LegEscrowed: "high", // A3-09: a leg failed its stipend; claimEscrow retries it
    ChangeQueued: "emergency",
    ChangeExecuted: "high",
    ChangeCancelled: "high",
    RescueQueued: "emergency", // the owner pulling tokens out, 7-day delay to object
    Rescued: "high",
    OwnershipTransferStarted: "emergency",
    OwnershipTransferred: "high",
  },
  alms: {
    WindowsSet: "high",
    WindowsCleared: "high",
    EligibleSet: "normal",
    ReceiptPosted: "normal",
    OwnershipTransferStarted: "emergency",
    OwnershipTransferred: "high",
  },
  vault: {
    LauncherQueued: "emergency",
    LauncherCancelled: "high",
    LauncherAttached: "emergency",
    OwnershipTransferStarted: "emergency",
    OwnershipTransferred: "high",
  },
  pass: {
    ExcessSwept: "high",
    OwnershipTransferStarted: "emergency",
    OwnershipTransferred: "high",
  },
};
