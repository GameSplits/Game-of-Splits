// Watcher pass tests with a mocked chain (review "Tests to add", watcher list).
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { ContractFunctionExecutionError, ContractFunctionRevertedError, encodeErrorResult } from "viem";
import { runCheck, guardSlots } from "../lib/check.mjs";
import { loadConfig } from "../lib/config.mjs";
import { fileStore } from "../lib/state.mjs";
import { sendlogKey } from "../lib/sendlog.mjs";
import { coreAbi, routeErrorsAbi, KEEPER_SELECTORS } from "../lib/abi.mjs";

const T0 = 1_800_000_000;
const K = "0x1111111111111111111111111111111111111111";
const CORE = "0x2222222222222222222222222222222222222222";
const R0 = "0x6666666666666666666666666666666666666666";
const CFG = "0x9999999999999999999999999999999999999999"; // GameConfig
const RAT = "0xAbababababababababababababababababababab".toLowerCase();
const RAKE = "0xCdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd".toLowerCase();
const TOKEN = "0xaAaAaAaaAaAaAaaAaAAAAAAAAaaaAaAaAaaAaaAa"; // the buy token
const RATE = 1_000_000n; // buy-token wei per USDG unit
const ts = (b) => T0 + Number(b) * 10;

const cfgOf = (extra = {}) => loadConfig({
  RPC_URL: "http://rpc.invalid", CHAIN_ID: "4663", CORE, ARROW: "0x3333333333333333333333333333333333333333",
  SEAT: "0x4444444444444444444444444444444444444444", ALMS: "0x5555555555555555555555555555555555555555",
  PASS: "0x7777777777777777777777777777777777777777", VAULT: "0x8888888888888888888888888888888888888888", KEEPER: K,
  RAT: RAT, RAKE_BUYER: RAKE,
  START_BLOCK: "1", HEALTHCHECK_URL: "http://hc.invalid", NONCE_START: "0", OIDC_REQUIRED: "0", PRICE_MODE: "testroute",
  CONFIRMATIONS: "0", PUSHOVER_TOKEN: "t", PUSHOVER_GROUP: "g", ...extra, // alerts go to the injected alert()
});

function revertErr(name, args = []) {
  const abi = [...coreAbi, ...routeErrorsAbi];
  return new ContractFunctionExecutionError(new ContractFunctionRevertedError({ abi, data: encodeErrorResult({ abi, errorName: name, args }), functionName: "burnBuyToken" }), { abi, functionName: "burnBuyToken", args: [] });
}
const notFound = () => Object.assign(new Error("Transaction not found"), { name: "TransactionNotFoundError" });

