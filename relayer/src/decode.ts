// Pull PriceAboveMax and WrongRound out of a revert payload.

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
] as const;

export function extractRevertData(err: unknown): Hex | null {
  const seen = new Set<unknown>();
  let cur: unknown = err;
  while (cur && typeof cur === "object" && !seen.has(cur)) {
    seen.add(cur);
    const rec = cur as { data?: unknown; raw?: unknown; cause?: unknown };
    if (typeof rec.data === "string" && rec.data.startsWith("0x")) return rec.data as Hex;
    if (typeof rec.raw === "string" && rec.raw.startsWith("0x")) return rec.raw as Hex;
    cur = rec.cause;
  }
  return null;
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
  } catch {
    // Not one of the two game errors.
  }
  return { ok: false, kind: "other" };
}
