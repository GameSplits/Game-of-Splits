import assert from "node:assert/strict";
import { createServer } from "node:http";
import test from "node:test";
import { encodeFunctionData, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { stashAbi } from "../src/abi.ts";
import { TESTNET_STASH, loadConfig } from "../src/config.ts";
import { shootTypes, stashDomain, takeTypes, withdrawTypes } from "../src/eip712.ts";
import { clientIp, handle, type HandleCtx, type HandleInput } from "../src/http.ts";
import { MemoryLines, cleanLine } from "../src/lines.ts";
import { pingHealthcheck } from "../src/ping.ts";
import { NonceQueue, OwnerNonceGuard, RateLimit, ResignBook } from "../src/policy.ts";

const KEY = `0x${"11".repeat(32)}` as Hex;
const OWNER_KEY = `0x${"33".repeat(32)}` as Hex;
const SESSION_KEY = `0x${"22".repeat(32)}` as Hex;
const owner = privateKeyToAccount(OWNER_KEY);
const session = privateKeyToAccount(SESSION_KEY);

function env(extra: Record<string, string> = {}): NodeJS.ProcessEnv {
  return {
    RELAYER_KEY: KEY,
    RPC_URL: "https://rpc.example.test",
    CHAIN_ID: "46630",
    STASH: TESTNET_STASH,
    ...extra,
  };
}

function harness(over: Partial<HandleCtx> = {}) {
  const sent: Hex[] = [];
  const alerts: string[] = [];
  let simulations = 0;
  const ctx: HandleCtx = {
    cfg: loadConfig(env()),
    relayer: owner.address,
    deps: {
      now: () => 1_000_000,
      simulate: async () => {
        simulations += 1;
        return { ok: true };
      },
      send: async (data) => {
        sent.push(data);
        return "0xabc";
      },
      ethBalance: async () => 10n ** 18n,
      alert: async (message) => {
        alerts.push(message);
      },
      priorityWei: 20_000_000n,
    },
    state: {
      rates: new RateLimit(),
      ips: new RateLimit(),
      resigns: new ResignBook(),
      nonces: new NonceQueue(async () => 4n),
      owners: new OwnerNonceGuard(),
    },
    sessionKey: async () => session.address,
    ...over,
  };
  return { ctx, sent, alerts, simulations: () => simulations };
}

async function shootBody(signature?: Hex): Promise<string> {
  const message = {
    owner: owner.address,
    maxPrice: 10n,
    expectedRound: 2n,
    nonce: 0n,
    deadline: 2_000_000_000n,
    epoch: 1n,
  };
  const sig =
    signature ??
    (await session.signTypedData({
      domain: stashDomain(46630, TESTNET_STASH),
      types: shootTypes,
      primaryType: "Shoot",
      message,
    }));
  return JSON.stringify({
    chainId: 46630,
    stash: TESTNET_STASH,
    order: {
      owner: message.owner,
      maxPrice: message.maxPrice.toString(),
      expectedRound: message.expectedRound.toString(),
      nonce: message.nonce.toString(),
      deadline: message.deadline.toString(),
      epoch: message.epoch.toString(),
    },
    signature: sig,
  });
}

function post(path: string, body: string, headers: HandleInput["headers"] = {}): HandleInput {
  return { method: "POST", path, route: null, headers, body };
}

test("client ip uses the first forwarded address", () => {
  assert.equal(clientIp({ "x-forwarded-for": "203.0.113.5, 10.0.0.1" }), "203.0.113.5");
  assert.equal(clientIp({}), "unknown");
});

test("a signed shoot is simulated and sent", async () => {
  const h = harness();
  const body = await shootBody();
  const out = await handle(h.ctx, post("/shoot", body, { "x-forwarded-for": "203.0.113.5" }));
  assert.equal(out.status, 200);
  assert.equal(out.body?.ok, true);
  assert.equal(out.body?.hash, "0xabc");
  assert.equal(h.simulations(), 1);
  assert.equal(h.sent.length, 1);
  const expected = encodeFunctionData({
    abi: stashAbi,
    functionName: "shoot",
    args: [
      {
        owner: owner.address,
        maxPrice: 10n,
        expectedRound: 2n,
        nonce: 0n,
        deadline: 2_000_000_000n,
        epoch: 1n,
      },
      JSON.parse(body).signature,
    ],
  });
  assert.equal(h.sent[0], expected);
});

test("paths with /api and the route query reach the same action", async () => {
  const body = await shootBody();
  const a = harness();
  assert.equal((await handle(a.ctx, post("/api/shoot", body))).status, 200);
  const b = harness();
  const viaQuery = await handle(b.ctx, { method: "POST", path: "/api/relay", route: "shoot", headers: {}, body });
  assert.equal(viaQuery.status, 200);
});

test("a bad signature is rejected before simulation", async () => {
  const h = harness();
  const good = await shootBody();
  const signature = JSON.parse(good).signature as string;
  const flipped = (signature.slice(0, -1) + (signature.endsWith("a") ? "b" : "a")) as Hex;
  const out = await handle(h.ctx, post("/shoot", await shootBody(flipped)));
  assert.equal(out.status, 400);
  assert.equal(out.body?.error, "bad signature");
  assert.equal(h.simulations(), 0);
  assert.equal(h.sent.length, 0);
});

test("a signature for another chain is rejected", async () => {
  const h = harness();
  const message = {
    owner: owner.address,
    maxPrice: 10n,
    expectedRound: 2n,
    nonce: 0n,
    deadline: 2_000_000_000n,
    epoch: 1n,
  };
  const signature = await session.signTypedData({
    domain: stashDomain(1, TESTNET_STASH),
    types: shootTypes,
    primaryType: "Shoot",
    message,
  });
  const raw = JSON.parse(await shootBody()) as { signature: string };
  raw.signature = signature;
  const out = await handle(h.ctx, post("/shoot", JSON.stringify(raw)));
  assert.equal(out.status, 400);
  assert.equal(out.body?.error, "bad signature");
  assert.equal(h.sent.length, 0);
});

test("another chain id or stash is rejected before the session is read", async () => {
  let reads = 0;
  const h = harness({
    sessionKey: async () => {
      reads += 1;
      return session.address;
    },
  });
  const body = JSON.parse(await shootBody()) as { chainId: number; stash: string };
  body.chainId = 1;
  const wrongChain = await handle(h.ctx, post("/shoot", JSON.stringify(body)));
  assert.equal(wrongChain.status, 400);
  assert.equal(wrongChain.body?.error, "wrong chain");
  body.chainId = 46630;
  body.stash = "0x0000000000000000000000000000000000000004";
  const wrongStash = await handle(h.ctx, post("/take", JSON.stringify(body)));
  assert.equal(wrongStash.status, 400);
  assert.equal(wrongStash.body?.error, "wrong stash");
  assert.equal(reads, 0);
  assert.equal(h.sent.length, 0);
});

test("simulation failure does not send", async () => {
  const h = harness();
  h.ctx.deps.simulate = async () => ({ ok: false, kind: "other", reason: "insufficient balance" });
  const out = await handle(h.ctx, post("/shoot", await shootBody()));
  assert.equal(out.status, 400);
  assert.equal(out.body?.error, "insufficient balance");
  assert.equal(h.sent.length, 0);
});

test("a missing session key is rejected", async () => {
  const h = harness({ sessionKey: async () => "0x0000000000000000000000000000000000000000" });
  const out = await handle(h.ctx, post("/shoot", await shootBody()));
  assert.equal(out.status, 400);
  assert.equal(out.body?.error, "key missing");
  assert.equal(h.sent.length, 0);
});

test("an owner withdrawal does not read the session key", async () => {
  const h = harness({
    sessionKey: async () => {
      throw new Error("session should stay unread");
    },
  });
  const message = { owner: owner.address, amount: 5_000_000n, nonce: 0n, deadline: 2_000_000_000n };
  const signature = await owner.signTypedData({
    domain: stashDomain(46630, TESTNET_STASH),
    types: withdrawTypes,
    primaryType: "Withdraw",
    message,
  });
  const out = await handle(
    h.ctx,
    post(
      "/withdraw",
      JSON.stringify({
        chainId: 46630,
        stash: TESTNET_STASH,
        order: {
          owner: message.owner,
          amount: message.amount.toString(),
          nonce: "0",
          deadline: message.deadline.toString(),
        },
        signature,
      }),
    ),
  );
  assert.equal(out.status, 200);
  assert.equal(h.sent.length, 1);
  assert.equal(h.sent[0].slice(0, 10), encodeFunctionData({
    abi: stashAbi,
    functionName: "withdraw",
    args: [message, signature],
  }).slice(0, 10));
});

test("a non-65-byte signature is left to the simulation", async () => {
  const h = harness();
  const body = JSON.parse(await shootBody()) as { signature: string };
  body.signature = `0x${"ab".repeat(40)}`;
  const out = await handle(h.ctx, post("/shoot", JSON.stringify(body)));
  assert.equal(out.status, 200);
  assert.equal(h.simulations(), 1);
});

test("rate limit is per IP", async () => {
  const h = harness();
  h.ctx.state.ips = new RateLimit(1, 60_000);
  const body = await shootBody();
  const first = await handle(h.ctx, post("/shoot", body, { "x-forwarded-for": "198.51.100.9" }));
  const second = await handle(h.ctx, post("/shoot", body, { "x-forwarded-for": "198.51.100.9" }));
  const other = await handle(h.ctx, post("/shoot", body, { "x-forwarded-for": "198.51.100.10" }));
  assert.equal(first.status, 200);
  assert.equal(second.status, 429);
  assert.equal(second.body?.error, "rate limit");
  assert.equal(other.status, 200);
});

test("unknown routes and the wrong verb are rejected", async () => {
  const h = harness();
  const missing = await handle(h.ctx, post("/deposit", "{}"));
  assert.equal(missing.status, 404);
  const verb = await handle(h.ctx, { method: "POST", path: "/health", route: null, headers: {}, body: "" });
  assert.equal(verb.status, 405);
  assert.equal(h.sent.length, 0);
});

test("health reports a low balance and alerts", async () => {
  const h = harness();
  h.ctx.deps.ethBalance = async () => 1n;
  const out = await handle(h.ctx, { method: "GET", path: "/health", route: null, headers: {}, body: "" });
  assert.equal(out.status, 200);
  assert.equal(out.body?.low, true);
  assert.equal(out.body?.balanceWei, "1");
  assert.equal(out.body?.chainId, 46630);
  assert.equal(String(out.body?.stash).toLowerCase(), TESTNET_STASH.toLowerCase());
  assert.equal(h.alerts.length, 1);
  assert.match(h.alerts[0], /0\.005 ETH/);
  assert.equal(h.alerts[0].includes(KEY), false);
});

test("health returns unavailable when the balance read fails", async () => {
  const h = harness();
  h.ctx.deps.ethBalance = async () => {
    throw new Error("rpc");
  };
  const out = await handle(h.ctx, { method: "GET", path: "/api/health", route: null, headers: {}, body: "" });
  assert.equal(out.status, 503);
  assert.equal(out.body?.error, "balance unavailable");
  assert.equal(h.alerts.length, 0);
});

test("the healthcheck ping is a POST and a dead url does not throw", async () => {
  let method = "";
  const server = createServer((req, res) => {
    method = req.method ?? "";
    res.writeHead(204);
    res.end();
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", () => resolve()));
  const addr = server.address();
  const port = typeof addr === "object" && addr ? addr.port : 0;
  await pingHealthcheck(`http://127.0.0.1:${port}/fail`);
  assert.equal(method, "POST");
  await new Promise<void>((resolve, reject) => server.close((err) => (err ? reject(err) : resolve())));
  await pingHealthcheck("http://127.0.0.1:1/absent");
});

async function takeBody(line?: unknown): Promise<string> {
  const message = { owner: owner.address, maxPrice: 10n, presetId: 0, color: 3, nonce: 0n, deadline: 2_000_000_000n, epoch: 1n };
  const sig = await session.signTypedData({ domain: stashDomain(46630, TESTNET_STASH), types: takeTypes, primaryType: "Take", message });
  return JSON.stringify({
    chainId: 46630,
    stash: TESTNET_STASH,
    order: {
      owner: message.owner,
      maxPrice: "10",
      presetId: 0,
      color: 3,
      nonce: "0",
      deadline: message.deadline.toString(),
      epoch: "1",
    },
    signature: sig,
    ...(line === undefined ? {} : { line }),
  });
}

const HASH = `0x${"ab".repeat(32)}`;

test("a one-click take saves the player's own line under the take's hash", async () => {
  const lines = new MemoryLines();
  const h = harness({ lines });
  h.ctx.deps.send = async () => HASH as Hex;
  const out = await handle(h.ctx, post("/take", await takeBody("  Dawn is   mine  ")));
  assert.equal(out.status, 200);
  assert.equal(out.body?.line, "saved");
  assert.deepEqual(await lines.getMany([HASH]), { [HASH]: "Dawn is mine" });
  const read = await handle(h.ctx, { method: "GET", path: "/lines", route: "lines", headers: {}, body: "", query: `?tx=${HASH},nothash` });
  assert.deepEqual(read.body, { ok: true, lines: { [HASH]: "Dawn is mine" } });
});

test("a take without a line, or with a filtered line, still goes through", async () => {
  const lines = new MemoryLines();
  const h = harness({ lines });
  h.ctx.deps.send = async () => HASH as Hex;
  const plain = await handle(h.ctx, post("/take", await takeBody()));
  assert.equal(plain.status, 200);
  assert.equal(plain.body?.line, undefined);
  const h2 = harness({ lines });
  h2.ctx.deps.send = async () => HASH as Hex;
  const bad = await handle(h2.ctx, post("/take", await takeBody("visit www.scam.xyz now")));
  assert.equal(bad.status, 200);
  assert.equal(bad.body?.line, "refused");
  assert.deepEqual(await lines.getMany([HASH]), {});
});

test("a store failure never fails the take", async () => {
  const h = harness({ lines: { set: async () => { throw new Error("down"); }, getMany: async () => ({}) } });
  h.ctx.deps.send = async () => HASH as Hex;
  const out = await handle(h.ctx, post("/take", await takeBody("Hold the line")));
  assert.equal(out.status, 200);
  assert.equal(out.body?.line, "unsaved");
});

test("lines are cleaned and filtered", () => {
  assert.equal(cleanLine("x".repeat(80))?.length, 64);
  assert.equal(cleanLine("grapes and scunthorpe"), "grapes and scunthorpe");
  assert.equal(cleanLine("r4pe"), null);
  assert.equal(cleanLine("send me your seed phrase"), null);
  assert.equal(cleanLine("t.me/x"), null);
  assert.equal(cleanLine("   "), null);
  assert.equal(cleanLine(42), null);
});

test("the Upstash store sends SET with a TTL and reads with MGET", async () => {
  const { UpstashLines } = await import("../src/lines.ts");
  const calls: Array<{ url: string; auth: string; body: unknown }> = [];
  const fake = (async (url: string, init: RequestInit) => {
    calls.push({ url, auth: String((init.headers as Record<string, string>).authorization), body: JSON.parse(String(init.body)) });
    const cmd = (JSON.parse(String(init.body)) as unknown[][])[0];
    const result = cmd[0] === "MGET" ? ["Dawn is mine", null] : "OK";
    return new Response(JSON.stringify([{ result }]), { status: 200 });
  }) as unknown as typeof fetch;
  const store = new UpstashLines("https://example.upstash.io/", "tok", fake);
  await store.set(HASH.toUpperCase().replace("0X", "0x"), "Dawn is mine");
  const other = `0x${"cd".repeat(32)}`;
  assert.deepEqual(await store.getMany([HASH, other]), { [HASH]: "Dawn is mine" });
  assert.equal(calls[0].url, "https://example.upstash.io/pipeline");
  assert.equal(calls[0].auth, "Bearer tok");
  assert.deepEqual(calls[0].body, [["SET", `seatline:${HASH}`, "Dawn is mine", "EX", String(60 * 60 * 24 * 120)]]);
  assert.deepEqual(calls[1].body, [["MGET", `seatline:${HASH}`, `seatline:${other}`]]);
});

test("client ip prefers the Vercel edge headers over x-forwarded-for", () => {
  assert.equal(clientIp({ "x-forwarded-for": "1.2.3.4, 9.9.9.9", "x-vercel-forwarded-for": "9.9.9.9" }), "9.9.9.9");
  assert.equal(clientIp({ "x-forwarded-for": "1.2.3.4", "x-real-ip": "8.8.8.8" }), "8.8.8.8");
});
