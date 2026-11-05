import { test } from "node:test";
import assert from "node:assert/strict";
import { toFunctionSelector } from "viem";
import {
  buildChain, link, makeSeedBook, tipFor, planKeeperRound, planRotation, withRetry, makeAlertHook,
  loadRunnerConfig, ratRunnerAbi, assertPinnedRequest, send, makeClients,
} from "../src/ratrunner.mjs";
import { GAS_CAP } from "../src/logic.mjs";
import http from "node:http";
import { spawnSync } from "node:child_process";
import { encodeFunctionData } from "viem";

// public anvil/hardhat account #0 (not a secret)
const ANVIL0 = "0x" + ["ac0974bec39a17e36ba4a6b4", "d238ff944bacb478cbed5efcae784d7bf4f2ff80"].join("");
import { PAIR_DEADLINE, PAIR_LATE_DEADLINE, STATUS } from "../src/lockwatch.mjs";

const ZERO = "0x" + "0".repeat(64);
const MASTER = "0x" + "42".repeat(32);
const T = 1_800_000_000n;
const open = (o = {}) => ({ status: 0, entrants: 4, pairingSeed: ZERO, seedMixed: false, seedL2Block: 0n, ...o });
const plan = (round, dt, o = {}) => planKeeperRound({ r: 5n, round, closeTime: T, now: T + dt, nowL2: 1001n, lastSeedRound: 4n, ...o });

test("selectors match RobinAmongThieves", () => {
  for (const sig of ["revealSeed(uint256,bytes32)", "commitSeedChain(bytes32,uint64)", "lockPairing(uint256)", "pair(uint256,uint256)"]) {
    const name = sig.split("(")[0];
    assert.equal(toFunctionSelector(sig), toFunctionSelector(ratRunnerAbi.find((x) => x.name === name)));
  }
});

test("hash chain: each link is keccak256(abi.encode(next))", () => {
  const c = buildChain(MASTER, 5);
  for (let i = 5; i > 0; --i) assert.equal(c[i - 1], link(c[i]));
});

test("seed book finds the preimage of the onchain tip and counts what is left", () => {
  const b = makeSeedBook(MASTER, 32, 2);
  const tip = b.tipOf(0);
  const f = b.next(tip);
  assert.deepEqual([f.gen, f.pos, f.remaining], [0, 0, 31]);
  assert.equal(link(f.seed), tip);
  const f2 = b.next(f.seed);
  assert.equal(link(f2.seed), f.seed);
  assert.equal(b.next(b.tipOf(1)).gen, 1);
  assert.equal(b.next("0x" + "99".repeat(32)), null);
});

test("seed book reports a used-up chain", () => {
  const b = makeSeedBook(MASTER, 16, 0);
  let s = b.tipOf(0);
  for (let i = 0; i < 16; ++i) s = b.next(s).seed;
  const end = b.next(s);
  assert.equal(end.seed, null);
  assert.equal(end.remaining, 0);
});

test("tipFor switches to the next chain at nextSeedFrom", () => {
  const t = { seedTip: "0x" + "01".repeat(32), nextSeedTip: "0x" + "02".repeat(32), nextSeedFrom: 10n };
  assert.equal(tipFor(9n, t), t.seedTip);
  assert.equal(tipFor(10n, t), t.nextSeedTip);
  assert.equal(tipFor(10n, { ...t, nextSeedTip: ZERO }), t.seedTip);
});

test("reveal window is [T, T+3m), then lapsed", () => {
  assert.equal(plan(open(), -1n).action, "none");
  assert.equal(plan(open(), 0n).action, "revealSeed");
  assert.equal(plan(open(), PAIR_DEADLINE - 1n).action, "revealSeed");
  assert.equal(plan(open(), PAIR_DEADLINE).action, "lapsed");
  assert.equal(plan(open({ entrants: 0 }), 10n).action, "none");
  assert.equal(plan(open(), 10n, { lastSeedRound: 5n }).action, "lapsed");
});

