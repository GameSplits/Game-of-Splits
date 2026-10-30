// Keeper configuration from the environment. Secrets (KEEPER_KEY, SENDLOG_SECRET, PUSHOVER_TOKEN) are never logged.
import { isAddress, isHex } from "viem";
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

export function loadConfig(env) {
  const dryRun = env.DRY_RUN !== "0"; // anything but an explicit "0" is a dry run
  const cfg = {
    rpcUrl: req(env, "RPC_URL"),
    chainId: Number(req(env, "CHAIN_ID")),
    core: addr(env, "CORE"),
    arrow: addr(env, "ARROW"),
    seat: addr(env, "SEAT"),
    alms: addr(env, "ALMS"),
    priceMode: env.PRICE_MODE ?? (Number(env.CHAIN_ID) === 4663 ? "v4quoter" : "testroute"),
    watcherUrl: env.WATCHER_URL ?? "",
    sendlogSecret: env.SENDLOG_SECRET ?? "",
    pushoverToken: env.PUSHOVER_TOKEN ?? "",
    pushoverGroup: env.PUSHOVER_GROUP ?? "",
    alertFile: env.ALERT_FILE ?? "", // tests: append alerts here instead of Pushover
    startDelayMaxS: Number(env.START_DELAY_MAX_S ?? 600),
    dryRun,
    key: env.KEEPER_KEY ?? "",
    // hard ceiling on maxFeePerGas (M6). `||`, not `??`: an unset GitHub var arrives as "" (review N6)
    maxFeeWei: (() => {
      const g = Number(env.MAX_FEE_GWEI || 1);
      if (!Number.isFinite(g) || g <= 0) throw new Error("MAX_FEE_GWEI must be a positive number");
      return BigInt(Math.round(g * 1e9));
    })(),
    // GitHub Actions OIDC for the send log (M7): on when the workflow has id-token: write
    oidcRequestUrl: env.ACTIONS_ID_TOKEN_REQUEST_URL ?? "",
    oidcRequestToken: env.ACTIONS_ID_TOKEN_REQUEST_TOKEN ?? "",
    oidcAudience: env.OIDC_AUDIENCE ?? "gos-watcher",
    keeperAddress: env.KEEPER_ADDRESS ?? "",
  };
  if (![4663, 46630].includes(cfg.chainId) && env.ALLOW_OTHER_CHAIN !== "1") throw new Error("CHAIN_ID must be 4663 or 46630");
  if (!["v4quoter", "testroute"].includes(cfg.priceMode)) throw new Error("PRICE_MODE must be v4quoter or testroute");
  if (cfg.key && !(isHex(cfg.key) && cfg.key.length === 66)) throw new Error("KEEPER_KEY must be a 32-byte hex key");
  if (!cfg.dryRun) {
    if (!cfg.key) throw new Error("live run needs KEEPER_KEY");
    if (!cfg.watcherUrl || !cfg.sendlogSecret) throw new Error("live run needs WATCHER_URL and SENDLOG_SECRET (the send log)");
  }
  checkAlertConfig(cfg); // N1: no deliverable alert channel = no keeper run
  if (!(cfg.maxFeeWei > 0n)) throw new Error("MAX_FEE_GWEI must be a positive number");
  if (!cfg.key && !isAddress(cfg.keeperAddress)) throw new Error("dry run without KEEPER_KEY needs KEEPER_ADDRESS");
  return cfg;
}