/** A mocked chain. `o` fields can be changed between passes. */
function chain(o = {}) {
  const m = {
    head: 100n, nonce: 0, balance: 10n ** 18n, logs: [], txs: {}, floorRate: RATE * 10n ** 18n * 9n / 10n,
    pending: { bonfirePending: 0n, vaultBurnPending: 0n, vaultBuyPending: 0n }, lastSwapAt: 0n, keeper: K, epoch: 0n,
    stale: false, buyToken: TOKEN,
    archiveDown: false, quote: null, simCalls: [], logsThrow: false, ...o,
  };
  const pub = {
    getBlockNumber: async () => m.head,
    getBlock: async ({ blockNumber } = {}) => {
      if (m.blockThrow && blockNumber !== undefined && m.blockThrow.includes(BigInt(blockNumber))) throw new Error("getBlock failed");
      return { timestamp: BigInt((m.timeOf ?? ts)(blockNumber ?? m.head)) };
    },
    readContract: async ({ functionName, args }) => {
      if (functionName === "routes") return R0;
      if (functionName === "tokenOut") return TOKEN;
      if (functionName === "RATE") return RATE;
      if (functionName === "keeper") return m.keeper;
      if (functionName === "config") return CFG;
      if (functionName === "epoch") return m.epoch;
      if (functionName === "buyToken") return m.buyToken;
      if (functionName === "anchorStale") return m.stale;
      if (functionName === "ratchetFloorRate") return m.floorRate;
      if (functionName === "swappedOnDay") return 0n;
      if (functionName === "lastSwapAt") return m.lastSwapAt;
      if (functionName === "buyPending") return m.rakePending ?? 0n;
      if (functionName === "legPending") return m.rakeLeg ?? 0n;
      if (functionName === "boughtOnDay") return m.rakeBought ?? 0n;
      if (functionName === "usdg") return "0x" + "5d".repeat(20);
      if (functionName === "balanceOf") return m.rakeBal ?? (m.rakePending ?? 0n) + (m.rakeLeg ?? 0n);
      if (functionName === "rounds" && m.roundsThrow) throw new Error("missing trie node");
      if (functionName === "rounds") { const t = Array(18).fill(0n); t[17] = (m.lockedRounds ?? []).includes(args[0]); return t; }
      if (functionName in m.pending) return m.pending[functionName];
      throw new Error(`unmocked ${functionName}`);
    },
    simulateContract: async (p) => {
      m.simCalls.push(p);
      if (m.archiveDown) throw new Error("HTTP request failed. URL: https://archive.example/v2/KEY");
      if (typeof m.quote === "function") {
        const r = m.quote(p);
        if (r instanceof Error) throw r;
        return { result: r };
      }
      return { result: p.args[2] * RATE };
    },
    getLogs: async ({ address, events, fromBlock, toBlock }) => {
      if (m.logsThrow) throw new Error("getLogs exploded");
      const names = new Set(events.map((e) => e.name));
      return m.logs.filter((l) => l.address.toLowerCase() === address.toLowerCase() && names.has(l.eventName) && l.blockNumber >= fromBlock && l.blockNumber <= toBlock);
    },
    getTransaction: async ({ hash }) => {
      if (m.txs[hash]) return m.txs[hash];
      const l = m.logs.find((x) => x.transactionHash === hash);
      if (l) return { hash, from: K, nonce: 0, value: 0n, to: CORE, blockNumber: l.blockNumber };
      throw notFound();
    },
    getTransactionCount: async () => m.nonce,
    getBalance: async () => m.balance,
  };
  return { m, clients: { pub, archive: pub } };
}
function rig(o) {
  const store = fileStore(join(mkdtempSync(join(tmpdir(), "gosw-")), "s.json"));
  const alerts = [];
  const alert = async (level, title, message) => alerts.push({ level, title, message });
  const { m, clients } = chain(o);
  return { m, store, alerts, run: (cfg = cfgOf()) => runCheck(cfg, store, alert, { clients }) };
}
const titles = (a) => a.map((x) => `${x.level}:${x.title}`);
const H = (n) => `0x${n.toString(16).padStart(64, "0")}`;
const fillLog = (block, usdgIn, out, i = 0) => ({
  address: CORE, eventName: "Burned", blockNumber: BigInt(block), transactionHash: H(1000 + block), logIndex: i,
  args: { token: TOKEN, source: 0, route: 0n, usdgIn, out, minOut: 1n },
});
const samplesBefore = (t, rate = RATE * 10n ** 18n) => [1, 2, 3, 4, 5].map((i) => ({ t: t - i * 300, rate: rate.toString() }));

test("first pass: state missing and nonce baseline missing both alert (expected once at setup)", async () => {
  const r = rig();
  await r.run();
  assert.deepEqual(titles(r.alerts).sort(), ["high:nonce baseline missing", "high:watcher state not found"]);
  r.alerts.length = 0;
  r.m.head = 110n;
  await r.run();
  assert.equal(r.alerts.length, 0);
});

test("H4: a wiped w:state alerts; a wiped w:nonce re-checks from NONCE_START, never silently from 'now'", async () => {
  const r = rig({ nonce: 2 });
  await r.store.rpush(sendlogKey(4663, 0), { hash: H(1) });
  r.m.txs[H(1)] = { hash: H(1), from: K, nonce: 0, value: 0n, to: CORE, input: KEEPER_SELECTORS.burnBuyToken, blockNumber: 5n };
  await r.run(); // nonce 1 is unlogged
  assert.ok(titles(r.alerts).includes("emergency:keeper tx not accounted for"));
  r.alerts.length = 0;
  await r.store.del("w:state");
  await r.store.del("w:nonce");
  r.m.head = 120n;
  await r.run();
  const t = titles(r.alerts);
  assert.ok(t.includes("high:watcher state not found"));
  assert.ok(t.includes("high:nonce baseline missing"));
  assert.ok(t.includes("emergency:keeper tx not accounted for"), "nonce 1 is checked again from NONCE_START=0, not skipped");
});

