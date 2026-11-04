// Local HTTP entry. The signing key is loaded from the environment and never logged.

import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import { pathToFileURL } from "node:url";
import { loadConfig, redact, type RelayerConfig } from "./config.ts";
import { CORS, handle } from "./http.ts";
import { createRuntime } from "./runtime.ts";

function readBody(req: IncomingMessage): Promise<string> {
  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = [];
    let size = 0;
    req.on("data", (chunk: Buffer) => {
      size += chunk.length;
      if (size > 8192) {
        reject(new Error("too large"));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
    req.on("error", reject);
  });
}

function write(res: ServerResponse, status: number, body: Record<string, unknown> | null): void {
  if (status === 204 || body === null) {
    res.writeHead(status, CORS);
    res.end();
    return;
  }
  res.writeHead(status, { ...CORS, "content-type": "application/json" });
  res.end(JSON.stringify(body));
}

export function start(cfg: RelayerConfig): Promise<Server> {
  const rt = createRuntime(cfg);
  const secrets = [cfg.key, cfg.rpcUrl, cfg.healthcheckUrl];
  const server = createServer(async (req, res) => {
    try {
      const url = new URL(req.url ?? "/", "http://127.0.0.1");
      const body = req.method === "POST" ? await readBody(req) : "";
      const out = await handle(rt, {
        method: req.method ?? "GET",
        path: url.pathname,
        route: url.searchParams.get("route"),
        headers: req.headers as Record<string, string | string[] | undefined>,
        body,
      });
      write(res, out.status, out.body);
    } catch (err) {
      const message = err instanceof Error ? err.message : "";
      console.error(redact(message, secrets));
      const tooLarge = message === "too large";
      write(res, tooLarge ? 413 : 400, { ok: false, error: tooLarge ? "too large" : "bad request" });
    }
  });
  return new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(cfg.port, "127.0.0.1", () => {
      console.log(`relayer ${rt.relayer} listening on ${cfg.port}`);
      resolve(server);
    });
  });
}

const entry = process.argv[1];
if (entry && import.meta.url === pathToFileURL(entry).href) {
  start(loadConfig(process.env)).catch((err: unknown) => {
    const message = err instanceof Error ? err.message : "config failed";
    console.error(redact(message, [process.env.RELAYER_KEY ?? "", process.env.RPC_URL ?? "", process.env.HEALTHCHECK_URL ?? ""]));
    process.exit(1);
  });
}
