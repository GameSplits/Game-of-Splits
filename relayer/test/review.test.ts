// Regression tests for the review gaps closed after 7d1f64d.
import assert from "node:assert/strict";
import test from "node:test";
import type { Hex } from "viem";
import { privateKeyToAccount, generatePrivateKey } from "viem/accounts";
import { TESTNET_STASH, loadConfig } from "../src/config.ts";
import * as eip712 from "../src/eip712.ts";
import { handle, type HandleCtx, type HandleInput } from "../src/http.ts";
import { MemoryUsedOrders, NonceQueue, OwnerNonceGuard, RateLimit, ResignBook, SpendBudget } from "../src/policy.ts";
import { sendCapped } from "../src/runtime.ts";
import { splitBudget } from "../src/relay.ts";

const domain = eip712.stashDomain(46630, TESTNET_STASH);
const session = privateKeyToAccount(`0x${"22".repeat(32)}` as Hex);
const str = (o: Record<string, unknown>) => Object.fromEntries(Object.entries(o).map(([k, v]) => [k, String(v)]));
const req = (route: string, body: string, ip: string): HandleInput => ({ method: "POST", path: `/${route}`, route, headers: { "x-vercel-forwarded-for": ip }, body });

function make(budgetWei: bigint, broadcastFails = false, balance = 0n, split = false) {
  let t = 1_000_000;
  const io = { broadcasts: 0, attempts: 0 };
  const share = split ? splitBudget(budgetWei, 2_500n) : { play: budgetWei, account: 0n };
  const spend = new SpendBudget(share.play);
  const ctx: HandleCtx = {
    cfg: loadConfig({ RELAYER_KEY: `0x${"11".repeat(32)}`, RPC_URL: "https://rpc.example.test", CHAIN_ID: "46630", STASH: TESTNET_STASH }),
    relayer: session.address,
    deps: {
      now: () => t,
      simulate: async () => ({ ok: true }),
      send: (data, o) =>
        sendCapped(
          {
            baseFee: async () => 20_000_000n,
            estimate: async () => 80_000n,
            broadcast: async () => {
              io.attempts++;
              if (broadcastFails) throw new Error("rpc timeout");
              io.broadcasts++;
              return "0xabc";
            },
          },
          500_000_000n, data, o),
      ethBalance: async () => 10n ** 18n,
      alert: async () => {},
      priorityWei: 1n,
    },
    state: { rates: new RateLimit(30, 60_000), hourly: new RateLimit(60, 3_600_000), ips: new RateLimit(60, 60_000), resigns: new ResignBook(), nonces: new NonceQueue(async () => 0n), owners: new OwnerNonceGuard(), spend, used: new MemoryUsedOrders(), revokes: new RateLimit(3, 3_600_000), ...(split ? { accountSpend: new SpendBudget(share.account) } : {}) },
    sessionKey: async () => session.address,
    stashBalance: async () => balance,
    ownerNonce: async () => 0n,
  };
  return { ctx, io, spend, tick: (ms: number) => (t += ms) };
}

async function shootBody(pk: Hex) {
  const owner = privateKeyToAccount(pk).address;
  const m = { owner, maxPrice: 10n ** 9n, expectedRound: 1n, nonce: 0n, deadline: 2_000_000_000n, epoch: 1n };
  const sig = await session.signTypedData({ domain, types: eip712.shootTypes, primaryType: "Shoot", message: m });
  return JSON.stringify({ chainId: 46630, stash: TESTNET_STASH, order: str(m), signature: sig });
}

async function revokeBody(pk: Hex, nonce: bigint) {
  const a = privateKeyToAccount(pk);
  const m = { owner: a.address, nonce, deadline: 2_000_000_000n };
  const sig = await a.signTypedData({ domain, types: eip712.revokeTypes, primaryType: "RevokeKey", message: m });
  return JSON.stringify({ chainId: 46630, stash: TESTNET_STASH, order: str(m), signature: sig });
}

async function authBody(pk: Hex) {
  const a = privateKeyToAccount(pk);
  const m = { owner: a.address, key: session.address, limit: 1n, expiry: 2_000_000_000n, nonce: 0n, deadline: 2_000_000_000n };
  const sig = await a.signTypedData({ domain, types: eip712.authorizeTypes, primaryType: "AuthorizeKey", message: m });
  return JSON.stringify({ chainId: 46630, stash: TESTNET_STASH, order: str(m), signature: sig });
}

