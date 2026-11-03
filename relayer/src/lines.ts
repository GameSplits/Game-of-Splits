// Seat lines. A player's own line for a one-click take is kept off chain, keyed by the take's transaction hash.
// The relayer saves a line only after it has sent that take itself, from an order signed by the player's key,
// so nobody can attach a line to someone else's take. Storage is Upstash Redis over its REST API.

export const MAX_LINE = 64;
const TTL_SECONDS = 60 * 60 * 24 * 120;
const KEY = (hash: string) => `seatline:${hash.toLowerCase()}`;

export interface LineStore {
  set(hash: string, line: string): Promise<void>;
  getMany(hashes: string[]): Promise<Record<string, string>>;
}

/** A small word filter, matched on whole words so "grape" or "scunthorpe" pass. A line that trips it is not saved,
 *  and the take shows its preset line instead. PHRASES are matched with the spaces taken out. */
const WORDS = new Set([
  "nigger", "nigga", "faggot", "fag", "retard", "kike", "spic", "chink", "tranny", "cunt", "rape", "rapist",
  "pedo", "pedophile", "nazi", "hitler", "kys",
]);
const PHRASES = ["killyourself", "seedphrase", "privatekey", "claimnow", "freeairdrop", "sendeth", "sendusdg"];

function deleet(s: string): string {
  return s
    .toLowerCase()
    .normalize("NFKD")
    .replace(/[\u0300-\u036f]/g, "")
    .replace(/[0@]/g, "o")
    .replace(/[1!|]/g, "i")
    .replace(/3/g, "e")
    .replace(/4/g, "a")
    .replace(/[5$]/g, "s")
    .replace(/7/g, "t");
}

export function blocked(s: string): boolean {
  const d = deleet(s);
  const words = d.split(/[^a-z]+/).filter(Boolean);
  if (words.some((w) => WORDS.has(w) || (w.endsWith("s") && WORDS.has(w.slice(0, -1))))) return true;
  const flat = d.replace(/[^a-z]/g, "");
  return PHRASES.some((p) => flat.includes(p));
}

/** Cleans a line: no control characters, no links, single spaces, at most 64 characters. Null when nothing is left
 *  or the filter trips. */
export function cleanLine(raw: unknown): string | null {
  if (typeof raw !== "string") return null;
  let s = raw.replace(/[\u0000-\u001f\u007f-\u009f\u200b-\u200f\u202a-\u202e\u2060-\u2064\ufeff]/g, " ");
  s = s.replace(/\s+/g, " ").trim();
  if (!s) return null;
  s = Array.from(s).slice(0, MAX_LINE).join("").trim();
  if (/(https?:\/\/|www\.|\.(com|io|xyz|net|org|app|gg|fun)\b|t\.me\/|discord\.gg)/i.test(s)) return null;
  if (blocked(s)) return null;
  return s;
}

export function isTxHash(v: unknown): v is string {
  return typeof v === "string" && /^0x[0-9a-fA-F]{64}$/.test(v);
}

export class MemoryLines implements LineStore {
  private map = new Map<string, string>();
  async set(hash: string, line: string) {
    this.map.set(KEY(hash), line);
  }
  async getMany(hashes: string[]) {
    const out: Record<string, string> = {};
    for (const h of hashes) {
      const v = this.map.get(KEY(h));
      if (v) out[h.toLowerCase()] = v;
    }
    return out;
  }
}

/** Upstash REST. Reads KV_REST_API_URL and KV_REST_API_TOKEN (what the Vercel integration sets), or the
 *  UPSTASH_REDIS_REST_* names. The token is sent only in the Authorization header and never logged. */
export class UpstashLines implements LineStore {
  private url: string;
  private token: string;
  private fetcher: typeof fetch;
  constructor(url: string, token: string, fetcher: typeof fetch = fetch) {
    this.url = url;
    this.token = token;
    this.fetcher = fetcher;
  }
  private async cmd(body: unknown[]): Promise<unknown> {
    const r = await this.fetcher(this.url.replace(/\/+$/, "") + "/pipeline", {
      method: "POST",
      headers: { authorization: `Bearer ${this.token}`, "content-type": "application/json" },
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(4000),
    });
    if (!r.ok) throw new Error(`store ${r.status}`);
    return r.json();
  }
  async set(hash: string, line: string) {
    await this.cmd([["SET", KEY(hash), line, "EX", String(TTL_SECONDS)]]);
  }
  async getMany(hashes: string[]) {
    if (hashes.length === 0) return {};
    const res = (await this.cmd([["MGET", ...hashes.map(KEY)]])) as Array<{ result?: Array<string | null> }>;
    const vals = res?.[0]?.result ?? [];
    const out: Record<string, string> = {};
    hashes.forEach((h, i) => {
      const v = vals[i];
      if (typeof v === "string" && v) out[h.toLowerCase()] = v;
    });
    return out;
  }
}

export function lineStoreFromEnv(env: Record<string, string | undefined>): LineStore | null {
  const url = env.KV_REST_API_URL || env.UPSTASH_REDIS_REST_URL;
  const token = env.KV_REST_API_TOKEN || env.UPSTASH_REDIS_REST_TOKEN;
  if (!url || !token || !/^https:\/\//.test(url)) return null;
  return new UpstashLines(url, token);
}
