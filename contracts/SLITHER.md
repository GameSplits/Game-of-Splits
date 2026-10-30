# Slither triage (slither 0.11.6, medium and high, production contracts only)

Run: `slither . --filter-paths "lib/|test/|script/|src/testnet/" --exclude-informational --exclude-low`

| Finding | Where | Verdict |
|---|---|---|
| arbitrary-from in transferFrom | `FairCore.collect` | **By design.** Only registered booths can call it, and they always pass their own `msg.sender` as the payer. Because players approve FairCore, any registered booth could pull from anyone with a live allowance. Booths are our two contracts, a new booth needs the 48h timelock, and the site approves exact amounts. Disclosed in /docs. |
| divide-before-multiply | `FairCore._swap` ratchet floor | **Fixed**: multiply first. |
| divide-before-multiply | `FairCore.collect` split, `LastArrow._settle` late shares | Intended floor rounding. Dust stays in the Vault ledger or the Purse and rolls over (invariant I1 checks it). |
| reentrancy (no-eth / benign) | `FairCore._swap`, `AlmsVote.releaseAlms`, `LastArrow.shoot` | Every external entry point is `nonReentrant`. The only callees are FairCore, timelocked routes and the v3/v4 pools. Ledgers are written before the external call; only the executed price is recorded after. |
| uninitialized-state `SheriffsSeat.top` | | False positive: written through a storage pointer in `_credit`. |
| uninitialized-local | `paid`, `sum`, `byDefault` | Zero defaults on purpose. |
| unused-return | `swapToWif`, `pm.settle`, `activeFair` | Outputs are re-checked by balance deltas; `settle`'s return equals the delta already checked. |

## v3 re-run

| Finding | Where | Verdict |
|---|---|---|
| reentrancy (benign) | `SheriffsSeat.take` | New with the auto-settle of yesterday (`award` before `collect`). `take` is `nonReentrant`; the callee is FairCore. |
| incorrect-equality | `_swap`, `decayedAnchor` (`== 0` checks) | Intended sentinel checks. |
| divide-before-multiply | `decayedAnchor`, `ratchetFloorRate` | Two single floors; rounding down makes the floor looser than exact by at most 1 unit (negligible). |

## v3.2 additions (re-run on v3.4: still 18 medium/high results, nothing new)

| Finding | Where | Verdict |
|---|---|---|
| incorrect-equality | `FairCore.pausedBetween` (`end == 0` for a pause still running) | Intended sentinel: an open pause has no end yet, so it counts up to `to`. |
| unused-return | `AlmsVote.finalize` reads only `end` from `core.fairs(fairId)` | Only the end is needed for the 7-day never-set fallback; `end == 0` (unknown Fair) reverts. |

## v3.5 re-run (19 medium/high results: the 18 above plus one)

| Finding | Where | Verdict |
|---|---|---|
| unused-return | `AlmsVote.clearWindows` reads only `start` from `core.fairs(fairId)` | Only the start is needed: clearing is allowed only before the Fair starts. A Fair with windows always exists (W1), so `start` is never the zero of an unknown Fair. |

## v3.6 re-run (21 medium/high results: the v3.5 set plus two)

| Finding | Where | Verdict |
|---|---|---|
| incorrect-equality | `FairCore._swap` (`floorRate == 0` → `NotSeeded`) | Intended: this is the v3.6 guard. A zero floor means "not seeded" (or a dust seed that rounds to zero), and no swap may run. |
| incorrect-equality | `FairPass.unlockableAt` (`lockedAt == 0`) | Intended sentinel: 0 means no pass, so the view returns 0. |
