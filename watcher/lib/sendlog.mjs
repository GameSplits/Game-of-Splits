// The keeper's send log endpoint logic. Before broadcasting, the keeper POSTs {chainId, nonce, hash, to, selector,
// sentAt}, signed with x-gos-signature = HMAC-SHA256(SENDLOG_SECRET, body) and, on GitHub, a fresh OIDC token in
// x-gos-oidc. Entries go in an append-only list per nonce (w:sendlog:<chainId>:<nonce>), so an honest re-sign of the
// same nonce (broadcast failed after logging) is kept beside the first entry and the nonce check accepts either (M1).
// Bad entries are refused here (L8): wrong chain, a call the keeper never makes, a stale or future sentAt.
import { createHmac, timingSafeEqual } from "node:crypto";
import { isHash, isAddress } from "viem";
import { allowedCalls } from "./detectors.mjs";
import { verifyGithubOidc } from "./oidc.mjs";

const MAX_PER_NONCE = 10;
const MAX_SKEW_S = 600;

export function verifySignature(secret, body, sig) {
  if (!secret || typeof sig !== "string" || !/^[0-9a-f]{64}$/.test(sig)) return false;
  const want = Buffer.from(createHmac("sha256", secret).update(body).digest("hex"), "hex");
  return timingSafeEqual(want, Buffer.from(sig, "hex"));
}

export const sendlogKey = (chainId, nonce) => `w:sendlog:${chainId}:${nonce}`;

/** headers: { sig, oidc }. deps: { alert, oidcOpts, nowS } (tests inject). Returns { status, body }. */
export async function handleSendlog(cfg, store, body, headers, deps = {}) {
  const nowS = deps.nowS ?? Math.floor(Date.now() / 1000);
  if (!verifySignature(cfg.sendlogSecret, body, headers?.sig)) return { status: 401, body: { error: "bad signature" } };
  let claims = null;
  if (cfg.oidcRequired) {
    const v = await verifyGithubOidc(headers?.oidc, cfg, { ...(deps.oidcOpts ?? {}), nowS });
    if (!v.ok) return { status: 401, body: { error: `oidc: ${v.reason}` } };
    claims = v.claims;
  }
  let e;
  try {
    e = JSON.parse(body);
  } catch {
    return { status: 400, body: { error: "bad json" } };
  }
  if (e.chainId !== cfg.chainId || !Number.isInteger(e.nonce) || e.nonce < 0 || !isHash(e.hash) || !isAddress(e.to) || !/^0x[0-9a-f]{8}$/i.test(e.selector ?? "")) {
    return { status: 400, body: { error: "bad entry" } };
  }
  const allowed = allowedCalls(cfg)[e.to.toLowerCase()];
  if (!allowed || !allowed.includes(e.selector.toLowerCase())) return { status: 400, body: { error: "not a call the keeper makes" } };
  if (!Number.isFinite(e.sentAt) || Math.abs(e.sentAt - nowS) > MAX_SKEW_S) return { status: 400, body: { error: "sentAt not fresh" } };

  const key = sendlogKey(cfg.chainId, e.nonce);
  const list = await store.lrange(key);
  if (list.some((x) => x.hash.toLowerCase() === e.hash.toLowerCase())) return { status: 200, body: { ok: true, dup: true } };
  if (list.length >= MAX_PER_NONCE) return { status: 429, body: { error: "too many entries for this nonce" } };
  await store.rpush(key, {
    hash: e.hash, to: e.to, selector: e.selector.toLowerCase(), sentAt: e.sentAt, loggedAt: nowS,
    ...(claims ? { sha: claims.sha, runId: claims.run_id } : {}),
  });

  // A new commit running the keeper is worth a look: a malicious commit on main would still pass OIDC.
  if (claims?.sha) {
    const prev = await store.get("w:keeper-sha");
    if (prev !== claims.sha) {
      await store.set("w:keeper-sha", claims.sha);
      if (prev && deps.alert) await deps.alert("high", "keeper code changed", `The keeper now runs commit ${claims.sha} (was ${prev}), run ${claims.run_id}. If nobody merged a change, revoke.`);
    }
  }
  return { status: 200, body: { ok: true } };
}

/** All logged entries for a nonce (the nonce check accepts any of them that matches the mined tx). */
export const entriesFor = (store, chainId, nonce) => store.lrange(sendlogKey(chainId, nonce));
