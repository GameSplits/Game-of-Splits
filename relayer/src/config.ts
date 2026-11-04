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
  maxFeeWei: bigint;
  /** The Stash withdrawal fee in USDG units (6 decimals). A relayed withdraw must be above it. */
  withdrawFee: bigint;
  port: number;
  healthcheckUrl: string;
  /** Gas cap for a relayed shoot or take. */
  gasCapPlay: bigint;
  /** Gas cap for a relayed withdraw, authorize, set limit or revoke. */
  gasCapAccount: bigint;
  /** ETH, in wei, the relayer may commit to sends in any rolling hour. Relaying pauses above it. */
  ethPerHourWei: bigint;
  /** Lowercase code hashes of ERC-1271 wallets whose non-65-byte signatures are checked. Empty means none are accepted. */
  erc1271CodeHashes: ReadonlySet<string>;
  /** Least Stash balance, in USDG units (6 decimals), for a relayed authorize or set limit. A revoke is gated in http.ts. */
  accountMinBalance: bigint;
  /** Share of the hourly ETH budget, in basis points, kept for account actions. Plays get the rest, so account actions never pause plays. */
  accountShareBps: bigint;
}

/** Highest relayed shoot or take on testnet 46630 used 557,499 gas, and the highest take 489,172. */
export const DEFAULT_GAS_CAP_PLAY = 900_000n;
/** Highest relayed withdraw, authorizeKey or revokeKey on testnet 46630 used 79,548 gas. The Stash unit tests peak at 107,509 (authorizeKey) and 52,361 (setLimit). */
export const DEFAULT_GAS_CAP_ACCOUNT = 250_000n;
export const DEFAULT_ETH_PER_HOUR = "0.02";
/** 1 USDG. */
export const DEFAULT_ACCOUNT_MIN_BALANCE = 1_000_000n;
export const DEFAULT_ACCOUNT_SHARE = "0.25";

function accountShare(raw: string): bigint {
  if (!/^0?\.[0-9]{1,4}$/.test(raw)) throw new Error("RELAY_ACCOUNT_BUDGET_SHARE must be a fraction between 0 and 1");
  const bps = BigInt((raw.split(".")[1] + "0000").slice(0, 4));
  if (bps <= 0n || bps >= 10_000n) throw new Error("RELAY_ACCOUNT_BUDGET_SHARE must be a fraction between 0 and 1");
  return bps;
}
/** Gas allowed for one off-chain ERC-1271 check of an allowlisted wallet. */
export const ERC1271_CHECK_GAS = 100_000n;

function gasCap(env: NodeJS.ProcessEnv, name: string, fallback: bigint): bigint {
  const raw = (env[name] ?? "").trim();
  if (!raw) return fallback;
  if (!/^[0-9]+$/.test(raw)) throw new Error(`${name} must be whole gas units`);
  const value = BigInt(raw);
  if (value < 50_000n || value > 5_000_000n) throw new Error(`${name} must be between 50000 and 5000000`);
  return value;
}

function ethToWei(raw: string, name: string): bigint {
  if (!/^[0-9]+(\.[0-9]{1,18})?$/.test(raw)) throw new Error(`${name} must be a positive ETH amount`);
  const [whole, frac = ""] = raw.split(".");
  const wei = BigInt(whole ?? "0") * 10n ** 18n + BigInt((frac + "0".repeat(18)).slice(0, 18));
  if (wei <= 0n) throw new Error(`${name} must be a positive ETH amount`);
  return wei;
}

