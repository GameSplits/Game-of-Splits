// Keeper flow tests with a mocked chain client and a real local HTTP send log / price endpoint (review "Tests to add").
import { test } from "node:test";
import assert from "node:assert/strict";
import { createServer } from "node:http";
import { mkdtempSync, readFileSync, existsSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { ContractFunctionExecutionError, ContractFunctionRevertedError, encodeErrorResult, parseAbi, keccak256, toHex } from "viem";
import { runKeeper } from "../src/keeper.mjs";
import { coreAbi, routeErrorsAbi } from "../src/abi.mjs";

const ME = "0x1111111111111111111111111111111111111111";
const CORE = "0x2222222222222222222222222222222222222222";
const R0 = "0x6666666666666666666666666666666666666666";
const R1 = "0x7777777777777777777777777777777777777777";
const TOKEN = "0x8888888888888888888888888888888888888888"; // the buy token
const OTHER = "0x9999999999999999999999999999999999999999"; // some other token
const ZERO = "0x0000000000000000000000000000000000000000";
const RPC = "https://rpc.example/v2/SUPERSECRETKEY123";
const NOW = 1_800_000_000;

function revertErr(name, args = []) {
  const abi = [...coreAbi, ...routeErrorsAbi];
  const data = encodeErrorResult({ abi, errorName: name, args });
  return new ContractFunctionExecutionError(new ContractFunctionRevertedError({ abi, data, functionName: "burnBuyToken" }), { abi, functionName: "burnBuyToken", args: [] });
}

/** A local watcher: records send-log POSTs, serves price samples. */
async function watcherStub({ samples, status = 200 } = {}) {
  const posts = [];
  const srv = createServer(async (req, res) => {
    let body = "";
    for await (const c of req) body += c;
    if (req.url === "/api/sendlog") {
      posts.push(JSON.parse(body));
      res.writeHead(typeof status === "function" ? status(posts.length) : status).end("{}");
    } else if (req.url === "/api/price") {
      res.writeHead(200, { "content-type": "application/json" }).end(JSON.stringify({ samples: samples.map((s) => ({ t: s.t, rate: s.rate.toString(), ...(s.e !== undefined ? { e: s.e.toString() } : {}) })) }));
    } else res.writeHead(404).end();
  });
  await new Promise((r) => srv.listen(0, "127.0.0.1", r));
  return { url: `http://127.0.0.1:${srv.address().port}`, posts, close: () => srv.close() };
}

/**
 * A mocked chain. Only the Bonfire has work (1,000 USDG pending). rate: buy-token wei per USDG unit (TestRoute.RATE),
 * may be a function of the probe count. sim(args, n): override the burnBuyToken simulation (n = call count).
 * routes: index -> [address, tokenOut]; by default route 0 delivers the buy token.
 */
function mockChain({ rate = 1_000_000_000_000n, sim, baseFee = 10_000_000n, receipts, broadcast, rateThrows, routes = { 0: [R0, TOKEN] }, reads: extraReads = {} } = {}) {
  const calls = { simulate: [], sent: [], probes: 0 };
  let nonce = 7;
  const rateNow = () => (typeof rate === "function" ? rate(calls.probes) : rate);
  const floorRate = (rate === undefined ? 0n : (typeof rate === "function" ? rate(0) : rate)) * 10n ** 18n * 9n / 10n;
  const reads = {
    currentRound: 0n, today: 0n, fairCount: 0n, keeper: ME, anchorStale: false, anchorEpoch: 0n, buyToken: TOKEN,
    ratchetFloorRate: floorRate, bonfirePending: 1_000_000_000n, vaultBurnPending: 0n, vaultBuyPending: 0n, lastSwapAt: 0n,
    swappedOnDay: 0n, ...extraReads,
  };
  const pub = {
    getChainId: async () => 4663,
    getBlock: async () => ({ timestamp: BigInt(NOW), baseFeePerGas: baseFee }),
    readContract: async ({ address, functionName, args }) => {
      if (functionName === "RATE") {
        calls.probes++;
        if (rateThrows) throw new Error(`HTTP request failed. URL: ${RPC}`);
        return rateNow();
      }
      if (functionName === "routes") return routes[Number(args[0])]?.[0] ?? ZERO;
      if (functionName === "tokenOut") return Object.values(routes).find(([a]) => a === address)[1];
      if (!(functionName in reads)) throw new Error(`unmocked read ${functionName} on ${address}`);
      return reads[functionName];
    },
    simulateContract: async (p) => {
      const n = calls.simulate.push(p);
      if (sim) {
        const r = sim(p, n);
        if (r instanceof Error) throw r;
        if (r !== undefined) return { result: r };
      }
      const [, , usdgIn, minOut] = p.args;
      const out = usdgIn * rateNow();
      if (out < minOut) throw revertErr("ShortFill");
      return { result: out };
    },
    sendRawTransaction: async ({ serializedTransaction }) => {
      if (broadcast) broadcast(calls.sent.length);
      calls.sent.push(serializedTransaction);
      return keccak256(serializedTransaction);
    },
    waitForTransactionReceipt: async () => (receipts ? receipts(calls.sent.length) : { status: "success", blockNumber: 100n + BigInt(calls.sent.length) }),
  };
  const wallet = { prepareTransactionRequest: async (r) => ({ ...r, nonce: nonce++, gas: 400_000n, type: "eip1559", chainId: 4663 }) };
  const account = { address: ME, signTransaction: async (r) => toHex(`tx:${r.nonce}:${r.data}:${Math.random()}`) };
  return { calls, clients: { pub, wallet, account, address: ME, chain: { id: 4663 } } };
}

function env(watcherUrl, extra = {}) {
  const dir = mkdtempSync(join(tmpdir(), "gosk-"));
  return {
    RPC_URL: RPC, CHAIN_ID: "4663", CORE, ARROW: "0x3333333333333333333333333333333333333333", SEAT: "0x4444444444444444444444444444444444444444",
    ALMS: "0x5555555555555555555555555555555555555555", PRICE_MODE: "testroute", DRY_RUN: "0",
    KEEPER_KEY: `0x${"ab".repeat(32)}`, WATCHER_URL: watcherUrl, SENDLOG_SECRET: "s", START_DELAY_MAX_S: "0",
    ALERT_FILE: join(dir, "alerts.jsonl"), ...extra,
  };
}
const goodSamples = (rate = 1_000_000_000_000n) => [1, 2, 3, 4, 5].map((i) => ({ t: NOW - i * 300, rate: rate * 10n ** 18n })); // spans 20+ min
const quiet = async (fn) => {
  const log = console.log;
  console.log = () => {};
  try {
    return await fn();
  } finally {
    console.log = log;
  }
};

test("1: a pre-send ShortFill() (route) retries once with a fresh quote, then skips (not an error)", async () => {
  const w = await watcherStub({ samples: goodSamples() });
  // every simulation at the keeper's minOut (quote - 1.5%) says ShortFill(); quotes at the floor fill
  const m = mockChain({ sim: (p) => (p.functionName === "burnBuyToken" && p.args[3] > p.args[2] * 900_000_000_000n ? revertErr("ShortFill") : undefined) });
  const s = await quiet(() => runKeeper(env(w.url), { clients: m.clients }));
  w.close();
  assert.equal(s.retries, 1);
  assert.equal(s.swaps.length, 0);
  assert.equal(s.errors.length, 0);
  assert.ok(s.skips.some((x) => x.reason === "ShortFill twice"));
  assert.equal(m.calls.sent.length, 0);
});

test("2: FairCore's ShortFill(uint256,uint256) is treated the same", async () => {
  const w = await watcherStub({ samples: goodSamples() });
  const m = mockChain({ sim: (p) => (p.functionName === "burnBuyToken" && p.args[3] > p.args[2] * 900_000_000_000n ? revertErr("ShortFill", [1n, 2n]) : undefined) });
  const s = await quiet(() => runKeeper(env(w.url), { clients: m.clients }));
  w.close();
  assert.equal(s.retries, 1);
  assert.equal(s.errors.length, 0);
  assert.ok(s.skips.some((x) => x.reason === "ShortFill twice"));
});

test("3+4+5: an onchain ShortFill is decoded and retried once; the retry has a new nonce, a new log entry, minOut >= floor, <= 250 USDG", async () => {
  const w = await watcherStub({ samples: goodSamples() });
  let sentCount = 0;
  const m = mockChain({
    receipts: (n) => ({ status: n === 1 ? "reverted" : "success", blockNumber: 100n + BigInt(n) }),
    // the re-simulation at the revert's block says ShortFill()
    sim: (p) => (p.blockNumber !== undefined && p.functionName === "burnBuyToken" ? revertErr("ShortFill") : undefined),
    broadcast: () => sentCount++,
  });
  const s = await quiet(() => runKeeper(env(w.url), { clients: m.clients }));
  w.close();
  assert.equal(s.retries, 1);
  assert.equal(s.swaps.length, 1);
  assert.equal(s.errors.length, 0);
  assert.equal(w.posts.length, 2, "both sends were logged");
  assert.notEqual(w.posts[0].nonce, w.posts[1].nonce, "the retry uses the next nonce");
  assert.notEqual(w.posts[0].hash, w.posts[1].hash);
  const floorRate = 1_000_000_000_000n * 10n ** 18n * 9n / 10n;
  for (const sw of s.swaps) {
    assert.ok(BigInt(sw.usdgIn) <= 250_000_000n);
    assert.ok(BigInt(sw.minOut) >= (BigInt(sw.usdgIn) * floorRate) / 10n ** 18n);
  }
  assert.ok(s.swaps.reduce((a, x) => a + BigInt(x.usdgIn), 0n) <= 250_000_000n, "never more than one planned call per ledger");
});

test("6: a failed price probe skips (fail closed)", async () => {
  const w = await watcherStub({ samples: goodSamples() });
  const m = mockChain({ rateThrows: true });
  const s = await quiet(() => runKeeper(env(w.url), { clients: m.clients }));
  w.close();
  assert.equal(m.calls.sent.length, 0);
  assert.ok(s.skips.some((x) => x.buybacks === "probe failed"));
});

test("7: price drift of more than 2% inside a run stops the run", async () => {
  const w = await watcherStub({ samples: goodSamples() });
  const base = 1_000_000_000_000n;
  const m = mockChain({ rate: (n) => (n <= 1 ? base : (base * 96n) / 100n) }); // 4% lower after the first probe
  const s = await quiet(() => runKeeper(env(w.url), { clients: m.clients }));
  w.close();
  assert.equal(m.calls.sent.length, 0);
  assert.ok(s.skips.some((x) => x.reason === "price moved during the run"));
});

test("8: a refused or failing send log means nothing is broadcast", async () => {
  for (const status of [500, 401]) {
    const w = await watcherStub({ samples: goodSamples(), status });
    const m = mockChain();
    const s = await quiet(() => runKeeper(env(w.url), { clients: m.clients }));
    w.close();
    assert.equal(m.calls.sent.length, 0, `HTTP ${status}`);
    assert.ok(s.errors.length > 0);
  }
});

test("9: a broadcast that fails after logging: the next run re-signs and logs the same nonce again", async () => {
  const w = await watcherStub({ samples: goodSamples() });
  const m1 = mockChain({ broadcast: () => { throw new Error("connection reset"); } });
  await quiet(() => runKeeper(env(w.url), { clients: m1.clients }));
  const m2 = mockChain(); // same starting nonce 7: the first tx never reached the chain
  await quiet(() => runKeeper(env(w.url), { clients: m2.clients }));
  w.close();
  assert.equal(w.posts.length, 2);
  assert.equal(w.posts[0].nonce, w.posts[1].nonce);
  assert.notEqual(w.posts[0].hash, w.posts[1].hash); // the watcher accepts either (watcher test "M1")
});

test("10: fee above the cap: skip, nothing signed", async () => {
  const w = await watcherStub({ samples: goodSamples() });
  const m = mockChain({ baseFee: 10n ** 9n }); // 1 gwei base -> 2 gwei maxFee > 1 gwei cap
  const s = await quiet(() => runKeeper(env(w.url), { clients: m.clients }));
  w.close();
  assert.equal(m.calls.sent.length, 0);
  assert.equal(w.posts.length, 0);
  assert.ok(s.skips.some((x) => x.reason === "FeeCap"));
});

test("11: error text that reaches Pushover never contains the RPC URL", async () => {
  const w = await watcherStub({ samples: goodSamples() });
  const m = mockChain({ sim: (p) => (p.functionName === "burnBuyToken" ? new Error(`HTTP request failed.\n\nURL: ${RPC}\nRequest body: {}`) : undefined) });
  const e = env(w.url);
  const s = await quiet(() => runKeeper(e, { clients: m.clients }));
  w.close();
  assert.ok(s.errors.length > 0);
  assert.ok(existsSync(e.ALERT_FILE));
  const alerts = readFileSync(e.ALERT_FILE, "utf8");
  assert.ok(alerts.includes("keeper errors"));
  assert.ok(!alerts.includes("SUPERSECRETKEY123") && !alerts.includes("rpc.example"), alerts);
});

test("price samples taken before the keeper's last fill don't count", async () => {
  const w = await watcherStub({ samples: goodSamples() });
  const m = mockChain();
  m.clients.pub.readContract = ((orig) => async (p) => (p.functionName === "lastSwapAt" ? BigInt(NOW - 700) : orig(p)))(m.clients.pub.readContract);
  const s = await quiet(() => runKeeper(env(w.url), { clients: m.clients }));
  w.close();
  assert.equal(m.calls.sent.length, 0);
  assert.ok(s.skips.some((x) => x.buybacks === "no-price-history"));
});

test("an honest run: one swap, logged before broadcast, minOut = quote - 1.5%", async () => {
  const w = await watcherStub({ samples: goodSamples() });
  const m = mockChain();
  const s = await quiet(() => runKeeper(env(w.url), { clients: m.clients }));
  w.close();
  assert.equal(s.swaps.length, 1);
  assert.equal(w.posts.length, 1);
  assert.equal(BigInt(s.swaps[0].minOut), (BigInt(s.swaps[0].quote) * 9850n) / 10000n);
});

test("F1 (N1): an undelivered push fails the keeper job", async () => {
  const w = await watcherStub({ samples: goodSamples() });
  const m = mockChain({ rateThrows: false, sim: (p) => (p.functionName === "burnBuyToken" ? new Error("rpc down") : undefined) });
  const real = globalThis.fetch;
  globalThis.fetch = async (url, init) => (String(url).includes("pushover") ? new Response('{"status":0}', { status: 500 }) : real(url, init));
  try {
    const e = env(w.url, { PUSHOVER_TOKEN: "tok12345678", PUSHOVER_GROUP: "grp12345678" });
    delete e.ALERT_FILE;
    const s = await quiet(() => runKeeper(e, { clients: m.clients }));
    assert.ok(s.errors.length > 0);
    assert.match(s.alertFailed, /pushover refused/); // main() exits 1 on this
  } finally {
    globalThis.fetch = real;
    w.close();
  }
});

test("F8 (N6): MAX_FEE_GWEI unset or empty means 1 gwei; zero or junk refuses to start", async () => {
  const { loadConfig } = await import("../src/config.mjs");
  const base = env("http://x");
  assert.equal(loadConfig({ ...base, MAX_FEE_GWEI: "" }).maxFeeWei, 10n ** 9n);
  assert.equal(loadConfig(base).maxFeeWei, 10n ** 9n);
  assert.equal(loadConfig({ ...base, MAX_FEE_GWEI: "0.5" }).maxFeeWei, 5n * 10n ** 8n);
  assert.throws(() => loadConfig({ ...base, MAX_FEE_GWEI: "0" }));
  assert.throws(() => loadConfig({ ...base, MAX_FEE_GWEI: "abc" }));
  assert.throws(() => loadConfig({ ...base, ALERT_FILE: "" }), /PUSHOVER/);
});

// ---------------------------------------------------------------- GameConfig: buy token, routes, epoch

test("G1: no anchor in the current GameConfig epoch: stand down, nothing simulated or sent", async () => {
  const w = await watcherStub({ samples: goodSamples() });
  const m = mockChain({ reads: { anchorStale: true } });
  const s = await quiet(() => runKeeper(env(w.url), { clients: m.clients }));
  w.close();
  assert.ok(s.skips.some((x) => x.buybacks === "NotSeeded"));
  assert.equal(s.errors.length, 0);
  assert.equal(m.calls.simulate.length, 0);
  assert.equal(m.calls.sent.length, 0);
});

test("G2: only routes whose tokenOut is the buy token are quoted and used", async () => {
  const w = await watcherStub({ samples: goodSamples() });
  const m = mockChain({ routes: { 0: [R0, OTHER], 1: [R1, TOKEN] } });
  const s = await quiet(() => runKeeper(env(w.url), { clients: m.clients }));
  w.close();
  assert.equal(s.swaps.length, 1);
  assert.equal(s.swaps[0].route, 1);
  assert.equal(s.swaps[0].token, TOKEN);
  assert.ok(m.calls.simulate.every((p) => p.args[1] === 1n), "route 0 (another token) never simulated");
});

test("G3: no route delivers the buy token: an error (alerted), nothing sent", async () => {
  const w = await watcherStub({ samples: goodSamples() });
  const m = mockChain({ routes: { 0: [R0, OTHER] } });
  const s = await quiet(() => runKeeper(env(w.url), { clients: m.clients }));
  w.close();
  assert.ok(s.errors.some((e) => /no route delivers the buy token/.test(e.buybacks)));
  assert.equal(m.calls.simulate.length, 0);
});

test("G4: mainnet price mode refuses a buy token with no quote pool", async () => {
  const w = await watcherStub({ samples: goodSamples() });
  const m = mockChain();
  const s = await quiet(() => runKeeper(env(w.url, { PRICE_MODE: "v4quoter" }), { clients: m.clients }));
  w.close();
  assert.ok(s.errors.some((e) => /no quote pool for buy token/.test(e.buybacks)));
  assert.equal(m.calls.simulate.length, 0);
  assert.equal(m.calls.sent.length, 0);
});

test("G5: price samples from an earlier epoch don't count", async () => {
  const w = await watcherStub({ samples: goodSamples().map((x) => ({ ...x, e: 0n })) });
  const m = mockChain({ reads: { anchorEpoch: 1n } });
  const s = await quiet(() => runKeeper(env(w.url), { clients: m.clients }));
  w.close();
  assert.ok(s.skips.some((x) => x.buybacks === "no-price-history"));
  assert.equal(m.calls.sent.length, 0);
  const w2 = await watcherStub({ samples: goodSamples().map((x) => ({ ...x, e: 1n })) });
  const s2 = await quiet(() => runKeeper(env(w2.url), { clients: mockChain({ reads: { anchorEpoch: 1n } }).clients }));
  w2.close();
  assert.equal(s2.swaps.length, 1, "samples from the current epoch do");
});
