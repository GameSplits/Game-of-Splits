import { test } from "node:test";
import assert from "node:assert/strict";
import {
  floorMin, planAmount, minOutFor, impactBps, priceCheck, bestRoute, rateOf,
  MIN_CHUNK, MAX_CALL, DAILY_CAP, MIN_GAP_S,
} from "../src/logic.mjs";
import { toEventSelector } from "viem";
import { KEEPER_SELECTORS, coreAbi } from "../src/abi.mjs";

test("selectors match cast sig", () => {
  assert.equal(KEEPER_SELECTORS.burnBuyToken, "0x2d7fd3b8"); // cast sig "burnBuyToken(uint8,uint256,uint256,uint256)"
  assert.equal(KEEPER_SELECTORS.buyForVault, "0x01137fd9"); // cast sig "buyForVault(uint256,uint256,uint256)"
  assert.equal(KEEPER_SELECTORS.settle, "0x8df82800");
  assert.equal(KEEPER_SELECTORS.finalize, "0x05261aea");
  assert.equal(KEEPER_SELECTORS.releaseAlms, "0xac834180");
});

test("floorMin matches FairCore integer math", () => {
  const rate = 7_812_500n * 10n ** 26n; // 781.25 tokens per USDG, anchor units
  assert.equal(floorMin(250_000_000n, rate), (250_000_000n * rate) / 10n ** 18n);
  assert.equal(floorMin(1n, 1n), 0n);
});

test("planAmount: min chunk, gap, cap, room", () => {
  const now = 1_800_000_000n;
  assert.deepEqual(planAmount({ pending: MIN_CHUNK - 1n, swappedToday: 0n, lastSwapAt: 0n, now }), { skip: "below-min" });
  assert.equal(planAmount({ pending: 10n ** 12n, swappedToday: 0n, lastSwapAt: 0n, now }).amt, MAX_CALL);
  assert.equal(planAmount({ pending: 7_000_000n, swappedToday: 0n, lastSwapAt: 0n, now }).amt, 7_000_000n);
  const soon = planAmount({ pending: 10n ** 12n, swappedToday: 0n, lastSwapAt: now - MIN_GAP_S + 1n, now });
  assert.equal(soon.skip, "too-soon");
  assert.equal(planAmount({ pending: 10n ** 12n, swappedToday: 0n, lastSwapAt: now - MIN_GAP_S, now }).amt, MAX_CALL);
  assert.equal(planAmount({ pending: 10n ** 12n, swappedToday: DAILY_CAP - 100_000_000n, lastSwapAt: 0n, now }).amt, 100_000_000n);
  assert.deepEqual(planAmount({ pending: 10n ** 12n, swappedToday: DAILY_CAP - 1n, lastSwapAt: 0n, now }), { skip: "daily-cap" });
  assert.deepEqual(planAmount({ pending: 10n ** 12n, swappedToday: DAILY_CAP, lastSwapAt: 0n, now }), { skip: "daily-cap" });
});

test("minOutFor: quote - 1.5%, floored, stall below the floor", () => {
  assert.deepEqual(minOutFor(1_000_000n, 900_000n), { minOut: 985_000n });
  assert.deepEqual(minOutFor(1_000_000n, 990_000n), { minOut: 990_000n }); // floor binds
  assert.deepEqual(minOutFor(1_000_000n, 1_000_000n), { minOut: 1_000_000n });
  assert.deepEqual(minOutFor(999_999n, 1_000_000n), { stall: true });
});

test("impactBps", () => {
  assert.equal(impactBps(990n, 1000n), 100n);
  assert.equal(impactBps(1000n, 1000n), 0n);
  assert.equal(impactBps(1001n, 1000n), 0n);
});

