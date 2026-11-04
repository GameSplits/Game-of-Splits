// Chain clients. The signing key is used to send and is never logged.

import {
  createPublicClient,
  createWalletClient,
  defineChain,
  encodeFunctionData,
  getAddress,
  http,
  keccak256,
  type Address,
  type PrivateKeyAccount,
  type PublicClient,
  type WalletClient,
  type Hex,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { ERC1271_MAGIC, erc1271Abi, stashAbi } from "./abi.ts";
import { ERC1271_CHECK_GAS, TESTNET_CHAIN_ID, redact, type RelayerConfig } from "./config.ts";
import { decodeRevert, extractRevertData } from "./decode.ts";
import type { HandleCtx } from "./http.ts";
import { pingHealthcheck } from "./ping.ts";
import { GasCapError, MaybeSentError, SpendCapError, broadcastAmbiguous, gasLimitFor, isNonceLow, knownRejection, neverReached } from "./policy.ts";
import { REVOKES_PER_HOUR, freshState, splitBudget, type RelayDeps, type RelayState, type SendOpts } from "./relay.ts";
import { SharedNonces, SharedRateLimit, SharedSpend, SharedUsedOrders, upstashEnv, upstashKv, type Kv } from "./shared.ts";
import type { Sim } from "./policy.ts";

export function simulationFromError(err: unknown): Sim {
  const data = extractRevertData(err);
  return data ? decodeRevert(data) : { ok: false, kind: "other", reason: "simulation failed" };
}

/** Chain calls one capped send needs. Split out so the cap and budget logic can be tested without a node. */
export interface SendIo {
  baseFee(): Promise<bigint>;
  estimate(data: Hex): Promise<bigint>;
  broadcast(tx: SendTx, raw?: Hex): Promise<Hex>;
  /** Signs the transaction locally, so its hash is known before it is sent. */
  sign?(tx: SendTx): Promise<{ raw: Hex; hash: Hex }>;
  /** Whether the node knows a transaction by hash, pending or mined. Throws when it cannot tell. */
  known?(hash: Hex): Promise<boolean>;
  /** Waits before a second lookup. */
  pause?(ms: number): Promise<void>;
}

export type SendTx = { data: Hex; nonce: bigint; gas: bigint; maxFeePerGas: bigint; maxPriorityFeePerGas: bigint };

/**
 * One relayed send. Refuses a fee above MAX_FEE_GWEI, refuses an estimate above the action's gas cap, never sets a
 * gas limit above the cap, and reserves gas limit times max fee against the hourly ETH budget before broadcasting.
 */
export async function sendCapped(io: SendIo, maxFeeWei: bigint, data: Hex, opts: SendOpts): Promise<Hex> {
  const base = await io.baseFee();
  const maxFeePerGas = base + opts.priorityWei;
  if (maxFeePerGas > maxFeeWei) throw new GasCapError();
  const gas = gasLimitFor(await io.estimate(data), opts.gasCap);
  if (!(await opts.reserve(gas * maxFeePerGas))) throw new SpendCapError();
  const tx: SendTx = { data, nonce: opts.nonce, gas, maxFeePerGas, maxPriorityFeePerGas: opts.priorityWei };
  const signed = io.sign ? await io.sign(tx) : undefined;
  opts.broadcasting?.();
  try {
    return await io.broadcast(tx, signed?.raw);
  } catch (err) {
    // Only the broadcast itself can leave the outcome unknown.
    if (broadcastAmbiguous(err)) throw new MaybeSentError(err, signed?.hash);
    // A clear error can still follow a send the node took (a proxy timeout, "already known"), so ask for the hash first.
    if (signed && io.known) {
      const known = io.known;
      const look = async (): Promise<boolean | null> => {
        try {
          return await known(signed.hash);
        } catch {
          return null;
        }
      };
      const low = isNonceLow(err) && !neverReached(err);
      let seen = await look();
      if (seen === null) {
        // No answer. A clear refusal still frees the order; anything else, or a used nonce, may be our own send.
        if (neverReached(err) || (knownRejection(err) && !low)) throw err;
        throw new MaybeSentError(err, signed.hash);
      }
      if (seen) return signed.hash;
      if (low) {
        // A used nonce right after our own send may be that send, taken by a node the lookup has not caught up with.
        await io.pause?.(1_000);
        seen = await look();
        if (seen) return signed.hash;
        throw new MaybeSentError(err, signed.hash);
      }
      // Not found may only mean the read node lags. Only a known refusal proves it did not go out.
      if (!neverReached(err) && !knownRejection(err)) throw new MaybeSentError(err, signed.hash);
    }
    throw err;
  }
}

/** The viem side of a capped send. The transaction is signed locally so its hash is known before it goes out. */
export function chainSendIo(
  pub: PublicClient,
  wallet: WalletClient,
  account: PrivateKeyAccount,
  chainId: number,
  to: Address,
): SendIo {
  const cfg = { chainId, stash: to };
  return {
    baseFee: async () => (await pub.getBlock()).baseFeePerGas ?? 0n,
    estimate: (d) => pub.estimateGas({ account: account.address, to: cfg.stash, data: d }),
    sign: async (tx) => {
      const raw = await account.signTransaction({
        type: "eip1559",
        chainId: cfg.chainId,
        to: cfg.stash,
        data: tx.data,
        value: 0n,
        nonce: Number(tx.nonce),
        gas: tx.gas,
        maxFeePerGas: tx.maxFeePerGas,
        maxPriorityFeePerGas: tx.maxPriorityFeePerGas,
      });
      return { raw, hash: keccak256(raw) };
    },
    broadcast: (_tx, raw) => wallet.sendRawTransaction({ serializedTransaction: raw! }),
    pause: (ms) => new Promise((r) => setTimeout(r, ms)),
    known: async (hash) => {
      try {
        await pub.getTransaction({ hash });
        return true;
      } catch (err) {
        if ((err as { name?: string }).name === "TransactionNotFoundError") return false;
        throw err;
      }
    },
  };
}

/** Relay state in Upstash, keyed by chain and relayer address so testnet and any later mainnet copy never mix. */
export function sharedState(
  kv: Kv,
  chainId: number,
  relayer: string,
  pending: () => Promise<bigint>,
  ethPerHourWei: bigint,
  accountShareBps = 0n,
): RelayState {
  const p = `gos-relayer:${chainId}:${relayer.toLowerCase()}`;
  const local = freshState(pending, ethPerHourWei, accountShareBps);
  const split = splitBudget(ethPerHourWei, accountShareBps);
  return {
    ...local,
    rates: new SharedRateLimit(kv, `${p}:rate`, 30, 60_000),
    hourly: new SharedRateLimit(kv, `${p}:hourly`, 60, 3_600_000),
    ips: new SharedRateLimit(kv, `${p}:ip`, 60, 60_000),
    nonces: new SharedNonces(kv, `${p}:nonce`, pending),
    spend: new SharedSpend(kv, `${p}:spend`, split.play),
    used: new SharedUsedOrders(kv, `${p}:used`),
    revokes: new SharedRateLimit(kv, `${p}:revoke`, REVOKES_PER_HOUR, 3_600_000),
    ...(split.account > 0n ? { accountSpend: new SharedSpend(kv, `${p}:spend-account`, split.account) } : {}),
  };
}

/** Upstash state when its env is set. Otherwise memory with a warning, except a production mainnet config, which refuses to start. */
export function chooseState(
  env: NodeJS.ProcessEnv,
  chainId: number,
  relayer: string,
  pending: () => Promise<bigint>,
  ethPerHourWei: bigint,
  log: (message: string) => void = console.warn,
  accountShareBps = 0n,
): RelayState {
  const up = upstashEnv(env);
  if (up) return sharedState(upstashKv(up), chainId, relayer, pending, ethPerHourWei, accountShareBps);
  if (env.NODE_ENV === "production" && chainId !== TESTNET_CHAIN_ID) {
    throw new Error("shared state required: set KV_REST_API_URL and KV_REST_API_TOKEN");
  }
  log("WARNING relayer state is in memory only. Limits, ETH budget, nonces and used orders are per process. Set KV_REST_API_URL and KV_REST_API_TOKEN.");
  return freshState(pending, ethPerHourWei, accountShareBps);
}

export function createRuntime(cfg: RelayerConfig, env: NodeJS.ProcessEnv = process.env): HandleCtx {
  const account = privateKeyToAccount(cfg.key);
  const chain = defineChain({
    id: cfg.chainId,
    name: "Robinhood",
    nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
    rpcUrls: { default: { http: [cfg.rpcUrl] } },
  });
  const transport = http(cfg.rpcUrl, { retryCount: 0, timeout: 20_000 });
  const pub = createPublicClient({ chain, transport });
  const wallet = createWalletClient({ account, chain, transport });
  const secrets = [cfg.key, cfg.rpcUrl, cfg.healthcheckUrl];

  const io = chainSendIo(pub, wallet, account, cfg.chainId, cfg.stash);
  const deps: RelayDeps = {
    now: () => Date.now(),
    simulate: async (data, gasCap) => {
      try {
        await pub.call({ account: account.address, to: cfg.stash, data, gas: gasCap });
        return { ok: true };
      } catch (err) {
        return simulationFromError(err);
      }
    },
    send: (data, opts) =>
      sendCapped(
        io,
        cfg.maxFeeWei,
        data,
        opts,
      ),
    ethBalance: () => pub.getBalance({ address: account.address }),
    alert: async (message) => {
      console.error(`ALERT ${redact(message, secrets)}`);
      if (cfg.healthcheckUrl) await pingHealthcheck(cfg.healthcheckUrl);
    },
    priorityWei: cfg.priorityWei,
  };

  return {
    cfg,
    relayer: account.address,
    deps,
    state: chooseState(
      env,
      cfg.chainId,
      account.address,
      async () => BigInt(await pub.getTransactionCount({ address: account.address, blockTag: "pending" })),
      cfg.ethPerHourWei,
      console.warn,
      cfg.accountShareBps,
    ),
    sessionKey: (owner: Address) => readSessionKey(pub, cfg.stash, owner),
    stashBalance: (owner: Address) => pub.readContract({ address: cfg.stash, abi: stashAbi, functionName: "balance", args: [owner] }),
    ownerNonce: (owner: Address) => pub.readContract({ address: cfg.stash, abi: stashAbi, functionName: "nonces", args: [owner] }),
    wallet: {
      codeHash: async (address: Address) => {
        const code = await pub.getCode({ address });
        return code && code !== "0x" ? keccak256(code) : null;
      },
      isValid1271: async (address: Address, digest: Hex, signature: Hex) => {
        const { data } = await pub.call({
          to: address,
          gas: ERC1271_CHECK_GAS,
          data: encodeFunctionData({ abi: erc1271Abi, functionName: "isValidSignature", args: [digest, signature] }),
        });
        return typeof data === "string" && data.slice(0, 10).toLowerCase() === ERC1271_MAGIC;
      },
    },
  };
}

async function readSessionKey(
  pub: ReturnType<typeof createPublicClient>,
  stash: Address,
  owner: Address,
): Promise<Address> {
  // Only the key is needed. It is the first word on both the five value and the six value session(), so read
  // that word directly and stay compatible with a Stash deployed before per-session fees.
  const { data } = await pub.call({
    to: stash,
    data: encodeFunctionData({ abi: stashAbi, functionName: "session", args: [owner] }),
  });
  if (!data || data.length < 66) throw new Error("session unavailable");
  return getAddress(`0x${data.slice(26, 66)}`);
}
