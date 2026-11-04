// Pure relay policy. No keys, no network.

export const LOW_BALANCE_WEI = 5_000_000_000_000_000n;

export type Sim =
  | { ok: true }
  | { ok: false; kind: "price"; price: bigint; maxPrice: bigint }
  | { ok: false; kind: "round"; expected: bigint; actual: bigint }
  | { ok: false; kind: "other"; reason?: string };

export type Decision = "send" | "retry" | "resign" | "reject";

/** One retry when the new price still fits under the signed max. A wrong round can be re-signed once inside that max. */
export function decideSim(sim: Sim, signedMax: bigint, alreadyRetried: boolean): Decision {
  if (sim.ok) return "send";
  if (alreadyRetried) return "reject";
  if (sim.kind === "price" && sim.price <= signedMax) return "retry";
  if (sim.kind === "round") return "resign";
  return "reject";
}

type MaybePromise<T> = T | Promise<T>;

/** Per key request budget. The in-memory classes below and the Upstash ones in shared.ts both fit. */
export interface Limiter {
  full(key: string, now: number): MaybePromise<boolean>;
  allow(key: string, now: number): MaybePromise<boolean>;
}

/** Hands out relayer account nonces one send at a time. */
export interface Nonces {
  run<T>(fn: (nonce: bigint) => Promise<T>): Promise<T>;
}

/** Hourly ETH budget. A release gives back a reservation whose send definitely did not go out. */
export interface Spend {
  reserve(wei: bigint, now: number): MaybePromise<boolean>;
  release(wei: bigint, at: number): MaybePromise<void>;
  alertDue(now: number): MaybePromise<boolean>;
}

/** Signed orders already taken, keyed by action, owner and order nonce. */
export interface UsedOrders {
  claim(id: string, now: number): MaybePromise<boolean>;
  drop(id: string): MaybePromise<void>;
}

export class MemoryUsedOrders implements UsedOrders {
  private readonly seen = new Map<string, number>();
  private readonly ttlMs: number;

  constructor(ttlMs = 600_000) {
    this.ttlMs = ttlMs;
  }

  claim(id: string, now: number): boolean {
    for (const [key, at] of this.seen) if (now - at >= this.ttlMs) this.seen.delete(key);
    const key = id.toLowerCase();
    if (this.seen.has(key)) return false;
    this.seen.set(key, now);
    return true;
  }

  drop(id: string): void {
    this.seen.delete(id.toLowerCase());
  }
}

export class RateLimit implements Limiter {
  private readonly hits = new Map<string, number[]>();
  private readonly limit: number;
  private readonly windowMs: number;

  constructor(limit = 30, windowMs = 60_000) {
    this.limit = limit;
    this.windowMs = windowMs;
  }

  /** True when `owner` has no room left in the window. Nothing is counted. */
  full(owner: string, now: number): boolean {
    return (this.hits.get(owner) ?? []).filter((t) => now - t < this.windowMs).length >= this.limit;
  }

  allow(owner: string, now: number): boolean {
    if (this.hits.size > 10_000) this.sweep(now);
    const fresh = (this.hits.get(owner) ?? []).filter((t) => now - t < this.windowMs);
    if (fresh.length >= this.limit) {
      this.hits.set(owner, fresh);
      return false;
    }
    fresh.push(now);
    this.hits.set(owner, fresh);
    return true;
  }

  private sweep(now: number): void {
    for (const [key, times] of this.hits) {
      if (!times.some((t) => now - t < this.windowMs)) this.hits.delete(key);
    }
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

const MAYBE_SENT = new Set(["TimeoutError", "AbortError", "HttpRequestError"]);

/**
 * True for errors where the transaction may have reached the node anyway. viem wraps the transport error, for example
 * TransactionExecutionError around TimeoutError, so the whole cause chain is checked.
 */
export function mayHaveBroadcast(err: unknown): boolean {
  const seen = new Set<unknown>();
  let cur: unknown = err;
  while (cur instanceof Error && !seen.has(cur)) {
    seen.add(cur);
    if (MAYBE_SENT.has(cur.name)) return true;
    cur = (cur as { cause?: unknown }).cause;
  }
  return false;
}

export class NonceQueue implements Nonces {
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
        const chain = await this.pending();
        // A send that may have gone out keeps its nonce, so nothing else is sent under it.
        this.next = mayHaveBroadcast(err) && chain <= nonce ? nonce + 1n : chain;
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

/** Thrown by a sender when base fee plus tip would exceed MAX_FEE_GWEI. The relay gives up at once instead of retrying. */
export class GasCapError extends Error {
  constructor() {
    super("gas price above cap");
    this.name = "GasCapError";
  }
}

/** Thrown by a sender when the gas estimate is above the cap for that action. Nothing is sent. */
export class GasLimitError extends Error {
  constructor() {
    super("gas above cap");
    this.name = "GasLimitError";
  }
}

/** Thrown by a sender when the hourly ETH budget has no room for this send. Nothing is sent. */
export class SpendCapError extends Error {
  constructor() {
    super("relay paused");
    this.name = "SpendCapError";
  }
}

/** Gas limit for one send: the estimate plus 20%, never above the cap. An estimate above the cap is refused. */
export function gasLimitFor(estimate: bigint, cap: bigint): bigint {
  if (estimate > cap) throw new GasLimitError();
  const padded = (estimate * 12n) / 10n;
  return padded > cap ? cap : padded;
}

/** ETH the relayer may commit to sends in a rolling window. Each send reserves its worst case, gas limit times max fee. */
export class SpendBudget implements Spend {
  private readonly spends: { at: number; wei: bigint }[] = [];
  private readonly limitWei: bigint;
  private readonly windowMs: number;
  private lastAlert = Number.NEGATIVE_INFINITY;

  constructor(limitWei: bigint, windowMs = 3_600_000) {
    this.limitWei = limitWei;
    this.windowMs = windowMs;
  }

  spent(now: number): bigint {
    while (this.spends.length > 0 && now - (this.spends[0]?.at ?? now) >= this.windowMs) this.spends.shift();
    return this.spends.reduce((sum, row) => sum + row.wei, 0n);
  }

  reserve(wei: bigint, now: number): boolean {
    if (this.spent(now) + wei > this.limitWei) return false;
    this.spends.push({ at: now, wei });
    return true;
  }

  release(wei: bigint, at: number): void {
    const i = this.spends.findIndex((row) => row.at === at && row.wei === wei);
    if (i >= 0) this.spends.splice(i, 1);
  }

  /** True at most once a window, so a pause raises one alert instead of one per request. */
  alertDue(now: number): boolean {
    if (now - this.lastAlert < this.windowMs) return false;
    this.lastAlert = now;
    return true;
  }
}
