// GitHub Actions OIDC check for the send log (review M7). The keeper's workflow has `id-token: write` and sends a fresh
// OIDC token with every send-log entry. The watcher verifies it against GitHub's public keys and pins the repo, the
// workflow file on main, the trigger and a short age. A key + SENDLOG_SECRET stolen and used OFF GitHub can't log, so
// its txs fail the nonce check (D1). A malicious commit on main still logs, but shows up as a new `sha` (alert).
import { createPublicKey, verify as cryptoVerify } from "node:crypto";

export const GITHUB_ISSUER = "https://token.actions.githubusercontent.com";
const JWKS_URL = `${GITHUB_ISSUER}/.well-known/jwks`;
const MAX_AGE_S = 600;

const b64url = (s) => Buffer.from(s.replace(/-/g, "+").replace(/_/g, "/"), "base64");

let jwksCache = null;
export async function githubJwks(fetchImpl = fetch) {
  if (jwksCache && jwksCache.at > Date.now() - 3600_000) return jwksCache.keys;
  const r = await fetchImpl(JWKS_URL);
  if (!r.ok) throw new Error(`jwks HTTP ${r.status}`);
  jwksCache = { at: Date.now(), keys: (await r.json()).keys };
  return jwksCache.keys;
}

/**
 * Verify a GitHub OIDC JWT. Returns { ok: true, claims } or { ok: false, reason }.
 * cfg: { oidcAudience, oidcRepository, oidcWorkflow, oidcRef }. getKeys: () => [jwk] (injectable for tests).
 */
export async function verifyGithubOidc(token, cfg, { getKeys = githubJwks, nowS = Math.floor(Date.now() / 1000) } = {}) {
  if (typeof token !== "string" || token.split(".").length !== 3) return { ok: false, reason: "no token" };
  const [h, p, sig] = token.split(".");
  let header, claims;
  try {
    header = JSON.parse(b64url(h).toString("utf8"));
    claims = JSON.parse(b64url(p).toString("utf8"));
  } catch {
    return { ok: false, reason: "malformed token" };
  }
  const isObj = (v) => !!v && typeof v === "object" && !Array.isArray(v);
  if (!isObj(header) || !isObj(claims)) return { ok: false, reason: "malformed token" };
  if (header.alg !== "RS256") return { ok: false, reason: `alg ${header.alg}` };
  const jwk = (await getKeys()).find((k) => k.kid === header.kid);
  if (!jwk) return { ok: false, reason: "unknown kid" };
  const good = cryptoVerify("RSA-SHA256", Buffer.from(`${h}.${p}`), createPublicKey({ key: jwk, format: "jwk" }), b64url(sig));
  if (!good) return { ok: false, reason: "bad signature" };
  const wantWorkflow = `${cfg.oidcRepository}/${cfg.oidcWorkflow}@${cfg.oidcRef}`;
  const checks = [
    [claims.iss === GITHUB_ISSUER, "issuer"],
    [claims.aud === cfg.oidcAudience || (Array.isArray(claims.aud) && claims.aud.includes(cfg.oidcAudience)), "audience"],
    [typeof claims.exp === "number" && claims.exp > nowS, "expired"],
    [typeof claims.iat === "number" && claims.iat <= nowS + 60 && nowS - claims.iat <= MAX_AGE_S, "too old"],
    [claims.repository === cfg.oidcRepository, `repository ${claims.repository}`],
    [claims.job_workflow_ref === wantWorkflow, `workflow ${claims.job_workflow_ref}`],
    [claims.ref === cfg.oidcRef, `ref ${claims.ref}`],
    [claims.event_name === "schedule" || claims.event_name === "workflow_dispatch", `event ${claims.event_name}`],
  ];
  const bad = checks.find(([ok]) => !ok);
  return bad ? { ok: false, reason: bad[1] } : { ok: true, claims };
}