test("H4: getLogs throwing doesn't stop the nonce or ETH checks; the scan isn't marked done", async () => {
  const r = rig({ nonce: 1, logsThrow: true });
  const rep = await r.run();
  const t = titles(r.alerts);
  assert.ok(t.includes("emergency:keeper tx not accounted for"), "D1 still ran");
  assert.ok(t.some((x) => x.startsWith("high:watcher detector failed")));
  assert.ok(rep.errors.some((e) => e.startsWith("event scan")));
  const st = await r.store.get("w:state");
  assert.equal((await r.store.get("w:scan"))?.lastBlock, undefined, "the failed range is scanned again next pass");
  assert.equal(st.eth.length, 1, "D5 still sampled the balance");
});

test("M1: an honest re-sign (two logged entries for one nonce) is accepted", async () => {
  const r = rig({ nonce: 1 });
  await r.run(); // baseline
  await r.store.set("w:nonce", "0");
  await r.store.rpush(sendlogKey(4663, 0), { hash: H(1) }); // logged, broadcast failed
  await r.store.rpush(sendlogKey(4663, 0), { hash: H(2) }); // re-signed and mined
  r.m.txs[H(2)] = { hash: H(2), from: K, nonce: 0, value: 0n, to: CORE, input: KEEPER_SELECTORS.burnBuyToken, blockNumber: 5n };
  r.alerts.length = 0;
  await r.run();
  assert.equal(r.alerts.length, 0, titles(r.alerts).join());
});

test("M4: three stalled ledgers give ONE push listing all three, then nothing until it changes", async () => {
  const r = rig({ floorRate: RATE * 10n ** 18n * 11n / 10n, pending: { bonfirePending: 10n ** 9n, vaultBurnPending: 10n ** 9n, vaultBuyPending: 10n ** 9n } });
  await r.run();
  r.alerts.length = 0;
  r.m.head = 112n;
  await r.run(); // second strike
  const stalls = r.alerts.filter((a) => a.title.startsWith("stall"));
  assert.equal(stalls.length, 1);
  assert.equal(stalls[0].title, "stall: anchor above market: Bonfire, Vault burn, Vault buy");
  assert.equal(stalls[0].message.split("\n").length, 4); // one line per ledger + the footer
  r.alerts.length = 0;
  r.m.head = 124n;
  await r.run();
  assert.equal(r.alerts.length, 0);
});

test("M8: a pass holding the lock makes the next one skip", async () => {
  const r = rig();
  assert.equal(await r.store.lock("w:lock", "other", 110), true);
  const rep = await r.run();
  assert.match(rep.skipped, /lock/);
  assert.equal(r.alerts.length, 0);
});

test("H2: archive RPC down -> the fill is queued, the archive alert fires (redacted), and it's verified next pass", async () => {
  const r = rig({ archiveDown: true });
  await r.store.set("w:price", samplesBefore(ts(50)));
  r.m.logs = [fillLog(50, 250_000_000n, 250_000_000n * RATE)];
  await r.run();
  let st = await r.store.get("w:scan");
  assert.equal(st.pendingFills.length, 1, "queued, not dropped");
  const arch = r.alerts.find((a) => a.title === "fill check: archive RPC failing");
  assert.ok(arch && arch.level === "high");
  assert.ok(!arch.message.includes("KEY") && !arch.message.includes("archive.example"), arch.message);
  r.m.archiveDown = false;
  r.m.head = 112n;
  await r.run();
  st = await r.store.get("w:scan");
  assert.equal(st.pendingFills.length, 0, "verified on the retry");
});

test("H2: with no archive and no price history, the fill raises 'fill not verified yet' (never just a note)", async () => {
  const r = rig({ archiveDown: true });
  r.m.logs = [fillLog(50, 250_000_000n, 250_000_000n * RATE)];
  await r.run();
  assert.ok(titles(r.alerts).includes("high:fill not verified yet"));
});

test("H2: a fill right after the 50-min gap is re-simulated with lastSwapAt/swappedOnDay zeroed", async () => {
  const r = rig();
  await r.store.set("w:price", samplesBefore(ts(50)));
  r.m.logs = [fillLog(50, 250_000_000n, 250_000_000n * RATE)];
  // the real prior-block state says TooSoon; only an overridden call fills
  r.m.quote = (p) => (p.stateOverride ? p.args[2] * RATE : revertErr("TooSoon", [1n]));
  await r.run();
  const sim = r.m.simCalls.find((p) => p.functionName === "burnBuyToken");
  const slots = guardSlots(0, BigInt(ts(49)) / 86400n);
  assert.deepEqual(sim.stateOverride[0].stateDiff.map((d) => d.slot), [slots.lastSwapAt, slots.swappedOnDay]);
  assert.equal(sim.blockNumber, 49n);
  const st = await r.store.get("w:scan");
  assert.equal(st.pendingFills.length, 0);
  assert.equal(r.alerts.filter((a) => a.title === "bad buyback fill").length, 0);
});

