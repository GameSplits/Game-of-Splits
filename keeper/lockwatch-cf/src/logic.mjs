// Port of keeper/src/lockwatch.mjs planRound / constants. Pure, no chain I/O.
export const PAIR_DEADLINE = 180n;
export const FALLBACK_END = 420n;
export const PAIR_LATE_DEADLINE = 480n;
export const HASH_WINDOW = 256n;
export const PAIR_STEPS = 256n;
export const STATUS = { Open: 0, Paired: 1, Settled: 2, Finalized: 3, Cancelled: 4 };
export const ZERO = "0x" + "0".repeat(64);

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
  if (nowL2 - at >= HASH_WINDOW) return { action: "lapsed", why: "reveal block hash gone" };
  return { action: "lockPairing", why: "seed revealed, not locked" };
}

export function afterRevert(action, round) {
  if (action === "lockPairing") return round.seedMixed ? "raced" : "failed";
  if (action === "fallbackSeed") return round.pairingSeed !== ZERO ? "raced" : "failed";
  if (action === "pair") return Number(round.status) !== STATUS.Open ? "raced" : "failed";
  return "failed";
}

/** Send failures that mean another sender already used this nonce or this tx is already in the pool. */
export const NONCE_RACE = /nonce too low|already known|replacement transaction underpriced|nonce has already been used|known transaction/i;

/**
 * After eth_sendRawTransaction throws: "raced" if the round already moved past this step (another caller did it),
 * "nonce" if the RPC reports a nonce or duplicate race and the round is still waiting (retry next tick, no page),
 * else "failed" (page).
 */
export function afterSendFailure(action, round, message) {
  if (afterRevert(action, round) === "raced") return "raced";
  if (NONCE_RACE.test(String(message || ""))) return "nonce";
  return "failed";
}

/** Addresses this worker must never send from (the keeper, the deployer): one sender per key. */
export function parseForbidden(list) {
  return String(list || "")
    .split(",")
    .map((a) => a.trim().toLowerCase())
    .filter(Boolean);
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
    pushoverToken: env.PUSHOVER_TOKEN ?? "",
    pushoverGroup: env.PUSHOVER_GROUP ?? "",
    alertFile: env.ALERT_FILE ?? "",
    noAlerts: env.NO_ALERTS === "1",
    forbidSenders: parseForbidden(env.FORBID_SENDERS),
  };
  for (const a of cfg.forbidSenders) {
    if (!/^0x[0-9a-f]{40}$/.test(a)) throw new Error("FORBID_SENDERS must be comma-separated addresses");
  }
  if (!/^0x[0-9a-fA-F]{40}$/.test(cfg.rat)) throw new Error("env RAT is not an address");
  if (![4663, 46630].includes(cfg.chainId)) throw new Error("CHAIN_ID must be 4663 or 46630");
  if (cfg.key && !(/^0x[0-9a-fA-F]{64}$/.test(cfg.key))) throw new Error("LOCKWATCH_KEY must be a 32-byte hex key");
  if (!cfg.dryRun && !cfg.key) throw new Error("live run needs LOCKWATCH_KEY");
  const canAlert = cfg.alertFile || (cfg.pushoverToken && cfg.pushoverGroup);
  if (!cfg.dryRun && !canAlert && !cfg.noAlerts) {
    throw new Error("live run needs PUSHOVER_TOKEN / PUSHOVER_GROUP or ALERT_FILE (or NO_ALERTS=1)");
  }
  if (!(cfg.pollMs >= 500)) throw new Error("POLL_MS must be at least 500");
  if (!(cfg.maxFeeWei > 0n)) throw new Error("MAX_FEE_GWEI must be a positive number");
  return cfg;
}
