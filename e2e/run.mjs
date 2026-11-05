// Keeper + watcher end-to-end on a local anvil fork (started and deployed by keeper_watcher.sh).
// Each step says which alerts it expects. A step fails if an expected alert is missing or an unexpected one appears.
// The keeper and the watcher are the real modules, run exactly as in production except: a file store instead of
// Upstash, an alert file instead of Pushover, OIDC off (no GitHub here), and the real Vercel handlers (api/*.mjs) served
// locally by watcher/bin/local.mjs, which also records the dead-man switch pings.
import { readFileSync, existsSync } from "node:fs";
import { join } from "node:path";
import { spawn } from "node:child_process";
import {
  createPublicClient, createWalletClient, http, defineChain, encodeFunctionData, parseAbi, keccak256, pad, toHex,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { runKeeper } from "../keeper/src/keeper.mjs";
import { fileStore } from "../watcher/lib/state.mjs";

const RPC = process.env.E2E_RPC;
const D = JSON.parse(readFileSync(process.env.E2E_DEPLOYMENT, "utf8"));
const WORK = process.env.E2E_WORK;
const KEY = process.env.E2E_KEEPER_KEY;
const SAFE = process.env.OWNER_SAFE; // a real multisig SafeL2 made by make_safe.sh, impersonated by anvil
const PAYER = "0x00000000000000000000000000000000000fee01";
const ATTACKER = "0x00000000000000000000000000000000000bad01";
const USDG = "0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168";
// Chapter 0 times from contracts/script/Chapter0Dates.sol, the one place they are set.
const DATES = readFileSync(new URL("../contracts/script/Chapter0Dates.sol", import.meta.url), "utf8");
const dateOf = (name) => {
  const m = DATES.match(new RegExp(`uint64 internal constant ${name} = ([0-9]+);`));
  if (!m) throw new Error(`Chapter0Dates.sol has no ${name}`);
  return Number(m[1]);
};
const FAIR0_START = dateOf("FAIR_START");
const FAIR0_END = dateOf("FAIR_END");
const PORT = Number(process.env.E2E_PORT ?? 8790);
const SECRET = "e2e-sendlog-secret";
const STATE = join(WORK, "watcher-state.json");
const ALERTS = join(WORK, "alerts.jsonl");
const HC = join(WORK, "healthchecks.log");
const CRON = "e2e-cron-secret";

const chain = defineChain({ id: 4663, name: "fork", nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 }, rpcUrls: { default: { http: [RPC] } } });
const pub = createPublicClient({ chain, transport: http(RPC) });
const thief = createWalletClient({ account: privateKeyToAccount(KEY), chain, transport: http(RPC) });
const rpc = (method, params = []) => pub.request({ method, params });

const core = parseAbi([
  "function collect(address payer, address player, uint256 roundKey, uint256 gross)",
  "function bonfirePending() view returns (uint256)",
  "function vaultBurnPending() view returns (uint256)",
  "function vaultBuyPending() view returns (uint256)",
  "function ratchetFloorRate() view returns (uint256)",
  "function anchorRate() view returns (uint256)",
  "function anchorStale() view returns (bool)",
  "function keeper() view returns (address)",
  "function burnBuyToken(uint8 source, uint256 route, uint256 usdgIn, uint256 minOut) returns (uint256)",
  "function resetRatchet(uint256)",
  "function pauseSales(bool)",
  "function queue(uint8 op, uint256 key, address value) returns (bytes32)",
  "function execute(uint8 op, uint256 key, address value)",
  "function cancel(bytes32)",
  "function opId(uint8 op, uint256 key, address value) view returns (bytes32)",
  "function revokeKeeper()",
  "function lastSwapAt(uint8) view returns (uint64)",
  "function timelockDelay() view returns (uint256)",
]);
const erc20 = parseAbi(["function approve(address,uint256) returns (bool)", "function transfer(address,uint256) returns (bool)", "function balanceOf(address) view returns (uint256)"]);
const route = parseAbi(["function swapToToken(uint256 usdgIn, uint256 minOut, address recipient) returns (uint256)"]);
const gameConfig = parseAbi([
  "function queueTokens((address playToken, uint256 passLock, address buyToken) t)",
  "function executeTokens()",
  "function tokensEta() view returns (uint256)",
  "function epoch() view returns (uint64)",
  "function tokens() view returns (address, uint256, address)",
]);
const quoterAbi = parseAbi([
  "struct PoolKey { address currency0; address currency1; uint24 fee; int24 tickSpacing; address hooks; }",
  "struct QuoteExactSingleParams { PoolKey poolKey; bool zeroForOne; uint128 exactAmount; bytes hookData; }",
  "function quoteExactInputSingle(QuoteExactSingleParams params) returns (uint256 amountOut, uint256 gasEstimate)",
]);

