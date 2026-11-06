import { DurableObject } from "cloudflare:workers";
import { planRound, loadLockwatchConfig, PAIR_STEPS, afterRevert, afterSendFailure } from "./logic.mjs";
import {
  calldata, getBlock, ethCallOk, ethCall, decodeRounds, decodeUint,
  ethGetTransactionCount, ethEstimateGas, ethSendRawTransaction, waitReceipt,
} from "./rpc.mjs";
import { makeAlerter, PUSHOVER_API } from "./alerts.mjs";
import { signEip1559Tx, accountAddress } from "./wallet.mjs";

const LOG_CAP = 200;

export class LockwatchDO extends DurableObject {
  constructor(ctx, env) {
    super(ctx, env);
  }

  async fetch(request) {
    const url = new URL(request.url);
    const path = url.pathname;
    try {
      if (path === "/start" && (request.method === "POST" || request.method === "GET")) {
        const cfg = this.cfg();
        await this.ctx.storage.put("running", true);
        await this.ctx.storage.put("seen", []);
        await this.pushLog(`start chain ${cfg.chainId} dry=${cfg.dryRun} fallback=${cfg.fallback} poll=${cfg.pollMs}ms`);
        await this.ensureAlarm(0);
        return json({ ok: true, running: true, dryRun: cfg.dryRun, chainId: cfg.chainId, rat: cfg.rat });
      }
      if (path === "/stop" && (request.method === "POST" || request.method === "GET")) {
        await this.ctx.storage.put("running", false);
        await this.ctx.storage.deleteAlarm();
        await this.pushLog("stop");
        return json({ ok: true, running: false });
      }
      if (path === "/tick" && (request.method === "POST" || request.method === "GET")) {
        const lines = await this.tickOnce();
        return json({ ok: true, lines });
      }
      if (path === "/status") {
        const running = !!(await this.ctx.storage.get("running"));
        const alarm = await this.ctx.storage.getAlarm();
        const cfg = this.cfg();
        return json({
          ok: true,
          running,
          nextAlarm: alarm ?? null,
          dryRun: cfg.dryRun,
          chainId: cfg.chainId,
          rat: cfg.rat,
          pollMs: cfg.pollMs,
        });
      }
      if (path === "/logs") {
        const logs = (await this.ctx.storage.get("logs")) || [];
        return json({ ok: true, logs });
      }
      if (path === "/test-alert" && (request.method === "POST" || request.method === "GET")) {
        const cfg = this.cfg();
        if (!(cfg.pushoverToken && cfg.pushoverGroup)) {
          return json({ ok: false, error: "no alert channel configured" }, 400);
        }
        const body = new URLSearchParams({
          token: cfg.pushoverToken,
          user: cfg.pushoverGroup,
          title: "GoS lockwatch testnet test",
          message: "Worker alert path smoke test (normal priority)",
          priority: "0",
        });
        const r = await fetch(PUSHOVER_API, { method: "POST", body, signal: AbortSignal.timeout(10_000) });
        let j = null;
        try { j = await r.json(); } catch { j = null; }
        if (!r.ok || j?.status !== 1) {
          return json({ ok: false, error: `pushover refused: HTTP ${r.status}` }, 502);
        }
        await this.pushLog("test-alert delivered");
        return json({ ok: true, delivered: true, status: j.status });
      }
      return json({ ok: true, endpoints: ["/start", "/stop", "/tick", "/status", "/logs", "/test-alert"] });
    } catch (e) {
      try { await this.pushLog(`error: ${e.message}`); } catch {}
      return json({ ok: false, error: e.message, stack: String(e.stack || "") }, 500);
    }
  }

  async alarm() {
    const running = !!(await this.ctx.storage.get("running"));
    if (!running) return;
    try {
      await this.tickOnce();
    } catch (e) {
      await this.pushLog(`tick failed: ${e.message}`);
    }
    const cfg = this.cfg();
    await this.ensureAlarm(cfg.pollMs);
  }

  cfg() {
    return loadLockwatchConfig(this.env);
  }

  async ensureAlarm(delayMs) {
    const when = Date.now() + Math.max(0, delayMs);
    await this.ctx.storage.setAlarm(when);
  }

  async pushLog(line) {
    const t = new Date().toISOString();
    const entry = `${t} ${line}`;
    console.log(entry);
    const logs = (await this.ctx.storage.get("logs")) || [];
    logs.push(entry);
    while (logs.length > LOG_CAP) logs.shift();
    await this.ctx.storage.put("logs", logs);
  }

