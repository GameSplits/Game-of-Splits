// Parse a site payload into one signed Stash call. Chain and contract are checked first.

import { encodeFunctionData, getAddress, type Address, type Hex } from "viem";
import { stashAbi } from "./abi.ts";
import type { RelayerConfig } from "./config.ts";
import {
  recoverSigner,
  signatureBytes,
  typedDigest,
  type AuthorizeMessage,
  type LimitMessage,
  type RevokeMessage,
  type ShootMessage,
  type SignedAction,
  type TakeMessage,
  type WithdrawMessage,
} from "./eip712.ts";
import type { ShotRequest } from "./relay.ts";

export const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000";

export class HttpError extends Error {
  readonly status: number;

  constructor(status: number, message: string) {
    super(message);
    this.status = status;
  }
}

export interface ParsedAction {
  action: SignedAction;
  request: ShotRequest;
  /** Shoot and take are signed by the session key. The other four are signed by the owner. */
  session: boolean;
}

export function guardTarget(cfg: { chainId: number; stash: Address }, chainId: number, stash: string): void {
  if (chainId !== cfg.chainId) throw new HttpError(400, "wrong chain");
  if (!/^0x[0-9a-fA-F]{40}$/.test(stash) || stash.toLowerCase() !== cfg.stash.toLowerCase()) {
    throw new HttpError(400, "wrong stash");
  }
}

function asAddress(value: unknown): Address {
  if (typeof value !== "string" || !/^0x[0-9a-fA-F]{40}$/.test(value)) throw new HttpError(400, "bad request");
  return getAddress(value.toLowerCase());
}

function asSignature(value: unknown): Hex {
  if (typeof value !== "string" || !/^0x[0-9a-fA-F]+$/.test(value) || value.length < 10 || value.length % 2 !== 0) {
    throw new HttpError(400, "bad request");
  }
  return value as Hex;
}

function uint(value: unknown): bigint {
  if (typeof value === "string" && /^[0-9]+$/.test(value)) return BigInt(value);
  if (typeof value === "bigint" && value >= 0n) return value;
  if (typeof value === "number" && Number.isSafeInteger(value) && value >= 0) return BigInt(value);
  throw new HttpError(400, "bad request");
}

function small(value: unknown): number {
  const n = uint(value);
  if (n > 255n) throw new HttpError(400, "bad request");
  return Number(n);
}

function chainField(value: unknown): number {
  if (typeof value === "number" && Number.isInteger(value)) return value;
  if (typeof value === "string" && /^[0-9]+$/.test(value)) return Number(value);
  return Number.NaN;
}

function orderOf(body: Record<string, unknown>): Record<string, unknown> {
  if (!body.order || typeof body.order !== "object") throw new HttpError(400, "bad request");
  return body.order as Record<string, unknown>;
}

function encode(action: SignedAction): Hex {
  switch (action.kind) {
    case "shoot":
      return encodeFunctionData({ abi: stashAbi, functionName: "shoot", args: [action.message, action.signature] });
    case "take":
      return encodeFunctionData({ abi: stashAbi, functionName: "take", args: [action.message, action.signature] });
    case "withdraw":
      return encodeFunctionData({ abi: stashAbi, functionName: "withdraw", args: [action.message, action.signature] });
    case "authorize-key":
      return encodeFunctionData({
        abi: stashAbi,
        functionName: "authorizeKey",
        args: [action.message, action.signature],
      });
    case "set-limit":
      return encodeFunctionData({ abi: stashAbi, functionName: "setLimit", args: [action.message, action.signature] });
    case "revoke-key":
      return encodeFunctionData({ abi: stashAbi, functionName: "revokeKey", args: [action.message, action.signature] });
  }
}

