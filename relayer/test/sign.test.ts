import assert from "node:assert/strict";
import test from "node:test";
import { getAddress, type Address, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { stashAbi } from "../src/abi.ts";
import { guardTarget, HttpError } from "../src/actions.ts";
import { TESTNET_CHAIN_ID, TESTNET_STASH } from "../src/config.ts";
import { recoverSigner, shootTypes, stashDomain, takeTypes, withdrawTypes, authorizeTypes, limitTypes, revokeTypes } from "../src/eip712.ts";

const OWNER_KEY = `0x${"33".repeat(32)}` as Hex;
const SESSION_KEY = `0x${"22".repeat(32)}` as Hex;
const owner = privateKeyToAccount(OWNER_KEY);
const session = privateKeyToAccount(SESSION_KEY);

const shoot = {
  owner: owner.address,
  maxPrice: 2_000_000n,
  expectedRound: 2n,
  nonce: 0n,
  deadline: 2_000_000_000n,
  epoch: 1n,
};

async function signShoot(chainId: number, stash: Address) {
  return session.signTypedData({
    domain: stashDomain(chainId, stash),
    types: shootTypes,
    primaryType: "Shoot",
    message: shoot,
  });
}

test("a shoot signature recovers the session key on chain 46630", async () => {
  const signature = await signShoot(TESTNET_CHAIN_ID, TESTNET_STASH);
  const recovered = await recoverSigner(TESTNET_CHAIN_ID, TESTNET_STASH, { kind: "shoot", message: shoot, signature });
  assert.equal(recovered, getAddress(session.address));
});

test("the same signature does not recover on another chain or another Stash", async () => {
  const signature = await signShoot(TESTNET_CHAIN_ID, TESTNET_STASH);
  const otherChain = await recoverSigner(1, TESTNET_STASH, { kind: "shoot", message: shoot, signature });
  const otherStash = getAddress("0x0000000000000000000000000000000000000004");
  const otherContract = await recoverSigner(TESTNET_CHAIN_ID, otherStash, { kind: "shoot", message: shoot, signature });
  assert.notEqual(otherChain.toLowerCase(), session.address.toLowerCase());
  assert.notEqual(otherContract.toLowerCase(), session.address.toLowerCase());
});

test("owner actions recover the owner", async () => {
  const deadline = 2_000_000_000n;
  const withdraw = { owner: owner.address, amount: 5_000_000n, nonce: 1n, deadline };
  const withdrawSig = await owner.signTypedData({
    domain: stashDomain(TESTNET_CHAIN_ID, TESTNET_STASH),
    types: withdrawTypes,
    primaryType: "Withdraw",
    message: withdraw,
  });
  assert.equal(
    await recoverSigner(TESTNET_CHAIN_ID, TESTNET_STASH, { kind: "withdraw", message: withdraw, signature: withdrawSig }),
    getAddress(owner.address),
  );

  const authorize = {
    owner: owner.address,
    key: session.address,
    limit: 1_000_000n,
    expiry: deadline,
    nonce: 2n,
    deadline,
  };
  const authorizeSig = await owner.signTypedData({
    domain: stashDomain(TESTNET_CHAIN_ID, TESTNET_STASH),
    types: authorizeTypes,
    primaryType: "AuthorizeKey",
    message: authorize,
  });
  assert.equal(
    await recoverSigner(TESTNET_CHAIN_ID, TESTNET_STASH, {
      kind: "authorize-key",
      message: authorize,
      signature: authorizeSig,
    }),
    getAddress(owner.address),
  );

  const limit = { owner: owner.address, newLimit: 2_000_000n, nonce: 3n, deadline };
  const limitSig = await owner.signTypedData({
    domain: stashDomain(TESTNET_CHAIN_ID, TESTNET_STASH),
    types: limitTypes,
    primaryType: "SetLimit",
    message: limit,
  });
  assert.equal(
    await recoverSigner(TESTNET_CHAIN_ID, TESTNET_STASH, { kind: "set-limit", message: limit, signature: limitSig }),
    getAddress(owner.address),
  );

  const revoke = { owner: owner.address, nonce: 4n, deadline };
  const revokeSig = await owner.signTypedData({
    domain: stashDomain(TESTNET_CHAIN_ID, TESTNET_STASH),
    types: revokeTypes,
    primaryType: "RevokeKey",
    message: revoke,
  });
  assert.equal(
    await recoverSigner(TESTNET_CHAIN_ID, TESTNET_STASH, { kind: "revoke-key", message: revoke, signature: revokeSig }),
    getAddress(owner.address),
  );
});

test("a take signature recovers the session key", async () => {
  const message = {
    owner: owner.address,
    maxPrice: 2_000_000n,
    presetId: 0,
    color: 3,
    nonce: 1n,
    deadline: 2_000_000_000n,
    epoch: 1n,
  };
  const signature = await session.signTypedData({
    domain: stashDomain(TESTNET_CHAIN_ID, TESTNET_STASH),
    types: takeTypes,
    primaryType: "Take",
    message,
  });
  const recovered = await recoverSigner(TESTNET_CHAIN_ID, TESTNET_STASH, { kind: "take", message, signature });
  assert.equal(recovered, getAddress(session.address));
});

test("a signature from the wrong key does not recover the session key", async () => {
  const signature = await owner.signTypedData({
    domain: stashDomain(TESTNET_CHAIN_ID, TESTNET_STASH),
    types: shootTypes,
    primaryType: "Shoot",
    message: shoot,
  });
  const recovered = await recoverSigner(TESTNET_CHAIN_ID, TESTNET_STASH, { kind: "shoot", message: shoot, signature });
  assert.notEqual(recovered.toLowerCase(), session.address.toLowerCase());
});

test("the chain and stash guard rejects other targets", () => {
  const cfg = { chainId: TESTNET_CHAIN_ID, stash: TESTNET_STASH };
  assert.doesNotThrow(() => guardTarget(cfg, 46630, TESTNET_STASH.toLowerCase()));
  assert.throws(() => guardTarget(cfg, 1, TESTNET_STASH), (err: unknown) => err instanceof HttpError && err.message === "wrong chain");
  assert.throws(
    () => guardTarget(cfg, 46630, "0x0000000000000000000000000000000000000004"),
    (err: unknown) => err instanceof HttpError && err.message === "wrong stash",
  );
  assert.throws(() => guardTarget(cfg, Number.NaN, ""), (err: unknown) => err instanceof HttpError && err.message === "wrong chain");
});

test("the submit abi is the six signed calls", () => {
  const writes = stashAbi.filter((item) => item.type === "function" && item.stateMutability === "nonpayable").map((item) => item.name);
  assert.deepEqual([...writes].sort(), ["authorizeKey", "revokeKey", "setLimit", "shoot", "take", "withdraw"]);
  assert.equal(stashAbi.some((item) => item.type === "function" && item.name === "deposit"), false);
});
