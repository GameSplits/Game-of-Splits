// The keeper POSTs { chainId, nonce, hash, to, selector, sentAt } here after signing and before broadcasting.
// x-gos-signature = HMAC-SHA256(SENDLOG_SECRET, body); x-gos-oidc = a fresh GitHub Actions OIDC token (M7).
import { loadConfig } from "../lib/config.mjs";
import { storeFromEnv } from "../lib/state.mjs";
import { makeAlerter } from "../lib/alerts.mjs";
import { handleSendlog } from "../lib/sendlog.mjs";

const MAX_BODY = 2048;

export async function POST(request) {
  if (Number(request.headers.get("content-length") ?? MAX_BODY + 1) > MAX_BODY) return Response.json({ error: "too large" }, { status: 413 }); // L2
  const body = await request.text();
  if (body.length > MAX_BODY) return Response.json({ error: "too large" }, { status: 413 });
  const cfg = loadConfig(process.env);
  const r = await handleSendlog(cfg, storeFromEnv(process.env), body, {
    sig: request.headers.get("x-gos-signature"), oidc: request.headers.get("x-gos-oidc"),
  }, { alert: makeAlerter(cfg, "watcher") });
  return Response.json(r.body, { status: r.status });
}
