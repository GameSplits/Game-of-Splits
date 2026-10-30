// Watcher configuration. It holds no private key and no GitHub credential.
import { isAddress } from "viem";
import { checkAlertConfig } from "./alerts.mjs";

const req = (env, k) => {
  const v = env[k];
  if (v === undefined || v === "") throw new Error(`missing env ${k}`);
  return v;
};
const addr = (env, k) => {
  const v = req(env, k);
  if (!isAddress(v)) throw new Error(`env ${k} is not an address`);
  return v;
};
const optAddr = (env, k) => {
  const v = env[k];
  if (v === undefined || v === "") return "";
  if (!isAddress(v)) throw new Error(`env ${k} is not an address`);
  return v;
};

export function loadConfig(env) {
  const chainId = Number(req(env, "CHAIN_ID"));
  const cfg = {
    rpcUrl: req(env, "RPC_URL"),
    archiveRpcUrl: env.ARCHIVE_RPC_URL || req(env, "RPC_URL"), // the fill check runs eth_call at past blocks
    chainId,
    core: addr(env, "CORE"),
    arrow: addr(env, "ARROW"),
    seat: addr(env, "SEAT"),
    alms: addr(env, "ALMS"),
    pass: addr(env, "PASS"),
    vault: addr(env, "VAULT"),
    // M-4: Robin Among Thieves and RakeBuyer (deployed by Deploy.s.sol with the rest), FeeSplitter only if deployed
    rat: addr(env, "RAT"),
    rakeBuyer: addr(env, "RAKE_BUYER"),
    feeSplitter: optAddr(env, "FEE_SPLITTER"),
    keeper: addr(env, "KEEPER"), // the expected keeper address; update it when the Safe rotates the key
    startBlock: BigInt(req(env, "START_BLOCK")), // L2 block from deployments/<chainId>.json
    priceMode: env.PRICE_MODE ?? (chainId === 4663 ? "v4quoter" : "testroute"),
    sendlogSecret: env.SENDLOG_SECRET ?? "",
    cronSecret: env.CRON_SECRET ?? "",
    pushoverToken: env.PUSHOVER_TOKEN ?? "",
    pushoverGroup: env.PUSHOVER_GROUP ?? "",
    alertFile: env.ALERT_FILE ?? "",
    // REQUIRED dead-man switch (review H3): healthchecks.io (period 2 min, grace 10 min) wired to Pushover. Pinged on
    // a clean pass, pinged at /fail on any error, and silent if the cron stops or is refused (wrong CRON_SECRET).
    healthcheckUrl: req(env, "HEALTHCHECK_URL"),
    // the keeper's nonce at go-live (0 for a fresh key): the nonce check's baseline if w:nonce is ever missing (H4)
    nonceStart: BigInt(req(env, "NONCE_START")),
    goLiveAt: BigInt(env.GO_LIVE_AT ?? 0), // unix time of DRY_RUN=0; the heartbeat uses it before the first swap (M9)
    confirmations: BigInt(env.CONFIRMATIONS ?? 5), // events are read up to head - this (L3)
    maintenanceUntil: Number(env.MAINTENANCE_UNTIL ?? 0), // owner events before this time go into one digest (M4)
    fillAvgAlertBps: BigInt(env.FILL_AVG_ALERT_BPS ?? 200), // fill vs the 30-min average: 2% ...
    fillSizeAllowBps: BigInt(env.FILL_SIZE_ALLOW_BPS ?? 100), // ... + 1% per 250 USDG of keeper buys in the last 10 min
    // GitHub OIDC on the send log (M7). Required unless OIDC_REQUIRED=0 (local tests only).
    oidcRequired: env.OIDC_REQUIRED !== "0",
    oidcRepository: env.OIDC_REPOSITORY ?? "",
    oidcWorkflow: env.OIDC_WORKFLOW ?? ".github/workflows/keeper.yml",
    oidcRef: env.OIDC_REF ?? "refs/heads/main",
    oidcAudience: env.OIDC_AUDIENCE ?? "gos-watcher",
    gapAlertBps: BigInt(env.GAP_ALERT_BPS ?? 1000), // floor more than 10% below market
    fillAlertBps: BigInt(env.FILL_ALERT_BPS ?? 200), // fill more than 2% below the prior-block quote
    ethDropMaxWei: BigInt(env.ETH_DROP_MAX_WEI_PER_HOUR ?? 1_000_000_000_000_000), // 0.001 ETH per hour
    heartbeatS: BigInt(env.HEARTBEAT_S ?? 3 * 3600), // pending work but no keeper swap for 3h
    maxRange: BigInt(env.MAX_BLOCK_RANGE ?? 200_000), // per run; the watcher catches up over several runs
  };
  checkAlertConfig(cfg); // N1: no deliverable alert channel = no watcher
  if (cfg.oidcRequired && !cfg.oidcRepository) throw new Error("missing env OIDC_REPOSITORY (owner/repo of the keeper)");
  return cfg;
}
