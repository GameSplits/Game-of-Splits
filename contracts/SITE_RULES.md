# Site and Marks rules (v3.6)

No contract change; these are rules for the site and the offchain Marks indexer. Alms display rules are in `ALMS_DISPLAY_RULES.md`.

## /pass: the Pass

- Before locking, say plainly: **"Locked for at least 24 hours. You can unlock from <time>."** Compute the time as now + 24h, in the player's local time and in UTC.
- After locking, show a countdown to `FairLens.player(who).passUnlockableAt` (also `FairPass.unlockableAt(who)`). From that moment the unlock button works, and nothing blocks it: not a pause, not the owner.
- Say what can't be undone:
  - the 24 hours applies even if the token's price drops;
  - unlocking and locking again starts a fresh 24 hours;
  - unlocking forfeits the Alms vote for any Chapter whose suggestions are already open.
- An unlock attempt inside the hold reverts `HoldNotOver(until)`. Show "you can unlock at <until>", not a generic error.
- Nobody can lock for someone else or extend someone else's hold (there is no `lockFor`). The page doesn't need to warn about that.
- The pass also gates the Outlaw Camp. The controller needs it to register an outlaw and to enter a round. The
  operator does not. Unlocking does not trap the licence, the bond or the budget: retire and withdraw still pay them out.

## Play token, pass amount and GameConfig updates

- Read the play token, the pass amount and the buy token from `FairLens.configNow()`. Never hardcode a token name or
  "5,000": show the token's symbol and the amount as read.
- Lock with `FairPass.lock(playToken, passLock)` using the values just read. If the config changed before the
  transaction landed it reverts `TokenChanged`: reload the values and ask again.
- While `configNow().tokensEta != 0`, show a banner with the queued play token, pass amount and buy token, and the
  time they can take effect (`tokensEta`). Same for a queued split (`splitEta`).
- A pass locked in an earlier play token doesn't count for play (`player(who).hasPass` is false) but unlocks exactly
  as locked: show "unlock to get back <passAmount> <passToken>" from `player(who)`, never the current values.

## Sheriff's Seat messages

- `SeatTaken` carries both `newHolder` and `payer`. When `payer != newHolder`, show **"posted by <payer>"** under the message, so nobody's name is put on words they didn't write.
- Run every message through the word filter as before. Raw text stays onchain.

## Settled days and rounds

- From v3.6, a day with no takes is never marked settled by a take (it has nothing to pay). Don't show an unsettled day with a 0 pot as "payout pending".
- A past day or round with a non-zero pot that isn't settled yet shows a "Settle" button (`settle` is permissionless). The keeper's settle sweep also covers every unsettled past day and round, not just yesterday.

## Last Arrow near the end of a chapter

- After the chapter's end no shot can land, so the last shot before the end wins the round. In the final hour of a chapter, show **"this round ends when the chapter ends at <time>"**.
- The round itself has no fixed maximum length. It ends when the countdown runs out. Each shot adds 10 minutes, never past 1 hour from now, so a late shot can always be answered until that clock hits zero.
- `round.hardEnd` from `roundState` / `FairLens.arrowNow().round` is always 0. That means there is no hard end. Do not show it, and do not treat 0 as a timestamp or as `min(deadline, hardEnd)`.
- Show the clock from `timeLeft()` / `effectiveDeadline` only.
- Pass `FairLens.arrowNow().expectedRound` (or `nextShotRound()`) to `shoot` as `expectedRound`, never `roundId`. Before the first round and after a round lapses, `roundId` is the old round and a shot opens `roundId + 1`, so `roundId` reverts `WrongRound`. `live` is false then (L-6).

## Marks indexer

- Credit Marks to the `player` (not the `payer`), as today.
- **"Held all chapter"** means the player's current lock (`Locked`) is from before the chapter's start, with no `Unlocked` until the chapter's end.
- **Marks count from the first shot after locking** (decided 25 Oct). There's no minimum lock age: the 24h hold already keeps each stack in one wallet for a day, and a flash loan can't be repaid.