// ------------------------------------------------------------------ chain helpers
const now = async () => Number((await pub.getBlock()).timestamp);
async function advance(seconds) {
  await rpc("evm_mine", [toHex((await now()) + seconds)]);
}
async function impersonated(from, to, data) {
  const hash = await rpc("eth_sendTransaction", [{ from, to, data, gas: toHex(3_000_000) }]);
  const r = await pub.waitForTransactionReceipt({ hash });
  if (r.status !== "success") throw new Error(`impersonated tx from ${from} to ${to} reverted`);
  return r;
}
const call = (from, to, abi, functionName, args) => impersonated(from, to, encodeFunctionData({ abi, functionName, args }));
const read = (address, abi, functionName, args = []) => pub.readContract({ address, abi, functionName, args });
// A1-12: after setup the Safe can only reset the anchor through the timelock (queue Op.ResetRatchet = 8, 48h on
// mainnet, then execute). The anchor is priced before the wait, the fork has no other trades, so it still holds.
const ZERO = "0x0000000000000000000000000000000000000000";
async function safeReset(anchor) {
  await call(SAFE, D.fairCore, core, "queue", [8, anchor, ZERO]);
  await advance(Number(await read(D.fairCore, core, "timelockDelay")) + 60);
  await call(SAFE, D.fairCore, core, "execute", [8, anchor, ZERO]);
}
// the queue, the execute and the wait itself (no keeper swap in 48h) push on top of the RatchetReset
const RESET_NOISE = ["watcher:emergency:core.OpQueued", "watcher:high:core.OpExecuted", "watcher:high:keeper not buying"];

async function routeARate(usdgIn) {
  // the same two V4Quoter legs the keeper and watcher use
  const { MAINNET, quotePoolFor } = await import("../watcher/lib/abi.mjs");
  const q = async (poolKey, zeroForOne, amt) => (await pub.simulateContract({
    address: MAINNET.quoter, abi: quoterAbi, functionName: "quoteExactInputSingle", args: [{ poolKey, zeroForOne, exactAmount: amt, hookData: "0x" }],
  })).result[0];
  const eth = await q(MAINNET.usdgPool, false, usdgIn);
  return ((await q(quotePoolFor(D.wif), true, eth)) * 10n ** 18n) / usdgIn;
}

// ------------------------------------------------------------------ keeper + watcher runners
const baseEnv = {
  RPC_URL: RPC, CHAIN_ID: "4663", CORE: D.fairCore, ARROW: D.lastArrow, SEAT: D.sheriffsSeat, ALMS: D.almsVote,
  PASS: D.fairPass, VAULT: D.locksleyVault, RAT: D.robinAmongThieves, RAKE_BUYER: D.rakeBuyer, KEEPER: thief.account.address, START_BLOCK: String(D.startBlock),
  SENDLOG_SECRET: SECRET, ALERT_FILE: ALERTS, STATE_FILE: STATE, PORT: String(PORT), CRON_SECRET: CRON,
  HEALTHCHECK_URL: `http://127.0.0.1:${PORT}/hc`, HC_FILE: HC, OIDC_REQUIRED: "0", CONFIRMATIONS: "0",
  ...(D.feeSplitter ? { FEE_SPLITTER: D.feeSplitter } : {}), // BLK-5: live at launch, so the watcher watches it
};
const store = fileStore(STATE);
const W = `http://127.0.0.1:${PORT}`;
async function watcher() {
  const r = await fetch(`${W}/api/check`, { headers: { authorization: `Bearer ${CRON}` } });
  const j = await r.json();
  if (!j.ok) throw new Error(`watcher pass not clean: ${JSON.stringify(j)}`);
  return j;
}
const keeper = (extra = {}) => runKeeper({
  ...baseEnv, DRY_RUN: "0", KEEPER_KEY: KEY, WATCHER_URL: W, START_DELAY_MAX_S: "0", ...extra,
});
async function watchPasses(n, gapS = 120) {
  const out = [];
  for (let i = 0; i < n; i++) {
    if (i) await advance(gapS);
    out.push(await watcher());
  }
  return out;
}

