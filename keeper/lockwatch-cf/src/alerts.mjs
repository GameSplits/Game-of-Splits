const PRIORITY = { emergency: 2, high: 1, normal: 0 };
export const PUSHOVER_API = "https://api.pushover.net/1/messages.json";

export function makeAlerter(cfg, source, log) {
  const can = cfg.alertFile || (cfg.pushoverToken && cfg.pushoverGroup);
  if (!can) return null;
  return async function alert(level, title, message) {
    const rec = { t: Math.floor(Date.now() / 1000), source, level, title, message };
    log(`ALERT ${level}: ${title} | ${message}`);
    if (cfg.alertFile) {
      // Workers have no local files; alertFile means "log only" here (tests).
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
    const r = await fetch(PUSHOVER_API, { method: "POST", body, signal: AbortSignal.timeout(10_000) });
    let j = null;
    try { j = await r.json(); } catch { j = null; }
    if (!r.ok || j?.status !== 1) throw new Error(`pushover refused: HTTP ${r.status}`);
  };
}
