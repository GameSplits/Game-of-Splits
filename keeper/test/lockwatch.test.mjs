import { test } from "node:test";
import assert from "node:assert/strict";
import { toFunctionSelector } from "viem";
import { planRound, afterRevert, loadLockwatchConfig, tick, ratAbi, PAIR_DEADLINE, FALLBACK_END, PAIR_LATE_DEADLINE, STATUS } from "../src/lockwatch.mjs";

const ZERO = "0x" + "0".repeat(64);
const SEED = "0x" + "ab".repeat(32);
const T = 1_800_000_000n;
const open = (o = {}) => ({ status: 0, entrants: 4, pairingSeed: SEED, seedMixed: false, seedL2Block: 1000n, ...o });
const plan = (round, dt, nowL2 = 1001n, fallback = false) => planRound({ round, closeTime: T, now: T + dt, nowL2, fallback });

test("selectors match RobinAmongThieves", () => {
  assert.equal(toFunctionSelector("lockPairing(uint256)"), toFunctionSelector(ratAbi.find((x) => x.name === "lockPairing")));
  assert.equal(toFunctionSelector("fallbackSeed(uint256)"), toFunctionSelector(ratAbi.find((x) => x.name === "fallbackSeed")));
  assert.equal(toFunctionSelector("pair(uint256,uint256)"), toFunctionSelector(ratAbi.find((x) => x.name === "pair")));
});

test("locks a revealed seed from the next L2 block until T+8m", () => {
  assert.equal(plan(open(), 10n).action, "lockPairing");
  assert.equal(plan(open(), PAIR_LATE_DEADLINE - 1n).action, "lockPairing");
  assert.equal(plan(open(), PAIR_LATE_DEADLINE).action, "none");
  assert.equal(plan(open(), 10n, 1000n).action, "wait"); // same block as the reveal
  assert.equal(plan(open(), 10n, 1000n + 257n).action, "lapsed"); // hash gone
  assert.equal(plan(open(), 10n, 1000n + 256n).action, "lapsed"); // I-1: the tx would land at 257
  assert.equal(plan(open(), 10n, 1000n + 255n).action, "lockPairing");
});

test("L-1: pairs a locked round until it leaves Open, alerts if a locked round cancels", () => {
  assert.equal(plan(open({ seedMixed: true }), 10n).action, "pair");
  assert.equal(plan(open({ seedMixed: true }), PAIR_LATE_DEADLINE - 1n, 5000n).action, "pair"); // hash age no matter
  assert.equal(plan(open({ seedMixed: true }), PAIR_LATE_DEADLINE).action, "lapsed");
  assert.equal(plan(open({ seedMixed: true, status: STATUS.Paired }), 10n).action, "none");
  assert.equal(plan(open({ seedMixed: true, status: STATUS.Cancelled }), 900n).action, "lapsed");
  assert.equal(plan(open({ seedMixed: false, status: STATUS.Cancelled }), 900n).action, "none");
});

test("leaves closed and empty rounds alone", () => {
  assert.equal(plan(open({ status: 1 }), 10n).action, "none");
  assert.equal(plan(open({ entrants: 0 }), 10n).action, "none");
  assert.equal(planRound({ round: open(), closeTime: T, now: T - 1n, nowL2: 1001n, fallback: true }).action, "none");
});

test("fallback only when enabled, from T+3m until T+7m", () => {
  const none = open({ pairingSeed: ZERO });
  assert.equal(plan(none, PAIR_DEADLINE).action, "wait");
  assert.equal(plan(none, PAIR_DEADLINE - 1n, 0n, true).action, "wait");
  assert.equal(plan(none, PAIR_DEADLINE, 0n, true).action, "fallbackSeed");
  assert.equal(plan(none, FALLBACK_END - 1n, 0n, true).action, "fallbackSeed");
  assert.equal(plan(none, FALLBACK_END, 0n, true).action, "lapsed");
});

test("config: dry run by default, live needs a key", () => {
  const base = { RPC_URL: "http://x", CHAIN_ID: "46630", RAT: "0x" + "11".repeat(20) };
  assert.equal(loadLockwatchConfig(base).dryRun, true);
  assert.throws(() => loadLockwatchConfig({ ...base, DRY_RUN: "0" }), /LOCKWATCH_KEY/);
  assert.throws(() => loadLockwatchConfig({ ...base, CHAIN_ID: "1" }), /CHAIN_ID/);
  assert.throws(() => loadLockwatchConfig({ ...base, RAT: "nope" }), /RAT/);
});

test("afterRevert tells a lost race from a real failure (K16v2 watcher Info)", () => {
  // L-3: viem returns bytes32 as hex strings, so the test uses them too
  assert.equal(afterRevert("lockPairing", { seedMixed: true, pairingSeed: SEED }), "raced");
  assert.equal(afterRevert("lockPairing", { seedMixed: false, pairingSeed: SEED }), "failed");
  assert.equal(afterRevert("fallbackSeed", { seedMixed: false, pairingSeed: SEED }), "raced");
  assert.equal(afterRevert("fallbackSeed", { seedMixed: false, pairingSeed: ZERO }), "failed");
  assert.equal(afterRevert("pair", { status: STATUS.Paired }), "raced");
  assert.equal(afterRevert("pair", { status: STATUS.Open }), "failed");
});

test("Review L1: a live lockwatch needs an alert channel; ALERTs page once per round, not every tick", async () => {
  const base = { RPC_URL: "http://x", CHAIN_ID: "46630", RAT: "0x" + "11".repeat(20), LOCKWATCH_KEY: "0x" + "22".repeat(32), DRY_RUN: "0" };
  assert.throws(() => loadLockwatchConfig(base), /PUSHOVER_TOKEN/);
  assert.equal(loadLockwatchConfig({ ...base, NO_ALERTS: "1" }).dryRun, false);
  assert.equal(loadLockwatchConfig({ ...base, ALERT_FILE: "/tmp/a.jsonl" }).alertFile, "/tmp/a.jsonl");

  const raw = Array(18).fill(0n);
  raw[10] = STATUS.Cancelled; raw[17] = true; // a locked round that was cancelled
  const pub = {
    getBlock: async () => ({ timestamp: 10_000n, number: 5000n }),
    readContract: async ({ functionName }) => (functionName === "currentRound" ? 2n : functionName === "closeTime" ? 1_000n : raw),
  };
  const sent = [];
  const c = { pub, alert: async (lvl, t, m) => sent.push([lvl, t, m]), seen: new Set() };
  const cfg = loadLockwatchConfig({ RPC_URL: "http://x", CHAIN_ID: "46630", RAT: "0x" + "11".repeat(20) });
  await tick(c, cfg, () => {});
  await tick(c, cfg, () => {});
  assert.equal(sent.length, 2); // rounds 1 and 2, once each
  assert.ok(sent.every(([lvl, , m]) => lvl === "high" && /cancelled/.test(m)));
});