test("priceCheck: window, minimum samples, deviation", () => {
  const now = 10_000;
  const s = (dt, rate) => ({ t: now - dt, rate });
  assert.equal(priceCheck([s(10, 100n), s(20, 100n), s(30, 100n)], now, 100n).skip, "no-price-history");
  assert.equal(priceCheck([s(10, 100n), s(20, 100n), s(30, 100n), s(1900, 100n)], now, 100n).skip, "no-price-history");
  const ok = priceCheck([s(10, 100n), s(600, 100n), s(1200, 100n), s(1790, 100n)], now, 102n);
  assert.equal(ok.ok, true);
  assert.equal(ok.devBps, 200n);
  assert.equal(priceCheck([s(10, 100n), s(600, 100n), s(1200, 100n), s(1790, 100n)], now, 103n).skip, "price-off-average");
  assert.equal(priceCheck([s(10, 100n), s(600, 100n), s(1200, 100n), s(1790, 100n)], now, 97n).skip, "price-off-average");
});

test("bestRoute and rateOf", () => {
  assert.equal(bestRoute([{ ok: true, out: 5n, route: 0 }, { ok: true, out: 7n, route: 1 }]).route, 1);
  assert.equal(bestRoute([{ ok: false }, { ok: true, out: 7n, route: 1 }]).route, 1);
  assert.equal(bestRoute([{ ok: false }, { ok: false }]), null);
  assert.equal(rateOf(781_250n * 10n ** 12n * 250_000_000n, 250_000_000n), 781_250n * 10n ** 30n);
});

test("driftCheck: 2% each way, plus 1% down per 250 USDG bought this run", async () => {
  const { driftCheck } = await import("../src/logic.mjs");
  const p0 = 1_000_000n;
  assert.equal(driftCheck(p0, p0, 0n).ok, true);
  assert.equal(driftCheck(979_900n, p0, 0n).ok, false);
  assert.equal(driftCheck(980_000n, p0, 0n).ok, true);
  assert.equal(driftCheck(970_000n, p0, 250_000_000n).ok, true); // 3% allowed after one 250 USDG buy
  assert.equal(driftCheck(969_900n, p0, 250_000_000n).ok, false);
  assert.equal(driftCheck(1_020_000n, p0, 500_000_000n).ok, true);
  assert.equal(driftCheck(1_020_100n, p0, 500_000_000n).ok, false); // upward never widens
});

test("aboveAverage (L11) and feePlan (M6)", async () => {
  const { aboveAverage, feePlan } = await import("../src/logic.mjs");
  assert.equal(aboveAverage(1_020_000n, 1_000_000n), false);
  assert.equal(aboveAverage(1_020_001n, 1_000_000n), true);
  assert.deepEqual(feePlan(10_000_000n, 10n ** 9n), { maxFeePerGas: 20_000_000n, maxPriorityFeePerGas: 0n });
  assert.ok(feePlan(600_000_000n, 10n ** 9n).skip);
});

test("priceCheck ignores samples from before the keeper's last fill", () => {
  const s = [100, 400, 700, 1000, 1300].map((t) => ({ t, rate: 1000n }));
  assert.equal(priceCheck(s, 1400, 1000n).ok, true);
  assert.equal(priceCheck(s, 1400, 1000n, 500).skip, "no-price-history"); // only 3 after t=500
  // N5: four samples bunched in the last 8 minutes aren't a 30-minute average
  const bunched = [1, 2, 3, 4].map((i) => ({ t: 2000 - i * 120, rate: 1000n }));
  assert.equal(priceCheck(bunched, 2000, 1000n).skip, "no-price-history");
  // N5: the median ignores one wild sample
  const wild = [...s.slice(0, 4), { t: 1350, rate: 5000n }];
  assert.equal(priceCheck(wild, 1400, 1000n).ok, true);
});

test("RatchetReset carries the epoch (topic matches cast keccak)", () => {
  const ev = coreAbi.find((x) => x.type === "event" && x.name === "RatchetReset");
  assert.deepEqual(ev.inputs.map((i) => `${i.type} ${i.name}`), ["uint256 newAnchor", "uint64 epoch"]);
  assert.equal(toEventSelector(ev), "0x94a15d7c0b5aa71c204786bc85f9cca2a7883dcc1f878733d3e49416076f8f09"); // cast keccak "RatchetReset(uint256,uint64)"
});