// ------------------------------------------------------------------ alert bookkeeping
let seen = 0;
function newAlerts() {
  if (!existsSync(ALERTS)) return [];
  const lines = readFileSync(ALERTS, "utf8").trim().split("\n").filter(Boolean);
  const fresh = lines.slice(seen).map((l) => JSON.parse(l));
  seen = lines.length;
  return fresh;
}
const results = [];
function expect(step, want, { allow = [] } = {}) {
  const got = newAlerts();
  const tags = got.map((a) => `${a.source}:${a.level}:${a.title}`);
  const missing = want.filter((w) => !tags.includes(w));
  const extra = tags.filter((t) => !want.includes(t) && !allow.some((a) => t.startsWith(a)));
  const ok = missing.length === 0 && extra.length === 0;
  results.push({ step, ok });
  console.log(`\n${ok ? "PASS" : "FAIL"}  ${step}  [${got.length} push${got.length === 1 ? "" : "es"}]`);
  for (const a of got) console.log(`      ${a.source} ${a.level.padEnd(9)} ${a.title} | ${a.message.replace(/\n/g, " / ").slice(0, 170)}`);
  if (!got.length) console.log("      (no alerts)");
  if (missing.length) console.log(`      MISSING: ${missing.join(", ")}`);
  if (extra.length) console.log(`      UNEXPECTED: ${extra.join(", ")}`);
  return got;
}
function check(step, cond, detail = "") {
  results.push({ step, ok: !!cond });
  console.log(`\n${cond ? "PASS" : "FAIL"}  ${step}${detail ? `\n      ${detail}` : ""}`);
}
const swapsOf = (s) => s.swaps.map((x) => `${x.ledger} ${Number(x.usdgIn) / 1e6} USDG`).join(", ") || "none";
const skipsOf = (s) => s.skips.map((x) => x.reason ?? x.buybacks).join(", ");
const T = (n) => (n === 1 ? "" : "s");
const ALL3 = "Bonfire, Vault burn, Vault buy";

