// The send log: after signing and before broadcasting, the keeper tells the watcher which tx it is about to send
// (nonce + hash + target + selector), HMAC-signed and, on GitHub Actions, with a fresh OIDC token (M7). The watcher's
// nonce check alerts on any keeper nonce with no matching, allowed, logged tx. If logging fails, the keeper does not send.
import { createHmac } from "node:crypto";

export function signBody(secret, body) {
  return createHmac("sha256", secret).update(body).digest("hex");
}

async function oidcToken(cfg) {
  if (!cfg.oidcRequestUrl || !cfg.oidcRequestToken) return null; // not on GitHub (local tests): the watcher decides
  const u = new URL(cfg.oidcRequestUrl);
  u.searchParams.set("audience", cfg.oidcAudience);
  const r = await fetch(u, { headers: { authorization: `bearer ${cfg.oidcRequestToken}` }, signal: AbortSignal.timeout(10_000) });
  if (!r.ok) throw new Error(`OIDC token request HTTP ${r.status}`);
  return (await r.json()).value;
}

export async function logSend(cfg, entry) {
  const body = JSON.stringify(entry);
  const headers = { "content-type": "application/json", "x-gos-signature": signBody(cfg.sendlogSecret, body) };
  const tok = await oidcToken(cfg);
  if (tok) headers["x-gos-oidc"] = tok;
  const r = await fetch(new URL("/api/sendlog", cfg.watcherUrl), { method: "POST", headers, body, signal: AbortSignal.timeout(15_000) });
  if (!r.ok) throw new Error(`send log refused: HTTP ${r.status}`);
}

export async function fetchPriceSamples(cfg) {
  if (!cfg.watcherUrl) return [];
  const r = await fetch(new URL("/api/price", cfg.watcherUrl), { signal: AbortSignal.timeout(15_000) });
  if (!r.ok) throw new Error(`price history HTTP ${r.status}`);
  const j = await r.json();
  // e = the GameConfig epoch the sample was taken in (absent on samples from before epochs were recorded: epoch 0)
  return (j.samples ?? []).map((s) => ({ t: Number(s.t), rate: BigInt(s.rate), e: BigInt(s.e ?? 0) }));
}