test("after the reveal it locks from the next L2 block, then pairs until not Open", () => {
  const seeded = open({ pairingSeed: "0x" + "ab".repeat(32), seedL2Block: 1000n });
  assert.equal(plan(seeded, 10n).action, "lockPairing");
  assert.equal(plan(seeded, 10n, { nowL2: 1000n }).action, "wait");
  assert.equal(plan({ ...seeded, seedMixed: true }, 10n).action, "pair");
  assert.equal(plan({ ...seeded, seedMixed: true, status: STATUS.Paired }, 10n).action, "none");
  assert.equal(plan({ ...seeded, seedMixed: true }, PAIR_LATE_DEADLINE).action, "lapsed");
});

test("rotation: commit the next generation two rounds ahead when links run low", () => {
  assert.equal(planRotation({ found: { gen: 0, remaining: 200 }, cur: 7n, nextSeedTip: ZERO, rotateAt: 96, maxGen: 8 }), null);
  assert.deepEqual(planRotation({ found: { gen: 0, remaining: 95 }, cur: 7n, nextSeedTip: ZERO, rotateAt: 96, maxGen: 8 }), { gen: 1, fromRound: 9n });
  assert.equal(planRotation({ found: { gen: 0, remaining: 5 }, cur: 7n, nextSeedTip: "0x" + "01".repeat(32), rotateAt: 96, maxGen: 8 }), null);
});

test("rotation refuses past MAX_GEN instead of committing an unknown tip", () => {
  const rot = planRotation({ found: { gen: 1, remaining: 0 }, cur: 100n, nextSeedTip: ZERO, rotateAt: 4, maxGen: 1 });
  assert.deepEqual(rot, { refuse: true, nextGen: 2 });
  const book = makeSeedBook(MASTER, 16, 1);
  assert.equal(book.next(book.tipOf(2)), null);
});

test("withRetry backs off exponentially and stops on success", async () => {
  const waits = [];
  let n = 0;
  const out = await withRetry(async () => {
    if (++n < 3) throw new Error("rpc down");
    return "ok";
  }, { tries: 4, baseMs: 100, sleep: async (ms) => waits.push(ms) });
  assert.equal(out, "ok");
  assert.equal(waits.length, 2);
  assert.ok(waits[0] >= 75 && waits[0] <= 125);
  assert.ok(waits[1] >= 150 && waits[1] <= 250);
});

test("withRetry gives up after the last try and caps the wait", async () => {
  const waits = [];
  await assert.rejects(withRetry(async () => { throw new Error("x"); }, { tries: 5, baseMs: 1000, maxMs: 2000, sleep: async (ms) => waits.push(ms) }), /x/);
  assert.equal(waits.length, 4);
  assert.ok(waits.every((w) => w <= 2500));
});

test("alert hook logs redacted and posts to the webhook only when set", async () => {
  const lines = [];
  const calls = [];
  const fakeFetch = async (url, init) => { calls.push({ url, body: JSON.parse(init.body) }); return { ok: true }; };
  const cfg = { rpcUrl: "https://rpc.example/v2/SECRETKEY123", webhookUrl: "https://hooks.example/abc12345", chainId: 46630 };
  const a = makeAlertHook(cfg, (l) => lines.push(l), fakeFetch);
  assert.equal(await a("high", "t", "failed at https://rpc.example/v2/SECRETKEY123"), true);
  assert.equal(calls.length, 1);
  assert.ok(!lines.join("").includes("SECRETKEY123"));
  assert.ok(!JSON.stringify(calls[0].body).includes("SECRETKEY123"));
  const b = makeAlertHook({ ...cfg, webhookUrl: "" }, (l) => lines.push(l), fakeFetch);
  await b("normal", "t", "m");
  assert.equal(calls.length, 1);
  const bad = makeAlertHook(cfg, (l) => lines.push(l), async () => ({ ok: false, status: 500 }));
  assert.equal(await bad("high", "t", "m"), false);
});

