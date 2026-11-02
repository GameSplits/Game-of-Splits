// Relayer configuration. The signing key is read from the environment only.

const KEY = /^0x[0-9a-fA-F]{64}$/;
const ADDR = /^0x[0-9a-fA-F]{40}$/;

export interface RelayerConfig {
  key: `0x${string}`;
  rpcUrl: string;
  chainId: number;
  stash: `0x${string}`;
  arrow: `0x${string}`;
  seat: `0x${string}`;
  priorityWei: bigint;
  port: number;
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

function address(env: NodeJS.ProcessEnv, name: string): `0x${string}` {
  const value = need(env, name);
  if (!ADDR.test(value)) throw new Error(`env ${name} is not an address`);
  return value as `0x${string}`;
}

/** Read the signing key from `RELAYER_KEY` only. The value is never copied into the error text. */
export function loadConfig(env: NodeJS.ProcessEnv): RelayerConfig {
  const key = env.RELAYER_KEY ?? "";
  if (!KEY.test(key)) throw new Error("missing or invalid env RELAYER_KEY");
  const chainId = Number(need(env, "CHAIN_ID"));
  if (!Number.isInteger(chainId) || chainId <= 0) throw new Error("CHAIN_ID must be a positive integer");
  const gwei = Number(env.PRIORITY_GWEI || "0.02");
  if (!Number.isFinite(gwei) || gwei <= 0) throw new Error("PRIORITY_GWEI must be a positive number");
  const port = Number(env.PORT || "8787");
  if (!Number.isInteger(port) || port <= 0 || port > 65535) throw new Error("PORT must be a valid port");
  return {
    key: key as `0x${string}`,
    rpcUrl: need(env, "RPC_URL"),
    chainId,
    stash: address(env, "STASH"),
    arrow: address(env, "ARROW"),
    seat: address(env, "SEAT"),
    priorityWei: BigInt(Math.round(gwei * 1e9)),
    port,
  };
}

export const LOW_BALANCE_WEI = 5_000_000_000_000_000n;