test("pause by spam: unfunded wallets are refused with deposit first and plays still relay", async () => {
  const h = make(100n * 96_000n * 20_000_001n);
  let refused = 0;
  for (let i = 0; i < 100; i++) {
    const out = await handle(h.ctx, req("authorize-key", await authBody(generatePrivateKey()), `203.0.113.${i % 2}`));
    if (out.status === 400 && out.body?.error === "deposit first") refused++;
    if (i % 50 === 49) h.tick(61_000);
  }
  assert.equal(refused, 100);
  assert.equal(h.io.broadcasts, 0);
  assert.equal(h.spend.spent(h.tick(0)), 0n);
  const play = await handle(h.ctx, req("shoot", await shootBody(`0x${"55".repeat(32)}` as Hex), "198.51.100.9"));
  assert.equal(play.status, 200);
});

test("funded wallets that use up the account share never pause plays", async () => {
  const h = make(4n * 96_000n * 20_000_001n, false, 5_000_000n, true);
  let paused = 0;
  for (let i = 0; i < 10; i++) {
    const out = await handle(h.ctx, req("authorize-key", await authBody(generatePrivateKey()), `203.0.113.${i}`));
    if (out.status === 503 && out.body?.error === "relay paused") paused++;
  }
  assert.ok(paused > 0, "account share runs out");
  const play = await handle(h.ctx, req("shoot", await shootBody(`0x${"56".repeat(32)}` as Hex), "198.51.100.9"));
  assert.equal(play.status, 200);
});

test("funded authorize at exactly the minimum is relayed, one unit below is refused", async () => {
  const ok = make(10n ** 18n, false, 1_000_000n);
  assert.equal((await handle(ok.ctx, req("authorize-key", await authBody(generatePrivateKey()), "203.0.113.1"))).status, 200);
  const low = make(10n ** 18n, false, 999_999n);
  const out = await handle(low.ctx, req("authorize-key", await authBody(generatePrivateKey()), "203.0.113.1"));
  assert.equal(out.status, 400);
  assert.equal(out.body?.error, "deposit first");
});

test("revoke with a live key is relayed at zero balance, with its own per-owner budget", async () => {
  const h = make(10n ** 18n);
  const owner = `0x${"66".repeat(32)}` as Hex;
  for (let n = 0; n < 3; n++) assert.equal((await handle(h.ctx, req("revoke-key", await revokeBody(owner, BigInt(n)), "203.0.113.1"))).status, 200);
  const fourth = await handle(h.ctx, req("revoke-key", await revokeBody(owner, 3n), "203.0.113.2"));
  assert.equal(fourth.status, 429);
});

test("revoke with no live key needs the deposit", async () => {
  const h = make(10n ** 18n);
  h.ctx.sessionKey = async () => "0x0000000000000000000000000000000000000000";
  const out = await handle(h.ctx, req("revoke-key", await revokeBody(generatePrivateKey(), 0n), "203.0.113.1"));
  assert.equal(out.status, 400);
  assert.equal(out.body?.error, "deposit first");
});

test("set limit from an unfunded wallet is refused", async () => {
  const h = make(10n ** 18n);
  const a = privateKeyToAccount(generatePrivateKey());
  const m = { owner: a.address, newLimit: 5n, nonce: 0n, deadline: 2_000_000_000n };
  const sig = await a.signTypedData({ domain, types: eip712.limitTypes, primaryType: "SetLimit", message: m });
  const out = await handle(h.ctx, req("set-limit", JSON.stringify({ chainId: 46630, stash: TESTNET_STASH, order: str(m), signature: sig }), "203.0.113.1"));
  assert.equal(out.body?.error, "deposit first");
});

test("same signed order sent twice is refused with nonce in use", async () => {
  const h = make(10n ** 18n, false, 5_000_000n);
  const body = await authBody(`0x${"44".repeat(32)}` as Hex);
  assert.equal((await handle(h.ctx, req("authorize-key", body, "203.0.113.1"))).status, 200);
  const again = await handle(h.ctx, req("authorize-key", body, "203.0.113.2"));
  assert.equal(again.status, 400);
  assert.equal(again.body?.error, "nonce in use");
  assert.equal(h.io.broadcasts, 1);
});

test("failed broadcast with a clear error refunds the single reservation", async () => {
  const h = make(10n ** 18n, true, 5_000_000n);
  const out = await handle(h.ctx, req("authorize-key", await authBody(generatePrivateKey()), "203.0.113.1"));
  assert.notEqual(out.status, 200);
  assert.equal(h.io.attempts, 2);
  assert.equal(h.spend.spent(1_000_000), 0n);
});
