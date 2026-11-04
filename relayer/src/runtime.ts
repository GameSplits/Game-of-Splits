// Chain clients. The signing key is used to send and is never logged.

import { createPublicClient, createWalletClient, defineChain, getAddress, http, type Address } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { stashAbi } from "./abi.ts";
import { redact, type RelayerConfig } from "./config.ts";
import { decodeRevert, extractRevertData } from "./decode.ts";
import type { HandleCtx } from "./http.ts";
import { pingHealthcheck } from "./ping.ts";
import { GasCapError } from "./policy.ts";
import { freshState, type RelayDeps } from "./relay.ts";
import type { Sim } from "./policy.ts";

export function simulationFromError(err: unknown): Sim {
  const data = extractRevertData(err);
  return data ? decodeRevert(data) : { ok: false, kind: "other", reason: "simulation failed" };
}

export function createRuntime(cfg: RelayerConfig): HandleCtx {
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

  const deps: RelayDeps = {
    now: () => Date.now(),
    simulate: async (data) => {
      try {
        await pub.call({ account: account.address, to: cfg.stash, data });
        return { ok: true };
      } catch (err) {
        return simulationFromError(err);
      }
    },
    send: async (data, opts) => {
      const block = await pub.getBlock();
      const base = block.baseFeePerGas ?? 0n;
      if (base + opts.priorityWei > cfg.maxFeeWei) throw new GasCapError();
      const gas = await pub.estimateGas({ account: account.address, to: cfg.stash, data });
      return wallet.sendTransaction({
        account,
        chain,
        to: cfg.stash,
        data,
        value: 0n,
        nonce: Number(opts.nonce),
        gas: (gas * 12n) / 10n,
        maxFeePerGas: base + opts.priorityWei,
        maxPriorityFeePerGas: opts.priorityWei,
      });
    },
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
    state: freshState(async () => BigInt(await pub.getTransactionCount({ address: account.address, blockTag: "pending" }))),
    sessionKey: (owner: Address) => readSessionKey(pub, cfg.stash, owner),
    stashBalance: (owner: Address) => pub.readContract({ address: cfg.stash, abi: stashAbi, functionName: "balance", args: [owner] }),
  };
}

async function readSessionKey(
  pub: ReturnType<typeof createPublicClient>,
  stash: Address,
  owner: Address,
): Promise<Address> {
  const session = await pub.readContract({
    address: stash,
    abi: stashAbi,
    functionName: "session",
    args: [owner],
  });
  return getAddress(session[0]);
}
