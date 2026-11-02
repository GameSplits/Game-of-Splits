// Vercel function entry. Every route is this one function so a warm instance shares the nonce queue.

import { loadConfig, loadOrigins, type OriginPolicy } from "./config.ts";
import { corsHeaders, handle, toResponse, type HandleInput } from "./http.ts";
import { createRuntime } from "./runtime.ts";

const MAX_BODY = 8192;

let runtime: ReturnType<typeof createRuntime> | undefined;
let origins: OriginPolicy | undefined;

function getRuntime(): ReturnType<typeof createRuntime> {
  if (!runtime) runtime = createRuntime(loadConfig(process.env));
  return runtime;
}

async function web(request: Request): Promise<Response> {
  if (!origins) origins = loadOrigins(process.env);
  const cors = corsHeaders(request.headers.get("origin"), origins);
  const url = new URL(request.url);
  const declared = Number(request.headers.get("content-length") ?? "0");
  if (Number.isFinite(declared) && declared > MAX_BODY) {
    return toResponse({ status: 413, body: { ok: false, error: "too large" } }, cors);
  }
  let body = "";
  if (request.method === "POST") {
    body = await request.text();
    if (body.length > MAX_BODY) return toResponse({ status: 413, body: { ok: false, error: "too large" } }, cors);
  }
  const headers: HandleInput["headers"] = {};
  request.headers.forEach((value, key) => {
    headers[key] = value;
  });
  const out = await handle(getRuntime(), {
    method: request.method,
    path: url.pathname,
    route: url.searchParams.get("route"),
    headers,
    body,
  });
  return toResponse(out, cors);
}

export function GET(request: Request): Promise<Response> {
  return web(request);
}

export function POST(request: Request): Promise<Response> {
  return web(request);
}

export function OPTIONS(request: Request): Promise<Response> {
  return web(request);
}
