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

const domain = eip712.stashDomain(46630, TESTNET_STASH);
const session = privateKeyToAccount(`0x${"22".repeat(32)}` as Hex);
const str = (o: Record<string, unknown>) => Object.fromEntries(Object.entries(o).map(([k, v]) => [k, String(v)]));
const req = (route: string, body: string, ip: string): HandleInput => ({ method: "POST", path: `/${route}`, route, headers: { "x-vercel-forwarded-for": ip }, body });

function make(budgetWei: bigint, broadcastFails = false) {
  let t = 1_000_000;
  const io = { broadcasts: 0, attempts: 0 };
  const spend = new SpendBudget(budgetWei);
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
    state: { rates: new RateLimit(30, 60_000), hourly: new RateLimit(60, 3_600_000), ips: new RateLimit(60, 60_000), resigns: new ResignBook(), nonces: new NonceQueue(async () => 0n), owners: new OwnerNonceGuard(), spend, used: new MemoryUsedOrders() },
    sessionKey: async () => session.address,
    stashBalance: async () => 0n,
    ownerNonce: async () => 0n,
  };
  return { ctx, io, spend, tick: (ms: number) => (t += ms) };
}

async function authBody(pk: Hex) {
  const a = privateKeyToAccount(pk);
  const m = { owner: a.address, key: session.address, limit: 1n, expiry: 2_000_000_000n, nonce: 0n, deadline: 2_000_000_000n };
  const sig = await a.signTypedData({ domain, types: eip712.authorizeTypes, primaryType: "AuthorizeKey", message: m });
  return JSON.stringify({ chainId: 46630, stash: TESTNET_STASH, order: str(m), signature: sig });
}

test("pause griefing still possible without a Stash-balance gate: free authorizeKeys exhaust the budget", async () => {
  // Still open. A Stash-balance gate for authorizeKey is a separate change.
  const h = make(100n * 96_000n * 20_000_001n);
  let ok = 0;
  for (let i = 0; i < 100; i++) {
    const out = await handle(h.ctx, req("authorize-key", await authBody(generatePrivateKey()), `203.0.113.${i % 2}`));
    if (out.status === 200) ok++;
    if (i % 100 === 99) h.tick(61_000);
  }
  assert.equal(ok, 100);
  const user = await handle(h.ctx, req("authorize-key", await authBody(generatePrivateKey()), "198.51.100.9"));
  assert.equal(user.status, 503);
  assert.equal(user.body?.error, "relay paused");
});

test("same signed order sent twice is refused with nonce in use", async () => {
  const h = make(10n ** 18n);
  const body = await authBody(`0x${"44".repeat(32)}` as Hex);
  assert.equal((await handle(h.ctx, req("authorize-key", body, "203.0.113.1"))).status, 200);
  const again = await handle(h.ctx, req("authorize-key", body, "203.0.113.2"));
  assert.equal(again.status, 400);
  assert.equal(again.body?.error, "nonce in use");
  assert.equal(h.io.broadcasts, 1);
});

test("failed broadcast with a clear error refunds the single reservation", async () => {
  const h = make(10n ** 18n, true);
  const out = await handle(h.ctx, req("authorize-key", await authBody(generatePrivateKey()), "203.0.113.1"));
  assert.notEqual(out.status, 200);
  assert.equal(h.io.attempts, 2);
  assert.equal(h.spend.spent(1_000_000), 0n);
});
