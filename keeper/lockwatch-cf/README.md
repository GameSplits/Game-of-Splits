# lockwatch on Cloudflare (Durable Object)

Port of `keeper/src/lockwatch.mjs` to a Worker + Durable Object whose alarm polls about every 2s.

## Behaviour

- Same `planRound` timing windows, simulate-first skips, `MAX_FEE_GWEI`, `DRY_RUN` default.
- Live mode (`DRY_RUN=0`) refuses to start without Pushover (or `NO_ALERTS=1`).
- Live broadcast of txs is not wired yet in this Worker; keep `DRY_RUN=1` until a secure key path is added.
- Endpoints on the Worker: `POST /start`, `POST /stop`, `POST /tick`, `GET /status`, `GET /logs`.

## Plan and cost

SQLite-backed Durable Objects work on the Workers Free plan. A 2s alarm is about 43k invocations/day, under the free 100k/day request limit, so dry-run testnet fits Free.

For the mainnet chapter, Workers Paid ($5/month) is recommended so a free-tier daily cap cannot stop the loop mid-chapter. Extra cost above the $5 base is usually near zero at this poll rate.

## Deploy (testnet, dry run)

```
cd keeper/lockwatch-cf
npx wrangler secret put RPC_URL   # testnet RPC
npx wrangler deploy
curl -X POST https://gos-lockwatch-testnet.<subdomain>.workers.dev/start
curl https://gos-lockwatch-testnet.<subdomain>.workers.dev/logs
```

Mainnet Worker name is `gos-lockwatch-mainnet` (`wrangler.toml` `[env.mainnet]`). Do not deploy it until the owner approves and `RAT` is set.