test("config: dry run by default; live needs key, seed secret and send log", () => {
  const base = { RPC_URL: "http://x", CHAIN_ID: "46630", RAT: "0x" + "11".repeat(20) };
  assert.equal(loadRunnerConfig(base).dryRun, true);
  assert.throws(() => loadRunnerConfig({ ...base, DRY_RUN: "0" }), /KEEPER_KEY/);
  const k = "0x" + "aa".repeat(32);
  assert.throws(() => loadRunnerConfig({ ...base, DRY_RUN: "0", KEEPER_KEY: k }), /SEED_SECRET/);
  assert.throws(() => loadRunnerConfig({ ...base, DRY_RUN: "0", KEEPER_KEY: k, SEED_SECRET: k }), /SENDLOG/);
  assert.equal(loadRunnerConfig({ ...base, DRY_RUN: "0", KEEPER_KEY: k, SEED_SECRET: k, NO_SENDLOG: "1" }).dryRun, false);
  assert.throws(() => loadRunnerConfig({ ...base, CHAIN_ID: "31337" }), /CHAIN_ID/);
  assert.equal(loadRunnerConfig({ ...base, CHAIN_ID: "31337", ALLOW_LOCAL_CHAIN: "1" }).chainId, 31337);
});

test("assertPinnedRequest refuses a lying RPC's chainId and gas", () => {
  const cfg = { chainId: 46630, maxFeeWei: 1_000_000_000n };
  assert.throws(() => assertPinnedRequest({ chainId: 1, gas: 100_000n, maxFeePerGas: 1n, maxPriorityFeePerGas: 0n, nonce: 0 }, cfg), /chainId/);
  assert.throws(() => assertPinnedRequest({ chainId: 46630, gas: 30_000_000n, maxFeePerGas: 1n, maxPriorityFeePerGas: 0n, nonce: 0 }, cfg), /gas/);
  assert.throws(() => assertPinnedRequest({ chainId: 46630, gas: 100_000n, maxFeePerGas: 2_000_000_000n, maxPriorityFeePerGas: 0n, nonce: 0 }, cfg), /maxFee/);
  assertPinnedRequest({ chainId: 46630, gas: GAS_CAP, maxFeePerGas: 1_000_000_000n, maxPriorityFeePerGas: 0n, nonce: 7 }, cfg);
});