test("H1: a fill 5% under the 30-min average is an emergency even when the prior-block quote matches it", async () => {
  const r = rig();
  await r.store.set("w:price", samplesBefore(ts(50)));
  const out = (250_000_000n * RATE * 95n) / 100n;
  r.m.logs = [fillLog(50, 250_000_000n, out)];
  r.m.quote = () => out; // the price was pushed in block 49: the prior-block simulation agrees with the bad fill
  await r.run();
  const bad = r.alerts.filter((a) => a.title === "bad buyback fill");
  assert.equal(bad.length, 1);
  assert.equal(bad[0].level, "emergency");
  assert.match(bad[0].message, /30-min average/);
});

test("M9: heartbeat fires from GO_LIVE_AT when the keeper has never swapped", async () => {
  const r = rig({ pending: { bonfirePending: 10n ** 9n, vaultBurnPending: 0n, vaultBuyPending: 0n } });
  await r.run(cfgOf({ GO_LIVE_AT: String(ts(100) - 4 * 3600) }));
  assert.ok(r.alerts.some((a) => a.title === "keeper not buying" && /never swapped/.test(a.message)));
});

test("M4: owner events inside MAINTENANCE_UNTIL come as one digest", async () => {
  const r = rig();
  r.m.logs = [1, 2, 3].map((i) => ({ address: CORE, eventName: "SalesPaused", blockNumber: BigInt(10 + i), transactionHash: H(i), logIndex: 0, args: { paused: true } }));
  await r.run(cfgOf({ MAINTENANCE_UNTIL: String(ts(100) + 3600) }));
  const d = r.alerts.filter((a) => a.title.startsWith("owner events"));
  assert.equal(d.length, 1);
  assert.equal(d[0].message.split("\n").length, 3);
  assert.equal(r.alerts.filter((a) => a.title === "core.SalesPaused").length, 0);
});

// ---------------------------------------------------------------- v3 (v2 re-audit)
test("F2 (N2): an alert that fails to send is raised again next pass; nothing advances until it's delivered", async () => {
  const r = rig({ nonce: 0 });
  await r.run(); // baseline
  r.alerts.length = 0;
  r.m.nonce = 1; // an unlogged keeper tx appears
  let fail = true;
  const flaky = async (level, title, message) => {
    if (fail) throw new Error("pushover refused: HTTP 500");
    r.alerts.push({ level, title, message });
  };
  const { clients } = chain();
  Object.assign(clients.pub, { getTransactionCount: async () => 1 });
  const rep1 = await runCheck(cfgOf(), r.store, flaky, { clients });
  assert.ok(rep1.errors.some((e) => e.startsWith("alert delivery failed (nonce)")), "a failed send is an error -> /fail ping");
  assert.equal(await r.store.get("w:nonce"), "0", "the nonce baseline didn't move");
  fail = false;
  await runCheck(cfgOf(), r.store, flaky, { clients });
  assert.deepEqual(titles(r.alerts), ["emergency:keeper tx not accounted for"]);
  assert.equal(await r.store.get("w:nonce"), "1");
});

test("F4 (N4): a fill with no 30-min samples is checked by the prior block AND raises a high alert", async () => {
  const r = rig();
  r.m.logs = [fillLog(50, 250_000_000n, 250_000_000n * RATE)];
  await r.run();
  const a = r.alerts.find((x) => x.title === "fill checked by prior-block only (no 30-min samples)");
  assert.ok(a && a.level === "high");
  assert.equal((await r.store.get("w:scan")).pendingFills.length, 0);
});

