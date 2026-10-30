// H3: every way the watcher can fail ends in a /fail ping or a missed ping, so the dead-man switch alerts.
import { test } from "node:test";
import assert from "node:assert/strict";
import { createServer } from "node:http";
import { mkdtempSync, readFileSync, existsSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { GET } from "../api/check.mjs";

async function hcServer() {
  const pings = [];
  const srv = createServer((req, res) => {
    pings.push(req.url);
    res.writeHead(200).end("OK");
  });
  await new Promise((r) => srv.listen(0, "127.0.0.1", r));
  return { url: `http://127.0.0.1:${srv.address().port}/ping`, pings, close: () => srv.close() };
}
const req = (auth) => new Request("http://local/api/check", { headers: auth ? { authorization: auth } : {} });

test("wrong or missing CRON_SECRET: 401 and no ping (the switch fires after its grace period)", async () => {
  const hc = await hcServer();
  const saved = { ...process.env };
  try {
    Object.assign(process.env, { HEALTHCHECK_URL: hc.url, CRON_SECRET: "right" });
    assert.equal((await GET(req("Bearer wrong"))).status, 401);
    assert.equal((await GET(req())).status, 401);
    process.env.CRON_SECRET = "";
    assert.equal((await GET(req("Bearer "))).status, 401);
    assert.equal(hc.pings.length, 0);
  } finally {
    process.env = saved;
    hc.close();
  }
});

test("a config error pings /fail and alerts (it used to 500 silently)", async () => {
  const hc = await hcServer();
  const dir = mkdtempSync(join(tmpdir(), "gosa-"));
  const saved = { ...process.env };
  try {
    Object.assign(process.env, {
      HEALTHCHECK_URL: hc.url, CRON_SECRET: "right", ALERT_FILE: join(dir, "a.jsonl"), STATE_FILE: join(dir, "s.json"),
      RPC_URL: "https://rpc.example/v2/SECRETKEY99", CHAIN_ID: "4663", // the rest is missing
    });
    const r = await GET(req("Bearer right"));
    assert.equal(r.status, 500);
    const body = await r.text();
    assert.ok(!body.includes("SECRETKEY99"));
    assert.deepEqual(hc.pings, ["/ping/fail"]);
    assert.ok(existsSync(process.env.ALERT_FILE));
    const a = readFileSync(process.env.ALERT_FILE, "utf8");
    assert.match(a, /watcher pass failed/);
    // a second failure within 30 min pings /fail again but doesn't push again (M4)
    await GET(req("Bearer right"));
    assert.equal(hc.pings.length, 2);
    assert.equal(readFileSync(process.env.ALERT_FILE, "utf8").trim().split("\n").length, 1);
  } finally {
    process.env = saved;
    hc.close();
  }
});

test("F1 (N1): the alerter throws unless Pushover confirms (HTTP 200 and status 1)", async () => {
  const { makeAlerter } = await import("../lib/alerts.mjs");
  const real = globalThis.fetch;
  const log = console.log;
  console.log = () => {};
  const replies = [
    [500, { status: 0, errors: ["server"] }, false],
    [200, { status: 0, errors: ["user key is invalid"] }, false],
    [200, { status: 1 }, true],
  ];
  try {
    const alert = makeAlerter({ pushoverToken: "tok12345678", pushoverGroup: "grp12345678" }, "watcher");
    for (const [code, body, ok] of replies) {
      globalThis.fetch = async () => new Response(JSON.stringify(body), { status: code });
      if (ok) await alert("emergency", "t", "m");
      else await assert.rejects(alert("emergency", "t", "m"), /pushover refused/);
    }
    globalThis.fetch = async () => { throw new Error("getaddrinfo ENOTFOUND api.pushover.net"); };
    await assert.rejects(alert("high", "t", "m"), /pushover unreachable/);
    assert.throws(() => makeAlerter({}, "watcher"), /PUSHOVER/);
  } finally {
    globalThis.fetch = real;
    console.log = log;
  }
});
