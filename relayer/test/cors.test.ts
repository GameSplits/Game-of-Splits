import assert from "node:assert/strict";
import test from "node:test";
import { isAllowedOrigin, loadOrigins } from "../src/config.ts";
import { corsHeaders } from "../src/http.ts";

test("defaults allow the live site and gos-testnet / gos-staging previews only", () => {
  const p = loadOrigins({});
  assert.equal(isAllowedOrigin("https://testnet.gameofsplits.fun", p), true);
  assert.equal(isAllowedOrigin("https://gos-testnet.vercel.app", p), true);
  assert.equal(isAllowedOrigin("https://gos-testnet-abc123xyz-game-of-splits.vercel.app", p), true);
  assert.equal(isAllowedOrigin("https://gos-testnet-git-preview-a-game-of-splits.vercel.app", p), true);
  assert.equal(isAllowedOrigin("https://gos-staging-git-preview-b-game-of-splits.vercel.app", p), true);
  assert.equal(isAllowedOrigin("https://evil.example", p), false);
  assert.equal(isAllowedOrigin("https://gos-testnet-abc-game-of-splits.vercel.app.evil.example", p), false);
  assert.equal(isAllowedOrigin("http://gos-testnet-abc-game-of-splits.vercel.app", p), false);
  assert.equal(isAllowedOrigin("https://other-abc-game-of-splits.vercel.app", p), false);
});

test("ALLOW_ORIGIN replaces the exact list and the pattern can be turned off", () => {
  const p = loadOrigins({ ALLOW_ORIGIN: "https://a.example, https://b.example/", ALLOW_ORIGIN_PATTERN: "off" });
  assert.deepEqual(p.exact, ["https://a.example", "https://b.example"]);
  assert.equal(p.pattern, null);
  assert.equal(isAllowedOrigin("https://b.example", p), true);
  assert.equal(isAllowedOrigin("https://gos-testnet-abc-game-of-splits.vercel.app", p), false);
});

test("a wildcard or an unanchored pattern is refused", () => {
  assert.throws(() => loadOrigins({ ALLOW_ORIGIN: "*" }));
  assert.throws(() => loadOrigins({ ALLOW_ORIGIN: "https://ok.example/path" }));
  assert.throws(() => loadOrigins({ ALLOW_ORIGIN_PATTERN: "gos-testnet" }));
});

test("only an allowed origin is echoed back", () => {
  const p = loadOrigins({});
  const ok = corsHeaders("https://testnet.gameofsplits.fun", p);
  assert.equal(ok["access-control-allow-origin"], "https://testnet.gameofsplits.fun");
  assert.equal(ok.vary, "Origin");
  const bad = corsHeaders("https://evil.example", p);
  assert.equal(bad["access-control-allow-origin"], undefined);
  assert.equal(corsHeaders(null, p)["access-control-allow-origin"], undefined);
});