test("F6 (H2): a fill in the first block after 00:00 UTC, with the daily cap full at the prior block, is verified", async () => {
  // block 50 is exactly midnight: block 49 belongs to the previous UTC day
  const DAY = 20_833n;
  const T0m = Number(DAY * 86400n) - 500;
  const r = rig();
  r.m.timeOf = (b) => T0m + Number(b) * 10;
  r.m.logs = [fillLog(50, 250_000_000n, 250_000_000n * RATE)];
  await r.store.set("w:price", [1, 2, 3, 4, 5].map((i) => ({ t: T0m + 500 - i * 300, rate: (RATE * 10n ** 18n).toString() })));
  const prevDaySlots = guardSlots(0, DAY - 1n);
  r.m.quote = (p) => (p.stateOverride?.[0].stateDiff.some((d) => d.slot === prevDaySlots.swappedOnDay) ? p.args[2] * RATE : revertErr("DailyCap"));
  const { clients } = chain(r.m);
  const rep = await runCheck(cfgOf(), r.store, async (...a) => r.alerts.push({ level: a[0], title: a[1], message: a[2] }), { clients });
  const f = rep.fills[0];
  assert.equal(f.d2a, "ok", JSON.stringify(f));
  assert.equal(f.d2b, "ok");
  assert.equal(r.alerts.filter((a) => /fill/.test(a.title)).length, 0);
});

test("F7 (N3): a lost w:scan alerts, and the newest blocks are scanned first while the backlog drains", async () => {
  const r = rig({ head: 1_000_000n });
  const cfg = cfgOf({ MAX_BLOCK_RANGE: "1000" });
  await r.run(cfg);
  await r.store.del("w:scan");
  r.alerts.length = 0;
  r.m.head = 1_000_100n;
  // an owner event at the tip: it must alert this pass, not after ~1,000 catch-up passes
  r.m.logs = [{ address: CORE, eventName: "OpQueued", blockNumber: 1_000_090n, transactionHash: H(77), logIndex: 0, args: { id: H(1), op: 1, key: 0n, value: K, eta: 1n } }];
  const rep = await r.run(cfg);
  assert.ok(titles(r.alerts).includes("high:scan position missing"));
  assert.ok(titles(r.alerts).includes("emergency:core.OpQueued"), "tip event alerted during the backlog");
  assert.deepEqual(rep.scanned[1], ["1", "1000"], "backlog continues from START_BLOCK");
});

test("F1 (N1): missing Pushover config refuses to load; ALERT_FILE alone is fine", () => {
  assert.throws(() => cfgOf({ PUSHOVER_TOKEN: "", PUSHOVER_GROUP: "" }), /PUSHOVER/);
  assert.doesNotThrow(() => cfgOf({ PUSHOVER_TOKEN: "", PUSHOVER_GROUP: "", ALERT_FILE: "/tmp/x.jsonl" }));
});

// ---------------------------------------------------------------- GameConfig
test("G1: GameConfig queues and executes alert every signer (emergency); a cancel is high", async () => {
  const r = rig();
  await r.run();
  r.alerts.length = 0;
  const ev = (i, eventName, args) => ({ address: CFG, eventName, blockNumber: BigInt(100 + i), transactionHash: H(500 + i), logIndex: 0, args });
  const split = { purseBps: 6000, almsBps: 2000, bonfireBps: 1750, tollBps: 1750, vBuyBps: 2500, vLiqBps: 2500, vBurnBps: 2500 };
  r.m.logs = [
    ev(1, "TokensQueued", { nextEpoch: 1n, playToken: TOKEN, passLock: 1n, buyToken: TOKEN, eta: 1n }),
    ev(2, "SplitQueued", { s: split, eta: 1n }),
    ev(3, "TokensCancelled", {}),
    ev(4, "TokensExecuted", { epoch: 1n, playToken: TOKEN, passLock: 1n, buyToken: TOKEN }),
    ev(5, "OwnershipTransferStarted", { previousOwner: K, newOwner: CORE }),
  ];
  r.m.head = 110n;
  await r.run();
  const t = titles(r.alerts);
  for (const want of ["emergency:config.TokensQueued", "emergency:config.SplitQueued", "high:config.TokensCancelled", "emergency:config.TokensExecuted", "emergency:config.OwnershipTransferStarted"]) {
    assert.ok(t.includes(want), `missing ${want} in ${t}`);
  }
});

test("G2: a new GameConfig epoch drops the stored price samples; new samples carry the epoch and token", async () => {
  const r = rig();
  await r.store.set("w:price", samplesBefore(ts(100)));
  await r.run();
  assert.equal((await r.store.get("w:price")).length, 6, "same epoch: kept");
  r.m.epoch = 1n;
  r.m.head = 101n;
  const rep = await r.run();
  const p = await r.store.get("w:price");
  assert.equal(p.length, 1, "only this pass's sample");
  assert.equal(p[0].e, 1);
  assert.equal(p[0].k, TOKEN);
  assert.ok(rep.notes.some((n) => /earlier epochs dropped/.test(n)));
});

