import { test } from "node:test";
import assert from "node:assert/strict";
import { verifyKeeperTx, fillShortfallBps, floorGapBps, gapAmount, strike, ethDropLastHour, fillVsAverage } from "../lib/detectors.mjs";
import { redact, errText } from "../lib/redact.mjs";
import { readFileSync, existsSync } from "node:fs";
import { toEventSelector, toFunctionSelector } from "viem";
import { KEEPER_SELECTORS, coreAbi } from "../lib/abi.mjs";

const cfg = {
  keeper: "0x1111111111111111111111111111111111111111",
  core: "0x2222222222222222222222222222222222222222",
  arrow: "0x3333333333333333333333333333333333333333",
  seat: "0x4444444444444444444444444444444444444444",
  alms: "0x5555555555555555555555555555555555555555",
  rat: "0x6666666666666666666666666666666666666666",
  rakeBuyer: "0x7777777777777777777777777777777777777777",
};
const H = "0x" + "ab".repeat(32);
const good = { hash: H, from: cfg.keeper, nonce: 7, value: 0n, to: cfg.core, input: KEEPER_SELECTORS.burnBuyToken + "00" };

test("D1: a logged, allowed keeper tx passes", () => {
  assert.deepEqual(verifyKeeperTx(good, { hash: H }, 7n, cfg), []);
  assert.deepEqual(verifyKeeperTx({ ...good, to: cfg.seat, input: KEEPER_SELECTORS.settle }, { hash: H }, 7n, cfg), []);
  assert.deepEqual(verifyKeeperTx({ ...good, to: cfg.alms, input: KEEPER_SELECTORS.releaseAlms }, { hash: H }, 7n, cfg), []);
});

test("M-5: the RAT seed chain and RakeBuyer buys are allowed keeper calls, only on their own contract", () => {
  for (const s of ["commitSeedChain", "revealSeed", "pair", "ratSettle"]) {
    assert.deepEqual(verifyKeeperTx({ ...good, to: cfg.rat, input: KEEPER_SELECTORS[s] }, { hash: H }, 7n, cfg), [], s);
  }
  assert.deepEqual(verifyKeeperTx({ ...good, to: cfg.rakeBuyer, input: KEEPER_SELECTORS.rakeBuy }, { hash: H }, 7n, cfg), []);
  assert.deepEqual(verifyKeeperTx({ ...good, to: cfg.rakeBuyer, input: KEEPER_SELECTORS.forwardToken }, { hash: H }, 7n, cfg), []);
  assert.ok(verifyKeeperTx({ ...good, to: cfg.rat, input: KEEPER_SELECTORS.rakeBuy }, { hash: H }, 7n, cfg).some((p) => /never sends/.test(p)));
  assert.ok(verifyKeeperTx({ ...good, to: cfg.rakeBuyer, input: KEEPER_SELECTORS.commitSeedChain }, { hash: H }, 7n, cfg).some((p) => /never sends/.test(p)));
  assert.equal(KEEPER_SELECTORS.commitSeedChain, toFunctionSelector("commitSeedChain(bytes32,uint64)"));
  assert.equal(KEEPER_SELECTORS.rakeBuy, toFunctionSelector("buy(uint256,uint256,uint256)"));
});

