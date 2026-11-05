// Relayer nonce recovery and maybe-sent classification. The chain model accepts only the next account nonce, like the
// sequencer, and otherwise throws a viem NonceTooHighError wrapped in a transaction error.
import assert from "node:assert/strict";
import http from "node:http";
import test from "node:test";
import { HttpRequestError, NonceTooHighError, TimeoutError, createPublicClient, createWalletClient, defineChain, http as transport, keccak256, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { TESTNET_STASH, loadConfig } from "../src/config.ts";
import * as eip712 from "../src/eip712.ts";
import { handle, type HandleCtx, type HandleInput } from "../src/http.ts";
import { NonceQueue, broadcastAmbiguous, mayHaveBroadcast } from "../src/policy.ts";
import { chainSendIo, sendCapped, sharedState, type SendIo } from "../src/runtime.ts";
import { NOT_SENT_HEADER, corsHeaders, toResponse } from "../src/http.ts";
import { parseTransaction } from "viem";
import { SharedNonces, type Kv } from "../src/shared.ts";
import { FakeKv } from "./fake-kv.ts";

const cfg = loadConfig({ RELAYER_KEY: `0x${"11".repeat(32)}`, RPC_URL: "https://rpc.example.test", CHAIN_ID: "46630", STASH: TESTNET_STASH });
const domain = eip712.stashDomain(46630, TESTNET_STASH);
const session = privateKeyToAccount(`0x${"22".repeat(32)}` as Hex);
const RELAYER = "0x00000000000000000000000000000000000000aa";
const NKEY = `gos-relayer:46630:${RELAYER}:nonce`;
const str = (o: Record<string, unknown>) => Object.fromEntries(Object.entries(o).map(([k, v]) => [k, String(v)]));
const req = (route: string, body: string, ip: string): HandleInput => ({ method: "POST", path: `/${route}`, route, headers: { "x-vercel-forwarded-for": ip }, body });
const owner = (i: number) => privateKeyToAccount(`0x${(i + 1000).toString(16).padStart(64, "0")}` as Hex);

async function authBody(i: number, nonce = 0n, deadline = 2_000_000_000n) {
  const a = owner(i);
  const m = { owner: a.address, key: session.address, limit: 1n, expiry: 2_000_000_000n, nonce, deadline };
  const signature = await a.signTypedData({ domain, types: eip712.authorizeTypes, primaryType: "AuthorizeKey", message: m });
  return JSON.stringify({ chainId: 46630, stash: TESTNET_STASH, order: str(m), signature });
}
async function limitBody(i: number, nonce: bigint) {
  const a = owner(i);
  const m = { owner: a.address, newLimit: 7n, nonce, deadline: 2_000_000_000n };
  const signature = await a.signTypedData({ domain, types: eip712.limitTypes, primaryType: "SetLimit", message: m });
  return JSON.stringify({ chainId: 46630, stash: TESTNET_STASH, order: str(m), signature });
}
async function revokeBody(i: number, nonce: bigint) {
  const a = owner(i);
  const m = { owner: a.address, nonce, deadline: 2_000_000_000n };
  const signature = await a.signTypedData({ domain, types: eip712.revokeTypes, primaryType: "RevokeKey", message: m });
  return JSON.stringify({ chainId: 46630, stash: TESTNET_STASH, order: str(m), signature });
}
const txErr = (cause: Error) => {
  const e = new Error("transaction execution failed", { cause });
  e.name = "TransactionExecutionError";
  return e;
};
const http503 = () => new HttpRequestError({ url: "http://127.0.0.1:1", status: 503, body: {} });
const http429 = () => new HttpRequestError({ url: "http://127.0.0.1:1", status: 429, body: {} });

type Chain = { pending: bigint; mined?: Set<string> };
type Faults = {
  baseFee?: () => Promise<bigint>;
  estimate?: () => Promise<bigint>;
  broadcast?: (n: bigint) => Promise<void>;
  /** Thrown after the node took the transaction, as a proxy that answers late or "already known" would. */
  after?: (n: bigint) => Error | undefined;
  /** Sign locally and look the hash up after a clear error, as the runtime does. */
  signed?: boolean;
  known?: (hash: Hex) => Promise<boolean>;
  /** A whole send path, such as the real chainSendIo, in place of the fake chain. */
  io?: SendIo;
};
const hashFor = (n: bigint) => `0x${n.toString(16).padStart(64, "0")}` as Hex;

function copy(kv: Kv, chain: Chain, f: Faults = {}, ownerNonce: (o: string) => Promise<bigint> = async () => 0n) {
  const sends: bigint[] = [];
  const ctx: HandleCtx = {
    cfg,
    relayer: RELAYER,
    deps: {
      now: () => (kv as FakeKv).now,
      simulate: async () => ({ ok: true }),
      send: (data, o) =>
        sendCapped(
          f.io ?? {
            baseFee: async () => (f.baseFee ? f.baseFee() : 20_000_000n),
            estimate: async () => (f.estimate ? f.estimate() : 80_000n),
            broadcast: async (tx) => {
              sends.push(tx.nonce);
              if (f.broadcast) await f.broadcast(tx.nonce);
              if (tx.nonce > chain.pending) throw txErr(new NonceTooHighError({ nonce: Number(tx.nonce) }));
              if (tx.nonce < chain.pending) throw txErr(new Error("nonce too low"));
              chain.pending++;
              chain.mined?.add(hashFor(tx.nonce));
              const late = f.after?.(tx.nonce);
              if (late) throw late;
              return hashFor(tx.nonce);
            },
            ...(f.signed
              ? {
                  sign: async (tx: { nonce: bigint }) => ({ raw: hashFor(tx.nonce), hash: hashFor(tx.nonce) }),
                  known: f.known ?? (async (h: Hex) => !!chain.mined?.has(h)),
                }
              : {}),
          },
          cfg.maxFeeWei,
          data,
          o,
        ),
      ethBalance: async () => 10n ** 18n,
      alert: async () => {},
      priorityWei: 1n,
    },
    state: sharedState(kv, 46630, RELAYER, async () => chain.pending, 10n ** 18n),
    storageMode: "memory",
    sessionKey: async () => session.address,
    stashBalance: async () => 5_000_000n,
    ownerNonce,
  };
  return { ctx, sends };
}

async function tail(c: HandleCtx, from: number, n: number) {
  const out: number[] = [];
  for (let i = from; i < from + n; i++) out.push((await handle(c, req("authorize-key", await authBody(i), `198.51.100.${i % 200}`))).status);
  return out;
}

const once = (fn: () => never) => {
  let done = false;
  return () => {
    if (!done) {
      done = true;
      fn();
    }
  };
};

test("an RPC 503 on the baseFee read before broadcast is a sure failure: the order is freed and relaying goes on", async () => {
  const kv = new FakeKv();
  const chain: Chain = { pending: 0n };
  const fail = once(() => {
    throw http503();
  });
  const a = copy(kv, chain, { baseFee: async () => (fail(), 20_000_000n) });
  const body = await authBody(0);
  assert.equal((await handle(a.ctx, req("authorize-key", body, "198.51.100.250"))).status, 200, "the retry inside the request succeeds");
  assert.deepEqual(await tail(a.ctx, 1, 5), [200, 200, 200, 200, 200]);
  assert.equal(chain.pending, 6n);
});

test("RPC 429 and 503 on every pre-broadcast read never skip a nonce or lock the order", async () => {
  for (const [label, f] of [
    ["baseFee 503", { baseFee: async () => Promise.reject(http503()) }],
    ["estimate 429", { estimate: async () => Promise.reject(txErr(http429())) }],
  ] as const) {
    const kv = new FakeKv();
    const chain: Chain = { pending: 0n };
    const a = copy(kv, chain, f as Faults);
    const body = await authBody(0);
    assert.equal((await handle(a.ctx, req("authorize-key", body, "198.51.100.250"))).status, 502, label);
    assert.equal(await kv.get(NKEY), 0, `${label}: nonce given back`);
    const b = copy(kv, chain);
    assert.equal((await handle(b.ctx, req("authorize-key", body, "198.51.100.251"))).status, 200, `${label}: same order relays`);
    assert.deepEqual(b.sends, [0n]);
  }
});

test("a refused connection on the broadcast itself is a sure failure", async () => {
  for (const err of [txErr(Object.assign(new Error("fetch failed"), { cause: Object.assign(new Error("connect"), { code: "ECONNREFUSED" }) }))]) {
    const kv = new FakeKv();
    const chain: Chain = { pending: 0n };
    let fail = true;
    const a = copy(kv, chain, { broadcast: async () => { if (fail) { fail = false; throw err; } } });
    assert.equal((await handle(a.ctx, req("authorize-key", await authBody(0), "198.51.100.250"))).status, 200);
    assert.deepEqual(a.sends, [0n, 0n], "retried at the same nonce, no gap");
  }
});

test("real viem errors: only an ambiguous broadcast failure is maybe sent", async () => {
  const srv = (fn: (b: { id: number }, res: http.ServerResponse) => void) => {
    const s = http.createServer((q, res) => {
      let d = "";
      q.on("data", (c) => (d += c));
      q.on("end", () => fn(JSON.parse(d), res));
    }).listen(0, "127.0.0.1");
    return new Promise<http.Server>((r) => s.on("listening", () => r(s)));
  };
  const chain = defineChain({ id: 46630, name: "t", nativeCurrency: { name: "E", symbol: "E", decimals: 18 }, rpcUrls: { default: { http: [] } } });
  const url = (s: http.Server) => `http://127.0.0.1:${(s.address() as { port: number }).port}`;
  const s503 = await srv((_b, res) => { res.statusCode = 503; res.end("busy"); });
  const s429 = await srv((_b, res) => { res.statusCode = 429; res.end("slow down"); });
  const sNonce = await srv((b, res) => {
    res.setHeader("content-type", "application/json");
    res.end(JSON.stringify({ jsonrpc: "2.0", id: b.id, error: { code: -32000, message: "nonce too high" } }));
  });
  const sHang = await srv(() => {});
  const closed = await srv(() => {});
  const refusedUrl = url(closed);
  await new Promise((r) => closed.close(r));
  const opts = { retryCount: 0, timeout: 300 };
  const pub = (u: string) => createPublicClient({ chain, transport: transport(u, opts) });
  const wal = (u: string) => createWalletClient({ account: privateKeyToAccount(`0x${"11".repeat(32)}`), chain, transport: transport(u, opts) });
  const tx = { to: RELAYER as Hex, data: "0x" as Hex, gas: 100000n, nonce: 1, maxFeePerGas: 10n ** 9n, maxPriorityFeePerGas: 1n };
  const caught = async (p: Promise<unknown>) => p.then(() => assert.fail("expected an error"), (e: unknown) => e);
  try {
    // Pre-broadcast reads are never classified at all, so they are sure failures whatever the shape.
    assert.equal(mayHaveBroadcast(await caught(pub(url(s503)).getBlock())), false);
    assert.equal(mayHaveBroadcast(await caught(pub(url(s429)).estimateGas({ account: RELAYER as Hex, to: RELAYER as Hex, data: "0x" }))), false);
    // Broadcast errors.
    assert.equal(broadcastAmbiguous(await caught(wal(url(s429)).sendTransaction(tx))), false, "429");
    assert.equal(broadcastAmbiguous(await caught(wal(refusedUrl).sendTransaction(tx))), false, "refused");
    const gap = await caught(wal(url(sNonce)).sendTransaction(tx));
    assert.equal(broadcastAmbiguous(gap), false, "nonce too high");
    assert.ok(String((gap as Error).message).length > 0);
    assert.equal(broadcastAmbiguous(await caught(wal(url(s503)).sendTransaction(tx))), true, "503");
    assert.equal(broadcastAmbiguous(await caught(wal(url(sHang)).sendTransaction(tx))), true, "timeout");
  } finally {
    for (const s of [s503, s429, sNonce, sHang]) {
      s.closeAllConnections();
      s.close();
    }
  }
});

test("B-1 trigger: a broadcast timeout that never reached the node recovers after one failed request", async () => {
  const kv = new FakeKv();
  const chain: Chain = { pending: 0n };
  let fail = true;
  const a = copy(kv, chain, { broadcast: async () => { if (fail) { fail = false; throw txErr(new TimeoutError({ body: {}, url: "http://127.0.0.1:1" })); } } });
  const body = await authBody(0);
  assert.equal((await handle(a.ctx, req("authorize-key", body, "198.51.100.250"))).status, 202);
  assert.equal((await handle(a.ctx, req("authorize-key", body, "198.51.100.251"))).body?.error, "nonce in use", "a maybe-sent order stays taken");
  assert.deepEqual(await tail(a.ctx, 1, 5), [200, 200, 200, 200, 200], "the gap is found and filled inside the next request");
  assert.equal(chain.pending, 5n);
});

test("B-1 trigger: an RPC 503 on the broadcast that never reached the node recovers after one failed request", async () => {
  const kv = new FakeKv();
  const chain: Chain = { pending: 0n };
  let fail = true;
  const a = copy(kv, chain, { broadcast: async () => { if (fail) { fail = false; throw txErr(http503()); } } });
  assert.equal((await handle(a.ctx, req("authorize-key", await authBody(0), "198.51.100.250"))).status, 202);
  assert.deepEqual(await tail(a.ctx, 1, 3), [200, 200, 200]);
});

test("B-1 trigger: two copies, a sure failure on A while B holds the next nonce, then both recover", async () => {
  const kv = new FakeKv();
  const chain: Chain = { pending: 0n };
  let bAllocated!: () => void;
  const bGot = new Promise<void>((r) => (bAllocated = r));
  let aFirst = true;
  let bFirst = true;
  const a = copy(kv, chain, { baseFee: async () => { if (aFirst) { aFirst = false; await bGot; return 10n ** 12n; } return 20_000_000n; } });
  const b = copy(kv, chain, { baseFee: async () => { if (bFirst) { bFirst = false; bAllocated(); } return 20_000_000n; } });
  const pa = handle(a.ctx, req("authorize-key", await authBody(0), "198.51.100.250"));
  await new Promise((r) => setTimeout(r, 5));
  const pb = handle(b.ctx, req("authorize-key", await authBody(1), "198.51.100.251"));
  const [ra, rb] = await Promise.all([pa, pb]);
  assert.equal(ra.status, 503, "gas price above cap");
  assert.equal(rb.status, 200, "B hits the gap, resyncs and fills it in the same request");
  assert.deepEqual([...(await tail(a.ctx, 10, 3)), ...(await tail(b.ctx, 30, 3))], [200, 200, 200, 200, 200, 200]);
  assert.equal(chain.pending, 7n);
});

test("B-1 trigger: a copy killed between taking a nonce and sending leaves a gap that the next request fills", async () => {
  const kv = new FakeKv();
  const chain: Chain = { pending: 0n };
  const a = copy(kv, chain);
  await kv.setNx(NKEY, "0", 1e12);
  await kv.incrBy(NKEY, 1);
  assert.deepEqual(await tail(a.ctx, 60, 4), [200, 200, 200, 200]);
  assert.deepEqual(a.sends, [1n, 0n, 1n, 2n, 3n]);
});

test("the gap resync does not bring back duplicate nonces for plain sure failures", async () => {
  const kv = new FakeKv();
  const a = new SharedNonces(kv, "n", async () => 10n);
  const b = new SharedNonces(kv, "n", async () => 10n);
  let releaseB!: () => void;
  const hold = new Promise<void>((r) => (releaseB = r));
  let started!: () => void;
  const bStarted = new Promise<void>((r) => (started = r));
  const failA = a.run(async () => {
    await bStarted;
    throw txErr(http429());
  });
  const inflightB = b.run(async (n) => {
    started();
    await hold;
    return n;
  });
  await assert.rejects(failA);
  const next = await a.run(async (n) => n);
  releaseB();
  assert.equal(await inflightB, 11n);
  assert.equal(next, 12n);
});

test("a failing cleanup keeps the original error and its classification", async () => {
  const kv = new FakeKv();
  kv.rewindNonce = async () => {
    throw new Error("upstash down");
  };
  const timeout = txErr(new TimeoutError({ body: {}, url: "http://127.0.0.1:1" }));
  const shared = new SharedNonces(kv, "n", async () => 0n);
  const maybe = await shared.run(() => sendCapped({ baseFee: async () => 1n, estimate: async () => 1n, broadcast: async () => Promise.reject(timeout) }, 10n ** 12n, "0x", { nonce: 0n, priorityWei: 1n, gasCap: 100_000n, reserve: async () => true })).catch((e: unknown) => e);
  assert.equal(mayHaveBroadcast(maybe), true);
  let pendingDown = true;
  const q = new NonceQueue(async () => {
    if (pendingDown) throw new Error("rpc down");
    return 0n;
  });
  pendingDown = false;
  await q.run(async (n) => n);
  pendingDown = true;
  const err = await q.run(async () => Promise.reject(new Error("gas price above cap"))).catch((e: unknown) => e);
  assert.equal((err as Error).message, "gas price above cap");
  pendingDown = false;
  const after = await shared.run(async (n) => n).catch((e: unknown) => e);
  assert.equal(after, 1n, "a maybe-sent nonce is never handed out again");
});

test("relayed set limit and authorize only at the current nonce; with the RPC down they fail closed and revoke stays open", async () => {
  const kv = new FakeKv();
  const chain: Chain = { pending: 0n };
  let next = 3n;
  let down = false;
  const a = copy(kv, chain, {}, async () => {
    if (down) throw new Error("rpc down");
    return next;
  });
  const r = (route: string, body: string, ip: string) => handle(a.ctx, req(route, body, ip));
  const fut = await r("set-limit", await limitBody(5, 4n), "203.0.113.1");
  const stale = await r("set-limit", await limitBody(5, 2n), "203.0.113.2");
  assert.deepEqual([fut.status, fut.body?.error], [400, "nonce not current"]);
  assert.deepEqual([stale.status, stale.body?.error], [400, "nonce used"]);
  assert.equal(a.sends.length, 0);
  assert.equal((await r("set-limit", await limitBody(5, 3n), "203.0.113.3")).status, 200);
  next = 4n;
  assert.equal((await r("set-limit", await limitBody(5, 4n), "203.0.113.4")).status, 200);
  down = true;
  const sl = await r("set-limit", await limitBody(6, 0n), "203.0.113.6");
  const au = await r("authorize-key", await authBody(6, 0n), "203.0.113.7");
  const rv = await r("revoke-key", await revokeBody(6, 9n), "203.0.113.8");
  assert.deepEqual([sl.status, sl.body?.error, au.status, au.body?.error], [502, "nonce unavailable", 502, "nonce unavailable"]);
  assert.equal(rv.status, 200, "revoke still relays while the nonce read is down");
});

const rpcErr = (msg: string) => txErr(Object.assign(new Error(msg), { name: "RpcRequestError", code: -32603 }));

test("C-2: a clear JSON-RPC error after the node took the send is checked by hash and counted as sent, with no second send", async () => {
  for (const msg of ["request timed out", "already known"]) {
    const kv = new FakeKv();
    const chain: Chain = { pending: 0n, mined: new Set() };
    let fail = true;
    const a = copy(kv, chain, { signed: true, after: () => (fail ? ((fail = false), rpcErr(msg)) : undefined) });
    const out = await handle(a.ctx, req("authorize-key", await authBody(0), "198.51.100.250"));
    assert.deepEqual([out.status, out.body?.hash], [200, hashFor(0n)], msg);
    assert.deepEqual(a.sends, [0n], msg);
    assert.equal((await handle(a.ctx, req("authorize-key", await authBody(1), "198.51.100.251"))).status, 200, msg);
    assert.deepEqual(a.sends, [0n, 1n], msg);
  }
});

test("C-2r: a JSON-RPC error whose hash the read node does not know yet is maybe sent, with one send and no retry", async () => {
  // The auditor's residuals A to C: the node took the send, the lookup lags. A retry could mine the order twice or end in 502.
  for (const msg of ["already known", "request timed out", "internal error"]) {
    const kv = new FakeKv();
    const chain: Chain = { pending: 0n, mined: new Set() };
    let fail = true;
    const a = copy(kv, chain, { signed: true, known: async () => false, after: () => (fail ? ((fail = false), rpcErr(msg)) : undefined) });
    const out = await handle(a.ctx, req("authorize-key", await authBody(0), "198.51.100.250"));
    assert.deepEqual([out.status, out.body?.maybeSent, out.body?.hash], [202, true, hashFor(0n)], msg);
    assert.deepEqual(a.sends, [0n], msg);
    assert.equal((await handle(a.ctx, req("authorize-key", await authBody(0), "198.51.100.250"))).body?.error, "nonce in use", msg);
    // The next order goes out at the next nonce, so nothing is mined twice.
    assert.equal((await handle(a.ctx, req("authorize-key", await authBody(1), "198.51.100.251"))).status, 200, msg);
    assert.deepEqual(a.sends, [0n, 1n], msg);
  }
});

test("C-2r: a known refusal with an unknown hash stays a sure failure and is retried, and the nonce gap still heals", async () => {
  const refusals = [
    rpcErr("insufficient funds for gas * price + value"),
    rpcErr("max fee per gas less than block base fee"),
    rpcErr("intrinsic gas too low"),
    rpcErr("invalid sender"),
    rpcErr("transaction underpriced"),
  ];
  for (const err of refusals) {
    const chain: Chain = { pending: 0n, mined: new Set() };
    let fail = true;
    const a = copy(new FakeKv(), chain, { signed: true, broadcast: async () => { if (fail) { fail = false; throw err; } } });
    assert.equal((await handle(a.ctx, req("authorize-key", await authBody(0), "198.51.100.250"))).status, 200, err.cause && String((err.cause as Error).message));
    assert.deepEqual(a.sends, [0n, 0n]);
  }
  // B-1 in signed mode: the counter is ahead of the chain, the node says too high, the same request resets and fills the gap.
  const kv = new FakeKv();
  const chain: Chain = { pending: 0n, mined: new Set() };
  await kv.set(NKEY, "1");
  const a = copy(kv, chain, { signed: true });
  assert.equal((await handle(a.ctx, req("authorize-key", await authBody(0), "198.51.100.250"))).status, 200);
  assert.deepEqual(a.sends, [1n, 0n]);
  assert.equal((await handle(a.ctx, req("authorize-key", await authBody(1), "198.51.100.251"))).status, 200);
  assert.deepEqual(a.sends, [1n, 0n, 1n]);
  // Nonce too low (another copy used it) also stays sure and moves on.
  const low = copy(new FakeKv(), { pending: 3n, mined: new Set() }, { signed: true });
  assert.equal((await handle(low.ctx, req("authorize-key", await authBody(2), "198.51.100.252"))).status, 200);
  assert.equal(low.sends.at(-1), 3n);
});

test("C-2: when the hash lookup fails after a JSON-RPC error the send counts as maybe sent, but a refused send stays a sure failure", async () => {
  const kv = new FakeKv();
  const chain: Chain = { pending: 0n, mined: new Set() };
  const down = async () => { throw http503(); };
  let fail = true;
  const a = copy(kv, chain, { signed: true, known: down, after: () => (fail ? ((fail = false), rpcErr("request timed out")) : undefined) });
  const out = await handle(a.ctx, req("authorize-key", await authBody(0), "198.51.100.250"));
  assert.deepEqual([out.status, out.body?.maybeSent, out.body?.hash], [202, true, hashFor(0n)]);
  assert.deepEqual(a.sends, [0n]);
  assert.equal((await handle(a.ctx, req("authorize-key", await authBody(0), "198.51.100.250"))).body?.error, "nonce in use");

  const refused = Object.assign(new Error("connect ECONNREFUSED"), { code: "ECONNREFUSED" });
  for (const [label, err] of [["refused", txErr(new TypeError("fetch failed", { cause: refused }))]] as const) {
    const kv2 = new FakeKv();
    const c2: Chain = { pending: 0n, mined: new Set() };
    let once2 = true;
    const b = copy(kv2, c2, { signed: true, known: down, broadcast: async () => { if (once2) { once2 = false; throw err; } } });
    assert.equal((await handle(b.ctx, req("authorize-key", await authBody(0), "198.51.100.250"))).status, 200, label);
    assert.deepEqual(b.sends, [0n, 0n], label);
  }
});

test("C-1: a maybe-sent relay answers 202 with maybeSent and the signed hash in the body, never a 5xx", async () => {
  const kv = new FakeKv();
  const chain: Chain = { pending: 0n, mined: new Set() };
  const a = copy(kv, chain, { signed: true, broadcast: async () => { throw txErr(new TimeoutError({ body: {}, url: "http://127.0.0.1:1" })); } });
  const out = await handle(a.ctx, req("authorize-key", await authBody(0), "198.51.100.250"));
  assert.equal(out.status, 202);
  assert.deepEqual(out.body, { ok: false, pending: true, maybeSent: true, error: "relay pending", hash: hashFor(0n) });
  assert.deepEqual(a.sends, [0n]);
  // With no local hash the body still says maybeSent, just without a hash.
  const b = copy(new FakeKv(), { pending: 0n }, { broadcast: async () => { throw txErr(http503()); } });
  const out2 = await handle(b.ctx, req("authorize-key", await authBody(0), "198.51.100.250"));
  assert.deepEqual([out2.status, out2.body?.maybeSent, out2.body?.pending, "hash" in (out2.body ?? {})], [202, true, true, false]);
});

test("C-2 with real viem: the runtime signs locally, and a JSON-RPC timeout on a send the node holds returns the node's hash", async () => {
  const seen = new Set<string>();
  let lookupDown = false;
  let refuse = false;
  const s = http.createServer((q, res) => {
    let d = "";
    q.on("data", (c) => (d += c));
    q.on("end", () => {
      const b = JSON.parse(d) as { id: number; method: string; params: unknown[] };
      res.setHeader("content-type", "application/json");
      const reply = (x: object) => res.end(JSON.stringify({ jsonrpc: "2.0", id: b.id, ...x }));
      if (b.method === "eth_getBlockByNumber") return reply({ result: { baseFeePerGas: "0x1", number: "0x1", hash: `0x${"0".repeat(64)}`, transactions: [] } });
      if (b.method === "eth_estimateGas") return reply({ result: "0x5208" });
      if (b.method === "eth_sendRawTransaction") {
        const raw = b.params[0] as Hex;
        if (refuse) return reply({ error: { code: -32000, message: "insufficient funds for gas * price + value" } });
        if (raw.length > 4) seen.add(keccak256(raw));
        return reply({ error: { code: -32603, message: "request timed out" } });
      }
      if (b.method === "eth_getTransactionByHash") {
        if (lookupDown) return reply({ error: { code: -32603, message: "internal error" } });
        return reply({ result: null });
      }
      reply({ error: { code: -32601, message: "method not found" } });
    });
  }).listen(0, "127.0.0.1");
  await new Promise((r) => s.on("listening", r));
  try {
    const u = `http://127.0.0.1:${(s.address() as { port: number }).port}`;
    const chain = defineChain({ id: 46630, name: "t", nativeCurrency: { name: "E", symbol: "E", decimals: 18 }, rpcUrls: { default: { http: [u] } } });
    const account = privateKeyToAccount(`0x${"11".repeat(32)}`);
    const t = transport(u, { retryCount: 0, timeout: 2_000 });
    const io = chainSendIo(createPublicClient({ chain, transport: t }), createWalletClient({ account, chain, transport: t }), account, 46630, TESTNET_STASH);
    const opts = { nonce: 3n, priorityWei: 1n, gasCap: 900_000n, reserve: async () => true };
    // Not found after a JSON-RPC timeout proves nothing, so it is maybe sent.
    const unknown = await sendCapped(io, 10n ** 12n, "0x01", opts).then(() => null, (e: unknown) => e);
    assert.equal(mayHaveBroadcast(unknown), true);
    const hash = [...seen][0] as Hex;
    assert.equal((unknown as { cause?: { hash?: string } }).cause?.hash ?? (unknown as { hash?: string }).hash, hash);
    // A known refusal from the node is a sure failure.
    refuse = true;
    const sure = await sendCapped(io, 10n ** 12n, "0x01", opts).then(() => null, (e: unknown) => e);
    assert.equal(mayHaveBroadcast(sure), false);
    refuse = false;
    // The node has it: counted as sent with the locally computed hash, which matches what the node saw.
    const known = { ...io, known: async (h: Hex) => h === hash };
    assert.equal(await sendCapped(known, 10n ** 12n, "0x01", opts), hash);
    // The lookup fails: maybe sent, carrying the hash.
    lookupDown = true;
    const maybe = await sendCapped(io, 10n ** 12n, "0x01", opts).then(() => null, (e: unknown) => e);
    assert.equal(mayHaveBroadcast(maybe), true);
    assert.equal((maybe as { hash?: string }).hash, hash);
  } finally {
    s.close();
  }
});

test("B-1r with real viem: a raw-send 'nonce too high' from the node heals the gap, giving 202 then 200, 200, 200", async () => {
  // The node models the sequencer: it takes only the next account nonce and answers geth's JSON-RPC errors.
  let pending = 0n;
  let dropNext = true;
  const mined = new Set<string>();
  const sent: bigint[] = [];
  const s = http.createServer((q, res) => {
    let d = "";
    q.on("data", (c) => (d += c));
    q.on("end", () => {
      const b = JSON.parse(d) as { id: number; method: string; params: unknown[] };
      const reply = (x: object, status = 200) => {
        res.writeHead(status, { "content-type": "application/json" });
        res.end(JSON.stringify({ jsonrpc: "2.0", id: b.id, ...x }));
      };
      if (b.method === "eth_sendRawTransaction") {
        const raw = b.params[0] as Hex;
        const n = BigInt(parseTransaction(raw).nonce ?? 0);
        sent.push(n);
        // A gateway 503 before the node saw it: the send may have gone out, so the relayer keeps the nonce.
        if (dropNext) return (dropNext = false), reply({ error: { code: -32603, message: "unavailable" } }, 503);
        if (n > pending) return reply({ error: { code: -32000, message: `nonce too high: address ${RELAYER}, tx: ${n} state: ${pending}` } });
        if (n < pending) return reply({ error: { code: -32000, message: `nonce too low: address ${RELAYER}, tx: ${n} state: ${pending}` } });
        pending++;
        const h = keccak256(raw);
        mined.add(h);
        return reply({ result: h });
      }
      if (b.method === "eth_getTransactionByHash") return reply({ result: null });
      reply({ error: { code: -32601, message: "method not found" } });
    });
  }).listen(0, "127.0.0.1");
  await new Promise((r) => s.on("listening", r));
  try {
    const u = `http://127.0.0.1:${(s.address() as { port: number }).port}`;
    const viemChain = defineChain({ id: 46630, name: "t", nativeCurrency: { name: "E", symbol: "E", decimals: 18 }, rpcUrls: { default: { http: [u] } } });
    const account = privateKeyToAccount(`0x${"11".repeat(32)}`);
    const t = transport(u, { retryCount: 0, timeout: 2_000 });
    const real = chainSendIo(createPublicClient({ chain: viemChain, transport: t }), createWalletClient({ account, chain: viemChain, transport: t }), account, 46630, TESTNET_STASH);
    const io: SendIo = { ...real, baseFee: async () => 20_000_000n, estimate: async () => 80_000n };
    const kv = new FakeKv();
    const chain: Chain = { pending: 0n };
    Object.defineProperty(chain, "pending", { get: () => pending });
    const a = copy(kv, chain, { io });
    const got: number[] = [];
    for (let i = 0; i < 4; i++) got.push((await handle(a.ctx, req("authorize-key", await authBody(i), `198.51.100.${10 + i}`))).status);
    assert.deepEqual(got, [202, 200, 200, 200]);
    assert.deepEqual(sent, [0n, 1n, 0n, 1n, 2n]);
    assert.equal(mined.size, 3);
    assert.equal(String(await kv.get(NKEY)), "3");
  } finally {
    s.close();
  }
});

test("H-1r: a clear refusal is retried even when the hash lookup fails, but a -32005 limit on the send is maybe sent", async () => {
  let fail = true;
  const a = copy(new FakeKv(), { pending: 0n, mined: new Set() }, {
    signed: true,
    known: async () => { throw new Error("lookup down"); },
    broadcast: async () => { if (fail) { fail = false; throw rpcErr("insufficient funds for gas * price + value"); } },
  });
  assert.equal((await handle(a.ctx, req("authorize-key", await authBody(0), "198.51.100.250"))).status, 200);
  assert.deepEqual(a.sends, [0n, 0n]);
  const limits = [
    txErr(Object.assign(new Error("rate limit exceeded"), { name: "RpcRequestError", code: -32005 })),
    rpcErr("rate limit reached for this key"),
    rpcErr("request limit exceeded"),
  ];
  for (const [i, err] of limits.entries()) {
    const b = copy(new FakeKv(), { pending: 0n, mined: new Set() }, {
      signed: true,
      known: async () => { throw new Error("lookup down"); },
      broadcast: async () => { throw err; },
    });
    const out = await handle(b.ctx, req("authorize-key", await authBody(0), `198.51.100.${240 + i}`));
    assert.deepEqual([out.status, out.body?.maybeSent, b.sends], [202, true, [0n]]);
  }
});

test("D-1r: once a raw send was tried, a cap or other failure on the retry is an unmarked 502 and the order stays taken", async () => {
  const marked = async (out: Awaited<ReturnType<typeof handle>>) => {
    const res = toResponse(out, { "access-control-expose-headers": "x-gos-relay" });
    return [out.status, out.body?.error, out.body?.sent, res.headers.get(NOT_SENT_HEADER)];
  };
  // A forwarded send answered with a limit while the lookup lags: maybe sent, no retry, no marker.
  const lag = copy(new FakeKv(), { pending: 0n, mined: new Set() }, {
    signed: true,
    known: async () => false,
    broadcast: async () => { throw txErr(Object.assign(new Error("rate limit exceeded"), { name: "RpcRequestError", code: -32005 })); },
  });
  const body = await authBody(0);
  const first = await handle(lag.ctx, req("authorize-key", body, "198.51.100.230"));
  assert.deepEqual([first.status, first.body?.sent, lag.sends], [202, undefined, [0n]]);
  // A refusal on attempt 1, then the gas price, the gas limit or the budget on attempt 2.
  const second: Partial<Faults>[] = [{ baseFee: async () => 10n ** 15n }, { estimate: async () => 10n ** 15n }];
  for (const [i, late] of second.entries()) {
    let tries = 0;
    const f: Faults = {
      signed: true,
      known: async () => false,
      broadcast: async () => { throw rpcErr("insufficient funds for gas * price + value"); },
      baseFee: async () => (tries++ === 0 ? 20_000_000n : late.baseFee ? late.baseFee() : 20_000_000n),
    };
    if (late.estimate) { let e = 0; f.estimate = async () => (e++ === 0 ? 80_000n : late.estimate!()); }
    const c = copy(new FakeKv(), { pending: 0n, mined: new Set() }, f);
    const b = await authBody(0);
    assert.deepEqual(await marked(await handle(c.ctx, req("authorize-key", b, `198.51.100.${231 + i}`))), [502, "relay failed", undefined, null]);
    assert.deepEqual(c.sends, [0n]);
    // Held: the same order cannot go again while the first send settles.
    assert.equal((await handle(c.ctx, req("authorize-key", b, `198.51.100.${235 + i}`))).status, 400);
  }
  // Nonce too high on both attempts still heals the gap, but the reply is not marked once a send was tried.
  const high = copy(new FakeKv(), { pending: 0n, mined: new Set() }, {
    signed: true,
    known: async () => false,
    broadcast: async () => { throw rpcErr("nonce too high"); },
  });
  assert.deepEqual(await marked(await handle(high.ctx, req("authorize-key", await authBody(0), "198.51.100.238"))), [502, "relay failed", undefined, null]);
});

test("B-1r: 'nonce too high' carried only in error.data, as a string or a nested message, still heals the gap", async () => {
  const datas: unknown[] = ["nonce too high: next nonce 0", { message: "nonce too high" }];
  for (const [i, data] of datas.entries()) {
    const chain = { pending: 0n, mined: new Set<string>() };
    let first = true;
    const a = copy(new FakeKv(), chain, {
      signed: true,
      broadcast: async () => {
        if (first) { first = false; throw txErr(Object.assign(new Error("Internal error"), { name: "RpcRequestError", code: -32000, data })); }
      },
    });
    const out = await handle(a.ctx, req("authorize-key", await authBody(0), `198.51.100.${220 + i}`));
    assert.equal(out.status, 200);
    assert.deepEqual(a.sends, [0n, 0n]);
  }
});

test("C-2r': 'nonce too low' after a broadcast error is looked up again, and if still unknown it is maybe sent, not retried", async () => {
  const low = rpcErr("nonce too low: address x, tx: 0 state: 1");
  // Still unknown on the second look: 202, one send.
  let looks = 0;
  const a = copy(new FakeKv(), { pending: 0n, mined: new Set() }, {
    signed: true,
    known: async () => (looks++, false),
    broadcast: async () => { throw low; },
  });
  const out = await handle(a.ctx, req("authorize-key", await authBody(0), "198.51.100.250"));
  assert.deepEqual([out.status, out.body?.maybeSent], [202, true]);
  assert.deepEqual([a.sends, looks], [[0n], 2]);
  // Found on the second look: counted as sent with that hash.
  let n = 0;
  const b = copy(new FakeKv(), { pending: 0n, mined: new Set() }, {
    signed: true,
    known: async () => n++ > 0,
    broadcast: async () => { throw low; },
  });
  const ok = await handle(b.ctx, req("authorize-key", await authBody(0), "198.51.100.251"));
  assert.deepEqual([ok.status, ok.body?.hash, b.sends], [200, hashFor(0n), [0n]]);
  // The lookup fails: maybe sent too.
  const c = copy(new FakeKv(), { pending: 0n, mined: new Set() }, {
    signed: true,
    known: async () => { throw new Error("lookup down"); },
    broadcast: async () => { throw low; },
  });
  assert.equal((await handle(c.ctx, req("authorize-key", await authBody(0), "198.51.100.252"))).status, 202);
});

test("not-sent marker: refusals before any send carry sent:false and the header, sends that may have gone out never do", async () => {
  const marked = async (out: Awaited<ReturnType<typeof handle>>) => {
    const res = toResponse(out, { "access-control-expose-headers": "x-gos-relay" });
    return [out.status, out.body?.sent, res.headers.get(NOT_SENT_HEADER)];
  };
  // Gas above the cap, found by the estimate before the send.
  const big = copy(new FakeKv(), { pending: 0n }, { estimate: async () => 10n ** 15n });
  assert.deepEqual(await marked(await handle(big.ctx, req("authorize-key", await authBody(0), "198.51.100.1"))), [400, false, "not-sent"]);
  // Gas price above the cap: a 5xx, but decided before the send.
  const cap = copy(new FakeKv(), { pending: 0n }, { baseFee: async () => 10n ** 15n });
  assert.deepEqual(await marked(await handle(cap.ctx, req("authorize-key", await authBody(0), "198.51.100.2"))), [503, false, "not-sent"]);
  assert.match(corsHeaders(null, {} as never)["access-control-expose-headers"] ?? "", /x-gos-relay/);
  // Validation.
  assert.deepEqual(await marked(await handle(cap.ctx, req("authorize-key", "{", "198.51.100.3"))), [400, false, "not-sent"]);
  // Maybe sent: no marker.
  const maybe = copy(new FakeKv(), { pending: 0n }, { broadcast: async () => { throw new TimeoutError({ body: {}, url: "http://127.0.0.1:1" }); } });
  assert.deepEqual(await marked(await handle(maybe.ctx, req("authorize-key", await authBody(0), "198.51.100.4"))), [202, undefined, null]);
  // Failed after send attempts: no marker.
  const failed = copy(new FakeKv(), { pending: 0n }, { broadcast: async () => { throw rpcErr("insufficient funds"); } });
  assert.deepEqual(await marked(await handle(failed.ctx, req("authorize-key", await authBody(0), "198.51.100.5"))), [502, undefined, null]);
  // Success: no marker.
  const ok = copy(new FakeKv(), { pending: 0n });
  assert.deepEqual(await marked(await handle(ok.ctx, req("authorize-key", await authBody(0), "198.51.100.6"))), [200, undefined, null]);
});

test("L-3: an HTTP 408 or 429 on the broadcast with a lagging lookup is maybe sent, with one send and no second nonce", async () => {
  const http408 = () => new HttpRequestError({ url: "http://127.0.0.1:1", status: 408, body: {} });
  for (const [i, err] of [txErr(http429()), txErr(http408())].entries()) {
    const a = copy(new FakeKv(), { pending: 0n, mined: new Set() }, { signed: true, known: async () => false, after: () => err });
    const out = await handle(a.ctx, req("authorize-key", await authBody(0), `198.51.100.${200 + i}`));
    assert.deepEqual([out.status, out.body?.maybeSent, a.sends], [202, true, [0n]]);
  }
});

test("L-1: a tried order is held until its deadline plus 30 s, not a flat 600 s", async () => {
  const kv = new FakeKv();
  const a = copy(kv, { pending: 0n, mined: new Set() }, { signed: true, known: async () => false, broadcast: async () => { throw rpcErr("insufficient funds"); } });
  const deadline = BigInt(kv.now / 1000 + 60);
  const body = await authBody(0, 0n, deadline);
  assert.equal((await handle(a.ctx, req("authorize-key", body, "198.51.100.210"))).status, 502);
  kv.now += 89_000;
  assert.equal((await handle(a.ctx, req("authorize-key", body, "198.51.100.211"))).body?.error, "nonce in use");
  kv.now += 2_000;
  assert.notEqual((await handle(a.ctx, req("authorize-key", body, "198.51.100.212"))).body?.error, "nonce in use");
  // A far deadline is still capped at 600 s.
  const kv2 = new FakeKv();
  const b = copy(kv2, { pending: 0n, mined: new Set() }, { signed: true, known: async () => false, broadcast: async () => { throw rpcErr("insufficient funds"); } });
  const far = await authBody(1);
  await handle(b.ctx, req("authorize-key", far, "198.51.100.213"));
  kv2.now += 599_000;
  assert.equal((await handle(b.ctx, req("authorize-key", far, "198.51.100.214"))).body?.error, "nonce in use");
  kv2.now += 2_000;
  assert.notEqual((await handle(b.ctx, req("authorize-key", far, "198.51.100.215"))).body?.error, "nonce in use");
});

test("L-2: a KV error releasing the budget after a tried send keeps the order held and unmarked", async () => {
  class BrokenRefunds extends FakeKv {
    async incrBy(key: string, by: number) {
      if (by < 0 && key.includes("spend")) throw new Error("kv down");
      return super.incrBy(key, by);
    }
  }
  const kv = new BrokenRefunds();
  const a = copy(kv, { pending: 0n, mined: new Set() }, { signed: true, known: async () => false, broadcast: async () => { throw rpcErr("insufficient funds"); } });
  const body = await authBody(0);
  const out = await handle(a.ctx, req("authorize-key", body, "198.51.100.220"));
  const res = toResponse(out, {});
  assert.deepEqual([out.status, out.body?.error, out.body?.sent, res.headers.get(NOT_SENT_HEADER)], [502, "relay failed", undefined, null]);
  const sends = a.sends.length;
  assert.equal((await handle(a.ctx, req("authorize-key", body, "198.51.100.221"))).body?.error, "nonce in use");
  assert.equal(a.sends.length, sends, "no second relay of the same order");
});