test("G3: a stale anchor (new epoch, not re-seeded) is NotSeeded; gap/stall/heartbeat stay quiet", async () => {
  const r = rig({ stale: true, floorRate: 0n, pending: { bonfirePending: 10n ** 9n, vaultBurnPending: 10n ** 9n, vaultBuyPending: 10n ** 9n } });
  await r.run(cfgOf({ GO_LIVE_AT: String(ts(100) - 10 * 3600) }));
  r.m.head = 101n;
  await r.run(cfgOf({ GO_LIVE_AT: String(ts(100) - 10 * 3600) }));
  const t = titles(r.alerts);
  assert.ok(t.includes("emergency:NotSeeded"));
  assert.ok(!t.some((x) => /stall|floor gap|keeper not buying/.test(x)), t.join(", "));
});

test("G4: a fill is judged only against samples of the token it bought", async () => {
  const r = rig();
  r.m.logs = [fillLog(50, 250_000_000n, 250_000_000n * RATE)];
  await r.store.set("w:price", samplesBefore(ts(50)).map((x) => ({ ...x, k: "0x000000000000000000000000000000000000dEaD" })));
  await r.run();
  assert.ok(r.alerts.some((a) => a.title === "fill checked by prior-block only (no 30-min samples)"), titles(r.alerts).join(", "));
});

test("G5: a re-seed alerts as core.RatchetReset and names the epoch it was set in", async () => {
  const r = rig();
  await r.run();
  r.alerts.length = 0;
  r.m.logs = [{ address: CORE, eventName: "RatchetReset", blockNumber: 105n, transactionHash: H(777), logIndex: 0, args: { newAnchor: 5n, epoch: 1n } }];
  r.m.head = 110n;
  await r.run();
  const a = r.alerts.find((x) => x.title === "core.RatchetReset");
  assert.equal(a?.level, "emergency");
  assert.match(a.message, /newAnchor=5 epoch=1/);
});

test("M-4: RAT, RakeBuyer, FeeSplitter and FairCore escrow events alert at their level", async () => {
  const FS = "0xEfefefefefefefefefefefefefefefefefefefef".toLowerCase();
  const r = rig();
  const cfg = cfgOf({ FEE_SPLITTER: FS });
  await r.run(cfg);
  r.alerts.length = 0;
  const ev = (address, i, eventName, args) => ({ address, eventName, blockNumber: BigInt(100 + i), transactionHash: H(700 + i), logIndex: 0, args });
  r.m.logs = [
    ev(RAKE, 1, "OpQueued", { id: H(1), op: 3, key: 0n, value: K, eta: 1n }),
    ev(RAKE, 2, "ForwardToSet", { to: K }),
    ev(RAKE, 3, "RatchetReset", { newAnchor: 1n, epoch: 0n }),
    ev(RAKE, 4, "ForwardFailed", { token: TOKEN, asset: TOKEN, to: K, amount: 1n }),
    ev(RAT, 5, "OpQueued", { id: H(2), op: 1, value: 0n, addr: K, eta: 1n }),
    ev(RAT, 6, "EntriesPaused", { paused: false }),
    ev(RAT, 7, "SeedChainCommitted", { tip: H(3), fromRound: 5n }),
    ev(RAT, 8, "PairingLapsed", { roundId: 4n }),
    ev(RAT, 9, "KeeperSet", { keeper: K }),
    ev(CORE, 10, "AlmsEscrowed", { fairId: 1n, to: K, amount: 1n }),
    ev(FS, 11, "LegEscrowed", { token: TOKEN, to: K, amount: 1n }),
  ];
  r.m.head = 120n;
  await r.run(cfg);
  const t = titles(r.alerts);
  for (const want of [
    "emergency:rakeBuyer.OpQueued", "emergency:rakeBuyer.ForwardToSet", "emergency:rakeBuyer.RatchetReset", "high:rakeBuyer.ForwardFailed",
    "emergency:rat.OpQueued", "high:rat.EntriesPaused", "high:rat.SeedChainCommitted", "high:rat.PairingLapsed", "emergency:rat.KeeperSet",
    "high:core.AlmsEscrowed", "high:feeSplitter.LegEscrowed",
  ]) assert.ok(t.includes(want), `missing ${want} in ${t}`);
});

