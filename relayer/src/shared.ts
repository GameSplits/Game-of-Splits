// Relay state shared by every server copy through Upstash Redis (REST). Without the Upstash env the relayer keeps
// state in memory, which is only correct for one process.

import { Redis } from "@upstash/redis";
import { isNonceGap, mayHaveBroadcast, type Limiter, type Nonces, type Spend, type UsedOrders } from "./policy.ts";

/** The few atomic Redis operations the shared state needs. Small so tests can run against an in-process fake. */
export interface Kv {
  /** INCRBY then PEXPIRE in one MULTI. Returns the new value. */
  incrTtl(key: string, by: number, ttlMs: number): Promise<number>;
  incrBy(key: string, by: number): Promise<number>;
  get(key: string): Promise<number | null>;
  /** SET key value NX PX ttl. True when the key was set. */
  setNx(key: string, value: string, ttlMs: number): Promise<boolean>;
  set(key: string, value: number): Promise<void>;
  del(key: string): Promise<void>;
  /**
   * Atomically gives back a nonce after a send that surely failed. Sets the counter to max(pending, nonce) only when
   * no other copy took a nonce after it (counter is still nonce + 1), and otherwise only moves it up to pending.
   * The counter never goes below a nonce another copy holds. With `kept` the nonce may have been used, so it is never
   * given back and the counter only moves up to pending. With `gap` the node reported a nonce too high, so the counter
   * is set to pending to fill the gap.
   */
  rewindNonce(key: string, nonce: number, pending: number, kept: boolean, gap: boolean): Promise<void>;
}

export interface UpstashEnv {
  url: string;
  token: string;
}

/** Vercel Marketplace names first (KV_REST_API_*), then the plain Upstash names. */
export function upstashEnv(env: NodeJS.ProcessEnv): UpstashEnv | null {
  const url = (env.KV_REST_API_URL ?? env.UPSTASH_REDIS_REST_URL ?? "").trim();
  const token = (env.KV_REST_API_TOKEN ?? env.UPSTASH_REDIS_REST_TOKEN ?? "").trim();
  if (!url || !token) return null;
  if (!/^https:\/\/[^/\s]+\/?$/.test(url)) throw new Error("KV_REST_API_URL must be an https URL");
  return { url, token };
}

export function upstashKv(cfg: UpstashEnv): Kv {
  const redis = new Redis({ url: cfg.url, token: cfg.token, automaticDeserialization: false });
  return {
    async incrTtl(key, by, ttlMs) {
      const [value] = await redis.multi().incrby(key, by).pexpire(key, ttlMs).exec<[number, number]>();
      return Number(value);
    },
    async incrBy(key, by) {
      return Number(await redis.incrby(key, by));
    },
    async get(key) {
      const raw = await redis.get<string>(key);
      return raw === null || raw === undefined ? null : Number(raw);
    },
    async setNx(key, value, ttlMs) {
      return (await redis.set(key, value, { nx: true, px: ttlMs })) === "OK";
    },
    async set(key, value) {
      await redis.set(key, String(value));
    },
    async del(key) {
      await redis.del(key);
    },
    async rewindNonce(key, nonce, pending, kept, gap) {
      await redis.eval(REWIND_NONCE, [key], [String(nonce), String(pending), kept ? "1" : "0", gap ? "1" : "0"]);
    },
  };
}

const REWIND_NONCE = `
local cur = tonumber(redis.call("GET", KEYS[1]) or "-1")
local nonce = tonumber(ARGV[1])
local pending = tonumber(ARGV[2])
if ARGV[4] == "1" then
  redis.call("SET", KEYS[1], tostring(pending))
elseif ARGV[3] == "0" and cur == nonce + 1 then
  redis.call("SET", KEYS[1], tostring(math.max(pending, nonce)))
elseif pending > cur then
  redis.call("SET", KEYS[1], tostring(pending))
end
return 1
`;

/** Fixed-window counter per key. `full` only reads, `allow` counts atomically. */
export class SharedRateLimit implements Limiter {
  private readonly kv: Kv;
  private readonly prefix: string;
  private readonly limit: number;
  private readonly windowMs: number;

  constructor(kv: Kv, prefix: string, limit = 30, windowMs = 60_000) {
    this.kv = kv;
    this.prefix = prefix;
    this.limit = limit;
    this.windowMs = windowMs;
  }

  private key(id: string, now: number): string {
    return `${this.prefix}:${id.toLowerCase()}:${Math.floor(now / this.windowMs)}`;
  }