export function parseAction(kind: SignedAction["kind"], raw: string, cfg: RelayerConfig): ParsedAction {
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    throw new HttpError(400, "bad request");
  }
  if (!parsed || typeof parsed !== "object") throw new HttpError(400, "bad request");
  const body = parsed as Record<string, unknown>;
  guardTarget(cfg, chainField(body.chainId), typeof body.stash === "string" ? body.stash : "");
  const row = orderOf(body);
  const signature = asSignature(body.signature);
  const owner = asAddress(row.owner);
  const replaces = body.replaces === true && (kind === "shoot" || kind === "take");

  let action: SignedAction;
  let maxPrice = 0n;
  if (kind === "shoot") {
    const message: ShootMessage = {
      owner,
      maxPrice: uint(row.maxPrice),
      expectedRound: uint(row.expectedRound),
      nonce: uint(row.nonce),
      deadline: uint(row.deadline),
      epoch: uint(row.epoch),
    };
    maxPrice = message.maxPrice;
    action = { kind, message, signature };
  } else if (kind === "take") {
    const message: TakeMessage = {
      owner,
      maxPrice: uint(row.maxPrice),
      presetId: small(row.presetId),
      color: small(row.color),
      nonce: uint(row.nonce),
      deadline: uint(row.deadline),
      epoch: uint(row.epoch),
    };
    maxPrice = message.maxPrice;
    action = { kind, message, signature };
  } else if (kind === "withdraw") {
    const message: WithdrawMessage = {
      owner,
      amount: uint(row.amount),
      nonce: uint(row.nonce),
      deadline: uint(row.deadline),
    };
    action = { kind, message, signature };
  } else if (kind === "authorize-key") {
    const message: AuthorizeMessage = {
      owner,
      key: asAddress(row.key),
      limit: uint(row.limit),
      expiry: uint(row.expiry),
      nonce: uint(row.nonce),
      deadline: uint(row.deadline),
    };
    action = { kind, message, signature };
  } else if (kind === "set-limit") {
    const message: LimitMessage = {
      owner,
      newLimit: uint(row.newLimit),
      nonce: uint(row.nonce),
      deadline: uint(row.deadline),
    };
    action = { kind, message, signature };
  } else {
    const message: RevokeMessage = {
      owner,
      nonce: uint(row.nonce),
      deadline: uint(row.deadline),
    };
    action = { kind, message, signature };
  }

  return {
    action,
    session: kind === "shoot" || kind === "take",
    request: {
      owner,
      maxPrice,
      replaces,
      calldata: encode(action),
      gasCap: kind === "shoot" || kind === "take" ? cfg.gasCapPlay : cfg.gasCapAccount,
    },
  };
}

/** Chain reads for an allowlisted ERC-1271 wallet. Both are bounded by the runtime. */
export interface WalletReader {
  codeHash(address: Address): Promise<Hex | null>;
  isValid1271(address: Address, digest: Hex, signature: Hex): Promise<boolean>;
}

/**
 * Every signature is checked before anything is simulated or counted.
 * A 65-byte signature must recover to `expected` over this relayer's domain.
 * Any other length is refused unless `expected` is a contract whose code hash is in ERC1271_CODEHASHES
 * and its isValidSignature accepts the digest within a fixed gas allowance.
 */
export async function assertSignature(
  cfg: RelayerConfig,
  action: SignedAction,
  expected: Address,
  wallet?: WalletReader,
): Promise<void> {
  if (signatureBytes(action.signature) !== 65) {
    if (cfg.erc1271CodeHashes.size === 0 || !wallet) throw new HttpError(400, "bad signature");
    let ok = false;
    try {
      const hash = await wallet.codeHash(expected);
      ok =
        hash !== null &&
        cfg.erc1271CodeHashes.has(hash.toLowerCase()) &&
        (await wallet.isValid1271(expected, typedDigest(cfg.chainId, cfg.stash, action), action.signature));
    } catch {
      ok = false;
    }
    if (!ok) throw new HttpError(400, "bad signature");
    return;
  }
  let recovered: Address;
  try {
    recovered = await recoverSigner(cfg.chainId, cfg.stash, action);
  } catch {
    throw new HttpError(400, "bad signature");
  }
  if (recovered.toLowerCase() !== expected.toLowerCase()) throw new HttpError(400, "bad signature");
}
