# Game of Splits watcher

Runs every 2 minutes on **Vercel Pro, in its own project** (not the site's). Holds no private key and no GitHub
credential. Mechanisms: `docs/OPERATIONS.md`.

| endpoint | who calls it | what |
|---|---|---|
| `GET /api/check` | Vercel cron (`vercel.json`), `Authorization: Bearer $CRON_SECRET` | one pass: price sample, events, nonce, gap, stall, heartbeat, ETH |
| `POST /api/sendlog` | the keeper, before each broadcast, `x-gos-signature: HMAC-SHA256(SENDLOG_SECRET, body)` | append-only send log (a second entry for a nonce is kept beside the first, never over it) |
| `GET /api/price` | the keeper | route-A price samples, last 2h (public data) |

## Setup
1. Upstash Redis (free tier is enough): create a database, **turn eviction off**, copy the REST URL and token.
2. Alert channel: one application (token) and one delivery group.
3. Vercel: new project from this folder, Pro plan. Environment variables:
   - `RPC_URL`, `ARCHIVE_RPC_URL` (an RPC that serves `eth_call` at past blocks, e.g. Alchemy; the fill check needs it)
   - `CHAIN_ID` (`4663`), `CORE`, `ARROW`, `SEAT`, `ALMS`, `PASS`, `VAULT`, `START_BLOCK` from `deployments/<chainId>.json`
   - `RAT` (`robinAmongThieves`) and `RAKE_BUYER` (`rakeBuyer`) from the same file (required); optional `FEE_SPLITTER`
   - `KEEPER` (the expected keeper address; update on a planned rotation)
   - `UPSTASH_REDIS_REST_URL`, `UPSTASH_REDIS_REST_TOKEN`
   - `CRON_SECRET`, `SENDLOG_SECRET` (long random strings; `SENDLOG_SECRET` also goes in the keeper's Environment)
   - `PUSHOVER_TOKEN`, `PUSHOVER_GROUP`
   - `HEALTHCHECK_URL` (**required**): a healthchecks.io check, period 2 min, grace 10 min, notifying the Pushover group.
     Clean pass → ping; any error → `/fail`; a stopped cron or a wrong `CRON_SECRET` → no ping. Both alert.
   - `NONCE_START` (**required**): the keeper's nonce at go-live (0 for a fresh key)
   - `OIDC_REPOSITORY` (**required**): `owner/repo` of the keeper's own repo (send-log entries must carry a GitHub
     OIDC token from `.github/workflows/keeper.yml` on `main`; `OIDC_REQUIRED=0` only for local tests)
   - `GO_LIVE_AT`: unix time of `DRY_RUN=0` (the heartbeat counts from it until the first swap)
   - optional `MAINTENANCE_UNTIL` (owner events before then come as one digest), `CONFIRMATIONS` (default 5)
4. Start the watcher **before** the keeper's first live run: the nonce check starts counting from its first pass, and the
   keeper fails closed without 30 minutes of price samples.

The first pass raises "watcher state not found" and "nonce baseline missing" (expected once) and alerts every owner event since `START_BLOCK`, one push per event type (the deploy and the accept batch). That's expected: planned
actions still alert, and a signer acknowledges them.

## Test
`npm test` (unit). End to end with the keeper on a mainnet fork: `bash e2e/keeper_watcher.sh` from the repo root.
Locally: `STATE_FILE=… ALERT_FILE=… node bin/local.mjs check|serve`.
