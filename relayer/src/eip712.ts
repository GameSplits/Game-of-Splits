// EIP-712 domain for Stash ("Stash", "1"). Field order matches the contract type strings.

import { recoverTypedDataAddress, type Address, type Hex } from "viem";

export const DOMAIN_NAME = "Stash";
export const DOMAIN_VERSION = "1";

export function stashDomain(chainId: number, stash: Address) {
  return {
    name: DOMAIN_NAME,
    version: DOMAIN_VERSION,
    chainId,
    verifyingContract: stash,
  } as const;
}

export const shootTypes = {
  Shoot: [
    { name: "owner", type: "address" },
    { name: "maxPrice", type: "uint256" },
    { name: "expectedRound", type: "uint256" },
    { name: "nonce", type: "uint256" },
    { name: "deadline", type: "uint256" },
    { name: "epoch", type: "uint256" },
  ],
} as const;

export const takeTypes = {
  Take: [
    { name: "owner", type: "address" },
    { name: "maxPrice", type: "uint256" },
    { name: "presetId", type: "uint8" },
    { name: "color", type: "uint8" },
    { name: "nonce", type: "uint256" },
    { name: "deadline", type: "uint256" },
    { name: "epoch", type: "uint256" },
  ],
} as const;

export const withdrawTypes = {
  Withdraw: [
    { name: "owner", type: "address" },
    { name: "amount", type: "uint256" },
    { name: "nonce", type: "uint256" },
    { name: "deadline", type: "uint256" },
  ],
} as const;

export const authorizeTypes = {
  AuthorizeKey: [
    { name: "owner", type: "address" },
    { name: "key", type: "address" },
    { name: "limit", type: "uint256" },
    { name: "expiry", type: "uint256" },
    { name: "nonce", type: "uint256" },
    { name: "deadline", type: "uint256" },
  ],
} as const;

export const limitTypes = {
  SetLimit: [
    { name: "owner", type: "address" },
    { name: "newLimit", type: "uint256" },
    { name: "nonce", type: "uint256" },
    { name: "deadline", type: "uint256" },
  ],
} as const;

export const revokeTypes = {
  RevokeKey: [
    { name: "owner", type: "address" },
    { name: "nonce", type: "uint256" },
    { name: "deadline", type: "uint256" },
  ],
} as const;

export interface ShootMessage {
  owner: Address;
  maxPrice: bigint;
  expectedRound: bigint;
  nonce: bigint;
  deadline: bigint;
  epoch: bigint;
}

export interface TakeMessage {
  owner: Address;
  maxPrice: bigint;
  presetId: number;
  color: number;
  nonce: bigint;
  deadline: bigint;
  epoch: bigint;
}

export interface WithdrawMessage {
  owner: Address;
  amount: bigint;
  nonce: bigint;
  deadline: bigint;
}

export interface AuthorizeMessage {
  owner: Address;
  key: Address;
  limit: bigint;
  expiry: bigint;
  nonce: bigint;
  deadline: bigint;
}

export interface LimitMessage {
  owner: Address;
  newLimit: bigint;
  nonce: bigint;
  deadline: bigint;
}

export interface RevokeMessage {
  owner: Address;
  nonce: bigint;
  deadline: bigint;
}

export type SignedAction =
  | { kind: "shoot"; message: ShootMessage; signature: Hex }
  | { kind: "take"; message: TakeMessage; signature: Hex }
  | { kind: "withdraw"; message: WithdrawMessage; signature: Hex }
  | { kind: "authorize-key"; message: AuthorizeMessage; signature: Hex }
  | { kind: "set-limit"; message: LimitMessage; signature: Hex }
  | { kind: "revoke-key"; message: RevokeMessage; signature: Hex };

export function signatureBytes(signature: string): number {
  if (!signature.startsWith("0x")) return 0;
  return (signature.length - 2) / 2;
}

/** Recover the ECDSA signer of a 65-byte Stash signature over the given chain and contract. */
export async function recoverSigner(chainId: number, stash: Address, action: SignedAction): Promise<Address> {
  const domain = stashDomain(chainId, stash);
  switch (action.kind) {
    case "shoot":
      return recoverTypedDataAddress({
        domain,
        types: shootTypes,
        primaryType: "Shoot",
        message: action.message,
        signature: action.signature,
      });
    case "take":
      return recoverTypedDataAddress({
        domain,
        types: takeTypes,
        primaryType: "Take",
        message: action.message,
        signature: action.signature,
      });
    case "withdraw":
      return recoverTypedDataAddress({
        domain,
        types: withdrawTypes,
        primaryType: "Withdraw",
        message: action.message,
        signature: action.signature,
      });
    case "authorize-key":
      return recoverTypedDataAddress({
        domain,
        types: authorizeTypes,
        primaryType: "AuthorizeKey",
        message: action.message,
        signature: action.signature,
      });
    case "set-limit":
      return recoverTypedDataAddress({
        domain,
        types: limitTypes,
        primaryType: "SetLimit",
        message: action.message,
        signature: action.signature,
      });
    case "revoke-key":
      return recoverTypedDataAddress({
        domain,
        types: revokeTypes,
        primaryType: "RevokeKey",
        message: action.message,
        signature: action.signature,
      });
  }
}
