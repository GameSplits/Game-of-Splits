// Vercel cron target (vercel.json: every 2 minutes). Vercel sends "Authorization: Bearer $CRON_SECRET".
// Dead-man switch (review H3): HEALTHCHECK_URL is pinged only after a clean pass, and at /fail on any error. A wrong
// or missing CRON_SECRET, a config error, a crash or a stopped cron all end in a missed ping, so the switch alerts.
import { loadConfig } from "../lib/config.mjs";
import { storeFromEnv } from "../lib/state.mjs";
import { makeAlerter } from "../lib/alerts.mjs";
import { runCheck } from "../lib/check.mjs";
import { errText } from "../lib/redact.mjs";
import { safeEqual, envAlerter, ping } from "../lib/http.mjs";

export async function GET(request) {
  const env = process.env;
  if (!env.CRON_SECRET || !safeEqual(request.headers.get("authorization") ?? "", `Bearer ${env.CRON_SECRET}`)) {
    return new Response("unauthorized", { status: 401 }); // no ping: the switch notices
  }
  const secrets = [env.RPC_URL, env.ARCHIVE_RPC_URL];
  let store = null;
  try {
    store = storeFromEnv(env); // first, so even a config error can be deduped
  } catch {
    store = null;
  }
  try {
    const cfg = loadConfig(env); // inside the try: a missing env var must alert too
    if (!store) store = storeFromEnv(env);
    const report = await runCheck(cfg, store, makeAlerter(cfg, "watcher"));
    if (report.skipped) return Response.json({ ok: true, skipped: report.skipped }); // the other pass pings
    await ping(cfg.healthcheckUrl, report.errors.length === 0);
    return Response.json({ ok: report.errors.length === 0, alerts: report.alerts.length, errors: report.errors, scanned: report.scanned, notes: report.notes, fills: report.fills });
  } catch (e) {
    const text = errText(e, secrets);
    await ping(env.HEALTHCHECK_URL, false);
    // one push per 30 min at most (M4); if even the store is down, the switch's /fail alert covers it
    let push = Boolean(store); // no store: the switch's own /fail alert is the only push (no storm)
    try {
      if (store) push = await store.lock("w:fail-alert", "1", 1800);
    } catch {
      push = false;
    }
    if (push) {
      try {
        await envAlerter(env)("high", "watcher pass failed", text);
      } catch {
        // no deliverable channel (N1): the /fail ping above is the alert
      }
    }
    return Response.json({ ok: false, error: text }, { status: 500 });
  }
}