test("M-4: a RakeBuyer fill 5% under the 30-min average is an emergency; with no samples it is a high alert", async () => {
  const bought = (block, usdgIn, out) => ({
    address: RAKE, eventName: "Bought", blockNumber: BigInt(block), transactionHash: H(2000 + block), logIndex: 0,
    args: { token: TOKEN, route: 0n, usdgIn, out, minOut: 1n },
  });
  const r = rig();
  await r.store.set("w:price", samplesBefore(ts(50)));
  r.m.logs = [bought(50, 50_000_000n, (50_000_000n * RATE * 95n) / 100n)];
  await r.run();
  const bad = r.alerts.filter((a) => a.title === "bad buyback fill");
  assert.equal(bad.length, 1);
  assert.equal(bad[0].level, "emergency");
  assert.match(bad[0].message, /rakeBuyer\.Bought/);

  const r2 = rig();
  r2.m.logs = [bought(50, 50_000_000n, 50_000_000n * RATE)];
  await r2.run();
  assert.ok(titles(r2.alerts).includes("high:RakeBuyer fill not checked"), titles(r2.alerts).join(","));

  const r3 = rig();
  await r3.store.set("w:price", samplesBefore(ts(50)));
  r3.m.logs = [bought(50, 50_000_000n, 50_000_000n * RATE)];
  await r3.run();
  assert.ok(!r3.alerts.some((a) => /fill/.test(a.title)), titles(r3.alerts).join(","));
});

test("M-4: RakeBuyer floor more than 10% under market alerts after two passes", async () => {
  const r = rig({ rakePending: 100_000_000n, floorRate: RATE * 10n ** 18n * 8n / 10n });
  await r.run();
  r.m.head += 1n;
  await r.run();
  const gap = r.alerts.filter((a) => a.title.startsWith("floor gap above 10%"));
  assert.ok(gap.some((a) => /RakeBuyer/.test(a.title)), titles(r.alerts).join(","));
});

test("M-4: a missing RAT or RAKE_BUYER address refuses to load", () => {
  assert.throws(() => cfgOf({ RAT: "" }), /RAT/);
  assert.throws(() => cfgOf({ RAKE_BUYER: "nope" }), /RAKE_BUYER/);
});

test("Review L1: a RAT round cancelled after its pairing was locked is high; an unlocked cancel is quiet", async () => {
  const r = rig({ lockedRounds: [7n] });
  await r.run();
  r.alerts.length = 0;
  const ev = (i, roundId) => ({ address: RAT, eventName: "RoundCancelled", blockNumber: BigInt(100 + i), transactionHash: H(900 + i), logIndex: 0, args: { roundId } });
  r.m.logs = [ev(1, 6n), ev(2, 7n)];
  r.m.head = 120n;
  await r.run();
  const c = r.alerts.filter((a) => a.title.startsWith("locked RAT round cancelled"));
  assert.equal(c.length, 1, titles(r.alerts).join(","));
  assert.equal(c[0].level, "high");
  assert.match(c[0].message, /round 7 /);
  assert.doesNotMatch(c[0].message, /round 6 /);
});

test("Review L5: FeeSplitter rescue and ownership events alert (queue and handover start are emergency)", async () => {
  const FS = "0xEfefefefefefefefefefefefefefefefefefefef".toLowerCase();
  const r = rig();
  const cfg = cfgOf({ FEE_SPLITTER: FS });
  await r.run(cfg);
  r.alerts.length = 0;
  const ev = (i, eventName, args) => ({ address: FS, eventName, blockNumber: BigInt(100 + i), transactionHash: H(950 + i), logIndex: 0, args });
  r.m.logs = [
    ev(1, "RescueQueued", { id: H(1), token: TOKEN, from: K, to: K, amount: 1n, eta: 1n }),
    ev(2, "Rescued", { token: TOKEN, from: K, to: K, amount: 1n }),
    ev(3, "OwnershipTransferStarted", { previousOwner: K, newOwner: K }),
    ev(4, "OwnershipTransferred", { previousOwner: K, newOwner: K }),
  ];
  r.m.head = 120n;
  await r.run(cfg);
  const t = titles(r.alerts);
  for (const want of ["emergency:feeSplitter.RescueQueued", "high:feeSplitter.Rescued", "emergency:feeSplitter.OwnershipTransferStarted", "high:feeSplitter.OwnershipTransferred"])
    assert.ok(t.includes(want), `missing ${want} in ${t}`);
});

