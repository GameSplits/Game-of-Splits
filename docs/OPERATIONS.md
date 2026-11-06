# Operations

How the game stays live after deploy. Mechanisms only; no runbooks here.

## Keeper

The Safe sets a keeper address on FairCore. That address alone can settle ended Last Arrow rounds and past Sheriff's Seat days, finalize or release Alms, and run the hourly buybacks (Bonfire and Vault) through the allowlisted routes while the price anchor is seeded for the current GameConfig epoch.

Keeper power is capped on chain: it cannot change GameConfig, move Purses or claims, touch Passes or the Alms destination, raise its own rights, or pause the game. The Safe can revoke the keeper in one transaction.

## Timelocks

GameConfig is Safe-owned with a 7-day timelock on parameter changes (play token, pass amount, buy token, shot split). FeeSplitter ownership changes and rescues use the same 7-day pattern. Pause, unpause and keeper revoke are immediate Safe actions where the contracts allow them.

## Pause and revoke

The Safe can pause new sales. Claims, unlocks and withdrawals still work while paused. Revoking the keeper stops buybacks and settlements until a new keeper is set.

## Lock watcher

Robin Among Thieves rounds pair from a revealed seed. The seed only counts once `lockPairing` (or the first `pair` call) mixes in the reveal block's hash, which must happen from a later L2 block within 256 L2 blocks of the reveal and before the round's deadline. If nobody locks in time, the round lapses with full refunds.

The keeper normally locks when it pairs. An optional lock watcher is a second line that calls `lockPairing` (and, if enabled, `fallbackSeed`) so a slow keeper does not cost a round. It holds no on-chain role; any funded key can run it. See `docs/LOCK_WATCHER.md`.

## Deploy handover

A `forge script --broadcast` run is a series of transactions. Each owned contract is handed to the Safe as soon as its last deployer-only call is done. If a broadcast stops partway, `ResumeHandover` strips whatever the deployer still owns and hands it to the Safe; the partial set is abandoned and redeployed from a fresh EOA. After a clean deploy, the deployer keystore is deleted and leftover gas is swept to the Safe.
