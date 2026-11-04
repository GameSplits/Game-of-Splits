// Local anvil fork of chain 46630. Funds the relayer with anvil_setBalance and sends nothing to the live network.

import assert from "node:assert/strict";
import { type ChildProcess, spawn } from "node:child_process";
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { createServer } from "node:net";
import { dirname, join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import {
  createPublicClient,
  encodeAbiParameters,
  encodeFunctionData,
  http,
  keccak256,
  parseEther,
  toHex,
  type Address,
  type Hex,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { generatePrivateKey } from "viem/accounts";
import { defineChain } from "viem";
import { TESTNET_STASH, loadConfig } from "../../src/config.ts";
import { shootTypes, stashDomain, takeTypes } from "../../src/eip712.ts";
import { start } from "../../src/server.ts";

const FORK_URL = "https://rpc.testnet.chain.robinhood.com";
const STASH = TESTNET_STASH;
const CORE = "0xc76d5ED46786e67Fb5925928af18C08da7078Cf0" as Address;
const ARROW = "0x14700ccE7f3c0Fc7E1DA3BA303Fe632E52197316" as Address;
const SEAT = "0x4f811cAAa659341a4d0066731F2bCa1b60e3F8ef" as Address;
const USDG = "0xA173301d53E1cA0790A6f8d074F515bFc543980c" as Address;
const RELAYER_KEY = `0x${"11".repeat(32)}` as Hex;
const ARB = "0x0000000000000000000000000000000000000064" as Address;

const erc20 = [
  {
    type: "function",
    name: "balanceOf",
    stateMutability: "view",
    inputs: [{ name: "account", type: "address" }],
    outputs: [{ type: "uint256" }],
  },
  {
    type: "function",
    name: "approve",
    stateMutability: "nonpayable",
    inputs: [
      { name: "spender", type: "address" },
      { name: "amount", type: "uint256" },
    ],
    outputs: [],
  },
] as const;

const stashSetup = [
  {
    type: "function",
    name: "core",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "address" }],
  },
  {
    type: "function",
    name: "arrow",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "address" }],
  },
  {
    type: "function",
    name: "seat",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "address" }],
  },
  {
    type: "function",
    name: "usdg",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "address" }],
  },
  {
    type: "function",
    name: "shotFee",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "uint256" }],
  },
  {
    type: "function",
    name: "deposit",
    stateMutability: "nonpayable",
    inputs: [{ name: "amount", type: "uint256" }],
    outputs: [],
  },
  {
    type: "function",
    name: "authorizeKey",
    stateMutability: "nonpayable",
    inputs: [
      { name: "key", type: "address" },
      { name: "limit", type: "uint256" },
      { name: "expiry", type: "uint256" },
    ],
    outputs: [],
  },
  {
    type: "function",
    name: "nonces",
    stateMutability: "view",
    inputs: [{ name: "owner", type: "address" }],
    outputs: [{ type: "uint256" }],
  },
  {
    type: "function",
    name: "session",
    stateMutability: "view",
    inputs: [{ name: "owner", type: "address" }],
    outputs: [
      { name: "key", type: "address" },
      { name: "expiry", type: "uint48" },
      { name: "epoch", type: "uint48" },
      { name: "limit", type: "uint256" },
      { name: "spent", type: "uint256" },
    ],
  },
] as const;