// thief helpers
const amt = 250_000_000n;
const floorFor = async () => (amt * (await read(D.fairCore, core, "ratchetFloorRate"))) / 10n ** 18n;
const simBurn = async (source, minOut) => (await pub.simulateContract({ address: D.fairCore, abi: core, functionName: "burnBuyToken", args: [source, 0n, amt, minOut], account: thief.account.address })).result;
async function pushPrice(size) {
  await call(PAYER, USDG, erc20, "transfer", [D.routeA, size]);
  await call(D.fairCore, D.routeA, route, "swapToToken", [size, 1n, ATTACKER]);
}
/** Binary-search a front-run size whose effect on a 250 USDG burn lands in [loBps, hiBps] below `ref` (rate x1e18). */
async function sizePush(source, ref, loBps, hiBps) {
  const floor = await floorFor();
  let lo = 10n * 10n ** 6n, hi = 200_000n * 10n ** 6n;
  for (let i = 0; i < 30; i++) {
    const mid = (lo + hi) / 2n;
    const snap = await rpc("evm_snapshot");
    await pushPrice(mid);
    let out = 0n;
    try { out = await simBurn(source, floor); } catch { out = 0n; }
    if ((await rpc("evm_revert", [snap])) !== true) throw new Error("evm_revert failed");
    const short = out === 0n ? 10_000n : ((ref - (out * 10n ** 18n) / amt) * 10_000n) / ref;
    if (process.env.E2E_DEBUG) console.log("push", mid, "short", short);
    if (short > hiBps) hi = mid;
    else if (short < loBps) lo = mid;
    else return { size: mid, floor, short };
  }
  throw new Error(`couldn't size a push for ${loBps}-${hiBps} bps`);
}
async function sameBlock(txs) {
  // all in one block, in fee order: the front-run first (higher tip), the thief last
  await rpc("evm_setAutomine", [false]);
  const hashes = [];
  for (const t of txs) hashes.push(await t());
  await rpc("evm_mine");
  await rpc("evm_setAutomine", [true]);
  return Promise.all(hashes.map((hash) => pub.getTransactionReceipt({ hash })));
}
const sendImp = (from, to, data, tip, gas = 2_000_000) => async () => {
  const base = (await pub.getBlock()).baseFeePerGas;
  return rpc("eth_sendTransaction", [{ from, to, data, gas: toHex(gas), maxFeePerGas: toHex(base * 4n + tip), maxPriorityFeePerGas: toHex(tip) }]);
};
const thiefBurn = (source, minOut) => async () => {
  const base = (await pub.getBlock()).baseFeePerGas;
  return thief.writeContract({ address: D.fairCore, abi: core, functionName: "burnBuyToken", args: [source, 0n, amt, minOut], gas: 2_000_000n, maxFeePerGas: base * 4n + 1n, maxPriorityFeePerGas: 1n });
};
const frontRun = (size) => [
  sendImp(PAYER, USDG, encodeFunctionData({ abi: erc20, functionName: "transfer", args: [D.routeA, size] }), 10n ** 10n, 200_000),
  sendImp(D.fairCore, D.routeA, encodeFunctionData({ abi: route, functionName: "swapToToken", args: [size, 1n, ATTACKER] }), 9n * 10n ** 9n),
];
const avgSamples = async () => {
  const t = await now();
  const s = ((await store.get("w:price")) ?? []).filter((x) => x.t > t - 1800);
  return s.reduce((a, x) => a + BigInt(x.rate), 0n) / BigInt(s.length);
};

// ------------------------------------------------------------------ the run
const server = spawn(process.execPath, [new URL("../watcher/bin/local.mjs", import.meta.url).pathname, "serve"], {
  env: { ...process.env, ...baseEnv, NONCE_START: "0", GO_LIVE_AT: "0" }, stdio: ["ignore", "pipe", "inherit"],
});
await new Promise((res) => server.stdout.once("data", res));

