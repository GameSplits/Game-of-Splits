// Budget griefing and gas drain through the relayer. Each case names the behaviour it locks in.
import assert from "node:assert/strict";
import test from "node:test";
import type { Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { TESTNET_STASH, loadConfig } from "../src/config.ts";
import * as eip712 from "../src/eip712.ts";
import { handle, type HandleCtx, type HandleInput } from "../src/http.ts";
import * as policy from "../src/policy.ts";
import { NonceQueue, OwnerNonceGuard, RateLimit, ResignBook } from "../src/policy.ts";
import type { RelayState, SendOpts } from "../src/relay.ts";
import * as runtime from "../src/runtime.ts";

const victim = privateKeyToAccount(`0x${"33".repeat(32)}` as Hex);
const session = privateKeyToAccount(`0x${"22".repeat(32)}` as Hex);
const JUNK = `0x${"ab".repeat(64)}` as Hex;
const WALLET_SIG = `0x${"77".repeat(70)}` as Hex;
const WALLET_HASH = `0x${"cd".repeat(32)}` as Hex;
const domain = eip712.stashDomain(46630, TESTNET_STASH);

function env(extra: Record<string, string> = {}): NodeJS.ProcessEnv {
  return { RELAYER_KEY: `0x${"11".repeat(32)}`, RPC_URL: "https://rpc.example.test", CHAIN_ID: "46630", STASH: TESTNET_STASH, ...extra };
}

function freshState(): RelayState {
  const SpendBudget = (policy as Record<string, unknown>).SpendBudget as (new (wei: bigint) => unknown) | undefined;
  return {
    rates: new RateLimit(30, 60_000),
    hourly: new RateLimit(60, 3_600_000),
    ips: new RateLimit(60, 60_000),
    resigns: new ResignBook(),
    nonces: new NonceQueue(async () => 0n),
    owners: new OwnerNonceGuard(),
    ...(SpendBudget ? { spend: new SpendBudget(10n ** 18n) } : {}),
  } as RelayState;
}

function harness(extraEnv: Record<string, string> = {}) {
  let t = 1_000_000;
  const sent: Hex[] = [];
  const caps: bigint[] = [];
  const sims = { n: 0 };
  const alerts: string[] = [];
  const ctx: HandleCtx = {
    cfg: loadConfig(env(extraEnv)),
    relayer: victim.address,
    deps: {
      now: () => t,
      // On chain Stash reverts BadSignature for a junk order. A real signature simulates fine.
      simulate: async (data, gasCap) => {
        sims.n++;
        caps.push(gasCap);
        return data.includes("ab".repeat(64)) ? { ok: false, kind: "other", reason: "BadSignature" } : { ok: true };
      },
      send: async (data, opts) => {
        sent.push(data);
        if (opts?.gasCap !== undefined) caps.push(opts.gasCap);
        return "0xabc";
      },
      ethBalance: async () => 10n ** 18n,
      alert: async (m) => {
        alerts.push(m);
      },
      priorityWei: 1n,
    },
    state: freshState(),
    storageMode: "memory",
    sessionKey: async () => session.address,
    stashBalance: async () => 5_000_000n,
  };
  return { ctx, sent, sims, caps, alerts, tick: (ms: number) => (t += ms) };
}

const order = { owner: victim.address, maxPrice: 10n, expectedRound: 2n, nonce: 0n, deadline: 2_000_000_000n, epoch: 1n };
const str = (o: Record<string, unknown>) => Object.fromEntries(Object.entries(o).map(([k, v]) => [k, String(v)]));
const shootBody = (signature: string, nonce = 0n) =>
  JSON.stringify({ chainId: 46630, stash: TESTNET_STASH, order: str({ ...order, nonce }), signature });
const signShoot = (nonce = 0n) =>
  session.signTypedData({ domain, types: eip712.shootTypes, primaryType: "Shoot", message: { ...order, nonce } });
const req = (route: string, body: string, ip: string): HandleInput => ({
  method: "POST",
  path: `/${route}`,
  route,
  headers: { "x-vercel-forwarded-for": ip },
  body,
});

const authMsg = { owner: victim.address, key: session.address, limit: 5_000_000n, expiry: 2_000_000_000n, nonce: 0n, deadline: 2_000_000_000n };
const authBody = (signature: string) => JSON.stringify({ chainId: 46630, stash: TESTNET_STASH, order: str(authMsg), signature });

// Junk signatures.
test("junk signatures from anyone do not use up a wallet's budget", async () => {
  const h = harness();
  for (let i = 0; i < 60; i++) {
    h.tick(2_100);
    const out = await handle(h.ctx, req("shoot", shootBody(JUNK), "203.0.113.7"));
    assert.equal(out.status, 400);
    assert.equal(out.body?.error, "bad signature");
  }
  assert.equal(h.sims.n, 0, "junk never reaches simulation");
  h.tick(61_000);
  const real = await handle(h.ctx, req("shoot", shootBody(await signShoot()), "198.51.100.9"));
  assert.equal(real.status, 200);
  assert.equal(h.sent.length, 1);
});

// Replays, with no nonce read available: the simulation rejects the replay and nothing is counted.
test("replays of a landed order do not use up a wallet's budget", async () => {
  const h = harness();
  h.ctx.deps.simulate = async () => ({ ok: false, kind: "other", reason: "InvalidAccountNonce" });
  const sig = await signShoot();
  for (let i = 0; i < 60; i++) {
    h.tick(2_100);
    assert.equal((await handle(h.ctx, req("shoot", shootBody(sig), "203.0.113.7"))).status, 400);
  }
  h.ctx.deps.simulate = async () => ({ ok: true });
  h.tick(61_000);
  const real = await handle(h.ctx, req("shoot", shootBody(await signShoot(1n), 1n), "198.51.100.9"));
  assert.equal(real.status, 200);
  assert.equal(h.sent.length, 1);
});

test("an order below the on-chain nonce is refused before simulation", async () => {
  const h = harness();
  h.ctx.ownerNonce = async () => 1n;
  const replay = await handle(h.ctx, req("shoot", shootBody(await signShoot()), "203.0.113.7"));
  assert.equal(replay.status, 400);
  assert.equal(replay.body?.error, "nonce used");
  assert.equal(h.sims.n, 0);
  const next = await handle(h.ctx, req("shoot", shootBody(await signShoot(1n), 1n), "198.51.100.9"));
  assert.equal(next.status, 200);
  h.ctx.ownerNonce = async () => {
    throw new Error("rpc down");
  };
  const unread = await handle(h.ctx, req("shoot", shootBody(await signShoot(1n), 1n), "198.51.100.9"));
  assert.equal(unread.status, 200, "a failed nonce read falls back to the simulation");
});

test("the per IP limit still throttles junk before any other work", async () => {
  const h = harness();
  for (let i = 0; i < 60; i++) await handle(h.ctx, req("shoot", shootBody(JUNK), "203.0.113.7"));
  const out = await handle(h.ctx, req("shoot", shootBody(JUNK), "203.0.113.7"));
  assert.equal(out.status, 429);
});

test("a wallet's own relayed calls are still limited to 30 a minute and 60 an hour", async () => {
  const h = harness();
  const sig = await signShoot();
  const ips = (i: number) => `198.51.100.${i % 200}`;
  for (let i = 0; i < 30; i++) assert.equal((await handle(h.ctx, req("shoot", shootBody(sig), ips(i)))).status, 200);
  assert.equal((await handle(h.ctx, req("shoot", shootBody(sig), ips(99)))).status, 429);
  h.tick(61_000);
  for (let i = 0; i < 30; i++) assert.equal((await handle(h.ctx, req("shoot", shootBody(sig), ips(i)))).status, 200);
  h.tick(61_000);
  assert.equal((await handle(h.ctx, req("shoot", shootBody(sig), ips(1)))).status, 429);
  assert.equal(h.sent.length, 60);
});

test("a failed simulation from the wallet itself is not counted", async () => {
  const h = harness();
  h.ctx.deps.simulate = async () => ({ ok: false, kind: "other", reason: "DeadlineExpired" });
  const sig = await signShoot();
  for (let i = 0; i < 40; i++) await handle(h.ctx, req("shoot", shootBody(sig), `198.51.100.${i}`));
  h.ctx.deps.simulate = async () => ({ ok: true });
  assert.equal((await handle(h.ctx, req("shoot", shootBody(sig), "198.51.100.250"))).status, 200);
});

test("a send that fails or is paused does not use up the wallet's budget", async () => {
  const h = harness();
  const SpendCapError = (policy as Record<string, unknown>).SpendCapError as typeof policy.SpendCapError;
  h.ctx.deps.send = async () => {
    throw new SpendCapError();
  };
  const sig = await signShoot();
  for (let i = 0; i < 40; i++) assert.equal((await handle(h.ctx, req("shoot", shootBody(sig), `198.51.100.${i}`))).status, 503);
  h.ctx.deps.send = async () => "0xabc";
  assert.equal((await handle(h.ctx, req("shoot", shootBody(sig), "198.51.100.250"))).status, 200);
});

// A 64-byte signature for an owner that is a gas-heavy contract.
test("a non-65-byte owner signature is refused with no simulation and no send", async () => {
  const h = harness();
  const out = await handle(h.ctx, req("authorize-key", authBody(JUNK), "203.0.113.7"));
  assert.equal(out.status, 400);
  assert.equal(out.body?.error, "bad signature");
  assert.equal(h.sims.n, 0);
  assert.equal(h.sent.length, 0);
});

test("a valid 65-byte owner signature is still relayed under the account gas cap", async () => {
  const h = harness();
  const sig = await victim.signTypedData({ domain, types: eip712.authorizeTypes, primaryType: "AuthorizeKey", message: authMsg });
  const out = await handle(h.ctx, req("authorize-key", authBody(sig), "198.51.100.9"));
  assert.equal(out.status, 200);
  assert.deepEqual(h.caps, [250_000n, 250_000n]);
  const shot = await handle(h.ctx, req("shoot", shootBody(await signShoot()), "198.51.100.9"));
  assert.equal(shot.status, 200);
  assert.deepEqual(h.caps.slice(2), [900_000n, 900_000n]);
});

test("an allowlisted ERC-1271 wallet is checked off chain, never skipped", async () => {
  const h = harness({ ERC1271_CODEHASHES: WALLET_HASH.toUpperCase().replace("0X", "0x") });
  const asked: Hex[] = [];
  let verdict = false;
  let hash: Hex | null = `0x${"ef".repeat(32)}`;
  h.ctx.wallet = {
    codeHash: async () => hash,
    isValid1271: async (_a, digest) => {
      asked.push(digest);
      return verdict;
    },
  };
  const body = authBody(WALLET_SIG);
  assert.equal((await handle(h.ctx, req("authorize-key", body, "198.51.100.9"))).status, 400, "code hash not allowlisted");
  assert.equal(asked.length, 0);
  hash = WALLET_HASH;
  assert.equal((await handle(h.ctx, req("authorize-key", body, "198.51.100.9"))).status, 400, "wallet says no");
  verdict = true;
  assert.equal((await handle(h.ctx, req("authorize-key", body, "198.51.100.9"))).status, 200);
  const typedDigest = (eip712 as Record<string, unknown>).typedDigest as typeof eip712.typedDigest;
  const expected = typedDigest(46630, TESTNET_STASH, { kind: "authorize-key", message: authMsg, signature: WALLET_SIG });
  assert.deepEqual(asked, [expected, expected]);
  assert.equal(h.sent.length, 1);
});

function io(estimate: bigint, baseFee = 20_000_000n) {
  const calls = { broadcast: [] as { gas: bigint; maxFeePerGas: bigint }[], estimates: 0 };
  return {
    calls,
    io: {
      baseFee: async () => baseFee,
      estimate: async () => {
        calls.estimates++;
        return estimate;
      },
      broadcast: async (tx: { gas: bigint; maxFeePerGas: bigint }) => {
        calls.broadcast.push(tx);
        return "0xabc" as Hex;
      },
    },
  };
}

const sendCapped = (runtime as Record<string, unknown>).sendCapped as typeof runtime.sendCapped;
const opts = (gasCap: bigint, reserved: bigint[] = [], ok = true): SendOpts => ({
  nonce: 0n,
  priorityWei: 20_000_000n,
  gasCap,
  reserve: (wei) => {
    reserved.push(wei);
    return ok;
  },
});

test("a 76M gas estimate is refused and nothing is broadcast", async () => {
  const x = io(76_377_451n);
  const reserved: bigint[] = [];
  await assert.rejects(sendCapped(x.io, 500_000_000n, "0x01", opts(250_000n, reserved)), { name: "GasLimitError" });
  assert.equal(x.calls.estimates, 1);
  assert.equal(x.calls.broadcast.length, 0);
  assert.equal(reserved.length, 0);
});

test("normal sends keep the 20% headroom and never exceed the cap", async () => {
  const shot = io(300_000n);
  const reserved: bigint[] = [];
  await sendCapped(shot.io, 500_000_000n, "0x01", opts(900_000n, reserved));
  assert.equal(shot.calls.broadcast[0]?.gas, 360_000n);
  assert.deepEqual(reserved, [360_000n * 40_000_000n]);
  const heavy = io(800_000n);
  await sendCapped(heavy.io, 500_000_000n, "0x01", opts(900_000n));
  assert.equal(heavy.calls.broadcast[0]?.gas, 900_000n);
});

test("a send the hourly ETH budget cannot cover is not broadcast", async () => {
  const x = io(300_000n);
  await assert.rejects(sendCapped(x.io, 500_000_000n, "0x01", opts(900_000n, [], false)), { name: "SpendCapError" });
  assert.equal(x.calls.broadcast.length, 0);
});

test("relaying pauses with one alert when the hourly ETH budget is spent, then resumes", async () => {
  const h = harness();
  const SpendBudget = (policy as Record<string, unknown>).SpendBudget as typeof policy.SpendBudget;
  // Room for two shots at 360k gas and the harness fee of 0.02 gwei plus a 1 wei tip.
  h.ctx.state.spend = new SpendBudget(2n * 360_000n * 20_000_001n);
  const x = io(300_000n);
  h.ctx.deps.send = (data, o) => sendCapped(x.io, 500_000_000n, data, o);
  const sig = await signShoot();
  const ip = (i: number) => `198.51.100.${i}`;
  assert.equal((await handle(h.ctx, req("shoot", shootBody(sig), ip(1)))).status, 200);
  assert.equal((await handle(h.ctx, req("shoot", shootBody(sig), ip(2)))).status, 200);
  const paused = await handle(h.ctx, req("shoot", shootBody(sig), ip(3)));
  assert.equal(paused.status, 503);
  assert.equal(paused.body?.error, "relay paused");
  assert.equal((await handle(h.ctx, req("shoot", shootBody(sig), ip(4)))).status, 503);
  assert.equal(h.alerts.filter((a) => a.includes("budget")).length, 1);
  assert.equal(x.calls.broadcast.length, 2);
  h.tick(3_600_000);
  assert.equal((await handle(h.ctx, req("shoot", shootBody(sig), ip(5)))).status, 200);
});

test("an estimate over the cap is refused with 400 and not retried", async () => {
  const h = harness();
  let sends = 0;
  const GasLimitError = (policy as Record<string, unknown>).GasLimitError as typeof policy.GasLimitError;
  h.ctx.deps.send = async () => {
    sends++;
    throw new GasLimitError();
  };
  const out = await handle(h.ctx, req("shoot", shootBody(await signShoot()), "198.51.100.9"));
  assert.equal(out.status, 400);
  assert.equal(out.body?.error, "gas above cap");
  assert.equal(sends, 1);
});

test("gas caps, ETH budget and the 1271 allowlist are read from env with safe defaults", () => {
  const cfg = loadConfig(env());
  assert.equal(cfg.gasCapPlay, 900_000n);
  assert.equal(cfg.gasCapAccount, 250_000n);
  assert.equal(cfg.ethPerHourWei, 20_000_000_000_000_000n);
  assert.equal(cfg.erc1271CodeHashes.size, 0);
  const set = loadConfig(env({ RELAY_GAS_CAP_PLAY: "1000000", RELAY_GAS_CAP_ACCOUNT: "200000", RELAY_ETH_PER_HOUR: "0.5", ERC1271_CODEHASHES: `${WALLET_HASH}, ${WALLET_HASH}` }));
  assert.equal(set.gasCapPlay, 1_000_000n);
  assert.equal(set.gasCapAccount, 200_000n);
  assert.equal(set.ethPerHourWei, 5n * 10n ** 17n);
  assert.deepEqual([...set.erc1271CodeHashes], [WALLET_HASH]);
  assert.throws(() => loadConfig(env({ RELAY_GAS_CAP_PLAY: "80000000" })), /RELAY_GAS_CAP_PLAY/);
  assert.throws(() => loadConfig(env({ RELAY_GAS_CAP_ACCOUNT: "1e6" })), /RELAY_GAS_CAP_ACCOUNT/);
  assert.throws(() => loadConfig(env({ RELAY_ETH_PER_HOUR: "0" })), /RELAY_ETH_PER_HOUR/);
  assert.throws(() => loadConfig(env({ RELAY_ETH_PER_HOUR: "-1" })), /RELAY_ETH_PER_HOUR/);
  assert.throws(() => loadConfig(env({ ERC1271_CODEHASHES: "0x1234" })), /ERC1271_CODEHASHES/);
});
