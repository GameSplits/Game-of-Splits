// Regression: Stash shares one nonce per owner, so a second action kind at the same nonce is refused.
import assert from "node:assert/strict";
import test from "node:test";
import { type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { TESTNET_STASH, loadConfig } from "../src/config.ts";
import * as eip712 from "../src/eip712.ts";
import { handle, type HandleCtx, type HandleInput } from "../src/http.ts";
import { sendCapped, sharedState } from "../src/runtime.ts";
import { FakeKv } from "./fake-kv.ts";

const cfg = loadConfig({ RELAYER_KEY: `0x${"11".repeat(32)}`, RPC_URL: "https://rpc.example.test", CHAIN_ID: "46630", STASH: TESTNET_STASH });
const domain = eip712.stashDomain(46630, TESTNET_STASH);
const session = privateKeyToAccount(`0x${"22".repeat(32)}` as Hex);
const ownerAcct = privateKeyToAccount(`0x${"33".repeat(32)}` as Hex);
const O = ownerAcct.address;
const RELAYER = "0x00000000000000000000000000000000000000aa";
const str = (o: Record<string, unknown>) => Object.fromEntries(Object.entries(o).map(([k, v]) => [k, String(v)]));
const req = (route: string, body: string, ip: string): HandleInput => ({ method: "POST", path: `/${route}`, route, headers: { "x-vercel-forwarded-for": ip }, body });
const D = 2_000_000_000n;
const wrap = (m: Record<string, unknown>, signature: Hex) => JSON.stringify({ chainId: 46630, stash: TESTNET_STASH, order: str(m), signature });

async function bodies(nonce: bigint) {
  const lim = { owner: O, newLimit: 7n, nonce, deadline: D };
  const sh = { owner: O, maxPrice: 10n ** 9n, expectedRound: 1n, nonce, deadline: D, epoch: 1n };
  const tk = { owner: O, maxPrice: 10n ** 9n, presetId: 0, color: 3, nonce, deadline: D, epoch: 1n };
  const wd = { owner: O, amount: 2_000_000n, nonce, deadline: D };
  return {
    "set-limit": wrap(lim, await ownerAcct.signTypedData({ domain, types: eip712.limitTypes, primaryType: "SetLimit", message: lim })),
    shoot: wrap(sh, await session.signTypedData({ domain, types: eip712.shootTypes, primaryType: "Shoot", message: sh })),
    take: wrap(tk, await session.signTypedData({ domain, types: eip712.takeTypes, primaryType: "Take", message: tk })),
    withdraw: wrap(wd, await ownerAcct.signTypedData({ domain, types: eip712.withdrawTypes, primaryType: "Withdraw", message: wd })),
  } as Record<string, string>;
}

function ctxFor(kv: FakeKv, chain: { pending: bigint }, sends: bigint[]): HandleCtx {
  return {
    cfg,
    relayer: RELAYER,
    deps: {
      now: () => kv.now,
      simulate: async () => ({ ok: true }),
      send: (data, o) =>
        sendCapped(
          {
            baseFee: async () => 20_000_000n,
            estimate: async () => 80_000n,
            broadcast: async (tx) => {
              sends.push(tx.nonce);
              chain.pending++;
              return `0x${tx.nonce.toString(16).padStart(64, "0")}` as Hex;
            },
          },
          cfg.maxFeeWei,
          data,
          o,
        ),
      ethBalance: async () => 10n ** 18n,
      alert: async () => {},
      priorityWei: 1n,
    },
    state: sharedState(kv, 46630, RELAYER, async () => chain.pending, cfg.ethPerHourWei, cfg.accountShareBps),
    storageMode: "memory",
    sessionKey: async () => session.address,
    stashBalance: async () => 5_000_000n,
    ownerNonce: async () => 0n,
  };
}

test("control: the same kind at the same nonce twice is refused", async () => {
  const kv = new FakeKv();
  const sends: bigint[] = [];
  const c = ctxFor(kv, { pending: 0n }, sends);
  const b = await bodies(0n);
  assert.equal((await handle(c, req("shoot", b.shoot, "198.51.100.1"))).status, 200);
  const again = await handle(c, req("shoot", b.shoot, "198.51.100.2"));
  assert.equal(again.body?.error, "nonce in use");
  assert.equal(sends.length, 1);
});

test("a second kind at the same owner nonce returns nonce in use", async () => {
  const kv = new FakeKv();
  const sends: bigint[] = [];
  const c = ctxFor(kv, { pending: 0n }, sends);
  const b = await bodies(0n);
  const first = await handle(c, req("set-limit", b["set-limit"], "198.51.100.10"));
  assert.equal(first.status, 200);
  const out: string[] = [];
  for (const k of ["shoot", "take", "withdraw"]) {
    const r = await handle(c, req(k, b[k], `198.51.100.${20 + out.length}`));
    out.push(`${k}=${r.status}:${r.body?.error ?? ""}`);
    assert.equal(r.status, 400);
    assert.equal(r.body?.error, "nonce in use");
  }
  assert.equal(sends.length, 1, "only the first kind is broadcast");
  assert.deepEqual(out, ["shoot=400:nonce in use", "take=400:nonce in use", "withdraw=400:nonce in use"]);
});
