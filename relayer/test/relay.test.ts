import assert from "node:assert/strict";
import { keccak256, toBytes } from "viem";
import test from "node:test";
import { SHOOT_TYPE, SHOOT_TYPEHASH, TAKE_TYPE, TAKE_TYPEHASH } from "../src/abi.ts";
import { loadConfig, redact } from "../src/config.ts";
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
    STASH: "0x0000000000000000000000000000000000000001",
    ARROW: "0x0000000000000000000000000000000000000002",
    SEAT: "0x0000000000000000000000000000000000000003",
    ...extra,
  };
}

function state(): RelayState {
  return {
    rates: new RateLimit(),
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
});

test("config reads the key from the environment and does not echo it", () => {
  const cfg = loadConfig(env());
  assert.equal(cfg.key, KEY);
  assert.equal(cfg.chainId, 46630);
  assert.equal(cfg.priorityWei, 20_000_000n);
  assert.throws(() => loadConfig(env({ RELAYER_KEY: SECRET.slice(0, 20) })), (err: Error) => {
    assert.equal(err.message.includes(SECRET.slice(0, 20)), false);
    assert.equal(err.message.includes("RELAYER_KEY"), true);
    return true;
  });
  assert.throws(() => loadConfig({ ...env(), RELAYER_KEY: "" }), /RELAYER_KEY/);
});

test("redact strips the key and the rpc url", () => {
  const text = redact(`failed ${KEY} at ${"https://rpc.example.test"}`, [KEY, "https://rpc.example.test"]);
  assert.equal(text.includes(KEY), false);
  assert.equal(text.includes("rpc.example"), false);
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
});
