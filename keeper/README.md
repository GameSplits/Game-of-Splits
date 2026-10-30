# Game of Splits keeper

One idempotent pass per hourly run: settle ended Last Arrow rounds and past Sheriff's Seat days, finalize/release Alms,
then buy the buy token (`FairCore.buyToken()`, $wif at launch) for the Bonfire, the Vault burn and the Vault buy, one
ledger at a time, only through routes whose `tokenOut()` is that token, and only while the anchor is seeded for the
current GameConfig epoch. Rules: `contracts/RUNBOOK_KEEPER.md`.

**DRY_RUN is on unless `DRY_RUN=0`.** It stays on until the owner's explicit approval for keeper go-live.

## Where it runs
Its own private GitHub repo (only this folder), GitHub Actions hourly: copy `workflow/keeper.yml` to
`.github/workflows/keeper.yml` there. The key is a secret in an Environment named `keeper` (no other workflow, no other
repo). The watcher runs elsewhere (Vercel) and holds no GitHub credential.

## Settings (Environment `keeper`)
| name | kind | value |
|---|---|---|
| `KEEPER_KEY` | secret | the keeper's private key (a fresh key, ETH for gas only; set by the owner, never pasted anywhere else) |
| `RPC_URL` | secret | Robinhood Chain RPC |
| `SENDLOG_SECRET` | secret | same value as the watcher's |
| `PUSHOVER_TOKEN`, `PUSHOVER_GROUP` | secret | the Pushover app token and delivery group |
| `CHAIN_ID` | var | `4663` (testnet `46630`) |
| `CORE`, `ARROW`, `SEAT`, `ALMS` | var | from `deployments/<chainId>.json` |
| `KEEPER_ADDRESS` | var | the keeper's address (dry runs before the key is set) |
| `WATCHER_URL` | var | the watcher's base URL |
| `DRY_RUN` | var | `1` until go-live |
| `MAX_FEE_GWEI` | var | optional fee ceiling (default 1) |

GitHub settings for the keeper repo: private; Environment `keeper` limited to the `main` branch with the owner as required
reviewer; secret scanning and push protection on; 2FA by passkey or hardware key. The workflow's `id-token: write`
gives each run a GitHub OIDC token that goes with every send-log entry, so a key used off GitHub can't log.

## Before every send
simulate with the exact args → sign → log `{nonce, hash, to, selector}` to the watcher (HMAC-signed) → broadcast →
wait. If the log is refused, it doesn't send. Buybacks also need ≥ 4 watcher price samples in the last 30 minutes
within 2% of the current quote (fail closed), and the onchain keeper must be this address.

## Test
`npm test` (unit). End to end with the watcher on a mainnet fork: `bash e2e/keeper_watcher.sh` from the repo root.

## lockPairing watcher

`src/lockwatch.mjs` is a separate, optional process that locks a revealed RAT pairing seed (and optionally calls `fallbackSeed`) if the keeper is slow. It uses its own key, `LOCKWATCH_KEY`. See `docs/LOCK_WATCHER.md`.
