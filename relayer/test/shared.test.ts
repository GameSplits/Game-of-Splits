// Shared Upstash state against an in-process fake. Two runtimes share one fake, as two Vercel copies share Upstash.
import assert from "node:assert/strict";
import test from "node:test";
import type { Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { TESTNET_STASH, loadConfig } from "../src/config.ts";
import * as eip712 from "../src/eip712.ts";
import { handle, type HandleCtx, type HandleInput } from "../src/http.ts";
import { SpendBudget, SpendCapError } from "../src/policy.ts";
import { submitShot, type RelayDeps } from "../src/relay.ts";
import { chooseState, sendCapped, sharedState } from "../src/runtime.ts";
import { SharedNonces, SharedRateLimit, SharedSpend, SharedUsedOrders, upstashEnv, upstashKv, type Kv } from "../src/shared.ts";

class FakeKv implements Kv {
  readonly rows = new Map<string, { v: string; exp: number }>();
  now = 1_000_000;
  private live(key: string) {
    const row = this.rows.get(key);
    if (row && row.exp <= this.now) this.rows.delete(key);
    return this.rows.get(key);
  }
  async incrTtl(key: string, by: number, ttlMs: number) {
    const v = await this.incrBy(key, by);
    this.rows.get(key)!.exp = this.now + ttlMs;
    return v;
  }
  async incrBy(key: string, by: number) {
    const row = this.live(key);
    const v = Number(row?.v ?? 0) + by;
    this.rows.set(key, { v: String(v), exp: row?.exp ?? Infinity });
    return v;
  }
  async get(key: string) {
    const row = this.live(key);
    return row ? Number(row.v) : null;
  }
  async setNx(key: string, value: string, ttlMs: number) {
    if (this.live(key)) return false;
    this.rows.set(key, { v: value, exp: this.now + ttlMs });
    return true;
  }
  async set(key: string, value: number) {
    this.rows.set(key, { v: String(value), exp: Infinity });
  }
  async del(key: string) {
    this.rows.delete(key);
  }
  async rewindNonce(key: string, nonce: number, pending: number, kept: boolean) {
    const cur = (await this.get(key)) ?? -1;
    if (!kept && cur === nonce + 1) await this.set(key, Math.max(pending, nonce));
    else if (pending > cur) await this.set(key, pending);
  }
}

test("upstashEnv reads the Vercel KV names or the Upstash names, and nothing when missing", () => {
  assert.equal(upstashEnv({}), null);
  assert.deepEqual(upstashEnv({ KV_REST_API_URL: "https://x.upstash.io", KV_REST_API_TOKEN: "t" }), { url: "https://x.upstash.io", token: "t" });
  assert.deepEqual(upstashEnv({ UPSTASH_REDIS_REST_URL: "https://y.upstash.io", UPSTASH_REDIS_REST_TOKEN: "t" })?.url, "https://y.upstash.io");
  assert.throws(() => upstashEnv({ KV_REST_API_URL: "http://x", KV_REST_API_TOKEN: "t" }));
});

test("without Upstash: memory state with a loud warning, and a production non-testnet config refuses to start", () => {
  const logs: string[] = [];
  const st = chooseState({}, 46630, "0xabc", async () => 0n, 10n ** 16n, (m) => logs.push(m));
  assert.ok(st.spend instanceof SpendBudget);
  assert.match(logs[0] ?? "", /WARNING relayer state is in memory only/);
  assert.throws(() => chooseState({ NODE_ENV: "production" }, 4663, "0xabc", async () => 0n, 10n ** 16n, () => {}), /shared state required/);
  const shared = chooseState({ NODE_ENV: "production", KV_REST_API_URL: "https://x.upstash.io", KV_REST_API_TOKEN: "t" }, 4663, "0xabc", async () => 0n, 10n ** 16n);
  assert.ok(shared.spend instanceof SharedSpend);
});

test("two copies share one per-owner and per-IP limit", async () => {
  const kv = new FakeKv();
  const a = new SharedRateLimit(kv, "r", 3, 60_000);
  const b = new SharedRateLimit(kv, "r", 3, 60_000);
  assert.equal(await a.allow("0xA", 0), true);
  assert.equal(await b.allow("0xa", 1), true);
  assert.equal(await a.allow("0xA", 2), true);
  assert.equal(await b.full("0xA", 3), true);
  assert.equal(await b.allow("0xA", 3), false);
  assert.equal(await a.full("0xA", 60_000), false, "new window");
});

test("two copies share one hourly ETH budget, refuse past it, and a release gives room back", async () => {
  const kv = new FakeKv();
  const gwei = 1_000_000_000n;
  const a = new SharedSpend(kv, "s", 10n * gwei);
  const b = new SharedSpend(kv, "s", 10n * gwei);
  assert.equal(await a.reserve(6n * gwei, 0), true);
  assert.equal(await b.reserve(5n * gwei, 1), false);
  assert.equal(await a.spentGwei(1), 6, "a refused reservation is taken back");
  assert.equal(await b.reserve(4n * gwei, 1), true);
  await a.release(6n * gwei, 0);
  assert.equal(await b.reserve(6n * gwei, 2), true);
  assert.equal(await a.alertDue(2), true);
  assert.equal(await b.alertDue(3), false, "one alert across copies");
});

test("concurrent reservations from two copies never exceed the budget", async () => {
  const kv = new FakeKv();
  const gwei = 1_000_000_000n;
  const copies = [new SharedSpend(kv, "s", 10n * gwei), new SharedSpend(kv, "s", 10n * gwei)];
  const results = await Promise.all(Array.from({ length: 20 }, (_, i) => copies[i % 2]!.reserve(gwei, 0)));
  assert.equal(results.filter(Boolean).length, 10);
  assert.ok((await copies[0]!.spentGwei(0)) <= 10);
});

test("two copies get distinct nonces, seeded from the chain and resynced after a failure", async () => {
  const kv = new FakeKv();
  let chain = 7n;
  const a = new SharedNonces(kv, "n", async () => chain);
  const b = new SharedNonces(kv, "n", async () => chain);
  const got = await Promise.all([a.run(async (n) => n), b.run(async (n) => n), a.run(async (n) => n), b.run(async (n) => n)]);
  assert.deepEqual([...got].sort((x, y) => (x < y ? -1 : x > y ? 1 : 0)), [7n, 8n, 9n, 10n]);
  chain = 11n;
  await assert.rejects(a.run(async () => {
    throw new Error("nonce too low");
  }));
  assert.equal(await b.run(async (n) => n), 11n, "counter reset to the chain pending nonce");
});

test("a used order is refused on the other copy until it expires or is dropped", async () => {
  const kv = new FakeKv();
  const a = new SharedUsedOrders(kv, "u", 600_000);
  const b = new SharedUsedOrders(kv, "u", 600_000);
  assert.equal(await a.claim("shoot:0xA:1"), true);
  assert.equal(await b.claim("shoot:0xa:1"), false);
  kv.now += 600_000;
  assert.equal(await b.claim("shoot:0xa:1"), true);
  await b.drop("shoot:0xa:1");
  assert.equal(await a.claim("shoot:0xA:1"), true);
});

const domain = eip712.stashDomain(46630, TESTNET_STASH);
const session = privateKeyToAccount(`0x${"22".repeat(32)}` as Hex);
const str = (o: Record<string, unknown>) => Object.fromEntries(Object.entries(o).map(([k, v]) => [k, String(v)]));
const req = (body: string, ip: string): HandleInput => ({ method: "POST", path: "/authorize-key", route: "authorize-key", headers: { "x-vercel-forwarded-for": ip }, body });

function copy(kv: Kv, io: { nonces: bigint[]; fail: boolean; timeout?: boolean }, budgetWei = 10n ** 18n): HandleCtx {
  const now = () => (kv as FakeKv).now;
  return {
    cfg: loadConfig({ RELAYER_KEY: `0x${"11".repeat(32)}`, RPC_URL: "https://rpc.example.test", CHAIN_ID: "46630", STASH: TESTNET_STASH }),
    relayer: session.address,
    deps: {
      now,
      simulate: async () => ({ ok: true }),
      send: (data, o) =>
        sendCapped(
          {
            baseFee: async () => 20_000_000n,
            estimate: async () => 80_000n,
            broadcast: async (tx) => {
              if (io.timeout) {
                const err = new Error("timed out");
                err.name = "TimeoutError";
                throw err;
              }
              if (io.fail) throw new Error("rpc refused");
              io.nonces.push(tx.nonce);
              return "0xabc";
            },
          },
          500_000_000n,
          data,
          o,
        ),
      ethBalance: async () => 10n ** 18n,
      alert: async () => {},
      priorityWei: 1n,
    },
    state: sharedState(kv, 46630, session.address, async () => 3n, budgetWei),
    sessionKey: async () => session.address,
    stashBalance: async () => 5_000_000n,
    ownerNonce: async () => 0n,
  };
}

async function authBody(seed: string, nonce = 0n) {
  const a = privateKeyToAccount(`0x${seed.repeat(32)}` as Hex);
  const m = { owner: a.address, key: session.address, limit: 1n, expiry: 2_000_000_000n, nonce, deadline: 2_000_000_000n };
  const sig = await a.signTypedData({ domain, types: eip712.authorizeTypes, primaryType: "AuthorizeKey", message: m });
  return JSON.stringify({ chainId: 46630, stash: TESTNET_STASH, order: str(m), signature: sig });
}

test("replay across copies: the same signed order sent to two copies goes out once", async () => {
  const kv = new FakeKv();
  const io = { nonces: [] as bigint[], fail: false };
  const [a, b] = [copy(kv, io), copy(kv, io)];
  const body = await authBody("44");
  const outs = await Promise.all([handle(a, req(body, "203.0.113.1")), handle(b, req(body, "203.0.113.2"))]);
  assert.deepEqual(outs.map((o) => o.status).sort(), [200, 400]);
  assert.equal(outs.find((o) => o.status === 400)?.body?.error, "nonce in use");
  assert.equal(io.nonces.length, 1);
});

test("two copies relay different wallets with distinct relayer nonces", async () => {
  const kv = new FakeKv();
  const io = { nonces: [] as bigint[], fail: false };
  const [a, b] = [copy(kv, io), copy(kv, io)];
  const outs = await Promise.all([
    handle(a, req(await authBody("44"), "203.0.113.1")),
    handle(b, req(await authBody("55"), "203.0.113.2")),
    handle(a, req(await authBody("66"), "203.0.113.3")),
  ]);
  assert.deepEqual(outs.map((o) => o.status), [200, 200, 200]);
  assert.deepEqual([...io.nonces].sort((x, y) => (x < y ? -1 : x > y ? 1 : 0)), [3n, 4n, 5n]);
});

test("two copies share the hourly budget: once one copy fills it the other pauses", async () => {
  const kv = new FakeKv();
  const io = { nonces: [] as bigint[], fail: false };
  const perSend: bigint = 96_000n * 20_000_001n;
  const [a, b] = [copy(kv, io, perSend + perSend / 2n), copy(kv, io, perSend + perSend / 2n)];
  assert.equal((await handle(a, req(await authBody("44"), "203.0.113.1"))).status, 200);
  const second = await handle(b, req(await authBody("55"), "203.0.113.2"));
  assert.equal(second.status, 503);
  assert.equal(second.body?.error, "relay paused");
});

test("a refused broadcast refunds the reservation and frees the order for a retry", async () => {
  const kv = new FakeKv();
  const io = { nonces: [] as bigint[], fail: true };
  const a = copy(kv, io);
  const body = await authBody("44");
  assert.equal((await handle(a, req(body, "203.0.113.1"))).status, 502);
  assert.equal(await (a.state.spend as SharedSpend).spentGwei(kv.now), 0);
  io.fail = false;
  assert.equal((await handle(a, req(body, "203.0.113.1"))).status, 200);
});

test("a timed out broadcast keeps one reservation for both attempts", async () => {
  const kv = new FakeKv();
  const io = { nonces: [] as bigint[], fail: false, timeout: true };
  const a = copy(kv, io);
  assert.equal((await handle(a, req(await authBody("44"), "203.0.113.1"))).status, 502);
  const spent = await (a.state.spend as SharedSpend).spentGwei(kv.now);
  assert.ok(spent > 0);
  assert.ok(spent <= Number((96_000n * 20_000_002n + 999_999_999n) / 1_000_000_000n), "one reservation, not two");
});

test("a spend cap refusal on the retry releases the first reservation", async () => {
  const st = sharedState(new FakeKv(), 46630, "0xabc", async () => 0n, 10n ** 18n);
  let calls = 0;
  const deps: RelayDeps = {
    now: () => 0,
    simulate: async () => ({ ok: true }),
    send: async (_d, o) => {
      calls++;
      if (calls === 1) {
        await o.reserve(1_000_000_000n);
        throw new Error("rpc refused");
      }
      throw new SpendCapError();
    },
    ethBalance: async () => 10n ** 18n,
    alert: async () => {},
    priorityWei: 1n,
  };
  const out = await submitShot(deps, st, { owner: "0xabc", maxPrice: 1n, replaces: false, calldata: "0x12", gasCap: 900_000n });
  assert.equal(out.status, 503);
  assert.equal(await (st.spend as SharedSpend).spentGwei(0), 0);
});

const live = upstashEnv(process.env);
test("live Upstash: two copies share limit, budget, nonce and used orders", { skip: live && process.env.RELAYER_UPSTASH_IT === "1" ? false : "set RELAYER_UPSTASH_IT=1 with KV_REST_API_URL and KV_REST_API_TOKEN" }, async () => {
  const kv = upstashKv(live!);
  const p = `gos-relayer:it:${Date.now()}`;
  const ra = new SharedRateLimit(kv, `${p}:r`, 2, 60_000);
  const rb = new SharedRateLimit(kv, `${p}:r`, 2, 60_000);
  const t = Date.now();
  assert.equal(await ra.allow("x", t), true);
  assert.equal(await rb.allow("x", t), true);
  assert.equal(await ra.allow("x", t), false);
  const gwei = 1_000_000_000n;
  const sa = new SharedSpend(kv, `${p}:s`, 10n * gwei, 60_000);
  assert.equal(await sa.reserve(8n * gwei, t), true);
  assert.equal(await new SharedSpend(kv, `${p}:s`, 10n * gwei, 60_000).reserve(3n * gwei, t), false);
  const na = new SharedNonces(kv, `${p}:n`, async () => 5n);
  const nb = new SharedNonces(kv, `${p}:n`, async () => 5n);
  assert.deepEqual((await Promise.all([na.run(async (n) => n), nb.run(async (n) => n)])).sort((x, y) => (x < y ? -1 : x > y ? 1 : 0)), [5n, 6n]);
  const u = new SharedUsedOrders(kv, `${p}:u`, 60_000);
  assert.equal(await u.claim("o"), true);
  assert.equal(await new SharedUsedOrders(kv, `${p}:u`, 60_000).claim("o"), false);
  for (const k of [`${p}:n`, `${p}:u:o`]) await kv.del(k);
});

test("a viem-wrapped timeout counts as maybe sent: one attempt, the reservation is kept and the order stays taken", async () => {
  const { TimeoutError } = await import("viem");
  const kv = new FakeKv();
  const a = copy(kv, { nonces: [], fail: false });
  let attempts = 0;
  const nonces: bigint[] = [];
  a.deps.send = async (_d, o) => {
    attempts++;
    nonces.push(o.nonce);
    await o.reserve(1_000_000_000n);
    const err = new Error("transaction execution failed", { cause: new TimeoutError({ body: {}, url: "https://rpc.example.test" }) });
    err.name = "TransactionExecutionError";
    throw err;
  };
  const body = await authBody("44");
  const out = await handle(a, req(body, "203.0.113.1"));
  assert.equal(out.status, 502);
  assert.equal(attempts, 1, "no retry under a new nonce");
  assert.ok((await (a.state.spend as SharedSpend).spentGwei(kv.now)) > 0, "reservation kept");
  assert.equal((await handle(a, req(body, "203.0.113.2"))).body?.error, "nonce in use");
  a.deps.send = async (_d, o) => {
    nonces.push(o.nonce);
    return "0xabc";
  };
  assert.equal((await handle(a, req(await authBody("55"), "203.0.113.3"))).status, 200);
  assert.notEqual(nonces[1], nonces[0], "the maybe-sent nonce is not reused");
});

test("Upstash failing after the hash came back still answers 200 and keeps the order taken", async () => {
  const kv = new FakeKv();
  const io = { nonces: [] as bigint[], fail: false };
  const a = copy(kv, io);
  const incr = kv.incrTtl.bind(kv);
  kv.incrTtl = async (key, by, ttl) => {
    if (io.nonces.length > 0 && !key.includes(":ip")) throw new Error("upstash down");
    return incr(key, by, ttl);
  };
  const body = await authBody("44");
  const first = await handle(a, req(body, "203.0.113.1"));
  assert.equal(first.status, 200);
  assert.equal(first.body?.hash, "0xabc");
  kv.incrTtl = incr;
  const again = await handle(a, req(body, "203.0.113.2"));
  assert.equal(again.body?.error, "nonce in use");
  assert.equal(io.nonces.length, 1);
});

test("a failed send never rewinds the shared nonce below another copy's in-flight nonce", async () => {
  const kv = new FakeKv();
  const a = new SharedNonces(kv, "n", async () => 10n);
  const b = new SharedNonces(kv, "n", async () => 10n);
  let releaseB!: () => void;
  const bHold = new Promise<void>((r) => (releaseB = r));
  let aStarted!: () => void;
  const aGot = new Promise<void>((r) => (aStarted = r));
  const failA = a.run(async (n) => {
    assert.equal(n, 10n);
    await aGot;
    throw new Error("rpc refused");
  });
  const inflightB = b.run(async (n) => {
    aStarted();
    await bHold;
    return n;
  });
  await assert.rejects(failA);
  const next = await a.run(async (n) => n);
  releaseB();
  const bNonce = await inflightB;
  assert.equal(bNonce, 11n);
  assert.notEqual(next, bNonce, "no two sends share a nonce");
  assert.ok(next > bNonce);
});

test("a surely failed send gives its nonce back when no other copy took a later one", async () => {
  const kv = new FakeKv();
  const a = new SharedNonces(kv, "n", async () => 10n);
  await assert.rejects(a.run(async () => {
    throw new Error("rpc refused");
  }));
  assert.equal(await a.run(async (n) => n), 10n);
});

test("authorize and set limit signed at a future nonce are refused before any send", async () => {
  const kv = new FakeKv();
  const io = { nonces: [] as bigint[], fail: false };
  const a = copy(kv, io);
  const future = await handle(a, req(await authBody("44", 1n), "203.0.113.1"));
  assert.equal(future.status, 400);
  assert.equal(future.body?.error, "nonce not current");
  assert.equal(io.nonces.length, 0);
  a.ownerNonce = async () => {
    throw new Error("rpc down");
  };
  assert.equal((await handle(a, req(await authBody("44", 0n), "203.0.113.2"))).status, 502, "fails closed when the nonce is unread");
  a.ownerNonce = async () => 0n;
  assert.equal((await handle(a, req(await authBody("44", 0n), "203.0.113.3"))).status, 200);
});
