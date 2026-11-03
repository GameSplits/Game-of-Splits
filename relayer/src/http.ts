// One request handler for the local server and the Vercel function.

import { getAddress, type Address } from "viem";
import { assertSignature, HttpError, parseAction, ZERO_ADDRESS } from "./actions.ts";
import { isAllowedOrigin, type OriginPolicy, type RelayerConfig } from "./config.ts";
import type { SignedAction } from "./eip712.ts";
import { LOW_BALANCE_WEI } from "./policy.ts";
import { cleanLine, isTxHash, type LineStore } from "./lines.ts";
import { submitShot, type RelayDeps, type RelayState } from "./relay.ts";

export interface HandleCtx {
  cfg: RelayerConfig;
  relayer: Address;
  deps: RelayDeps;
  state: RelayState;
  sessionKey(owner: Address): Promise<Address>;
  /** Where one-click Seat lines are kept. Null when no store is configured: takes still go through, lines are not saved. */
  lines?: LineStore | null;
}

export interface HandleInput {
  method: string;
  path: string;
  route: string | null;
  headers: Record<string, string | string[] | undefined>;
  body: string;
  /** The query string, with or without the leading "?". */
  query?: string;
}

export interface HandleOutput {
  status: number;
  body: Record<string, unknown> | null;
}

const ACTIONS = ["shoot", "take", "withdraw", "authorize-key", "set-limit", "revoke-key"] as const;
type ActionName = (typeof ACTIONS)[number];

const BASE_HEADERS: Record<string, string> = {
  "access-control-allow-methods": "GET, POST, OPTIONS",
  "access-control-allow-headers": "content-type",
  "access-control-max-age": "86400",
  "cache-control": "no-store",
  vary: "Origin",
};

/** CORS headers for one request. Only an allowed Origin is echoed back; any other origin gets no allow header. */
export function corsHeaders(origin: string | null | undefined, policy: OriginPolicy): Record<string, string> {
  if (origin && isAllowedOrigin(origin, policy)) {
    return { ...BASE_HEADERS, "access-control-allow-origin": origin };
  }
  return { ...BASE_HEADERS };
}

function isAction(name: string): name is ActionName {
  return (ACTIONS as readonly string[]).includes(name);
}

export function clientIp(headers: HandleInput["headers"]): string {
  const fwd = headers["x-forwarded-for"];
  const raw = Array.isArray(fwd) ? fwd[0] : fwd;
  if (typeof raw === "string" && raw.trim()) {
    const first = raw.split(",")[0]?.trim() ?? "";
    if (first) return first.slice(0, 64);
  }
  return "unknown";
}

function barePath(path: string): string {
  const noQuery = path.split("?")[0] || "/";
  const trimmed = noQuery.length > 1 ? noQuery.replace(/\/+$/, "") : noQuery;
  if (trimmed.startsWith("/api/")) return trimmed.slice(4);
  return trimmed;
}

export async function handle(ctx: HandleCtx, input: HandleInput): Promise<HandleOutput> {
  if (input.method === "OPTIONS") return { status: 204, body: null };
  const name = input.route && input.route.length > 0 ? input.route : barePath(input.path).replace(/^\//, "");
  if (name === "health") {
    if (input.method !== "GET") return { status: 405, body: { ok: false, error: "method" } };
    return health(ctx);
  }
  if (name === "lines") {
    if (input.method !== "GET") return { status: 405, body: { ok: false, error: "method" } };
    if (!ctx.state.ips.allow(clientIp(input.headers), ctx.deps.now())) {
      return { status: 429, body: { ok: false, error: "rate limit" } };
    }
    return readLines(ctx, input.query ?? "");
  }
  if (!isAction(name)) return { status: 404, body: { ok: false, error: "not found" } };
  if (input.method !== "POST") return { status: 405, body: { ok: false, error: "method" } };
  if (!ctx.state.ips.allow(clientIp(input.headers), ctx.deps.now())) {
    return { status: 429, body: { ok: false, error: "rate limit" } };
  }
  try {
    const parsed = parseAction(name, input.body, ctx.cfg);
    if (parsed.session) {
      let key: Address;
      try {
        key = getAddress(await ctx.sessionKey(parsed.action.message.owner));
      } catch {
        return { status: 502, body: { ok: false, error: "session unavailable" } };
      }
      if (key.toLowerCase() === ZERO_ADDRESS) return { status: 400, body: { ok: false, error: "key missing" } };
      await assertSignature(ctx.cfg, parsed.action, key);
    } else {
      await assertSignature(ctx.cfg, parsed.action as SignedAction, parsed.action.message.owner);
    }
    const result = await submitShot(ctx.deps, ctx.state, parsed.request);
    if (name === "take" && result.body.ok && result.body.hash) {
      const saved = await saveLine(ctx, result.body.hash, input.body);
      if (saved !== null) return { status: result.status, body: { ...result.body, line: saved } };
    }
    return { status: result.status, body: result.body };
  } catch (err) {
    if (err instanceof HttpError) return { status: err.status, body: { ok: false, error: err.message } };
    return { status: 400, body: { ok: false, error: "bad request" } };
  }
}

/** Saves the player's own line for a take this relayer just sent. A store error never fails the take. Returns
 *  "saved", "refused" (filtered or empty) or null when no line was asked for. */
async function saveLine(ctx: HandleCtx, hash: string, raw: string): Promise<"saved" | "refused" | "unsaved" | null> {
  let line: unknown;
  try {
    line = (JSON.parse(raw) as Record<string, unknown>).line;
  } catch {
    return null;
  }
  if (line === undefined || line === null || line === "") return null;
  const clean = cleanLine(line);
  if (!clean) return "refused";
  if (!ctx.lines) return "unsaved";
  try {
    await ctx.lines.set(hash, clean);
    return "saved";
  } catch {
    return "unsaved";
  }
}

async function readLines(ctx: HandleCtx, query: string): Promise<HandleOutput> {
  const tx = new URLSearchParams(query.replace(/^\?/, "")).get("tx") ?? "";
  const hashes = [...new Set(tx.split(",").map((h) => h.trim().toLowerCase()).filter(isTxHash))].slice(0, 50);
  if (!ctx.lines || hashes.length === 0) return { status: 200, body: { ok: true, lines: {} } };
  try {
    return { status: 200, body: { ok: true, lines: await ctx.lines.getMany(hashes) } };
  } catch {
    return { status: 503, body: { ok: false, error: "lines unavailable" } };
  }
}

async function health(ctx: HandleCtx): Promise<HandleOutput> {
  try {
    const balance = await ctx.deps.ethBalance();
    const low = balance < LOW_BALANCE_WEI;
    if (low) await ctx.deps.alert("relayer balance below 0.005 ETH");
    return {
      status: 200,
      body: {
        ok: true,
        balanceWei: balance.toString(),
        low,
        chainId: ctx.cfg.chainId,
        stash: ctx.cfg.stash,
        relayer: ctx.relayer,
      },
    };
  } catch {
    return { status: 503, body: { ok: false, error: "balance unavailable" } };
  }
}

export function toResponse(out: HandleOutput, cors: Record<string, string>): Response {
  if (out.status === 204 || out.body === null) return new Response(null, { status: out.status, headers: cors });
  return new Response(JSON.stringify(out.body), {
    status: out.status,
    headers: { ...cors, "content-type": "application/json" },
  });
}
