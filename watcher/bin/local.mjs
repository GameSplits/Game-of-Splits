// Local runner for tests (never deployed). `serve` runs the REAL Vercel handlers (api/*.mjs) on PORT, plus /hc and
// /hc/fail that record dead-man pings to HC_FILE. `check` runs one pass directly. Uses STATE_FILE and ALERT_FILE.
import { createServer } from "node:http";
import { appendFileSync } from "node:fs";
import * as check from "../api/check.mjs";
import * as sendlog from "../api/sendlog.mjs";
import * as price from "../api/price.mjs";

const mode = process.argv[2];
if (mode === "check") {
  const r = await check.GET(new Request("http://local/api/check", { headers: { authorization: `Bearer ${process.env.CRON_SECRET}` } }));
  console.log(await r.text());
} else if (mode === "serve") {
  const routes = { "GET /api/check": check.GET, "POST /api/sendlog": sendlog.POST, "GET /api/price": price.GET };
  createServer(async (req, res) => {
    let body = "";
    for await (const ch of req) body += ch;
    const path = req.url.split("?")[0];
    if (path === "/hc" || path === "/hc/fail") {
      if (process.env.HC_FILE) appendFileSync(process.env.HC_FILE, `${Math.floor(Date.now() / 1000)} ${path === "/hc" ? "ok" : "fail"}\n`);
      res.writeHead(200).end("OK");
      return;
    }
    const h = routes[`${req.method} ${path}`];
    if (!h) return res.writeHead(404).end();
    const r = await h(new Request(`http://local${req.url}`, { method: req.method, headers: req.headers, body: req.method === "POST" ? body : undefined }));
    res.writeHead(r.status, Object.fromEntries(r.headers));
    res.end(await r.text());
  }).listen(Number(process.env.PORT ?? 8787), "127.0.0.1", () => console.log("serving"));
} else {
  console.log("usage: node bin/local.mjs check|serve");
  process.exit(2);
}
