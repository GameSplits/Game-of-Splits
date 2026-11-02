import assert from "node:assert/strict";
import { keccak256, toBytes } from "viem";
import test from "node:test";
import {
  AUTHORIZE_TYPE,
  AUTHORIZE_TYPEHASH,
  REVOKE_TYPE,
  REVOKE_TYPEHASH,
  SET_LIMIT_TYPE,
  SET_LIMIT_TYPEHASH,
  SHOOT_TYPE,
  SHOOT_TYPEHASH,
  TAKE_TYPE,
  TAKE_TYPEHASH,
  WITHDRAW_TYPE,
  WITHDRAW_TYPEHASH,
} from "../src/abi.ts";
import { RELAYER_ADDRESS, TESTNET_CHAIN_ID, TESTNET_STASH, loadConfig, redact } from "../src/config.ts";
import { simulationFromError } from "../src/runtime.ts";
import { decodeRevert } from "../src/decode.ts";
import { encodeErrorResult } from "viem";
import { gameErrors } from "../src/decode.ts";
import { NonceQueue, RateLimit, ResignBook, decideSim } from "../src/policy.ts";
import { submitShot, type RelayDeps, type RelayState } from "../src/relay.ts";
import { OwnerNonceGuard } from "../src/policy.ts";

const KEY = `0x${"11".repeat(32)}` as const;
const SECRET = `0x${"ab".repeat(32)}` as const;

function env(extra: Record<string, string> = {}): NodeJS.ProcessEnv {
  return {
    RELAYER_KEY: KEY,
    RPC_URL: "https://rpc.example.test",
    CHAIN_ID: "46630",
    STASH: TESTNET_STASH,
    ...extra,
  };
}

function state(): RelayState {
  return {
    rates: new RateLimit(),
    ips: new RateLimit(),
    resigns: new ResignBook(),
    nonces: new NonceQueue(async () => 7n),
    owners: new OwnerNonceGuard(),
  };
}

function deps(over: Partial<RelayDeps> = {}): RelayDeps & { sent: { nonce: bigint; priorityWei: bigint }[]; alerts: string[] } {
  const sent: { nonce: bigint; priorityWei: bigint }[] = [];
  const alerts: string[] = [];
  const base: RelayDeps = {
    now: () => 1_000_000,
    simulate: async () => ({ ok: true }),
    send: async (_data, opts) => {
      sent.push(opts);
      return "0xabc";
    },
    ethBalance: async () => 10n ** 18n,
    alert: async (message) => {
      alerts.push(message);
    },
    priorityWei: 20_000_000n,
  };
  const merged = { ...base, ...over, sent, alerts };
  return merged;
}

test("typehashes match the Stash strings", () => {
  assert.equal(keccak256(toBytes(SHOOT_TYPE)), SHOOT_TYPEHASH);
  assert.equal(keccak256(toBytes(TAKE_TYPE)), TAKE_TYPEHASH);
  assert.equal(keccak256(toBytes(WITHDRAW_TYPE)), WITHDRAW_TYPEHASH);
  assert.equal(keccak256(toBytes(AUTHORIZE_TYPE)), AUTHORIZE_TYPEHASH);
  assert.equal(keccak256(toBytes(SET_LIMIT_TYPE)), SET_LIMIT_TYPEHASH);
  assert.equal(keccak256(toBytes(REVOKE_TYPE)), REVOKE_TYPEHASH);
});

test("config reads the key from the environment and does not echo it", () => {
  const cfg = loadConfig(env());
  assert.equal(cfg.key, KEY);
  assert.equal(cfg.chainId, TESTNET_CHAIN_ID);
  assert.equal(cfg.stash, TESTNET_STASH);
  assert.equal(cfg.healthcheckUrl, "");
  assert.equal(cfg.priorityWei, 20_000_000n);
  assert.equal(RELAYER_ADDRESS, "0x58941E09432D2EF6316FA3b99476e69e68933c94");
  assert.equal(loadConfig(env({ HEALTHCHECK_URL: "https://hc.example/fail" })).healthcheckUrl, "https://hc.example/fail");
  assert.throws(() => loadConfig(env({ CHAIN_ID: "1" })), /46630/);
  assert.throws(() => loadConfig(env({ STASH: "0x0000000000000000000000000000000000000001" })), /46630 deployment/);
  assert.throws(() => loadConfig(env({ HEALTHCHECK_URL: "notaurl" })), /HEALTHCHECK_URL/);
  assert.throws(() => loadConfig(env({ RELAYER_KEY: SECRET.slice(0, 20) })), (err: Error) => {
    assert.equal(err.message.includes(SECRET.slice(0, 20)), false);
    assert.equal(err.message.includes("RELAYER_KEY"), true);
    return true;
  });
  assert.throws(() => loadConfig({ ...env(), RELAYER_KEY: "" }), /RELAYER_KEY/);
});