test("Review L3: a RakeBuyer floor above the route-A quote is a stall after two passes; an unseeded RakeBuyer says so", async () => {
  const r = rig({ rakePending: 100_000_000n, floorRate: RATE * 10n ** 18n * 11n / 10n });
  await r.run();
  r.m.head += 1n;
  await r.run();
  assert.ok(r.alerts.some((a) => a.title.startsWith("stall") && /RakeBuyer/.test(a.title + a.message)), titles(r.alerts).join(","));
  assert.ok(!r.alerts.some((a) => a.title.startsWith("floor gap") && /RakeBuyer/.test(a.title)), titles(r.alerts).join(","));

  const r2 = rig({ rakePending: 100_000_000n, floorRate: 0n });
  await r2.run();
  assert.ok(r2.alerts.some((a) => a.title.startsWith("RakeBuyer anchor not seeded")), titles(r2.alerts).join(","));
});

test("Review M: RakeBuyer gap counts unsynced rake, skips a full daily cap, and a FairCore rotation doesn't hide the others", async () => {
  // 120 USDG arrived from RAT with no sync(): half (60) is buyable, so the gap check runs
  const r = rig({ rakePending: 0n, rakeBal: 120_000_000n, floorRate: RATE * 10n ** 18n * 8n / 10n });
  await r.run();
  r.m.head += 1n;
  await r.run();
  assert.ok(r.alerts.some((a) => a.title.startsWith("floor gap above 10%") && /RakeBuyer/.test(a.title)), titles(r.alerts).join(","));

  const full = rig({ rakePending: 100_000_000n, rakeBought: 480_000_000n, floorRate: RATE * 10n ** 18n * 8n / 10n });
  await full.run();
  full.m.head += 1n;
  await full.run();
  assert.ok(!full.alerts.some((a) => /RakeBuyer/.test(a.title)), titles(full.alerts).join(","));

  const rot = rig();
  const K2 = "0x" + "12".repeat(20);
  rot.m.keeper = K2; // every keeper() read returns K2, FairCore included
  await rot.run();
  const kc = rot.alerts.filter((a) => a.title.startsWith("keeper address changed"));
  for (const who of ["FairCore", "RobinAmongThieves", "RakeBuyer"]) assert.ok(kc.some((a) => a.message.includes(who)), `${who}: ${kc.map((a) => a.message)}`);
});

test("Review delta M1: a failing rounds() read on a cancel alerts and does not freeze the scan", async () => {
  const r = rig({ roundsThrow: true });
  await r.run();
  r.alerts.length = 0;
  r.m.logs = [{ address: RAT, eventName: "RoundCancelled", blockNumber: 105n, transactionHash: H(950), logIndex: 0, args: { roundId: 9n } }];
  r.m.head = 120n;
  await r.run();
  assert.ok(titles(r.alerts).includes("high:RAT round cancelled, lock state unread"), titles(r.alerts).join(","));
  assert.ok(!r.alerts.some((a) => /detector failed|event scan/.test(a.title)), titles(r.alerts).join(","));
  assert.equal((await r.store.get("w:scan")).lastBlock, "120");
});

test("Review delta M2: a RakeBuyer fill whose check fails stays queued and is judged next pass", async () => {
  const r = rig();
  await r.run();
  r.alerts.length = 0;
  await r.store.set("w:price", samplesBefore(ts(110)));
  r.m.logs = [{ address: RAKE, eventName: "Bought", blockNumber: 110n, transactionHash: H(3110), logIndex: 0, args: { token: TOKEN, route: 0n, usdgIn: 50_000_000n, out: (50_000_000n * RATE * 95n) / 100n, minOut: 1n } }];
  r.m.head = 120n;
  r.m.blockThrow = [110n];
  await r.run();
  assert.ok(!r.alerts.some((a) => a.title === "bad buyback fill"));
  assert.equal((await r.store.get("w:scan")).pendingRake.length, 1);
  r.m.blockThrow = [];
  r.m.head = 121n;
  await r.run();
  assert.equal(r.alerts.filter((a) => a.title === "bad buyback fill").length, 1, titles(r.alerts).join(","));
  assert.equal((await r.store.get("w:scan")).pendingRake.length, 0);
});
