import { test } from "node:test";
import assert from "node:assert/strict";
import { afterSendFailure, loadLockwatchConfig, parseForbidden, STATUS, ZERO } from "../src/logic.mjs";

const open = { status: STATUS.Open, seedMixed: false, pairingSeed: ZERO };
const base = { RPC_URL: "http://x", CHAIN_ID: "46630", RAT: "0x" + "1".repeat(40) };

test("send failure: round already moved on is a race, not a page", () => {
  assert.equal(afterSendFailure("pair", { ...open, status: STATUS.Paired }, "execution reverted"), "raced");
  assert.equal(afterSendFailure("lockPairing", { ...open, seedMixed: true }, "whatever"), "raced");
  assert.equal(afterSendFailure("fallbackSeed", { ...open, pairingSeed: "0x" + "2".repeat(64) }, "x"), "raced");
});

test("send failure: nonce too low while the round still waits is a nonce race (round 302 case)", () => {
  const msg = "rpc eth_sendRawTransaction: nonce too low: address 0x074d2447775506B25D472Db137817Ee7c05a3A21, tx: 1 state: 2";
  assert.equal(afterSendFailure("pair", open, msg), "nonce");
  assert.equal(afterSendFailure("pair", open, "already known"), "nonce");
});

test("send failure: anything else with the round still waiting pages", () => {
  assert.equal(afterSendFailure("pair", open, "insufficient funds for gas"), "failed");
  assert.equal(afterSendFailure("pair", open, undefined), "failed");
});

test("FORBID_SENDERS parses and validates", () => {
  assert.deepEqual(parseForbidden(" 0xAbC0000000000000000000000000000000000001 ,,"), ["0xabc0000000000000000000000000000000000001"]);
  assert.deepEqual(loadLockwatchConfig({ ...base, FORBID_SENDERS: "0x4696ebA115691d7AA5A3bb810F172cdb7DCF21E5" }).forbidSenders, [
    "0x4696eba115691d7aa5a3bb810f172cdb7dcf21e5",
  ]);
  assert.throws(() => loadLockwatchConfig({ ...base, FORBID_SENDERS: "keeper" }), /FORBID_SENDERS/);
  assert.deepEqual(loadLockwatchConfig(base).forbidSenders, []);
});

test("mainnet env with an empty RAT refuses to start", () => {
  assert.throws(() => loadLockwatchConfig({ ...base, CHAIN_ID: "4663", RAT: "", DRY_RUN: "0" }), /missing env RAT/);
});