test("D1: unlogged, ETH-moving, wrong target or wrong selector all fail", () => {
  assert.match(verifyKeeperTx(good, null, 7n, cfg)[0], /no send-log entry/);
  assert.match(verifyKeeperTx(null, { hash: H }, 7n, cfg)[0], /isn't on chain/);
  assert.ok(verifyKeeperTx({ ...good, value: 1n }, { hash: H }, 7n, cfg).some((p) => /moved ETH/.test(p)));
  assert.ok(verifyKeeperTx({ ...good, to: "0x9999999999999999999999999999999999999999" }, { hash: H }, 7n, cfg).some((p) => /not a game contract/.test(p)));
  assert.ok(verifyKeeperTx({ ...good, input: "0xa9059cbb00" }, { hash: H }, 7n, cfg).some((p) => /never sends/.test(p)));
  assert.ok(verifyKeeperTx({ ...good, to: cfg.arrow, input: KEEPER_SELECTORS.burnBuyToken }, { hash: H }, 7n, cfg).some((p) => /never sends/.test(p)));
  assert.ok(verifyKeeperTx({ ...good, to: null }, { hash: H }, 7n, cfg).some((p) => /contract creation/.test(p)));
  assert.ok(verifyKeeperTx({ ...good, nonce: 8 }, { hash: H }, 7n, cfg).some((p) => /nonce 8/.test(p)));
});

test("D2: fill shortfall", () => {
  assert.equal(fillShortfallBps(980n, 1000n), 200n);
  assert.equal(fillShortfallBps(1000n, 1000n), 0n);
  assert.equal(fillShortfallBps(1001n, 1000n), 0n);
});

test("D3/D9: floor gap, stall, daily-room gate, two strikes", () => {
  assert.equal(floorGapBps(1000n, 900n), 1000n);
  assert.equal(floorGapBps(1000n, 1000n), 0n);
  assert.equal(floorGapBps(999n, 1000n), null);
  assert.equal(gapAmount(4_999_999n, 0n), 0n);
  assert.equal(gapAmount(10n ** 12n, 0n), 250_000_000n);
  assert.equal(gapAmount(10n ** 12n, 3_000_000_000n - 4_000_000n), 0n); // no room left: doesn't count
  assert.equal(gapAmount(10n ** 12n, 3_000_000_000n - 100_000_000n), 100_000_000n);
  let s = strike(undefined, true);
  assert.deepEqual(s, { strikes: 1, fire: false });
  s = strike(s.strikes, true);
  assert.deepEqual(s, { strikes: 2, fire: true });
  assert.deepEqual(strike(s.strikes, true), { strikes: 3, fire: false });
  assert.deepEqual(strike(3, false), { strikes: 0, fire: false });
});

test("D5: ETH drop over the last hour", () => {
  const now = 100_000;
  assert.equal(ethDropLastHour([], now, 5n), 0n);
  assert.equal(ethDropLastHour([{ t: now - 600, bal: "100" }], now, 5n), 0n); // too recent to compare
  assert.equal(ethDropLastHour([{ t: now - 3600, bal: "100" }, { t: now - 600, bal: "90" }], now, 40n), 60n);
});

test("D2b (H1): fill vs the 30-min average, with an allowance for size and the keeper's own recent buys", () => {
  const avg = 1_000_000n * 10n ** 18n; // buy-token wei per USDG unit, x1e18
  const samples = [1, 2, 3, 4, 5].map((i) => ({ t: 10_000 - i * 300, rate: avg.toString() }));
  const fill = (pct, usdgIn = 250_000_000n, recentUsdg = 0n) =>
    fillVsAverage({ out: (usdgIn * 1_000_000n * BigInt(10_000 - pct * 100)) / 10_000n, usdgIn, fillT: 10_000, samples, recentUsdg });
  assert.equal(fill(2).bad, false); // 2% short on 250 USDG: allowed 3%
  assert.equal(fill(4).bad, true); // a push one block earlier: 4% short is caught
  assert.equal(fill(4, 250_000_000n, 500_000_000n).bad, false); // the keeper's own 500 USDG just before moved it: 5% allowed
  assert.equal(fill(2, 10_000_000n).bad, false);
  assert.equal(fill(3, 10_000_000n).bad, true); // tiny fill: 2.04% allowed
  assert.equal(fillVsAverage({ out: 1n, usdgIn: 1n, fillT: 10_000, samples: samples.slice(0, 3) }).ok, false); // too few samples
  assert.equal(fillVsAverage({ out: 1n, usdgIn: 1n, fillT: 20_000, samples }).ok, false); // samples too old
  const bunched = [1, 2, 3, 4, 5].map((i) => ({ t: 10_000 - i * 120, rate: avg.toString() }));
  assert.match(fillVsAverage({ out: 1n, usdgIn: 1n, fillT: 10_000, samples: bunched }).reason, /span/); // N5: 10 min isn't 30
  const wild = [...samples.slice(0, 4), { t: 9_990, rate: (avg * 3n).toString() }]; // one pumped sample
  assert.equal(fillVsAverage({ out: 250_000_000n * 1_000_000n, usdgIn: 250_000_000n, fillT: 10_000, samples: wild }).bad, false); // median
});

test("M3: redact strips URLs (keys in the path) and named secrets", () => {
  const rpc = "https://rbh.g.alchemy.com/v2/SUPERSECRETKEY123";
  const t = redact(`HTTP request failed.\nURL: ${rpc}\nstatus 500`, [rpc]);
  assert.ok(!t.includes("SUPERSECRETKEY123") && !t.includes("alchemy"));
  assert.ok(!redact("see wss://node.example/ws/KEY99999 now").includes("KEY99999"));
  assert.equal(errText({ revert: { name: "TooSoon" } }), "TooSoon");
  assert.ok(!errText(new Error(`fetch failed URL: ${rpc}`)).includes("SUPERSECRETKEY123"));
});

test("shared files are identical in keeper/ and watcher/", () => {
  for (const [k, w] of [["../keeper/src/abi.mjs", "lib/abi.mjs"], ["../keeper/src/alerts.mjs", "lib/alerts.mjs"], ["../keeper/src/redact.mjs", "lib/redact.mjs"]]) {
    const kp = new URL(`../${k}`, import.meta.url);
    if (!existsSync(kp)) continue; // the watcher's own repo has no keeper next to it
    assert.equal(readFileSync(kp, "utf8"), readFileSync(new URL(`../${w}`, import.meta.url), "utf8"), w);
  }
});

test("RatchetReset carries the epoch (topic matches cast keccak)", () => {
  const ev = coreAbi.find((x) => x.type === "event" && x.name === "RatchetReset");
  assert.equal(toEventSelector(ev), "0x94a15d7c0b5aa71c204786bc85f9cca2a7883dcc1f878733d3e49416076f8f09"); // cast keccak "RatchetReset(uint256,uint64)"
});

test("L-2: FAIRCORE_SLOTS match forge inspect (41/42, also pinned in contracts/test/unit/WatcherSlots.t.sol)", async () => {
  const { FAIRCORE_SLOTS } = await import("../lib/abi.mjs");
  assert.deepEqual(FAIRCORE_SLOTS, { lastSwapAt: 41n, swappedOnDay: 42n });
});
