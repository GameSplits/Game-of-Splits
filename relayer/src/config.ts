// Relayer configuration. The signing key is read from the environment only.

import { getAddress, type Address, type Hex } from "viem";

const KEY = /^0x[0-9a-fA-F]{64}$/;

export const TESTNET_CHAIN_ID = 46630;
export const MAINNET_CHAIN_ID = 4663;
export const TESTNET_STASH = getAddress("0x79bf9F0B9d527b38fdD8Bcca4DD5b948290a1AE3");
/** Stash on Robinhood Chain mainnet 4663, from contracts/deployments/4663.json. */
export const MAINNET_STASH: Address | null = getAddress("0x46d56Ecf2fF7C3c32be968412584B6177461b3BD");
/** Public address of the testnet relayer. The key stays in RELAYER_KEY. */
export const RELAYER_ADDRESS = getAddress("0x58941E09432D2EF6316FA3b99476e69e68933c94");

/** Everything that differs between chains. A chain id that is not a key here is refused. */
export interface ChainProfile {
  chainId: number;
  label: string;
  /** The only Stash the relayer will send to on this chain. Null means not deployed yet, so loading fails. */
  stash: Address | null;
  /** Exact browser origins used when ALLOWED_ORIGINS and ALLOW_ORIGIN are unset. */
  defaultOrigins: string;
  /** Whether a Vercel preview pattern may be loaded. */
  previewPattern: boolean;
}

export type ChainTable = Readonly<Record<number, ChainProfile>>;

export const CHAINS: ChainTable = Object.freeze({
  [TESTNET_CHAIN_ID]: Object.freeze({
    chainId: TESTNET_CHAIN_ID,
    label: "testnet",
    stash: TESTNET_STASH,
    defaultOrigins: "https://testnet.gameofsplits.fun,https://gos-testnet.vercel.app",
    previewPattern: true,
  }),
  [MAINNET_CHAIN_ID]: Object.freeze({
    chainId: MAINNET_CHAIN_ID,
    label: "mainnet",
    stash: MAINNET_STASH,
    defaultOrigins: "https://gameofsplits.fun,https://www.gameofsplits.fun",
    previewPattern: false,
  }),
});

/** CHAIN_ID is required and must name a chain in the table. There is no default chain. */
export function chainProfile(raw: string | undefined, chains: ChainTable = CHAINS): ChainProfile {
  const text = (raw ?? "").trim();
  const id = /^[0-9]{1,10}$/.test(text) ? Number(text) : NaN;
  const profile = Object.prototype.hasOwnProperty.call(chains, id) ? chains[id] : undefined;
  if (!profile) throw new Error(`CHAIN_ID must be one of ${Object.keys(chains).join(" or ")}`);
  return profile;
}

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
export function loadConfig(env: NodeJS.ProcessEnv, chains: ChainTable = CHAINS): RelayerConfig {
  const key = env.RELAYER_KEY ?? "";
  if (!KEY.test(key)) throw new Error("missing or invalid env RELAYER_KEY");
  const profile = chainProfile(need(env, "CHAIN_ID"), chains);
  if (profile.stash === null) {
    throw new Error(`STASH for ${profile.chainId} is not pinned in config.ts yet`);
  }
  let stash: Address;
  try {
    stash = getAddress(need(env, "STASH"));
  } catch {
    throw new Error("env STASH is not an address");
  }
  if (stash.toLowerCase() !== profile.stash.toLowerCase()) {
    throw new Error(`STASH must be the ${profile.chainId} deployment`);
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
    chainId: profile.chainId,
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

/** Testnet default origins. Each chain has its own default in CHAINS. */
export const DEFAULT_ALLOW_ORIGIN = CHAINS[TESTNET_CHAIN_ID]!.defaultOrigins;
/**
 * Preview URLs for our gos-testnet and gos-staging projects on the game-of-splits team only.
 * Used on testnet (46630). Mainnet (4663) never loads a preview pattern: use the exact list (gameofsplits.fun and www).
 */
export const DEFAULT_ALLOW_ORIGIN_PATTERN =
  "^https://gos-(testnet|staging)-[a-z0-9-]+-game-of-splits\\.vercel\\.app$";

/**
 * Exact origins from `ALLOWED_ORIGINS` or `ALLOW_ORIGIN` (comma-separated), else the chain's default.
 * Optional `ALLOW_ORIGIN_PATTERN` is one anchored regex for Vercel previews and is testnet-only
 * (never loaded on 4663, and off when the value is "off"). Signatures still protect every action.
 * CHAIN_ID (or `chainId`) must name a known chain, so a missing or unknown chain fails closed.
 */
export function loadOrigins(env: NodeJS.ProcessEnv, chainId?: number, chains: ChainTable = CHAINS): OriginPolicy {
  const profile = chainProfile(chainId === undefined ? env.CHAIN_ID : String(chainId), chains);
  const listRaw = (env.ALLOWED_ORIGINS ?? env.ALLOW_ORIGIN ?? "").trim() || profile.defaultOrigins;
  const exact = listRaw
    .split(",")
    .map((s) => s.trim().replace(/\/+$/, ""))
    .filter((s) => s.length > 0);
  for (const origin of exact) {
    if (origin === "*" || !/^https?:\/\/[^/\s]+$/.test(origin)) {
      throw new Error("ALLOW_ORIGIN must list exact http(s) origins");
    }
  }
  const patRaw = (env.ALLOW_ORIGIN_PATTERN ?? "").trim();
  let pattern: RegExp | null = null;
  // Mainnet and an explicit off use the exact list only. A stranger's Vercel project cannot match the default.
  if (profile.previewPattern && patRaw !== "off") {
    const raw = patRaw || DEFAULT_ALLOW_ORIGIN_PATTERN;
    if (!raw.startsWith("^") || !raw.endsWith("$")) {
      throw new Error("ALLOW_ORIGIN_PATTERN must be anchored with ^ and $");
    }
    if (!raw.includes("game-of-splits")) {
      throw new Error("ALLOW_ORIGIN_PATTERN must name the game-of-splits team");
    }
    pattern = new RegExp(raw);
  }
  return { exact, pattern };
}

export function isAllowedOrigin(origin: string, policy: OriginPolicy): boolean {
  if (origin.length > 200) return false;
  if (policy.exact.includes(origin)) return true;
  return policy.pattern !== null && policy.pattern.test(origin);
}
