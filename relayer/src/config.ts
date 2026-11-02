// Relayer configuration. The signing key is read from the environment only.

import { getAddress, type Address, type Hex } from "viem";

const KEY = /^0x[0-9a-fA-F]{64}$/;

export const TESTNET_CHAIN_ID = 46630;
export const TESTNET_STASH = getAddress("0x904aA57AC6ee0f4c402b3abc1c3c5A599078660c");
/** Public address of the testnet relayer. The key stays in RELAYER_KEY. */
export const RELAYER_ADDRESS = getAddress("0x58941E09432D2EF6316FA3b99476e69e68933c94");

export interface RelayerConfig {
  key: Hex;
  rpcUrl: string;
  chainId: number;
  stash: Address;
  priorityWei: bigint;
  port: number;
  healthcheckUrl: string;
}

export function redact(text: string, secrets: readonly string[]): string {
  let out = text;
  for (const secret of secrets) {
    if (secret.length > 0) out = out.split(secret).join("[redacted]");
  }
  return out;
}

function need(env: NodeJS.ProcessEnv, name: string): string {
  const value = env[name];
  if (value === undefined || value === "") throw new Error(`missing env ${name}`);
  return value;
}

/** Read the signing key from `RELAYER_KEY` only. The value is never copied into the error text. */
export function loadConfig(env: NodeJS.ProcessEnv): RelayerConfig {
  const key = env.RELAYER_KEY ?? "";
  if (!KEY.test(key)) throw new Error("missing or invalid env RELAYER_KEY");
  const chainRaw = need(env, "CHAIN_ID");
  if (!/^[0-9]+$/.test(chainRaw) || Number(chainRaw) !== TESTNET_CHAIN_ID) {
    throw new Error("CHAIN_ID must be 46630");
  }
  let stash: Address;
  try {
    stash = getAddress(need(env, "STASH"));
  } catch {
    throw new Error("env STASH is not an address");
  }
  if (stash.toLowerCase() !== TESTNET_STASH.toLowerCase()) {
    throw new Error("STASH must be the 46630 deployment");
  }
  const gwei = Number(env.PRIORITY_GWEI || "0.02");
  if (!Number.isFinite(gwei) || gwei <= 0) throw new Error("PRIORITY_GWEI must be a positive number");
  const port = Number(env.PORT || "8787");
  if (!Number.isInteger(port) || port <= 0 || port > 65535) throw new Error("PORT must be a valid port");
  const healthcheckUrl = (env.HEALTHCHECK_URL ?? "").trim();
  if (healthcheckUrl && !/^https?:\/\/\S+$/.test(healthcheckUrl)) {
    throw new Error("HEALTHCHECK_URL must be an http(s) URL");
  }
  return {
    key: key as Hex,
    rpcUrl: need(env, "RPC_URL"),
    chainId: TESTNET_CHAIN_ID,
    stash,
    priorityWei: BigInt(Math.round(gwei * 1e9)),
    port,
    healthcheckUrl,
  };
}
