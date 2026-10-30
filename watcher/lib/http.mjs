// Shared pieces of the Vercel handlers.
import { createHash, timingSafeEqual } from "node:crypto";
import { makeAlerter } from "./alerts.mjs";

/** Timing-safe string compare (L1): compares SHA-256 digests, so lengths never leak either. */
export function safeEqual(a, b) {
  const h = (s) => createHash("sha256").update(String(s)).digest();
  return timingSafeEqual(h(a), h(b));
}

/** An alerter built straight from env, for when loadConfig itself failed (H3). */
export function envAlerter(env) {
  return makeAlerter({
    pushoverToken: env.PUSHOVER_TOKEN ?? "", pushoverGroup: env.PUSHOVER_GROUP ?? "", alertFile: env.ALERT_FILE ?? "",
    rpcUrl: env.RPC_URL, archiveRpcUrl: env.ARCHIVE_RPC_URL, sendlogSecret: env.SENDLOG_SECRET, cronSecret: env.CRON_SECRET,
  }, "watcher");
}

/** Ping the dead-man switch: the plain URL on a clean pass, URL + "/fail" on any error. Never throws. */
export async function ping(url, ok) {
  if (!url) return;
  try {
    await fetch(ok ? url : `${url.replace(/\/$/, "")}/fail`, { method: "POST", signal: AbortSignal.timeout(5000) });
  } catch {
    // the switch's own grace period covers a missed ping
  }
}
