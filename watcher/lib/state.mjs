// Watcher state. Production: Upstash Redis over its REST API (no SDK). Tests: a JSON file.
// Keys: "w:state" (dedupe, strikes, ETH samples), "w:scan" (event scan position + the fill queue), "w:nonce" (the nonce baseline, its own key so a lost
// w:state can't silently re-baseline it), "w:price" (route-A samples), "w:lock" (one pass at a time),
// "w:sendlog:<chainId>:<nonce>" (a list per keeper nonce, append-only, written only by the send-log endpoint).
// Turn Upstash eviction OFF: an evicted key must never look like "no data yet".
import { readFileSync, writeFileSync, existsSync } from "node:fs";

export function upstashStore(url, token) {
  const cmd = async (...args) => {
    const r = await fetch(url, { method: "POST", headers: { authorization: `Bearer ${token}` }, body: JSON.stringify(args) });
    if (!r.ok) throw new Error(`upstash HTTP ${r.status}`);
    const j = await r.json();
    if (j.error) throw new Error(`upstash: ${j.error}`);
    return j.result;
  };
  return {
    get: async (k) => {
      const v = await cmd("GET", k);
      return v == null ? null : JSON.parse(v);
    },
    set: async (k, v) => void (await cmd("SET", k, JSON.stringify(v))),
    del: async (k) => void (await cmd("DEL", k)),
    // one pass at a time: SET key value NX EX ttl
    lock: async (k, id, ttlS) => (await cmd("SET", k, id, "NX", "EX", String(ttlS))) === "OK",
    // atomic compare-and-delete (review N10): only the pass that took the lock can release it
    unlock: async (k, id) => void (await cmd("EVAL", "if redis.call('get', KEYS[1]) == ARGV[1] then return redis.call('del', KEYS[1]) else return 0 end", "1", k, id)),
    rpush: async (k, v) => Number(await cmd("RPUSH", k, JSON.stringify(v))),
    lrange: async (k) => ((await cmd("LRANGE", k, "0", "-1")) ?? []).map((x) => JSON.parse(x)),
  };
}

export function fileStore(path) {
  const load = () => (existsSync(path) ? JSON.parse(readFileSync(path, "utf8")) : {});
  const save = (d) => writeFileSync(path, JSON.stringify(d, null, 1));
  const mut = (fn) => {
    const d = load();
    const r = fn(d);
    save(d);
    return r;
  };
  return {
    get: async (k) => load()[k] ?? null,
    set: async (k, v) => mut((d) => void (d[k] = v)),
    del: async (k) => mut((d) => void delete d[k]),
    lock: async (k, id, ttlS) => mut((d) => {
      const cur = d[k];
      if (cur && cur.exp > Date.now() / 1000) return false;
      d[k] = { id, exp: Date.now() / 1000 + ttlS };
      return true;
    }),
    unlock: async (k, id) => mut((d) => {
      if (d[k]?.id === id) delete d[k];
    }),
    rpush: async (k, v) => mut((d) => (d[k] = [...(d[k] ?? []), v]).length),
    lrange: async (k) => load()[k] ?? [],
  };
}

export function storeFromEnv(env) {
  if (env.STATE_FILE) return fileStore(env.STATE_FILE);
  // Vercel Marketplace Upstash names (KV_*) first, then the plain Upstash names — same order as the relayer.
  const url = (env.KV_REST_API_URL ?? env.UPSTASH_REDIS_REST_URL ?? "").trim();
  const token = (env.KV_REST_API_TOKEN ?? env.UPSTASH_REDIS_REST_TOKEN ?? "").trim();
  if (url && token) return upstashStore(url, token);
  throw new Error("watcher needs KV_REST_API_URL + KV_REST_API_TOKEN (or UPSTASH_REDIS_REST_URL + UPSTASH_REDIS_REST_TOKEN, or STATE_FILE in tests)");
}