const coreAbi = [
  { type: "function", name: "salesPaused", stateMutability: "view", inputs: [], outputs: [{ type: "bool" }] },
  { type: "function", name: "owner", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
  {
    type: "function",
    name: "pauseSales",
    stateMutability: "nonpayable",
    inputs: [{ name: "paused", type: "bool" }],
    outputs: [],
  },
  { type: "function", name: "fairPass", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
  { type: "function", name: "config", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
] as const;

const configAbi = [
  {
    type: "function",
    name: "tokens",
    stateMutability: "view",
    inputs: [],
    outputs: [
      { name: "playToken", type: "address" },
      { name: "passLock", type: "uint256" },
      { name: "buyToken", type: "address" },
    ],
  },
] as const;

const passAbi = [
  {
    type: "function",
    name: "lock",
    stateMutability: "nonpayable",
    inputs: [
      { name: "expectedToken", type: "address" },
      { name: "maxAmount", type: "uint256" },
    ],
    outputs: [],
  },
  {
    type: "function",
    name: "hasPass",
    stateMutability: "view",
    inputs: [{ name: "account", type: "address" }],
    outputs: [{ type: "bool" }],
  },
] as const;

const arrowAbi = [
  { type: "function", name: "currentPrice", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { type: "function", name: "nextShotRound", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  {
    type: "function",
    name: "roundState",
    stateMutability: "view",
    inputs: [{ name: "roundId", type: "uint256" }],
    outputs: [
      {
        name: "round",
        type: "tuple",
        components: [
          { name: "start", type: "uint64" },
          { name: "deadline", type: "uint64" },
          { name: "hardEnd", type: "uint64" },
          { name: "shots", type: "uint32" },
          { name: "settled", type: "bool" },
          { name: "nextPrice", type: "uint128" },
          { name: "lastShooter", type: "address" },
          { name: "lastShotL2Block", type: "uint64" },
          { name: "leader", type: "address" },
          { name: "leaderCount", type: "uint32" },
          { name: "pauseMark", type: "uint64" },
        ],
      },
    ],
  },
] as const;

const seatAbi = [
  { type: "function", name: "price", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { type: "function", name: "today", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  {
    type: "function",
    name: "holderOf",
    stateMutability: "view",
    inputs: [{ name: "day", type: "uint256" }],
    outputs: [
      { name: "holder", type: "address" },
      { name: "since", type: "uint64" },
      { name: "lastPaid", type: "uint128" },
    ],
  },
] as const;

function freePort(): Promise<number> {
  return new Promise((resolve, reject) => {
    const server = createServer();
    server.listen(0, "127.0.0.1", () => {
      const addr = server.address();
      if (!addr || typeof addr === "string") {
        reject(new Error("no port"));
        return;
      }
      const port = addr.port;
      server.close(() => resolve(port));
    });
  });
}

function assertLocal(url: string): void {
  const host = new URL(url).hostname;
  if (host !== "127.0.0.1" && host !== "localhost") throw new Error("refusing a non-local RPC");
}

function redactKeys(text: string): string {
  return text.replace(/0x[0-9a-fA-F]{64}/g, "0x[redacted]");
}

function arbBytecode(): Hex {
  const root = dirname(fileURLToPath(import.meta.url));
  const forge = process.env.FORGE ?? "forge";
  execFileSync(forge, ["build", "--root", root], { stdio: "pipe" });
  const artifact = JSON.parse(readFileSync(join(root, "out/ForkArb.sol/ForkArb.json"), "utf8")) as {
    deployedBytecode: { object?: string } | string;
  };
  const object = typeof artifact.deployedBytecode === "string" ? artifact.deployedBytecode : artifact.deployedBytecode.object;
  if (!object || object === "0x") throw new Error("ForkArb bytecode missing");
  return (object.startsWith("0x") ? object : `0x${object}`) as Hex;
}

test("relays a signed shoot and take through the deployed Stash on an anvil fork", { timeout: 300_000 }, async () => {
  const anvilPort = await freePort();
  const httpPort = await freePort();
  const anvilUrl = `http://127.0.0.1:${anvilPort}`;
  assertLocal(anvilUrl);
  let log = "";
  const anvil = spawn(
    process.env.ANVIL ?? "anvil",
    [
      "--fork-url",
      FORK_URL,
      "--chain-id",
      "46630",
      "--port",
      String(anvilPort),
      "--host",
      "127.0.0.1",
      "--silent",
      "--no-rate-limit",
    ],
    { stdio: ["ignore", "pipe", "pipe"] },
  );
  anvil.stdout?.on("data", (chunk: Buffer) => {
    log = (log + chunk.toString()).slice(-4000);
  });
  anvil.stderr?.on("data", (chunk: Buffer) => {
    log = (log + chunk.toString()).slice(-4000);
  });
  let server: Awaited<ReturnType<typeof start>> | undefined;
  const stop = (child: ChildProcess) => {
    if (!child.killed) child.kill("SIGKILL");
  };

  try {
    await waitForChain(anvilUrl, anvil);
    const chain = defineChain({
      id: 46630,
      name: "Robinhood",
      nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
      rpcUrls: { default: { http: [anvilUrl] } },
    });
    const pub = createPublicClient({ chain, transport: http(anvilUrl, { retryCount: 0, timeout: 20_000 }) });

    async function rpc(method: string, params: unknown[]): Promise<{ result?: unknown; error?: { message?: string } }> {
      assertLocal(anvilUrl);
      const res = await fetch(anvilUrl, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
      });
      return (await res.json()) as { result?: unknown; error?: { message?: string } };
    }

    async function sendAs(from: Address, to: Address, data: Hex): Promise<void> {
      const unlocked = await rpc("anvil_impersonateAccount", [from]);
      if (unlocked.error) throw new Error(unlocked.error.message ?? "impersonate failed");
      const sent = await rpc("eth_sendTransaction", [{ from, to, data }]);
      if (sent.error || typeof sent.result !== "string") {
        throw new Error(sent.error?.message ?? "send failed");
      }
      const receipt = await pub.waitForTransactionReceipt({ hash: sent.result as Hex, timeout: 30_000 });
      if (receipt.status !== "success") throw new Error(`reverted ${sent.result}`);
    }

    const code = arbBytecode();
    const etched = await rpc("anvil_setCode", [ARB, code]);
    if (etched.error) throw new Error(etched.error.message ?? "setCode failed");

    const core = await pub.readContract({ address: STASH, abi: stashSetup, functionName: "core" });
    const arrow = await pub.readContract({ address: STASH, abi: stashSetup, functionName: "arrow" });
    const seat = await pub.readContract({ address: STASH, abi: stashSetup, functionName: "seat" });
    const usdg = await pub.readContract({ address: STASH, abi: stashSetup, functionName: "usdg" });
    assert.equal(core.toLowerCase(), CORE.toLowerCase());
    assert.equal(arrow.toLowerCase(), ARROW.toLowerCase());
    assert.equal(seat.toLowerCase(), SEAT.toLowerCase());
    assert.equal(usdg.toLowerCase(), USDG.toLowerCase());

    const player = privateKeyToAccount(generatePrivateKey());
    const session = privateKeyToAccount(generatePrivateKey());
    const relayer = privateKeyToAccount(RELAYER_KEY);
    const rich = `0x${parseEther("10").toString(16)}` as Hex;
    for (const account of [player.address, session.address, relayer.address]) {
      const funded = await rpc("anvil_setBalance", [account, rich]);
      if (funded.error) throw new Error(funded.error.message ?? "setBalance failed");
    }

    if (await pub.readContract({ address: core, abi: coreAbi, functionName: "salesPaused" })) {
      const owner = await pub.readContract({ address: core, abi: coreAbi, functionName: "owner" });
      const gas = await rpc("anvil_setBalance", [owner, rich]);
      if (gas.error) throw new Error(gas.error.message ?? "setBalance failed");
      await sendAs(owner, core, encodeFunctionData({ abi: coreAbi, functionName: "pauseSales", args: [false] }));
    }

    const pass = await pub.readContract({ address: core, abi: coreAbi, functionName: "fairPass" });
    const config = await pub.readContract({ address: core, abi: coreAbi, functionName: "config" });
    const tokens = await pub.readContract({ address: config, abi: configAbi, functionName: "tokens" });
    const playToken = tokens[0];
    const passLock = tokens[1];
    await deal(rpc, pub, playToken, player.address, passLock);
    await sendAs(
      player.address,
      playToken,
      encodeFunctionData({ abi: erc20, functionName: "approve", args: [pass, passLock] }),
    );
    await sendAs(
      player.address,
      pass,
      encodeFunctionData({ abi: passAbi, functionName: "lock", args: [playToken, passLock] }),
    );
    assert.equal(await pub.readContract({ address: pass, abi: passAbi, functionName: "hasPass", args: [player.address] }), true);

    const arrowPrice = await pub.readContract({ address: arrow, abi: arrowAbi, functionName: "currentPrice" });
    const round = await pub.readContract({ address: arrow, abi: arrowAbi, functionName: "nextShotRound" });
    const seatPrice = await pub.readContract({ address: seat, abi: seatAbi, functionName: "price" });
    const shotFee = await pub.readContract({ address: STASH, abi: stashSetup, functionName: "shotFee" });
    assert.ok(arrowPrice > 0n, "arrow price");
    assert.ok(seatPrice > 0n, "seat price");
    const deposit = arrowPrice + seatPrice + shotFee * 2n + 5_000_000n;
    await deal(rpc, pub, usdg, player.address, deposit);
    await sendAs(
      player.address,
      usdg,
      encodeFunctionData({ abi: erc20, functionName: "approve", args: [STASH, deposit] }),
    );
    await sendAs(player.address, STASH, encodeFunctionData({ abi: stashSetup, functionName: "deposit", args: [deposit] }));
    const block = await pub.getBlock();
    const expiry = block.timestamp + 86_400n;
    const unlimited = (1n << 128n) - 1n;
    await sendAs(
      player.address,
      STASH,
      encodeFunctionData({
        abi: stashSetup,
        functionName: "authorizeKey",
        args: [session.address, unlimited, expiry],
      }),
    );
    const stored = await pub.readContract({ address: STASH, abi: stashSetup, functionName: "session", args: [player.address] });
    const sessionKey = stored[0];
    const epoch = BigInt(stored[2]);
    assert.equal(sessionKey.toLowerCase(), session.address.toLowerCase());

    const relayerUsdgBefore = await pub.readContract({
      address: usdg,
      abi: erc20,
      functionName: "balanceOf",
      args: [relayer.address],
    });
    assert.equal(relayerUsdgBefore, 0n);

    const cfg = loadConfig({
      RELAYER_KEY,
      RPC_URL: anvilUrl,
      CHAIN_ID: "46630",
      STASH,
      PORT: String(httpPort),
    });
    assertLocal(cfg.rpcUrl);
    server = await start(cfg);

    const healthRes = await fetch(`http://127.0.0.1:${httpPort}/health`);
    const health = (await healthRes.json()) as { low: boolean; chainId: number; stash: string; relayer: string };
    assert.equal(health.low, false);
    assert.equal(health.chainId, 46630);
    assert.equal(health.stash.toLowerCase(), STASH.toLowerCase());
    assert.equal(health.relayer.toLowerCase(), relayer.address.toLowerCase());

    const deadline = block.timestamp + 3_600n;
    const nonce = await pub.readContract({ address: STASH, abi: stashSetup, functionName: "nonces", args: [player.address] });
    const shootMessage = {
      owner: player.address,
      maxPrice: arrowPrice * 2n,
      expectedRound: round,
      nonce,
      deadline,
      epoch,
    };
    const shootSig = await session.signTypedData({
      domain: stashDomain(46630, STASH),
      types: shootTypes,
      primaryType: "Shoot",
      message: shootMessage,
    });
    const shootOrder = orderJson(shootMessage);

    const before = await pub.getTransactionCount({ address: relayer.address });
    const wrongChain = await post(httpPort, "/shoot", { chainId: 1, stash: STASH, order: shootOrder, signature: shootSig });
    assert.equal(wrongChain.status, 400);
    assert.equal(wrongChain.body.error, "wrong chain");
    const wrongStash = await post(httpPort, "/shoot", {
      chainId: 46630,
      stash: "0x0000000000000000000000000000000000000004",
      order: shootOrder,
      signature: shootSig,
    });
    assert.equal(wrongStash.status, 400);
    assert.equal(wrongStash.body.error, "wrong stash");
    const flipped = (shootSig.slice(0, -1) + (shootSig.endsWith("a") ? "b" : "a")) as Hex;
    const badSig = await post(httpPort, "/shoot", { chainId: 46630, stash: STASH, order: shootOrder, signature: flipped });
    assert.equal(badSig.status, 400);
    assert.equal(badSig.body.error, "bad signature");
    assert.equal(await pub.getTransactionCount({ address: relayer.address }), before);

    const shot = await post(httpPort, "/shoot", { chainId: 46630, stash: STASH, order: shootOrder, signature: shootSig });
    assert.equal(shot.status, 200, JSON.stringify(shot.body));
    assert.equal(shot.body.ok, true);
    const shotReceipt = await pub.waitForTransactionReceipt({ hash: shot.body.hash as Hex, timeout: 30_000 });
    assert.equal(shotReceipt.status, "success");
    const shotTx = await pub.getTransaction({ hash: shotReceipt.transactionHash });
    assert.equal(shotTx.value, 0n);
    assert.equal(shotTx.from.toLowerCase(), relayer.address.toLowerCase());
    assert.equal(shotTx.to?.toLowerCase(), STASH.toLowerCase());
    const landed = await pub.readContract({ address: arrow, abi: arrowAbi, functionName: "roundState", args: [round] });
    assert.equal(landed.lastShooter.toLowerCase(), player.address.toLowerCase());

    const takeNonce = await pub.readContract({
      address: STASH,
      abi: stashSetup,
      functionName: "nonces",
      args: [player.address],
    });
    const takeMessage = {
      owner: player.address,
      maxPrice: seatPrice * 2n,
      presetId: 0,
      color: 1,
      nonce: takeNonce,
      deadline,
      epoch,
    };
    const takeSig = await session.signTypedData({
      domain: stashDomain(46630, STASH),
      types: takeTypes,
      primaryType: "Take",
      message: takeMessage,
    });
    const taken = await post(httpPort, "/take", {
      chainId: 46630,
      stash: STASH,
      order: {
        owner: takeMessage.owner,
        maxPrice: takeMessage.maxPrice.toString(),
        presetId: takeMessage.presetId,
        color: takeMessage.color,
        nonce: takeMessage.nonce.toString(),
        deadline: takeMessage.deadline.toString(),
        epoch: takeMessage.epoch.toString(),
      },
      signature: takeSig,
    });
    assert.equal(taken.status, 200, JSON.stringify(taken.body));
    const takeReceipt = await pub.waitForTransactionReceipt({ hash: taken.body.hash as Hex, timeout: 30_000 });
    assert.equal(takeReceipt.status, "success");
    const takeTx = await pub.getTransaction({ hash: takeReceipt.transactionHash });
    assert.equal(takeTx.value, 0n);
    const day = await pub.readContract({ address: seat, abi: seatAbi, functionName: "today" });
    const holder = await pub.readContract({ address: seat, abi: seatAbi, functionName: "holderOf", args: [day] });
    assert.equal(holder[0].toLowerCase(), player.address.toLowerCase());
    const relayerUsdgAfter = await pub.readContract({
      address: usdg,
      abi: erc20,
      functionName: "balanceOf",
      args: [relayer.address],
    });
    assert.equal(relayerUsdgAfter, 0n);
  } catch (err) {
    const detail = redactKeys(log).trim();
    if (detail) console.error(detail);
    throw err;
  } finally {
    if (server) await new Promise<void>((resolve) => server?.close(() => resolve()));
    stop(anvil);
  }
});

function orderJson(message: {
  owner: Address;
  maxPrice: bigint;
  expectedRound: bigint;
  nonce: bigint;
  deadline: bigint;
  epoch: bigint;
}) {
  return {
    owner: message.owner,
    maxPrice: message.maxPrice.toString(),
    expectedRound: message.expectedRound.toString(),
    nonce: message.nonce.toString(),
    deadline: message.deadline.toString(),
    epoch: message.epoch.toString(),
  };
}

async function post(
  port: number,
  path: string,
  body: unknown,
): Promise<{ status: number; body: { ok?: boolean; error?: string; hash?: string } }> {
  const res = await fetch(`http://127.0.0.1:${port}${path}`, {
    method: "POST",
    headers: { "content-type": "application/json", "x-forwarded-for": "203.0.113.20" },
    body: JSON.stringify(body),
  });
  return { status: res.status, body: (await res.json()) as { ok?: boolean; error?: string; hash?: string } };
}

async function deal(
  rpc: (method: string, params: unknown[]) => Promise<{ result?: unknown; error?: { message?: string } }>,
  pub: ReturnType<typeof createPublicClient>,
  token: Address,
  to: Address,
  amount: bigint,
): Promise<void> {
  // Both testnet tokens keep balances at mapping slot 0. anvil_setStorageAt writes the fork only.
  const slot = keccak256(encodeAbiParameters([{ type: "address" }, { type: "uint256" }], [to, 0n]));
  const dealt = await rpc("anvil_setStorageAt", [token, slot, toHex(amount, { size: 32 })]);
  if (dealt.error) throw new Error(dealt.error.message ?? "setStorageAt failed");
  const balance = await pub.readContract({ address: token, abi: erc20, functionName: "balanceOf", args: [to] });
  if (balance < amount) throw new Error(`deal of ${token} left ${balance.toString()}`);
}

async function waitForChain(url: string, child: ChildProcess): Promise<void> {
  assertLocal(url);
  let last = "";
  for (let i = 0; i < 80; i++) {
    if (child.exitCode !== null) break;
    try {
      const res = await fetch(url, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "eth_chainId", params: [] }),
      });
      const body = (await res.json()) as { result?: string };
      if (body.result === "0xb626") return;
      last = JSON.stringify(body);
    } catch (err) {
      last = err instanceof Error ? err.message : "unreachable";
    }
    await new Promise((resolve) => setTimeout(resolve, 250));
  }
  throw new Error(`anvil did not reach chain 46630 (${last})`);
}