test("redact strips the key, the rpc url, and a healthcheck url", () => {
  const hook = "https://hc.example/secret-token";
  const text = redact(`failed ${KEY} at ${"https://rpc.example.test"} ping ${hook}`, [KEY, "https://rpc.example.test", hook]);
  assert.equal(text.includes(KEY), false);
  assert.equal(text.includes("rpc.example"), false);
  assert.equal(text.includes("secret-token"), false);
});

test("decideSim retries once inside the signed max", () => {
  assert.equal(decideSim({ ok: true }, 10n, false), "send");
  assert.equal(decideSim({ ok: false, kind: "price", price: 9n, maxPrice: 10n }, 10n, false), "retry");
  assert.equal(decideSim({ ok: false, kind: "price", price: 9n, maxPrice: 10n }, 10n, true), "reject");
  assert.equal(decideSim({ ok: false, kind: "price", price: 11n, maxPrice: 10n }, 10n, false), "reject");
  assert.equal(decideSim({ ok: false, kind: "round", expected: 1n, actual: 2n }, 10n, false), "resign");
  assert.equal(decideSim({ ok: false, kind: "other" }, 10n, false), "reject");
});

test("price above the signed max is not sent", async () => {
  const d = deps({
    simulate: async () => ({ ok: false, kind: "price", price: 50n, maxPrice: 10n }),
  });
  const result = await submitShot(d, state(), { owner: "0xabc", maxPrice: 10n, replaces: false, calldata: "0x1234" });
  assert.equal(result.status, 400);
  assert.equal(result.body.error, "price above signed max");
  assert.equal(result.body.livePrice, "50");
  assert.equal(d.sent.length, 0);
});

test("a price still inside the signed max is simulated again and sent once", async () => {
  let calls = 0;
  const d = deps({
    simulate: async () => {
      calls += 1;
      if (calls === 1) return { ok: false, kind: "price", price: 8n, maxPrice: 10n };
      return { ok: true };
    },
  });
  const result = await submitShot(d, state(), { owner: "0xabc", maxPrice: 10n, replaces: false, calldata: "0x1234" });
  assert.equal(result.status, 200);
  assert.equal(calls, 2);
  assert.equal(d.sent.length, 1);
  assert.equal(d.sent[0].priorityWei, 40_000_000n);
  assert.equal(d.sent[0].nonce, 7n);
});

test("wrong round offers one resign inside the original max", async () => {
  const st = state();
  const d = deps({
    simulate: async () => ({ ok: false, kind: "round", expected: 1n, actual: 2n }),
  });
  const first = await submitShot(d, st, { owner: "0xAbC", maxPrice: 10n, replaces: false, calldata: "0x11" });
  assert.equal(first.body.resign, true);
  assert.equal(first.body.liveRound, "2");
  assert.equal(d.sent.length, 0);

  const high = await submitShot(d, st, { owner: "0xabc", maxPrice: 11n, replaces: true, calldata: "0x22" });
  assert.equal(high.body.error, "above signed max");
  assert.equal(d.sent.length, 0);

  const d2 = deps({ simulate: async () => ({ ok: true }) });
  d2.sent = d.sent;
  const again = await submitShot(
    { ...d, simulate: async () => ({ ok: true }), send: d.send },
    st,
    { owner: "0xabc", maxPrice: 10n, replaces: true, calldata: "0x22" },
  );
  assert.equal(again.status, 200);
  assert.equal(d.sent.length, 1);

  const third = await submitShot(d, st, { owner: "0xabc", maxPrice: 10n, replaces: true, calldata: "0x33" });
  assert.equal(third.body.error, "resign window closed");
});