  async tickOnce() {
    const cfg = this.cfg();
    const lines = [];
    const log = async (s) => {
      lines.push(s);
      await this.pushLog(s);
    };
    const alert = makeAlerter(cfg, "lockwatch-cf", (s) => console.log(s));
    let seenArr = (await this.ctx.storage.get("seen")) || [];
    const seen = new Set(seenArr);

    const warn = async (r, msg) => {
      const k = `${r}:${msg}`;
      if (seen.has(k)) return;
      seen.add(k);
      await log(`round ${r}: ALERT ${msg}`);
      if (alert) {
        try {
          await alert("high", `lockwatch round ${r}`, msg);
        } catch (e) {
          seen.delete(k);
          await log(`round ${r}: alert not delivered (${e.message})`);
        }
      }
    };

    const block = await getBlock(cfg.rpcUrl);
    const now = block.timestamp;
    const nowL2 = block.number;
    const curHex = await ethCall(cfg.rpcUrl, cfg.rat, calldata("currentRound"));
    const cur = decodeUint(curHex);
    await log(`tick block=${nowL2} ts=${now} currentRound=${cur}`);

    for (const r of [cur - 1n, cur]) {
      if (r < 1n) continue;
      const [rawHex, closeHex] = await Promise.all([
        ethCall(cfg.rpcUrl, cfg.rat, calldata("rounds", [r])),
        ethCall(cfg.rpcUrl, cfg.rat, calldata("closeTime", [r])),
      ]);
      const round = decodeRounds(rawHex);
      const closeTime = decodeUint(closeHex);
      const plan = planRound({ round, closeTime, now, nowL2, fallback: cfg.fallback });
      if (plan.action === "lapsed") await warn(r, plan.why);
      if (!["lockPairing", "pair", "fallbackSeed"].includes(plan.action)) {
        if (plan.action !== "none") await log(`round ${r}: ${plan.action} (${plan.why})`);
        continue;
      }
      const args = plan.action === "pair" ? [r, PAIR_STEPS] : [r];
      const data = calldata(plan.action, args);
      const fromSim = cfg.key ? accountAddress(cfg.key) : undefined;
      const sim = await ethCallOk(cfg.rpcUrl, cfg.rat, data, fromSim);
      if (!sim.ok) {
        await log(`round ${r}: ${plan.action} would revert (${sim.error}), skipping`);
        continue;
      }
      if (cfg.dryRun) {
        await log(`round ${r}: dry run, would call ${plan.action} (${plan.why})`);
        continue;
      }
      // Live send (DRY_RUN=0). Config loader already requires key + alert channel.
      const from = accountAddress(cfg.key);
      // One sender per key: never send from the keeper or another reserved address.
      if (cfg.forbidSenders.includes(from.toLowerCase())) {
        await warn(r, `LOCKWATCH_KEY is a reserved address (${from}); not sending. Give lockwatch its own key`);
        continue;
      }
      const [nonce, latest] = await Promise.all([
        ethGetTransactionCount(cfg.rpcUrl, from),
        ethGetTransactionCount(cfg.rpcUrl, from, "latest"),
      ]);
      if (nonce !== latest) {
        // A tx from this key is still pending: ours from an earlier tick, or another process using the same key.
        await log(`round ${r}: ${from} has a pending tx (latest ${latest}, pending ${nonce}), skipping this tick`);
        continue;
      }
      let gasLimit;
      try {
        gasLimit = await ethEstimateGas(cfg.rpcUrl, { from, to: cfg.rat, data });
        gasLimit = (gasLimit * 12n) / 10n; // +20% headroom
      } catch (e) {
        await log(`round ${r}: estimateGas failed (${e.message}), using 400000`);
        gasLimit = 400000n;
      }
      const maxFee = cfg.maxFeeWei;
      const maxPriority = maxFee < 100000000n ? maxFee : 100000000n; // <= 0.1 gwei tip, never above cap
      const raw = signEip1559Tx(cfg.key, {
        chainId: cfg.chainId,
        nonce,
        maxPriorityFeePerGas: maxPriority,
        maxFeePerGas: maxFee,
        gasLimit,
        to: cfg.rat,
        value: 0n,
        data,
      });
      let hash;
      try {
        hash = await ethSendRawTransaction(cfg.rpcUrl, raw);
      } catch (e) {
        // Race check, as on the revert path: another caller may already have done this step, or used this nonce.
        let how = "failed";
        try {
          const nowRound = decodeRounds(await ethCall(cfg.rpcUrl, cfg.rat, calldata("rounds", [r])));
          how = afterSendFailure(plan.action, nowRound, e.message);
        } catch (e2) {
          await log(`round ${r}: re-read after send failure failed (${e2.message})`);
        }
        if (how === "raced") await log(`round ${r}: ${plan.action} send failed, another caller already did it (${e.message})`);
        else if (how === "nonce") await log(`round ${r}: ${plan.action} send hit a nonce race (${e.message}), retrying next tick`);
        else await warn(r, `${plan.action} send failed (${e.message})`);
        continue;
      }
      await log(`round ${r}: sent ${plan.action} ${hash}`);
      let rcpt;
      try {
        rcpt = await waitReceipt(cfg.rpcUrl, hash);
      } catch (e) {
        await warn(r, `${plan.action} no receipt (${e.message})`);
        continue;
      }
      if (rcpt.status === "0x1") continue;
      const againHex = await ethCall(cfg.rpcUrl, cfg.rat, calldata("rounds", [r]));
      const again = decodeRounds(againHex);
      const how = afterRevert(plan.action, again);
      if (how === "raced") await log(`round ${r}: ${plan.action} reverted, another caller already did it`);
      else await warn(r, `${plan.action} reverted and the round is still not done`);
    }

    seenArr = [...seen];
    if (seenArr.length > 1000) seenArr = [];
    await this.ctx.storage.put("seen", seenArr);
    return lines;
  }
}

export default {
  async fetch(request, env) {
    try {
      if (!env.LOCKWATCH) {
        return json({ ok: false, error: "LOCKWATCH binding missing" }, 500);
      }
      const name = `lockwatch-${env.CHAIN_ID || "x"}-v2`;
      let stub;
      if (typeof env.LOCKWATCH.getByName === "function") {
        stub = env.LOCKWATCH.getByName(name);
      } else {
        const id = env.LOCKWATCH.idFromName(name);
        stub = env.LOCKWATCH.get(id);
      }
      return stub.fetch(request);
    } catch (e) {
      return json({ ok: false, error: e.message, stack: String(e.stack || "") }, 500);
    }
  },
};

function json(obj, status = 200) {
  return new Response(JSON.stringify(obj, (_, v) => (typeof v === "bigint" ? v.toString() : v)), {
    status,
    headers: { "content-type": "application/json" },
  });
}
