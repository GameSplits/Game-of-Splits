// Pull a revert payload into a simulation result the relay policy can read.

import { decodeErrorResult, type Hex } from "viem";
import type { Sim } from "./policy.ts";

export const gameErrors = [
  {
    type: "error",
    name: "PriceAboveMax",
    inputs: [
      { name: "price", type: "uint256" },
      { name: "maxPrice", type: "uint256" },
    ],
  },
  {
    type: "error",
    name: "WrongRound",
    inputs: [
      { name: "expected", type: "uint256" },
      { name: "actual", type: "uint256" },
    ],
  },
  {
    type: "error",
    name: "InvalidAccountNonce",
    inputs: [
      { name: "account", type: "address" },
      { name: "currentNonce", type: "uint256" },
    ],
  },
  { type: "error", name: "BadSignature", inputs: [] },
  { type: "error", name: "DeadlineExpired", inputs: [] },
  { type: "error", name: "KeyMissing", inputs: [] },
  { type: "error", name: "KeyExpired", inputs: [] },
  { type: "error", name: "StaleEpoch", inputs: [] },
  { type: "error", name: "OverLimit", inputs: [] },
  { type: "error", name: "InsufficientBalance", inputs: [] },
  { type: "error", name: "ZeroAmount", inputs: [] },
  { type: "error", name: "BadPreset", inputs: [] },
  { type: "error", name: "AmountNotAboveFee", inputs: [] },
  { type: "error", name: "BalanceAtOrBelowFee", inputs: [] },
  { type: "error", name: "ExpiryNotFuture", inputs: [] },
  { type: "error", name: "ExpiryTooFar", inputs: [] },
  { type: "error", name: "LimitBelowSpent", inputs: [] },
  { type: "error", name: "QuoteFailed", inputs: [] },
  { type: "error", name: "NoPass", inputs: [] },
  { type: "error", name: "BackToBack", inputs: [] },
  { type: "error", name: "SameBlock", inputs: [] },
  { type: "error", name: "AlreadyHolder", inputs: [] },
  { type: "error", name: "Paused", inputs: [] },
  { type: "error", name: "NoActiveFair", inputs: [] },
  { type: "error", name: "BadColor", inputs: [] },
  { type: "error", name: "ChapterEndingSoon", inputs: [] },
  { type: "error", name: "TooManyEntries", inputs: [] },
] as const;

const errorString = [
  { type: "error", name: "Error", inputs: [{ name: "message", type: "string" }] },
] as const;

const reasons: Record<string, string> = {
  InvalidAccountNonce: "bad nonce",
  BadSignature: "bad signature",
  DeadlineExpired: "deadline expired",
  KeyMissing: "key missing",
  KeyExpired: "key expired",
  StaleEpoch: "stale epoch",
  OverLimit: "over limit",
  InsufficientBalance: "insufficient balance",
  ZeroAmount: "zero amount",
  BadPreset: "bad preset",
  AmountNotAboveFee: "amount not above fee",
  BalanceAtOrBelowFee: "balance at or below the withdrawal fee",
  ExpiryNotFuture: "expiry not in the future",
  ExpiryTooFar: "expiry too far",
  LimitBelowSpent: "limit below spent",
  QuoteFailed: "quote failed",
  NoPass: "no pass",
  BackToBack: "back to back",
  SameBlock: "same block",
  AlreadyHolder: "already holder",
  Paused: "sales paused",
  NoActiveFair: "no active fair",
  BadColor: "bad color",
  ChapterEndingSoon: "A new round can't start in the last hour of a chapter",
  TooManyEntries: "This wallet already has 3 outlaws in this round",
};

function hexData(value: unknown): Hex | null {
  if (typeof value === "string" && /^0x[0-9a-fA-F]{8,}$/.test(value)) return value as Hex;
  if (value && typeof value === "object") {
    const nested = (value as { data?: unknown }).data;
    if (typeof nested === "string" && /^0x[0-9a-fA-F]{8,}$/.test(nested)) return nested as Hex;
  }
  return null;
}

export function extractRevertData(err: unknown): Hex | null {
  const seen = new Set<unknown>();
  const stack: unknown[] = [err];
  while (stack.length > 0) {
    const cur = stack.pop();
    if (!cur || (typeof cur !== "object" && typeof cur !== "function") || seen.has(cur)) continue;
    seen.add(cur);
    const rec = cur as Record<string, unknown>;
    for (const key of ["data", "raw", "result"]) {
      const found = hexData(rec[key]);
      if (found) return found;
    }
    if (rec.cause) stack.push(rec.cause);
  }
  return null;
}

function safeText(message: string): string | null {
  if (message.length === 0 || message.length > 80) return null;
  if (!/^[A-Za-z0-9 ._-]+$/.test(message)) return null;
  return message;
}

export function decodeRevert(data: Hex): Sim {
  try {
    const decoded = decodeErrorResult({ abi: gameErrors, data });
    if (decoded.errorName === "PriceAboveMax") {
      const [price, maxPrice] = decoded.args as readonly [bigint, bigint];
      return { ok: false, kind: "price", price, maxPrice };
    }
    if (decoded.errorName === "WrongRound") {
      const [expected, actual] = decoded.args as readonly [bigint, bigint];
      return { ok: false, kind: "round", expected, actual };
    }
    const reason = reasons[decoded.errorName];
    if (reason) return { ok: false, kind: "other", reason };
  } catch {
    // Not one of the known custom errors.
  }
  try {
    const decoded = decodeErrorResult({ abi: errorString, data });
    const reason = safeText(String(decoded.args[0] ?? ""));
    if (reason) return { ok: false, kind: "other", reason };
  } catch {
    // Not an Error(string) revert.
  }
  return { ok: false, kind: "other", reason: "simulation failed" };
}
