import assert from "node:assert/strict";
import test from "node:test";
import { isAllowedOrigin, loadOrigins } from "../src/config.ts";
import { corsHeaders } from "../src/http.ts";

test("defaults allow the live site and gos-testnet / gos-staging previews only", () => {
  const p = loadOrigins({ CHAIN_ID: "46630" });
  assert.equal(isAllowedOrigin("https://testnet.gameofsplits.fun", p), true);
  assert.equal(isAllowedOrigin("https://gos-testnet.vercel.app", p), true);
  assert.equal(isAllowedOrigin("https://gos-testnet-abc123xyz-game-of-splits.vercel.app", p), true);
  assert.equal(isAllowedOrigin("https://gos-testnet-git-preview-a-game-of-splits.vercel.app", p), true);
  assert.equal(isAllowedOrigin("https://gos-staging-git-preview-b-game-of-splits.vercel.app", p), true);
  assert.equal(isAllowedOrigin("https://evil.example", p), false);
  assert.equal(isAllowedOrigin("https://gos-testnet-abc-game-of-splits.vercel.app.evil.example", p), false);
  assert.equal(isAllowedOrigin("http://gos-testnet-abc-game-of-splits.vercel.app", p), false);
  assert.equal(isAllowedOrigin("https://other-abc-game-of-splits.vercel.app", p), false);
  assert.equal(isAllowedOrigin("https://gos-testnet-abc-evil-team.vercel.app", p), false);
});

test("ALLOW_ORIGIN and ALLOWED_ORIGINS replace the exact list and the pattern can be turned off", () => {
  const p = loadOrigins({ CHAIN_ID: "46630", ALLOW_ORIGIN: "https://a.example, https://b.example/", ALLOW_ORIGIN_PATTERN: "off" });
  assert.deepEqual(p.exact, ["https://a.example", "https://b.example"]);
  assert.equal(p.pattern, null);
  assert.equal(isAllowedOrigin("https://b.example", p), true);
  assert.equal(isAllowedOrigin("https://gos-testnet-abc-game-of-splits.vercel.app", p), false);
  const alias = loadOrigins({ CHAIN_ID: "46630", ALLOWED_ORIGINS: "https://c.example", ALLOW_ORIGIN_PATTERN: "off" });
  assert.deepEqual(alias.exact, ["https://c.example"]);
});

test("mainnet chain id loads no preview pattern and defaults to the mainnet site only", () => {
  const p = loadOrigins({ CHAIN_ID: "4663" });
  assert.equal(p.pattern, null);
  assert.deepEqual(p.exact, ["https://gameofsplits.fun", "https://www.gameofsplits.fun"]);
  assert.equal(isAllowedOrigin("https://gameofsplits.fun", p), true);
  assert.equal(isAllowedOrigin("https://testnet.gameofsplits.fun", p), false);
  assert.equal(isAllowedOrigin("https://gos-testnet-abc-game-of-splits.vercel.app", p), false);
  const explicit = loadOrigins(
    {
      ALLOWED_ORIGINS: "https://gameofsplits.fun,https://www.gameofsplits.fun",
      ALLOW_ORIGIN_PATTERN: "^https://gos-testnet-[a-z0-9-]+-game-of-splits\\.vercel\\.app$",
    },
    4663,
  );
  assert.equal(explicit.pattern, null);
  assert.deepEqual(explicit.exact, ["https://gameofsplits.fun", "https://www.gameofsplits.fun"]);
});

test("a wildcard, an unanchored pattern, or a pattern without our team is refused", () => {
  assert.throws(() => loadOrigins({ CHAIN_ID: "46630", ALLOW_ORIGIN: "*" }), /exact/);
  assert.throws(() => loadOrigins({ CHAIN_ID: "46630", ALLOW_ORIGIN: "https://ok.example/path" }), /exact/);
  assert.throws(() => loadOrigins({ CHAIN_ID: "46630", ALLOW_ORIGIN_PATTERN: "gos-testnet" }), /anchored/);
  assert.throws(
    () => loadOrigins({ CHAIN_ID: "46630", ALLOW_ORIGIN_PATTERN: "^https://gos-testnet-[a-z0-9-]+-other-team\\.vercel\\.app$" }),
    /game-of-splits/,
  );
});

test("only an allowed origin is echoed back", () => {
  const p = loadOrigins({ CHAIN_ID: "46630" });
  const ok = corsHeaders("https://testnet.gameofsplits.fun", p);
  assert.equal(ok["access-control-allow-origin"], "https://testnet.gameofsplits.fun");
  assert.equal(ok.vary, "Origin");
  const bad = corsHeaders("https://evil.example", p);
  assert.equal(bad["access-control-allow-origin"], undefined);
  assert.equal(corsHeaders(null, p)["access-control-allow-origin"], undefined);
});
