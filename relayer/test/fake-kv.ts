// In-process stand-in for Upstash, with the same rewind rule as the Lua script.
import type { Kv } from "../src/shared.ts";

export class FakeKv implements Kv {
  readonly rows = new Map<string, { v: string; exp: number }>();
  now = 1_000_000;
  private live(key: string) {
    const row = this.rows.get(key);
    if (row && row.exp <= this.now) this.rows.delete(key);
    return this.rows.get(key);
  }
  async incrTtl(key: string, by: number, ttlMs: number) {
    const v = await this.incrBy(key, by);
    this.rows.get(key)!.exp = this.now + ttlMs;
    return v;
  }
  async incrBy(key: string, by: number) {
    const row = this.live(key);
    const v = Number(row?.v ?? 0) + by;
    this.rows.set(key, { v: String(v), exp: row?.exp ?? Infinity });
    return v;
  }
  async get(key: string) {
    const row = this.live(key);
    return row ? Number(row.v) : null;
  }
  async setNx(key: string, value: string, ttlMs: number) {
    if (this.live(key)) return false;
    this.rows.set(key, { v: value, exp: this.now + ttlMs });
    return true;
  }
  async set(key: string, value: number) {
    this.rows.set(key, { v: String(value), exp: Infinity });
  }
  async del(key: string) {
    this.rows.delete(key);
  }
  async rewindNonce(key: string, nonce: number, pending: number, kept: boolean, gap: boolean) {
    const cur = (await this.get(key)) ?? -1;
    if (gap) await this.set(key, pending);
    else if (!kept && cur === nonce + 1) await this.set(key, Math.max(pending, nonce));
    else if (pending > cur) await this.set(key, pending);
  }
}
