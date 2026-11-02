// Pure relay policy. No keys, no network.

export const LOW_BALANCE_WEI = 5_000_000_000_000_000n;

export type Sim =
  | { ok: true }
  | { ok: false; kind: "price"; price: bigint; maxPrice: bigint }
  | { ok: false; kind: "round"; expected: bigint; actual: bigint }
  | { ok: false; kind: "other" };

export type Decision = "send" | "retry" | "resign" | "reject";

/** One retry when the new price still fits under the signed max. A wrong round can be re-signed once inside that max. */
export function decideSim(sim: Sim, signedMax: bigint, alreadyRetried: boolean): Decision {
  if (sim.ok) return "send";
  if (alreadyRetried) return "reject";
  if (sim.kind === "price" && sim.price <= signedMax) return "retry";
  if (sim.kind === "round") return "resign";
  return "reject";
}

export class RateLimit {
  private readonly hits = new Map<string, number[]>();
  private readonly limit: number;
  private readonly windowMs: number;

  constructor(limit = 30, windowMs = 60_000) {
    this.limit = limit;
    this.windowMs = windowMs;
  }

  allow(owner: string, now: number): boolean {
    const fresh = (this.hits.get(owner) ?? []).filter((t) => now - t < this.windowMs);
    if (fresh.length >= this.limit) {
      this.hits.set(owner, fresh);
      return false;
    }
    fresh.push(now);
    this.hits.set(owner, fresh);
    return true;
  }
}

export class ResignBook {
  private readonly pending = new Map<string, { maxPrice: bigint; at: number; used: boolean }>();
  private readonly ttlMs: number;

  constructor(ttlMs = 60_000) {
    this.ttlMs = ttlMs;
  }

  offer(owner: string, maxPrice: bigint, now: number): void {
    this.pending.set(owner.toLowerCase(), { maxPrice, at: now, used: false });
  }

  /** Accept one replacement whose max price does not exceed the original signed max. */
  take(owner: string, maxPrice: bigint, now: number): "ok" | "none" | "used" | "above" | "stale" {
    const row = this.pending.get(owner.toLowerCase());
    if (!row) return "none";
    if (now - row.at > this.ttlMs) return "stale";
    if (row.used) return "used";
    if (maxPrice > row.maxPrice) return "above";
    row.used = true;
    return "ok";
  }
}

export class NonceQueue {
  private tail: Promise<void> = Promise.resolve();
  private next: bigint | null = null;
  private readonly pending: () => Promise<bigint>;

  constructor(pending: () => Promise<bigint>) {
    this.pending = pending;
  }

  run<T>(fn: (nonce: bigint) => Promise<T>): Promise<T> {
    const job = this.tail.then(async () => {
      if (this.next === null) this.next = await this.pending();
      const nonce = this.next;
      try {
        const out = await fn(nonce);
        this.next = nonce + 1n;
        return out;
      } catch (err) {
        this.next = await this.pending();
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

export class OwnerNonceGuard {
  private readonly busy = new Set<string>();

  hold(owner: string): boolean {
    const id = owner.toLowerCase();
    if (this.busy.has(id)) return false;
    this.busy.add(id);
    return true;
  }

  release(owner: string): void {
    this.busy.delete(owner.toLowerCase());
  }
}
