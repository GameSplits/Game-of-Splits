import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { createHmac, generateKeyPairSync, sign as rsaSign } from "node:crypto";
import { handleSendlog, sendlogKey } from "../lib/sendlog.mjs";
import { verifyGithubOidc } from "../lib/oidc.mjs";
import { fileStore } from "../lib/state.mjs";

const NOW = 1_800_000_000;
const CORE = "0x2222222222222222222222222222222222222222";
const base = {
  chainId: 4663, sendlogSecret: "s3cret", oidcRequired: false, core: CORE,
  arrow: "0x3333333333333333333333333333333333333333", seat: "0x4444444444444444444444444444444444444444", alms: "0x5555555555555555555555555555555555555555",
  rat: "0x6666666666666666666666666666666666666666", rakeBuyer: "0x7777777777777777777777777777777777777777",
  oidcRepository: "GameSplits/gos-keeper", oidcWorkflow: ".github/workflows/keeper.yml", oidcRef: "refs/heads/main", oidcAudience: "gos-watcher",
};
const sign = (b) => createHmac("sha256", "s3cret").update(b).digest("hex");
const entry = (nonce, hash, extra = {}) => JSON.stringify({ chainId: 4663, nonce, hash, to: CORE, selector: "0x2d7fd3b8", sentAt: NOW, ...extra });
const H1 = "0x" + "aa".repeat(32);
const H2 = "0x" + "bb".repeat(32);
const store = () => fileStore(join(mkdtempSync(join(tmpdir(), "gos-")), "s.json"));
const post = (cfg, st, b, h = {}, deps = {}) => handleSendlog(cfg, st, b, { sig: sign(b), ...h }, { nowS: NOW, ...deps });

test("send log: signature required; entries append per nonce, never overwrite (M1)", async () => {
  const st = store();
  const b1 = entry(3, H1);
  assert.equal((await handleSendlog(base, st, b1, { sig: "00".repeat(32) }, { nowS: NOW })).status, 401);
  assert.equal((await handleSendlog(base, st, b1, {}, { nowS: NOW })).status, 401);
  assert.equal((await post(base, st, b1)).status, 200);
  assert.equal((await post(base, st, entry(3, H2))).status, 200); // an honest re-sign of nonce 3
  assert.equal((await post(base, st, b1)).body.dup, true);
  const list = await st.lrange(sendlogKey(4663, 3));
  assert.deepEqual(list.map((e) => e.hash), [H1, H2]);
});

test("send log refuses calls the keeper never makes, wrong chains, stale or future times (L8)", async () => {
  const st = store();
  assert.equal((await post(base, st, entry(1, H1, { selector: "0xa9059cbb" }))).status, 400);
  assert.equal((await post(base, st, entry(1, H1, { to: "0x9999999999999999999999999999999999999999" }))).status, 400);
  assert.equal((await post(base, st, entry(1, H1, { to: base.arrow }))).status, 400); // burnBuyToken isn't an Arrow call
  assert.equal((await post(base, st, entry(1, H1, { to: base.arrow, selector: "0x8df82800" }))).status, 200); // settle is
  assert.equal((await post(base, st, entry(1, H1, { chainId: 1 }))).status, 400);
  assert.equal((await post(base, st, entry(1, H2, { sentAt: NOW - 3600 }))).status, 400);
  assert.equal((await post(base, st, entry(1, H2, { sentAt: NOW + 3600 }))).status, 400);
});

// ---------------------------------------------------------------- OIDC (M7)
const { publicKey, privateKey } = generateKeyPairSync("rsa", { modulusLength: 2048 });
const jwk = { ...publicKey.export({ format: "jwk" }), kid: "k1", alg: "RS256", use: "sig" };
const b64 = (o) => Buffer.from(JSON.stringify(o)).toString("base64url");
function jwt(claims, { kid = "k1", key = privateKey } = {}) {
  const h = b64({ alg: "RS256", typ: "JWT", kid });
  const p = b64(claims);
  return `${h}.${p}.${rsaSign("RSA-SHA256", Buffer.from(`${h}.${p}`), key).toString("base64url")}`;
}
const good = {
  iss: "https://token.actions.githubusercontent.com", aud: "gos-watcher", iat: NOW - 30, exp: NOW + 270,
  repository: "GameSplits/gos-keeper", ref: "refs/heads/main", event_name: "schedule", sha: "abc123", run_id: "9",
  job_workflow_ref: "GameSplits/gos-keeper/.github/workflows/keeper.yml@refs/heads/main",
};
const opts = { getKeys: async () => [jwk], nowS: NOW };

test("OIDC: a token from the keeper workflow on main passes; anything else fails", async () => {
  assert.equal((await verifyGithubOidc(jwt(good), base, opts)).ok, true);
  assert.equal((await verifyGithubOidc(jwt({ ...good, event_name: "workflow_dispatch" }), base, opts)).ok, true);
  const bad = {
    "other repo": { repository: "evil/fork" },
    "other branch": { ref: "refs/heads/dev", job_workflow_ref: "GameSplits/gos-keeper/.github/workflows/keeper.yml@refs/heads/dev" },
    "other workflow": { job_workflow_ref: "GameSplits/gos-keeper/.github/workflows/x.yml@refs/heads/main" },
    "pull request": { event_name: "pull_request" },
    expired: { exp: NOW - 1 },
    "too old": { iat: NOW - 3600 },
    audience: { aud: "someone-else" },
    issuer: { iss: "https://evil.example" },
  };
  for (const [why, over] of Object.entries(bad)) assert.equal((await verifyGithubOidc(jwt({ ...good, ...over }), base, opts)).ok, false, why);
  const other = generateKeyPairSync("rsa", { modulusLength: 2048 }).privateKey;
  assert.equal((await verifyGithubOidc(jwt(good, { key: other }), base, opts)).reason, "bad signature");
  assert.equal((await verifyGithubOidc(jwt(good, { kid: "nope" }), base, opts)).reason, "unknown kid");
  assert.equal((await verifyGithubOidc("x.y", base, opts)).ok, false);
  for (const odd of [null, 7, "x", [1]]) assert.equal((await verifyGithubOidc(jwt(odd), base, opts)).reason, "malformed token", JSON.stringify(odd));
});

test("OIDC required: entries without a valid token are refused; a new commit sha alerts once", async () => {
  const cfg = { ...base, oidcRequired: true };
  const st = store();
  const alerts = [];
  const deps = { oidcOpts: { getKeys: async () => [jwk] }, alert: async (...a) => alerts.push(a) };
  assert.equal((await post(cfg, st, entry(1, H1), {}, deps)).status, 401);
  assert.equal((await post(cfg, st, entry(1, H1), { oidc: jwt({ ...good, repository: "evil/x" }) }, deps)).status, 401);
  assert.equal((await post(cfg, st, entry(1, H1), { oidc: jwt(good) }, deps)).status, 200);
  assert.equal(alerts.length, 0, "first sha is the baseline");
  assert.equal((await post(cfg, st, entry(2, H2), { oidc: jwt({ ...good, sha: "def456" }) }, deps)).status, 200);
  assert.equal(alerts.length, 1);
  assert.equal(alerts[0][1], "keeper code changed");
  assert.equal((await post(cfg, st, entry(3, H2), { oidc: jwt(null) }, deps)).status, 401, "null claims get a clean 401");
});
