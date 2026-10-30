// Alerts: Pushover (priority 2 = emergency, repeats every 30 s until acknowledged; 1 = high; 0 = normal), or a JSONL
// file in tests. Always also printed to stdout without secrets.
// FAILS CLOSED (review N1): with no Pushover config and no ALERT_FILE the alerter refuses to exist, and a send that
// Pushover doesn't confirm (HTTP 200 and {status: 1}) THROWS. Callers turn that into a /fail ping (watcher) or a
// failed job (keeper), so a dead alert channel can never look healthy. Shared with keeper/src/alerts.mjs.
import { appendFileSync } from "node:fs";
import { redact } from "./redact.mjs";

const PRIORITY = { emergency: 2, high: 1, normal: 0 };
export const PUSHOVER_API = "https://api.pushover.net/1/messages.json";

/** Throws if alerts couldn't be delivered anywhere. Call from loadConfig. */
export function checkAlertConfig(cfg) {
  if (cfg.alertFile) return;
  if (!cfg.pushoverToken || !cfg.pushoverGroup) throw new Error("missing env PUSHOVER_TOKEN / PUSHOVER_GROUP (alerts must be deliverable)");
}

export function makeAlerter(cfg, source) {
  checkAlertConfig(cfg);
  const secrets = [cfg.rpcUrl, cfg.archiveRpcUrl, cfg.pushoverToken, cfg.pushoverGroup, cfg.sendlogSecret, cfg.cronSecret, cfg.key];
  return async function alert(level, rawTitle, rawMessage) {
    // last line of defence: nothing secret-shaped (RPC URLs with keys, tokens) ever leaves in an alert
    const title = redact(rawTitle, secrets);
    const message = redact(rawMessage, secrets);
    const rec = { t: Math.floor(Date.now() / 1000), source, level, title, message };
    console.log(`ALERT ${level}: ${title} | ${message}`);
    if (cfg.alertFile) {
      appendFileSync(cfg.alertFile, JSON.stringify(rec) + "\n");
      return;
    }
    const body = new URLSearchParams({
      token: cfg.pushoverToken,
      user: cfg.pushoverGroup,
      title: `GoS ${source}: ${title}`.slice(0, 250),
      message: (message || title).slice(0, 1024),
      priority: String(PRIORITY[level] ?? 0),
    });
    if (level === "emergency") {
      body.set("retry", "30");
      body.set("expire", "3600");
    }
    let r;
    try {
      r = await fetch(PUSHOVER_API, { method: "POST", body, signal: AbortSignal.timeout(10_000) });
    } catch (e) {
      throw new Error(`pushover unreachable: ${redact(e.message, secrets)}`);
    }
    let j = null;
    try {
      j = await r.json();
    } catch {
      j = null;
    }
    if (!r.ok || j?.status !== 1) throw new Error(`pushover refused: HTTP ${r.status}${j?.errors ? ` ${redact(JSON.stringify(j.errors), secrets)}` : ""}`);
  };
}
