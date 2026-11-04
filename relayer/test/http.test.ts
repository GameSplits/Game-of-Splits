import assert from "node:assert/strict";
import { createServer } from "node:http";
import test from "node:test";
import { encodeFunctionData, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { stashAbi } from "../src/abi.ts";
import { TESTNET_STASH, loadConfig } from "../src/config.ts";
import { shootTypes, stashDomain, takeTypes, withdrawTypes } from "../src/eip712.ts";
import { clientIp, handle, type HandleCtx, type HandleInput } from "../src/http.ts";
import { pingHealthcheck } from "../src/ping.ts";
import { NonceQueue, OwnerNonceGuard, RateLimit, ResignBook, SpendBudget } from "../src/policy.ts";

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
      hourly: new RateLimit(60, 3_600_000),
      ips: new RateLimit(),
      resigns: new ResignBook(),
      nonces: new NonceQueue(async () => 4n),
      owners: new OwnerNonceGuard(),
      spend: new SpendBudget(10n ** 18n),
    },
    sessionKey: async () => session.address,
    stashBalance: async () => 5_000_000n,
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

test("a non-65-byte signature is refused before simulation", async () => {
  const h = harness();
  const body = JSON.parse(await shootBody()) as { signature: string };
  body.signature = `0x${"ab".repeat(40)}`;
  const out = await handle(h.ctx, post("/shoot", JSON.stringify(body)));
  assert.equal(out.status, 400);
  assert.equal(out.body?.error, "bad signature");
  assert.equal(h.simulations(), 0);
  assert.equal(h.sent.length, 0);
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

test("a take with its own line is refused, a preset take goes through", async () => {
  const h = harness();
  h.ctx.deps.send = async () => HASH as Hex;
  const custom = await handle(h.ctx, post("/take", await takeBody("Dawn is mine")));
  assert.equal(custom.status, 400);
  assert.equal(custom.body?.error, "custom lines are off");
  assert.equal(h.sent.length, 0);
  const plain = await handle(h.ctx, post("/take", await takeBody()));
  assert.equal(plain.status, 200);
  assert.equal(plain.body?.line, undefined);
});

test("lines are no longer served", async () => {
  const h = harness();
  const read = await handle(h.ctx, { method: "GET", path: "/lines", route: "lines", headers: {}, body: "", query: `?tx=${HASH}` });
  assert.deepEqual(read.body, { ok: true, lines: {} });
});

async function withdrawBody(amount: bigint): Promise<string> {
  const message = { owner: owner.address, amount, nonce: 0n, deadline: 2_000_000_000n };
  const signature = await owner.signTypedData({ domain: stashDomain(46630, TESTNET_STASH), types: withdrawTypes, primaryType: "Withdraw", message });
  return JSON.stringify({
    chainId: 46630,
    stash: TESTNET_STASH,
    order: { owner: message.owner, amount: amount.toString(), nonce: "0", deadline: message.deadline.toString() },
    signature,
  });
}

test("a withdraw at or below the 1 USDG fee is refused before it is sent", async () => {
  const h = harness();
  for (const amount of [1n, 999_999n, 1_000_000n]) {
    const out = await handle(h.ctx, post("/withdraw", await withdrawBody(amount)));
    assert.equal(out.status, 400);
    assert.equal(out.body?.error, "amount must be above the withdrawal fee");
  }
  assert.equal(h.sent.length, 0);
  const ok = await handle(h.ctx, post("/withdraw", await withdrawBody(1_000_001n)));
  assert.equal(ok.status, 200);
});

test("WITHDRAW_FEE sets the fee and must be whole units", () => {
  assert.equal(loadConfig(env({ WITHDRAW_FEE: "2000000" })).withdrawFee, 2_000_000n);
  assert.equal(loadConfig(env()).withdrawFee, 1_000_000n);
  assert.throws(() => loadConfig(env({ WITHDRAW_FEE: "1.5" })), /WITHDRAW_FEE/);
});

test("client ip prefers the Vercel edge headers over x-forwarded-for", () => {
  assert.equal(clientIp({ "x-forwarded-for": "1.2.3.4, 9.9.9.9", "x-vercel-forwarded-for": "9.9.9.9" }), "9.9.9.9");
  assert.equal(clientIp({ "x-forwarded-for": "1.2.3.4", "x-real-ip": "8.8.8.8" }), "8.8.8.8");
});

test("a withdraw is refused while the Stash balance is at or below the fee", async () => {
  for (const balance of [0n, 1n, 1_000_000n]) {
    const h = harness({ stashBalance: async () => balance });
    const out = await handle(h.ctx, post("/withdraw", await withdrawBody(2_000_000n)));
    assert.equal(out.status, 400);
    assert.equal(out.body?.error, "balance at or below the withdrawal fee");
    assert.equal(h.sent.length, 0);
  }
  const h = harness({ stashBalance: async () => 1_000_001n });
  const ok = await handle(h.ctx, post("/withdraw", await withdrawBody(1_000_001n)));
  assert.equal(ok.status, 200);
});

test("a withdraw is refused when the Stash balance cannot be read", async () => {
  const h = harness({ stashBalance: async () => { throw new Error("rpc"); } });
  const out = await handle(h.ctx, post("/withdraw", await withdrawBody(2_000_000n)));
  assert.equal(out.status, 502);
  assert.equal(h.sent.length, 0);
});
