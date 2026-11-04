// One request handler for the local server and the Vercel function.

import { getAddress, type Address } from "viem";
import { assertSignature, HttpError, parseAction, ZERO_ADDRESS } from "./actions.ts";
import { isAllowedOrigin, type OriginPolicy, type RelayerConfig } from "./config.ts";
import type { SignedAction } from "./eip712.ts";
import { LOW_BALANCE_WEI, RateLimit } from "./policy.ts";
import { submitShot, type RelayDeps, type RelayState } from "./relay.ts";

export interface HandleCtx {
  cfg: RelayerConfig;
  relayer: Address;
  deps: RelayDeps;
  state: RelayState;
  sessionKey(owner: Address): Promise<Address>;
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

/** Reads of /lines get their own, larger budget, so page polls never use up a player's budget for takes. */
const READS = new RateLimit(240, 60_000);

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
  // Vercel's edge sets x-vercel-forwarded-for and x-real-ip; a client can only prepend to x-forwarded-for.
  const edge = headers["x-vercel-forwarded-for"] ?? headers["x-real-ip"];
  const e = Array.isArray(edge) ? edge[0] : edge;
  if (typeof e === "string" && e.trim()) return (e.split(",")[0]?.trim() ?? "").slice(0, 64) || "unknown";
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
    if (!READS.allow(clientIp(input.headers), ctx.deps.now())) {
      return { status: 429, body: { ok: false, error: "rate limit" } };
    }
    // Seat lines are presets only. Custom lines are no longer saved or served, so this always answers empty.
    return { status: 200, body: { ok: true, lines: {} } };
  }
  if (!isAction(name)) return { status: 404, body: { ok: false, error: "not found" } };
  if (input.method !== "POST") return { status: 405, body: { ok: false, error: "method" } };
  if (!ctx.state.ips.allow(clientIp(input.headers), ctx.deps.now())) {
    return { status: 429, body: { ok: false, error: "rate limit" } };
  }
  try {
    if (name === "take" && hasCustomLine(input.body)) {
      return { status: 400, body: { ok: false, error: "custom lines are off" } };
    }
    const parsed = parseAction(name, input.body, ctx.cfg);
    if (parsed.action.kind === "withdraw" && parsed.action.message.amount <= ctx.cfg.withdrawFee) {
      return { status: 400, body: { ok: false, error: "amount must be above the withdrawal fee" } };
    }
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
    return { status: result.status, body: result.body };
  } catch (err) {
    if (err instanceof HttpError) return { status: err.status, body: { ok: false, error: err.message } };
    return { status: 400, body: { ok: false, error: "bad request" } };
  }
}

/** True when a take carries its own line text. Only the signed preset is accepted. */
function hasCustomLine(raw: string): boolean {
  try {
    const line = (JSON.parse(raw) as Record<string, unknown>).line;
    return line !== undefined && line !== null && line !== "";
  } catch {
    return false;
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
