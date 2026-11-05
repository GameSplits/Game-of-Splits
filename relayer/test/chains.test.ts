import assert from "node:assert/strict";
import test from "node:test";
import { getAddress } from "viem";
import {
  CHAINS,
  MAINNET_CHAIN_ID,
  MAINNET_STASH,
  TESTNET_CHAIN_ID,
  TESTNET_STASH,
  chainProfile,
  loadConfig,
  loadOrigins,
  type ChainTable,
} from "../src/config.ts";

const FAKE_MAINNET_STASH = getAddress("0x00000000000000000000000000000000000a4663");
const withMainnet: ChainTable = {
  ...CHAINS,
  [MAINNET_CHAIN_ID]: { ...CHAINS[MAINNET_CHAIN_ID]!, stash: FAKE_MAINNET_STASH },
};

function env(extra: Record<string, string | undefined> = {}): NodeJS.ProcessEnv {
  return { RELAYER_KEY: `0x${"11".repeat(32)}`, RPC_URL: "https://rpc.example.test", ...extra };
}

test("only 46630 and 4663 are known chains", () => {
  assert.deepEqual(Object.keys(CHAINS).map(Number).sort((a, b) => a - b), [MAINNET_CHAIN_ID, TESTNET_CHAIN_ID]);
  assert.equal(CHAINS[TESTNET_CHAIN_ID]!.stash, TESTNET_STASH);
  assert.equal(CHAINS[TESTNET_CHAIN_ID]!.previewPattern, true);
  assert.equal(CHAINS[MAINNET_CHAIN_ID]!.previewPattern, false);
  assert.ok(Object.isFrozen(CHAINS));
});

test("CHAIN_ID is required and there is no default chain", () => {
  assert.throws(() => loadConfig(env({ STASH: TESTNET_STASH })), /missing env CHAIN_ID/);
  assert.throws(() => loadConfig(env({ CHAIN_ID: "", STASH: TESTNET_STASH })), /missing env CHAIN_ID/);
  assert.throws(() => loadOrigins({}), /CHAIN_ID must be one of/);
  assert.throws(() => chainProfile(undefined), /CHAIN_ID must be one of/);
});

test("any other chain id fails closed", () => {
  for (const bad of ["1", "0", "46631", "4662", "8453", "-4663", "4663.0", "0x1237", " 46630x", "constructor", "__proto__", "99999999999"]) {
    assert.throws(() => chainProfile(bad), /CHAIN_ID must be one of/, bad);
    assert.throws(() => loadConfig(env({ CHAIN_ID: bad, STASH: TESTNET_STASH })), /CHAIN_ID must be one of/, bad);
    assert.throws(() => loadOrigins({ CHAIN_ID: bad }), /CHAIN_ID must be one of/, bad);
  }
  assert.throws(() => loadOrigins({ CHAIN_ID: "46630" }, 1), /CHAIN_ID must be one of/);
});

test("testnet still loads with its pinned Stash", () => {
  const cfg = loadConfig(env({ CHAIN_ID: "46630", STASH: TESTNET_STASH }));
  assert.equal(cfg.chainId, TESTNET_CHAIN_ID);
  assert.equal(cfg.stash, TESTNET_STASH);
});

test("mainnet refuses to start while its Stash is not pinned", () => {
  assert.equal(MAINNET_STASH, null);
  assert.throws(() => loadConfig(env({ CHAIN_ID: "4663", STASH: TESTNET_STASH })), /STASH for 4663 is not pinned/);
  assert.throws(() => loadConfig(env({ CHAIN_ID: "4663", STASH: FAKE_MAINNET_STASH })), /STASH for 4663 is not pinned/);
});

test("mainnet with a pinned Stash loads 4663 and only that Stash", () => {
  const cfg = loadConfig(env({ CHAIN_ID: "4663", STASH: FAKE_MAINNET_STASH.toLowerCase() }), withMainnet);
  assert.equal(cfg.chainId, MAINNET_CHAIN_ID);
  assert.equal(cfg.stash, FAKE_MAINNET_STASH);
  assert.throws(() => loadConfig(env({ CHAIN_ID: "4663", STASH: TESTNET_STASH }), withMainnet), /STASH must be the 4663 deployment/);
  assert.throws(
    () => loadConfig(env({ CHAIN_ID: "46630", STASH: FAKE_MAINNET_STASH }), withMainnet),
    /STASH must be the 46630 deployment/,
  );
});

test("the chain id comes from CHAIN_ID, never from the Stash or a default", () => {
  const cfg = loadConfig(env({ CHAIN_ID: "46630", STASH: TESTNET_STASH }), withMainnet);
  assert.equal(cfg.chainId, TESTNET_CHAIN_ID);
});

test("mainnet never loads a preview pattern, even when one is set", () => {
  const p = loadOrigins(
    { CHAIN_ID: "4663", ALLOW_ORIGIN_PATTERN: "^https://gos-testnet-[a-z0-9-]+-game-of-splits\\.vercel\\.app$" },
    undefined,
    withMainnet,
  );
  assert.equal(p.pattern, null);
  assert.deepEqual(p.exact, ["https://gameofsplits.fun", "https://www.gameofsplits.fun"]);
  const t = loadOrigins({ CHAIN_ID: "46630" });
  assert.notEqual(t.pattern, null);
  assert.deepEqual(t.exact, ["https://testnet.gameofsplits.fun", "https://gos-testnet.vercel.app"]);
});