function codeHashes(raw: string): ReadonlySet<string> {
  const list = raw
    .split(",")
    .map((s) => s.trim().toLowerCase())
    .filter((s) => s.length > 0);
  for (const hash of list) {
    if (!/^0x[0-9a-f]{64}$/.test(hash)) throw new Error("ERC1271_CODEHASHES must list 32-byte hex code hashes");
  }
  return new Set(list);
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

function minBalance(raw: string): bigint {
  if (!raw) return DEFAULT_ACCOUNT_MIN_BALANCE;
  if (!/^[0-9]+$/.test(raw)) throw new Error("RELAY_ACCOUNT_MIN_BALANCE must be whole USDG units");
  return BigInt(raw);
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
  const capGwei = Number(env.MAX_FEE_GWEI || "0.5");
  if (!Number.isFinite(capGwei) || capGwei <= 0) throw new Error("MAX_FEE_GWEI must be a positive number");
  const maxFeeWei = BigInt(Math.round(capGwei * 1e9));
  if (maxFeeWei <= BigInt(Math.round(gwei * 1e9)) * 2n) throw new Error("MAX_FEE_GWEI must be above twice PRIORITY_GWEI");
  const feeRaw = (env.WITHDRAW_FEE ?? "").trim() || "1000000";
  if (!/^[0-9]+$/.test(feeRaw)) throw new Error("WITHDRAW_FEE must be whole USDG units");
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
    maxFeeWei,
    withdrawFee: BigInt(feeRaw),
    port,
    healthcheckUrl,
    gasCapPlay: gasCap(env, "RELAY_GAS_CAP_PLAY", DEFAULT_GAS_CAP_PLAY),
    gasCapAccount: gasCap(env, "RELAY_GAS_CAP_ACCOUNT", DEFAULT_GAS_CAP_ACCOUNT),
    ethPerHourWei: ethToWei((env.RELAY_ETH_PER_HOUR ?? "").trim() || DEFAULT_ETH_PER_HOUR, "RELAY_ETH_PER_HOUR"),
    erc1271CodeHashes: codeHashes(env.ERC1271_CODEHASHES ?? ""),
    accountMinBalance: minBalance((env.RELAY_ACCOUNT_MIN_BALANCE ?? "").trim()),
    accountShareBps: accountShare((env.RELAY_ACCOUNT_BUDGET_SHARE ?? "").trim() || DEFAULT_ACCOUNT_SHARE),
  };
}

/** Browser origins the relayer answers with CORS. Signatures are what protect the funds; this only stops other sites using it from a browser. */
export interface OriginPolicy {
  exact: readonly string[];
  pattern: RegExp | null;
}

export const DEFAULT_ALLOW_ORIGIN = "https://testnet.gameofsplits.fun,https://gos-testnet.vercel.app";
/** Vercel preview URLs for the gos-testnet and gos-staging projects on the game-of-splits team. */
export const DEFAULT_ALLOW_ORIGIN_PATTERN = "^https://gos-(testnet|staging)-[a-z0-9-]+-game-of-splits\\.vercel\\.app$";

/** `ALLOW_ORIGIN` is a comma-separated list of exact origins. `ALLOW_ORIGIN_PATTERN` is one regex for preview URLs; set it to "off" to allow exact origins only. */
export function loadOrigins(env: NodeJS.ProcessEnv): OriginPolicy {
  const listRaw = (env.ALLOW_ORIGIN ?? "").trim() || DEFAULT_ALLOW_ORIGIN;
  const exact = listRaw
    .split(",")
    .map((s) => s.trim().replace(/\/+$/, ""))
    .filter((s) => s.length > 0);
  for (const origin of exact) {
    if (origin === "*" || !/^https?:\/\/[^/\s]+$/.test(origin)) throw new Error("ALLOW_ORIGIN must list exact http(s) origins");
  }
  const patRaw = (env.ALLOW_ORIGIN_PATTERN ?? "").trim() || DEFAULT_ALLOW_ORIGIN_PATTERN;
  let pattern: RegExp | null = null;
  if (patRaw !== "off") {
    if (!patRaw.startsWith("^") || !patRaw.endsWith("$")) throw new Error("ALLOW_ORIGIN_PATTERN must be anchored with ^ and $");
    pattern = new RegExp(patRaw);
  }
  return { exact, pattern };
}

export function isAllowedOrigin(origin: string, policy: OriginPolicy): boolean {
  if (origin.length > 200) return false;
  if (policy.exact.includes(origin)) return true;
  return policy.pattern !== null && policy.pattern.test(origin);
}