try {
  // Setup: into Fair 0, fill the ledgers (20,000 USDG of plays through the Arrow booth), Safe re-seeds the anchor.
  await rpc("anvil_setStorageAt", [USDG, keccak256(`${pad(PAYER)}${pad(toHex(1)).slice(2)}`), pad(toHex(50_000_000n * 10n ** 6n))]);
  for (const a of [PAYER, D.lastArrow, D.fairCore, SAFE]) await rpc("anvil_setBalance", [a, toHex(10n ** 20n)]);
  await call(PAYER, USDG, erc20, "approve", [D.fairCore, 2n ** 255n]);
  // A1-12: after setup the Safe re-seeds through queue(Op.ResetRatchet = 8), 48h on mainnet. Queue it now, so the
  // delay runs out during the warp into Fair 0, then execute it there (the seed is 8 days old by then).
  const reseed = await routeARate(10_000_000n);
  await call(SAFE, D.fairCore, core, "queue", [8, reseed, "0x0000000000000000000000000000000000000000"]);
  await rpc("evm_mine", [toHex(FAIR0_START + 3600)]);
  for (let i = 0; i < 10; i++) await call(D.lastArrow, D.fairCore, core, "collect", [PAYER, PAYER, 1n, 2_000_000_000n]);
  const pend = await Promise.all(["bonfirePending", "vaultBurnPending", "vaultBuyPending"].map((f) => read(D.fairCore, core, f)));
  console.log(`ledgers: Bonfire ${Number(pend[0]) / 1e6}, Vault burn ${Number(pend[1]) / 1e6}, Vault buy ${Number(pend[2]) / 1e6} USDG; owner: multisig SafeL2 ${SAFE}`);
  await call(SAFE, D.fairCore, core, "execute", [8, reseed, "0x0000000000000000000000000000000000000000"]); // the seed is 8 days old by now

  // 0. First watcher passes. Expected once: state + nonce baseline missing (fresh store), and the deploy, the accept
  //    batch and the re-seed as owner events, now one push per event type (M4). Five passes build the price history.
  await watchPasses(11); // 20 minutes of samples: the keeper needs >= 4 spanning 20 min (review N5)
  const setup = newAlerts();
  console.log(`\nsetup: ${setup.length} pushes (was 21 in v1)`);
  for (const a of setup) console.log(`      ${a.level.padEnd(9)} ${a.title}${a.message.includes("\n") ? ` (${a.message.split("\n").length} lines)` : ""}`);
  check("setup: re-seed, state-missing and nonce-baseline alerts are there",
    ["core.RatchetReset", "watcher state not found", "nonce baseline missing"].every((t) => setup.some((a) => a.title === t)));

  // 1. Honest keeper run: three buybacks, all logged, all fills verified by both fill checks. Watcher: silent.
  const pBefore = await routeARate(10_000_000n);
  let s = await keeper();
  const p0 = await routeARate(10_000_000n);
  check("1a honest keeper run buys on all three ledgers", s.swaps.length === 3 && s.errors.length === 0, `swaps: ${swapsOf(s)}; errors: ${JSON.stringify(s.errors)}`);
  console.log(`      route-A probe price moved ${(Number((pBefore - p0) * 10000n / pBefore) / 100).toFixed(2)}% from the keeper's own 750 USDG of buys`);
  let r = await watcher();
  check("1b all three fills verified by both checks", r.fills.length === 3 && r.fills.every((f) => f.done && f.d2a === "ok" && f.d2b === "ok"), JSON.stringify(r.fills.map((f) => [f.d2a, f.d2b])));
  expect("1c watcher after the honest run: no alerts", []);

  // 2. Keeper again 2 minutes later: only samples after its last fill count, and there aren't 4 yet. Silent skip.
  await advance(120);
  await watcher();
  s = await keeper();
  check("2a keeper again 2 min later: nothing sent", s.swaps.length === 0 && s.errors.length === 0, `skips: ${skipsOf(s)}`);
  expect("2b no alerts", []);

  // 2c (H2). A thief fill in the FIRST block after the 50-minute gap: at the block before, the real state says TooSoon.
  //     v1 only noted that; now the watcher zeroes the gap in a stateOverride and the fill is fully verified.
  const bonfireAt = Number(await read(D.fairCore, core, "lastSwapAt", [0]));
  await rpc("evm_mine", [toHex(bonfireAt + 3000 - 1)]);
  await rpc("anvil_setNextBlockTimestamp", [toHex(bonfireAt + 3000)]);
  const h4c = await thiefBurn(0, await floorFor())();
  const rc = await pub.waitForTransactionReceipt({ hash: h4c });
  await advance(60);
  r = await watcher();
  const f4c = r.fills.find((f) => f.where.startsWith(h4c));
  check("2c fill at the first block after the gap is verified (TooSoon at the prior block overridden)", rc.status === "success" && f4c?.done && f4c.d2a === "ok", JSON.stringify(f4c));
  expect("2d unlogged nonce + 'checked by prior-block only' (no 30-min samples before it: not the honest keeper, review N4)", ["watcher:emergency:keeper tx not accounted for", "watcher:high:fill checked by prior-block only (no 30-min samples)"]);

  // 3. Thief with the key moves ETH out (unlogged tx). D1 nonce + D5 ETH drop, both emergency.
  await advance(3600);
  await watcher();
  newAlerts();
  await thief.sendTransaction({ to: ATTACKER, value: 10n ** 16n });
  await advance(60);
  await watcher();
  expect("3 thief sends 0.01 ETH from the keeper", ["watcher:emergency:keeper tx not accounted for", "watcher:emergency:keeper ETH dropping fast"]);

  // 4. Thief floor fill on the Bonfire, front-run IN THE SAME BLOCK: the prior-block simulation (D2a) catches it.
  //    An hour more first, so the decayed floor leaves room for a sandwich (the fork has no arbitrage to undo pushes).
  await advance(3600);
  await watcher();
  newAlerts();
  let q0 = await simBurn(0, await floorFor());
  let p = await sizePush(0, (q0 * 10n ** 18n) / amt, 220n, 500n);
  let rs = await sameBlock([...frontRun(p.size), thiefBurn(0, p.floor)]);
  check("4a front-run and thief burn in one block, in that order", rs.every((x) => x.status === "success") && rs[0].blockNumber === rs[2].blockNumber && rs[1].transactionIndex < rs[2].transactionIndex, `push ${Number(p.size) / 1e6} USDG, ${p.short} bps`);
  await advance(60);
  await watcher();
  expect("4b same-block sandwich", ["watcher:emergency:bad buyback fill", "watcher:emergency:keeper tx not accounted for"], { allow: ["watcher:emergency:keeper ETH dropping fast", "watcher:high:fill checked by prior-block only"] });

  // 5. A keeper whose send log is refused (wrong secret) doesn't send. Then the keeper is down for 18 hours:
  //    the anchor decays, the floor falls more than 10% under market (D3, ONE push for all ledgers) + heartbeat.
  await advance(3600);
  await watchPasses(11);
  newAlerts();
  const n0 = await pub.getTransactionCount({ address: thief.account.address });
  s = await keeper({ SENDLOG_SECRET: "wrong" });
  const n1 = await pub.getTransactionCount({ address: thief.account.address });
  check("5a send log refused: the keeper sends nothing", n1 === n0 && s.swaps.length === 0 && s.errors.length > 0, `nonce ${n0} -> ${n1}; errors: ${s.errors.map((e) => e.error).join(", ")}`);
  newAlerts(); // its own "keeper errors" alert
  await advance(18 * 3600);
  await watchPasses(11);
  expect("5b keeper down 18h: one floor-gap push for three ledgers + heartbeat", [`watcher:high:floor gap above 10%: ${ALL3}`, "watcher:high:keeper not buying"]);

  // 6. Keeper back: it buys at market, the fills raise the anchor, the watcher goes quiet.
  s = await keeper();
  check("6a keeper back: buys again", s.swaps.length >= 1 && s.errors.length === 0, `swaps: ${swapsOf(s)}`);
  await watchPasses(3);
  expect("6b watcher after recovery: no alerts", []);

  // 6c (H1). Thief pushes the price ONE BLOCK EARLIER, then fills at the floor. The prior-block simulation already sees
  //     the push, so it agrees with the fill; only the new check against the watcher's own 30-min average catches it.
  await advance(150 * 60 - 6 * 60); // 2.5h after recovery (under the 3h heartbeat), floor has decayed ~2.5%
  await watchPasses(11);
  newAlerts();
  const avg = await avgSamples();
  p = await sizePush(1, avg, 360n, 520n);
  await pushPrice(p.size); // block N-1
  const h6c = await thiefBurn(1, await floorFor())(); // block N
  const r6c = await pub.waitForTransactionReceipt({ hash: h6c });
  await advance(60);
  r = await watcher();
  const f6c = r.fills.find((f) => f.where.startsWith(h6c));
  check("6c push in block N-1 + floor fill in N: the prior-block check passes it, the average check doesn't", r6c.status === "success" && f6c?.d2a === "ok" && f6c?.d2b === "bad", `push ${Number(p.size) / 1e6} USDG, fill ${p.short} bps under the average; ${JSON.stringify(f6c)}`);
  expect("6d N-1 push", ["watcher:emergency:bad buyback fill", "watcher:emergency:keeper tx not accounted for"], { allow: ["watcher:high:stall"] });
  await safeReset(await routeARate(10_000_000n)); // the push left the market under the floor
  await advance(3600);
  await watchPasses(4);
  newAlerts();

  // 7. Stall: the Safe resets the anchor 10% above market. The keeper skips silently; the watcher sends ONE stall
  //    push for all three ledgers (was 6 pushes in v1). The reset itself is an owner event (D4).
  await safeReset(((await routeARate(10_000_000n)) * 110n) / 100n);
  await watchPasses(11);
  s = await keeper();
  check("7a keeper doesn't swap into a stall", s.swaps.length === 0, `skips: ${skipsOf(s)}`);
  const g7 = expect("7b stall: 1 stall push (+ the reset)", ["watcher:emergency:core.RatchetReset", `watcher:high:stall: anchor above market: ${ALL3}`], { allow: RESET_NOISE });
  check("7c exactly one stall push", g7.filter((a) => a.title.startsWith("stall")).length === 1);
  await safeReset(await routeARate(10_000_000n));
  await watcher();
  newAlerts();

  // 8. Owner actions: pause and unpause sales (one push for both), queue a new keeper (the thief's address), cancel. D4.
  await call(SAFE, D.fairCore, core, "pauseSales", [true]);
  await call(SAFE, D.fairCore, core, "pauseSales", [false]);
  await call(SAFE, D.fairCore, core, "queue", [1, 0n, ATTACKER]);
  await call(SAFE, D.fairCore, core, "cancel", [await read(D.fairCore, core, "opId", [1, 0n, ATTACKER])]);
  await watcher();
  expect("8 owner actions", ["watcher:high:core.SalesPaused", "watcher:emergency:core.OpQueued", "watcher:high:core.OpCancelled"]);

  // 8b (H4). The store loses w:state and w:nonce: both alert, and the nonce check re-checks from NONCE_START, so the
  //     thief's old unlogged txs alert again instead of being forgotten. The scan position survives (no re-alert flood).
  await store.del("w:state");
  await store.del("w:nonce");
  await advance(120);
  await watcher();
  const g8 = expect("8b state wiped", ["watcher:high:watcher state not found", "watcher:high:nonce baseline missing", "watcher:emergency:keeper tx not accounted for"], { allow: ["watcher:emergency:keeper ETH dropping fast", "watcher:high:keeper not buying"] }); // the wipe drops the heartbeat dedupe too, and no keeper swap since the timelocked resets
  const nonceAlert = g8.find((a) => a.title === "keeper tx not accounted for");
  check("8c the re-check names all four thief nonces again", nonceAlert && (nonceAlert.message.match(/^nonce \d+/gm) ?? []).length === 4, nonceAlert?.message.replace(/\n/g, " / ").slice(0, 300));

  // 8d. A GameConfig tokens update (here only the pass amount), the Safe's 7-day queue. Queue and execute alert every
  //     signer; the execute starts a new epoch, so the anchor is stale: the watcher raises NotSeeded and drops its old
  //     price samples, the keeper stands down. After the Safe re-seeds, the keeper buys again on the new samples.
  await call(SAFE, D.gameConfig, gameConfig, "queueTokens", [{ playToken: D.wif, passLock: 5_000n * 10n ** 18n, buyToken: D.wif }]);
  await advance(60);
  await watcher();
  expect("8d GameConfig update queued: every signer is told", ["watcher:emergency:config.TokensQueued"], { allow: ["watcher:emergency:keeper ETH dropping fast"] });
  const eta = Number(await read(D.gameConfig, gameConfig, "tokensEta"));
  await rpc("evm_mine", [toHex(Math.max(eta, FAIR0_END) + 60)]); // after the delay, with no Fair running
  await watchPasses(3); // samples in epoch 0 right before the execute (the keeper idled a week: those alerts aren't this step's)
  newAlerts();
  await call(SAFE, D.gameConfig, gameConfig, "executeTokens", []);
  const [, lock8] = await read(D.gameConfig, gameConfig, "tokens");
  check("8e executed after the delay: epoch 1, pass amount 5,000, anchor stale", (await read(D.gameConfig, gameConfig, "epoch")) === 1n && lock8 === 5_000n * 10n ** 18n && (await read(D.fairCore, core, "anchorStale")));
  await advance(60);
  r = await watcher();
  expect("8f executed: the execute + NotSeeded", ["watcher:emergency:config.TokensExecuted", "watcher:emergency:NotSeeded"]);
  check("8g the watcher dropped the earlier epoch's price samples", r.notes.some((n) => /earlier epochs dropped/.test(n)) && ((await store.get("w:price")) ?? []).every((x) => x.e === 1));
  s = await keeper();
  check("8h keeper stands down until the re-seed", s.swaps.length === 0 && s.errors.length === 0 && s.skips.some((x) => x.buybacks === "NotSeeded"), `skips: ${skipsOf(s)}`);
  await safeReset(await routeARate(10_000_000n));
  await watchPasses(11); // a fresh 20 minutes of samples in the new epoch
  expect("8i re-seed", ["watcher:emergency:core.RatchetReset"], { allow: RESET_NOISE });
  s = await keeper();
  check("8j keeper buys again in the new epoch", s.swaps.length >= 1 && s.errors.length === 0, `swaps: ${swapsOf(s)}; skips: ${skipsOf(s)}`);
  await advance(60);
  r = await watcher();
  check("8k its fills are verified by both checks", r.fills.length >= 1 && r.fills.every((f) => f.done && f.d2a === "ok" && f.d2b === "ok"), JSON.stringify(r.fills.map((f) => [f.d2a, f.d2b])));
  expect("8l no alerts after the re-seeded run", []);

  // 8m (BLK-5). The Safe queues a FeeSplitter recipient change and cancels it: every signer is told.
  if (D.feeSplitter) {
    const fsAbi = parseAbi(["function queue(uint8 op, uint256 key, address value) returns (bytes32)", "function cancel(bytes32)", "function opId(uint8 op, uint256 key, address value) view returns (bytes32)"]);
    await call(SAFE, D.feeSplitter, fsAbi, "queue", [4, 0n, ATTACKER]);
    await advance(60);
    await watcher();
    expect("8m FeeSplitter change queued", ["watcher:emergency:feeSplitter.ChangeQueued"], { allow: ["watcher:high:keeper not buying"] });
    await call(SAFE, D.feeSplitter, fsAbi, "cancel", [await read(D.feeSplitter, fsAbi, "opId", [4, 0n, ATTACKER])]);
    await advance(60);
    await watcher();
    expect("8n FeeSplitter change cancelled", ["watcher:high:feeSplitter.ChangeCancelled"], { allow: ["watcher:high:keeper not buying"] });
  } else check("8m FeeSplitter in the deployment file", false, "no feeSplitter: run DeployFeeSplitter");

  // 9. Revoke (Path A): the keeper stands down silently (the watcher reports the revoke); keeper checks go idle.
  await call(SAFE, D.fairCore, core, "revokeKeeper", []);
  await watcher();
  await advance(3600);
  s = await keeper();
  check("9a revoked keeper sends nothing", s.swaps.length === 0 && (await read(D.fairCore, core, "keeper")) === "0x0000000000000000000000000000000000000000");
  const r9 = await watcher();
  expect("9b revoke: one push, from the watcher", ["watcher:high:core.KeeperSet"]);
  check("9c watcher notes the keeper checks are idle", r9.notes.some((n) => n.includes("revoked")));

  // Dead-man switch: every clean pass pinged /hc, none pinged /fail; a wrong CRON_SECRET is refused without a ping.
  const before = readFileSync(HC, "utf8").trim().split("\n").length;
  const bad = await fetch(`${W}/api/check`, { headers: { authorization: "Bearer wrong" } });
  const hc = readFileSync(HC, "utf8").trim().split("\n");
  check("10 dead-man: clean passes ping, a wrong CRON_SECRET doesn't", bad.status === 401 && hc.length === before && hc.every((l) => l.endsWith(" ok")), `${hc.length} pings, ${hc.filter((l) => l.endsWith("fail")).length} fail`);
  const total = readFileSync(ALERTS, "utf8").trim().split("\n").length;
  console.log(`\npushes over the whole run: ${total}`);
} finally {
  server.kill();
}

const failed = results.filter((x) => !x.ok);
console.log(`\n${results.length - failed.length}/${results.length} checks passed${failed.length ? `; FAILED: ${failed.map((f) => f.step).join(" | ")}` : ""}`);
process.exit(failed.length ? 1 : 0);