  async full(id: string, now: number): Promise<boolean> {
    return ((await this.kv.get(this.key(id, now))) ?? 0) >= this.limit;
  }

  async allow(id: string, now: number): Promise<boolean> {
    return (await this.kv.incrTtl(this.key(id, now), 1, this.windowMs * 2)) <= this.limit;
  }
}

const GWEI = 1_000_000_000n;
const toGwei = (wei: bigint): number => Number((wei + GWEI - 1n) / GWEI);

/**
 * Hourly ETH budget in one counter per clock hour, kept in gwei so it stays inside a safe integer. A reservation that
 * would cross the limit is taken back at once, so it fails closed under a race. A release refunds the same hour.
 */
export class SharedSpend implements Spend {
  private readonly kv: Kv;
  private readonly prefix: string;
  private readonly windowMs: number;
  private readonly limitGwei: number;

  constructor(kv: Kv, prefix: string, limitWei: bigint, windowMs = 3_600_000) {
    this.kv = kv;
    this.prefix = prefix;
    this.windowMs = windowMs;
    this.limitGwei = Number(limitWei / GWEI);
  }

  private key(now: number): string {
    return `${this.prefix}:${Math.floor(now / this.windowMs)}`;
  }

  async reserve(wei: bigint, now: number): Promise<boolean> {
    const gwei = toGwei(wei);
    const key = this.key(now);
    const total = await this.kv.incrTtl(key, gwei, this.windowMs * 2);
    if (total <= this.limitGwei) return true;
    await this.kv.incrBy(key, -gwei);
    return false;
  }

  async release(wei: bigint, at: number): Promise<void> {
    await this.kv.incrBy(this.key(at), -toGwei(wei));
  }

  async spentGwei(now: number): Promise<number> {
    return (await this.kv.get(this.key(now))) ?? 0;
  }

  /** One alert per window across all copies. */
  async alertDue(now: number): Promise<boolean> {
    return this.kv.setNx(`${this.prefix}:alert`, "1", this.windowMs);
  }
}

/**
 * Relayer account nonce. INCR hands each send a distinct nonce across copies. The counter is seeded from the chain
 * pending count when missing. After a send that surely failed its nonce is given back only if no other copy took a
 * later one, and the counter never moves below a nonce another copy holds. A send that may have gone out keeps it.
 * When the node reports a nonce too high, a nonce was skipped (a lost send or a killed copy), so the counter is reset
 * to the chain pending count. The next attempt then fills the gap. A copy whose nonce gets handed out again fails
 * with nonce too low, a sure failure.
 */
export class SharedNonces implements Nonces {
  private readonly kv: Kv;
  private readonly key: string;
  private readonly pending: () => Promise<bigint>;
  private tail: Promise<void> = Promise.resolve();

  constructor(kv: Kv, key: string, pending: () => Promise<bigint>) {
    this.kv = kv;
    this.key = key;
    this.pending = pending;
  }

  run<T>(fn: (nonce: bigint) => Promise<T>): Promise<T> {
    const job = this.tail.then(async () => {
      if ((await this.kv.get(this.key)) === null) {
        const chain = Number(await this.pending());
        await this.kv.setNx(this.key, String(chain), 365 * 86_400_000);
      }
      const nonce = BigInt((await this.kv.incrBy(this.key, 1)) - 1);
      try {
        return await fn(nonce);
      } catch (err) {
        const kept = mayHaveBroadcast(err);
        const gap = isNonceGap(err);
        try {
          await this.kv.rewindNonce(this.key, Number(nonce), Number(await this.pending()), kept, gap);
        } catch {
          // Cleanup is best effort. The original error and its classification stand.
        }
        throw err;
      }
    });
    this.tail = job.then(
      () => undefined,
      () => undefined,
    );
    return job;
  }
}

/** Signed orders seen recently, so the same order sent twice is relayed once. */
export class SharedUsedOrders implements UsedOrders {
  private readonly kv: Kv;
  private readonly prefix: string;
  private readonly ttlMs: number;

  constructor(kv: Kv, prefix: string, ttlMs = 600_000) {
    this.kv = kv;
    this.prefix = prefix;
    this.ttlMs = ttlMs;
  }

  claim(id: string, _now?: number, ttlMs = this.ttlMs): Promise<boolean> {
    return this.kv.setNx(`${this.prefix}:${id.toLowerCase()}`, "1", Math.min(ttlMs, this.ttlMs));
  }

  async drop(id: string): Promise<void> {
    await this.kv.del(`${this.prefix}:${id.toLowerCase()}`);
  }
}