test("lying RPC (chainId 1, gas 30m) never gets a signature", async () => {
  const EVIL = { chainId: "0x1", maxFeePerGas: "0x746a528800", maxPriorityFeePerGas: "0x0", gas: "0x1c9c380" };
  const raws = [];
  const seen = [];
  const srv = http.createServer((q, s) => {
    let b = "";
    q.on("data", (d) => (b += d));
    q.on("end", () => {
      const reqs = [].concat(JSON.parse(b));
      const out = reqs.map(({ id, method, params }) => {
        seen.push(method);
        const r = (result) => ({ jsonrpc: "2.0", id, result });
        switch (method) {
          case "eth_chainId": return r("0xb626");
          case "eth_fillTransaction": {
            const t = params[0];
            return r({ raw: "0x", tx: { ...t, ...EVIL, nonce: "0x0", type: "0x2" } });
          }
          case "eth_getTransactionCount": return r("0x0");
          case "eth_getBlockByNumber": return r({
            number: "0x10", baseFeePerGas: "0x989680", timestamp: "0x1",
            hash: "0x" + "0".repeat(64), transactions: [],
          });
          case "eth_maxPriorityFeePerGas": return r("0x0");
          case "eth_estimateGas": return r("0x1c9c380"); // 30M, above GAS_CAP
          case "eth_call": return r("0x");
          case "eth_sendRawTransaction": raws.push(params[0]); return r("0x" + "ab".repeat(32));
          case "eth_getTransactionReceipt": return r({
            status: "0x1", blockNumber: "0x10", transactionHash: "0x" + "ab".repeat(32),
            logs: [], blockHash: "0x" + "0".repeat(64), cumulativeGasUsed: "0x0", gasUsed: "0x0",
            effectiveGasPrice: "0x0", from: "0x" + "0".repeat(40), to: null, contractAddress: null,
            logsBloom: "0x" + "0".repeat(512), transactionIndex: "0x0", type: "0x2",
          });
          case "eth_blockNumber": return r("0x10");
          default: return { jsonrpc: "2.0", id, error: { code: -32601, message: "no " + method } };
        }
      });
      s.setHeader("content-type", "application/json");
      s.end(JSON.stringify(Array.isArray(JSON.parse(b)) ? out : out[0]));
    });
  });
  await new Promise((r) => srv.listen(0, "127.0.0.1", r));
  try {
    const cfg = {
      rpcUrl: `http://127.0.0.1:${srv.address().port}`,
      chainId: 46630,
      rat: "0x" + "11".repeat(20),
      key: ANVIL0,
      maxFeeWei: 1_000_000_000n,
      dryRun: false,
      watcherUrl: "",
      sendlogSecret: "",
    };
    const c = makeClients(cfg);
    await assert.rejects(
      send(c, cfg, "pair", [4n, 256n], () => {}),
      /gas cap|refusing to sign/,
    );
    assert.equal(raws.length, 0, "nothing broadcast");
    // explicit pinned prepare must keep our chainId and skip fill
    seen.length = 0;
    const data = encodeFunctionData({ abi: ratRunnerAbi, functionName: "pair", args: [4n, 256n] });
    const req = await c.wallet.prepareTransactionRequest({
      to: cfg.rat, data, chainId: cfg.chainId, nonce: 7,
      maxFeePerGas: 1_000_000_000n, maxPriorityFeePerGas: 0n, gas: 2_000_000n,
    });
    assert.equal(req.chainId, 46630);
    assert.equal(seen.includes("eth_fillTransaction"), false);
    assertPinnedRequest(req, cfg);
  } finally {
    srv.close();
  }
});

test("invalid KEEPER_KEY only says invalid KEEPER_KEY", () => {
  for (const key of ["0x" + "00".repeat(32), "0x" + "ff".repeat(32)]) {
    const r = spawnSync(process.execPath, ["src/ratrunner.mjs"], {
      env: {
        PATH: process.env.PATH,
        RPC_URL: "http://127.0.0.1:1",
        CHAIN_ID: "46630",
        RAT: "0x" + "11".repeat(20),
        DRY_RUN: "0",
        KEEPER_KEY: key,
        SEED_SECRET: "0x" + "ab".repeat(32),
        NO_SENDLOG: "1",
      },
      encoding: "utf8",
      timeout: 20000,
    });
    const all = (r.stdout ?? "") + (r.stderr ?? "");
    assert.ok(/invalid KEEPER_KEY/.test(all), all.slice(0, 200));
    assert.ok(!/11579208923731619542357098500868790785/.test(all), "must not print the curve order or decimal n");
    assert.ok(!all.toLowerCase().includes(key.slice(2).toLowerCase()));
  }
});

test("dry run never prints a reveal seed", async () => {
  const lines = [];
  const seed = "0x" + "ab".repeat(32);
  const c = {
    pub: {
      async simulateContract() { return {}; },
    },
    wallet: null,
    address: "0x" + "22".repeat(20),
  };
  await send(c, { rat: "0x" + "11".repeat(20), dryRun: true }, "revealSeed", [5n, seed], (m) => lines.push(m));
  assert.equal(lines.length, 1);
  assert.ok(lines[0].includes("<seed>"));
  assert.ok(!lines[0].toLowerCase().includes(seed.slice(2).toLowerCase()));
});
