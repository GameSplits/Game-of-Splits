# lockPairing watcher (A2-13 residual)

A Robin Among Thieves round pairs from a seed. The keeper reveals it by T+3m, or after T+3m anyone may call `fallbackSeed` until T+7m. The seed only counts once `lockPairing` (or the first `pair` call) mixes in the reveal block's hash. That has to happen from a later L2 block, within 256 L2 blocks of the reveal (about 26 seconds), and before T+8m. If nobody locks it in time, the round lapses and is cancelled with full refunds.

The keeper's own `pair` call normally does the lock. The watcher is a second line, so a slow keeper does not cost a round.

## What it does

Every `POLL_MS` (default 2s) it reads the current and previous round.

- Seed revealed, not locked, hash still readable, before T+8m. It calls `lockPairing`.
- No seed after T+3m and `FALLBACK=1`. It calls `fallbackSeed` (until T+7m), then locks on a later poll.
- Seed locked but the round still Open (nobody paired it). It calls `pair(round, 256)` so the round does not cancel
  unpaired at T+8m (L-1).
- Hash window gone (distance 256 or more, I-1), no seed after T+7m, a locked round past T+8m, or a locked round
  that was cancelled. It logs an ALERT line.

Every call is simulated first and skipped if it would revert. Only the keeper key could game timing, and the watcher holds no role, so any funded key works.

## Running it

Dry run is the default and prints what it would send.

```
cd keeper
RPC_URL=<rpc> CHAIN_ID=4663 RAT=<RobinAmongThieves> node src/lockwatch.mjs
```

Live run with its own key (never the keeper key, never committed).

```
RPC_URL=<rpc> CHAIN_ID=4663 RAT=<addr> LOCKWATCH_KEY=<masked secret> PUSHOVER_TOKEN=<secret> PUSHOVER_GROUP=<secret> DRY_RUN=0 FALLBACK=1 node src/lockwatch.mjs
```

`MAX_FEE_GWEI` caps the fee per call (default 1).

## Tests

A live run refuses to start without an alert channel (Pushover, or `ALERT_FILE`), unless `NO_ALERTS=1`. Each
round's alert fires once, not every tick.

`npm test` in `keeper/` runs `test/lockwatch.test.mjs`, which covers the timing windows with no chain.

## Status

Written and unit tested only. It has not been run against a live chain. Where it runs (a small always-on host, not the scheduled keeper workflow, since rounds need second-level reaction) is still open.
