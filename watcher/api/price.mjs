// Read-only: the route-A price samples of the last 2h, for the keeper's 30-minute check. Public data; cached 30 s at the
// edge so a flood of requests can't run up Upstash reads (L2).
import { storeFromEnv } from "../lib/state.mjs";

export async function GET() {
  const cutoff = Math.floor(Date.now() / 1000) - 7200;
  const samples = ((await storeFromEnv(process.env).get("w:price")) ?? []).filter((s) => s.t > cutoff);
  return Response.json({ samples }, { headers: { "cache-control": "public, max-age=0, s-maxage=30" } });
}