test("low balance alerts and the alert text has no key", async () => {
  const d = deps({ ethBalance: async () => 1n });
  await submitShot(d, state(), { owner: "0xabc", maxPrice: 1n, replaces: false, calldata: "0x1234" });
  assert.equal(d.alerts.length, 1);
  assert.equal(d.alerts[0].includes(KEY), false);
  assert.match(d.alerts[0], /0\.005 ETH/);
  assert.equal(d.sent.length, 1);
});

test("owner nonce is held until the in flight shot finishes", async () => {
  let release: () => void = () => {};
  const gate = new Promise<void>((resolve) => {
    release = resolve;
  });
  const d = deps({
    simulate: async () => {
      await gate;
      return { ok: true };
    },
  });
  const st = state();
  const first = submitShot(d, st, { owner: "0xabc", maxPrice: 1n, replaces: false, calldata: "0x01" });
  await new Promise((resolve) => setTimeout(resolve, 10));
  const second = await submitShot(d, st, { owner: "0xABC", maxPrice: 1n, replaces: false, calldata: "0x02" });
  assert.equal(second.body.error, "nonce in use");
  release();
  assert.equal((await first).status, 200);
});

test("rate limit is per owner", async () => {
  const rates = new RateLimit(2, 1_000);
  assert.equal(rates.allow("0xa", 0), true);
  assert.equal(rates.allow("0xa", 10), true);
  assert.equal(rates.allow("0xa", 20), false);
  assert.equal(rates.allow("0xb", 20), true);
  assert.equal(rates.allow("0xa", 2_000), true);
});

test("nonce queue assigns sequential nonces and refreshes after a failed send", async () => {
  let pending = 4n;
  const queue = new NonceQueue(async () => pending);
  const seen: bigint[] = [];
  await Promise.all([
    queue.run(async (nonce) => {
      seen.push(nonce);
    }),
    queue.run(async (nonce) => {
      seen.push(nonce);
    }),
  ]);
  assert.deepEqual(seen, [4n, 5n]);
  pending = 9n;
  await assert.rejects(queue.run(async () => {
    throw new Error("not broadcast");
  }));
  const next = await queue.run(async (nonce) => nonce);
  assert.equal(next, 9n);
});

test("resign book rejects a higher max and a second use", () => {
  const book = new ResignBook(1_000);
  book.offer("0xabc", 10n, 0);
  assert.equal(book.take("0xABC", 11n, 10), "above");
  assert.equal(book.take("0xabc", 10n, 10), "ok");
  assert.equal(book.take("0xabc", 10n, 10), "used");
  book.offer("0xdef", 3n, 0);
  assert.equal(book.take("0xdef", 3n, 5_000), "stale");
});

test("decode PriceAboveMax and WrongRound", () => {
  const price = encodeErrorResult({
    abi: gameErrors,
    errorName: "PriceAboveMax",
    args: [8n, 5n],
  });
  const decoded = decodeRevert(price);
  assert.equal(decoded.ok, false);
  if (!decoded.ok && decoded.kind === "price") {
    assert.equal(decoded.price, 8n);
    assert.equal(decoded.maxPrice, 5n);
  } else {
    assert.fail("expected a price error");
  }
  const round = encodeErrorResult({
    abi: gameErrors,
    errorName: "WrongRound",
    args: [1n, 2n],
  });
  const decodedRound = decodeRevert(round);
  if (!decodedRound.ok && decodedRound.kind === "round") assert.equal(decodedRound.actual, 2n);
  else assert.fail("expected a round error");
  assert.equal(decodeRevert("0x1234").kind, "other");
  const bad = encodeErrorResult({ abi: gameErrors, errorName: "BadSignature" });
  const badSim = decodeRevert(bad);
  assert.equal(badSim.ok, false);
  if (!badSim.ok && badSim.kind === "other") assert.equal(badSim.reason, "bad signature");
  else assert.fail("expected a bad signature");
  const nested = simulationFromError({ cause: { data: bad } });
  if (!nested.ok && nested.kind === "other") assert.equal(nested.reason, "bad signature");
  else assert.fail("expected a nested bad signature");
});

test("a failed simulation is not sent", async () => {
  const d = deps({
    simulate: async () => ({ ok: false, kind: "other", reason: "bad signature" }),
  });
  const result = await submitShot(d, state(), { owner: "0xabc", maxPrice: 10n, replaces: false, calldata: "0x1234" });
  assert.equal(result.status, 400);
  assert.equal(result.body.error, "bad signature");
  assert.equal(d.sent.length, 0);
});

test("a failed send is tried once more", async () => {
  const sent: { nonce: bigint; priorityWei: bigint }[] = [];
  let calls = 0;
  const d = deps({
    send: async (_data, opts) => {
      calls += 1;
      if (calls === 1) throw new Error("rpc down");
      sent.push(opts);
      return "0xabc";
    },
  });
  const result = await submitShot(d, state(), { owner: "0xabc", maxPrice: 1n, replaces: false, calldata: "0x1234" });
  assert.equal(result.status, 200);
  assert.equal(result.body.hash, "0xabc");
  assert.equal(calls, 2);
  assert.equal(sent.length, 1);
  assert.equal(sent[0].priorityWei, 40_000_000n);
  assert.equal(sent[0].nonce, 7n);
});

test("two failed sends return a clear error and stop", async () => {
  let calls = 0;
  const d = deps({
    send: async () => {
      calls += 1;
      throw new Error("still down");
    },
  });
  const result = await submitShot(d, state(), { owner: "0xabc", maxPrice: 1n, replaces: false, calldata: "0x1234" });
  assert.equal(result.status, 502);
  assert.equal(result.body.error, "relay failed");
  assert.equal(result.body.ok, false);
  assert.equal(calls, 2);
  assert.equal(d.sent.length, 0);
});

test("a simulation RPC failure is tried once", async () => {
  let calls = 0;
  const d = deps({
    simulate: async () => {
      calls += 1;
      if (calls === 1) throw new Error("rpc");
      return { ok: true };
    },
  });
  const result = await submitShot(d, state(), { owner: "0xabc", maxPrice: 1n, replaces: false, calldata: "0x1234" });
  assert.equal(result.status, 200);
  assert.equal(calls, 2);
  assert.equal(d.sent.length, 1);
});

test("two simulation RPC failures are not sent", async () => {
  let calls = 0;
  const d = deps({
    simulate: async () => {
      calls += 1;
      throw new Error("rpc");
    },
  });
  const result = await submitShot(d, state(), { owner: "0xabc", maxPrice: 1n, replaces: false, calldata: "0x1234" });
  assert.equal(result.status, 502);
  assert.equal(result.body.error, "simulation failed");
  assert.equal(calls, 2);
  assert.equal(d.sent.length, 0);
});

test("submitShot rate limit is per owner", async () => {
  const st = state();
  st.rates = new RateLimit(1, 1_000);
  const d = deps();
  const first = await submitShot(d, st, { owner: "0xabc", maxPrice: 1n, replaces: false, calldata: "0x01" });
  const second = await submitShot(d, st, { owner: "0xABC", maxPrice: 1n, replaces: false, calldata: "0x02" });
  const other = await submitShot(d, st, { owner: "0xdef", maxPrice: 1n, replaces: false, calldata: "0x03" });
  assert.equal(first.status, 200);
  assert.equal(second.status, 429);
  assert.equal(second.body.error, "rate limit");
  assert.equal(other.status, 200);
});

test("a send over the gas cap is refused once with 503, not retried", async () => {
  const { GasCapError } = await import("../src/policy.ts");
  let calls = 0;
  const d = deps({
    send: async () => {
      calls += 1;
      throw new GasCapError();
    },
  });
  const result = await submitShot(d, state(), { owner: "0xabc", maxPrice: 10n, replaces: false, calldata: "0x1234" });
  assert.equal(result.status, 503);
  assert.equal(result.body.error, "gas price above cap");
  assert.equal(calls, 1);
});

test("MAX_FEE_GWEI defaults to 0.5 and must sit above twice the tip", () => {
  assert.equal(loadConfig(env()).maxFeeWei, 500_000_000n);
  assert.equal(loadConfig(env({ MAX_FEE_GWEI: "2" })).maxFeeWei, 2_000_000_000n);
  assert.throws(() => loadConfig(env({ MAX_FEE_GWEI: "0" })));
  assert.throws(() => loadConfig(env({ MAX_FEE_GWEI: "0.03", PRIORITY_GWEI: "0.02" })));
});
