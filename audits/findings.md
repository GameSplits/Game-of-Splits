# Findings

All confirmed findings from the review passes on the contracts, the relayer and the watcher. Site and hosting findings are summarised in [site-and-infra.md](site-and-infra.md).

**How to read this table**
- **Status.** *Fixed* means the deployed code has the fix, and a test shows it. *Acknowledged* means no code change: the reason is in the table, and the item is either bounded or a design choice. Tool results triaged as false positives are in [static-analysis.md](static-analysis.md).
- **Severity.** This is the final rating after review. Several items were re-rated when their proof-of-concept was checked against the code, and the table shows the rating after that.
- **Fix reference.** A commit on `main` in this repository. Review notes from before the 6 Nov 2026 history cleanup cite older commit IDs that no longer exist, so those fixes are referenced here by their current commit, or by file and function.
- **Deployed source.** `contracts/src` at deploy commit `0bd046b` is the same tree as `main` today.

No Critical or High finding that could steal funds was found.

## Medium

| ID | Area | Title | Status | Fix reference |
|---|---|---|---|---|
| A-01 | Stash | If the USDG issuer froze the fee wallet, withdrawals and relayed plays would revert, because the fee was pushed on every call | Fixed | [`1093d3c`](https://github.com/GameSplits/Game-of-Splits/commit/1093d3c): fees build up in `feesAccrued` and leave through a separate `flushFees()`. Tests: `test/unit/StashFeesAndNonces.t.sol`, `test/invariant/StashInvariants.t.sol` |
| RAT-01 | RobinAmongThieves | One controller with one Pass could enter many outlaws in a round and fill all seats | Fixed | [`e2e2fce`](https://github.com/GameSplits/Game-of-Splits/commit/e2e2fce): `MAX_ENTRIES_PER_CONTROLLER = 3` per round. Test: `test/unit/RatEntryCap.t.sol`. The original proof-of-concept passes on the old code and reverts `TooManyEntries()` on the fix |
| N-1 | relayer | A contract wallet with a gas-heavy ERC-1271 check could make the relayer pay for very large transactions, draining its gas balance. User funds were not at risk, since direct calls still work | Fixed | [`126de6d`](https://github.com/GameSplits/Game-of-Splits/commit/126de6d) (verify every signature, per-action gas cap, hourly ETH budget) and [`783a0fd`](https://github.com/GameSplits/Game-of-Splits/commit/783a0fd) (balance gate on key actions). Same issue as S-7 and R-03 in the review notes |
| N-2 | relayer | Junk-signature orders naming a player could use up that player's relay rate limit and lock them out of gasless plays for an hour | Fixed | [`126de6d`](https://github.com/GameSplits/Game-of-Splits/commit/126de6d): per-wallet limits count only calls that verify and are sent. Same issue as R-01 in the review notes |

## Low

| ID | Area | Title | Status | Fix reference or reason |
|---|---|---|---|---|
| A-03 | Stash | A signed but unsubmitted key authorisation could survive a direct revoke | Fixed | [`1093d3c`](https://github.com/GameSplits/Game-of-Splits/commit/1093d3c): direct `authorizeKey`, `setLimit` and `revokeKey` use the nonce, plus a new `cancelNonce()` |
| A-02 | LastArrow | Because the chapter end is a hard stop, a shot in the final seconds could open a round that nobody else can answer | Fixed | [`449813a`](https://github.com/GameSplits/Game-of-Splits/commit/449813a): no new round opens in the last hour of a chapter (`ChapterEndingSoon`). Test: `test/unit/ArrowChapterEnd.t.sol`. ARCH-01 is a duplicate |
| SWAP-1 | FairCore | The swap output was measured on the recipient, so a route that delivered less than `minOut` could still pass. Found in an earlier review | Fixed | [`ed72b0a`](https://github.com/GameSplits/Game-of-Splits/commit/ed72b0a): FairCore measures its own balance and then forwards. Tests: `test/unit/MaliciousRoute.t.sol`, `test/unit/SwapOwnBalance.t.sol`. See [SECURITY.md](../SECURITY.md#swap-payee-residual) for the residual |
| RAT-F1 | RobinAmongThieves | After the RAT-01 fix, the contract had only 7 bytes of headroom under the EIP-170 size limit | Fixed | [`81626b8`](https://github.com/GameSplits/Game-of-Splits/commit/81626b8): trimmed to 24,109 B (467 B spare), and CI now runs a size check |
| RL-01 | relayer | Chain id and Stash were hardcoded to testnet | Fixed | [`a847516`](https://github.com/GameSplits/Game-of-Splits/commit/a847516): per-chain config that refuses any other chain |
| RL-02 | relayer | Default CORS accepted a pattern of preview hosts | Fixed | [`c1baf11`](https://github.com/GameSplits/Game-of-Splits/commit/c1baf11): exact origin allowlist. Checked live on 10 Nov 2026: other origins get no CORS header |
| DP-5 | watcher | A malformed token payload caused a server error instead of a clean refusal. It was only reachable after the HMAC check | Fixed | [`9c342aa`](https://github.com/GameSplits/Game-of-Splits/commit/9c342aa) |
| S-1 | Stash | Owner and key orders share one nonce, so a compromised session key could invalidate a relayed revoke | Acknowledged | It needs the key, the loss is capped by the session limit, and a direct `revokeKey()` always works |
| S-2 | Stash | A key holder can front-run a limit cut | Acknowledged | It needs the key, and the owner can revoke |
| S-3 | Stash | A relayed Seat take has no expected-day field | Acknowledged | The price stays at or below the signed `maxPrice`, and the signed deadline bounds the delay |
| S-4 | Stash | A booth re-added after setup would need a new approval from Stash | Acknowledged | An operations note. No booth change is planned |
| S-5 | Stash | The shot fee is not part of the signed key authorisation | Acknowledged | Only the Safe can change the fee, and it is capped by `MAX_SHOT_FEE` |
| S-6 | Stash | One large depositor can fill the deposit cap | Acknowledged | The cap raiser is the Safe (confirmed onchain) and can raise the cap |
| C-5 | FairCore | Spend and winnings can be credited to different chapters when a round spans a chapter boundary. This only feeds AlmsVote eligibility | Acknowledged | Chapters are scheduled so no round spans the boundary. See SECURITY.md |
| C-6 | FairCore | A compromised keeper could step the price anchor up with dust swaps | Acknowledged | Capped at about 2% per 4-hour window, and the Safe can revoke the keeper at once |
| C-7 | FairCore | A queued ratchet reset can be invalidated if the anchor moves | Acknowledged | Operational. Leave headroom when queueing |
| T-2 | SheriffsSeat | Takes in the same second credit 0 seconds | Acknowledged | A design choice |
| P-1 | FairPass | Rotating the play token would affect passes locked in the last 24 hours | Acknowledged | Owner-only, timelocked, and announced in advance. No rotation is planned |
| RB-01 | RakeBuyer | After an owner `reconcile`, part of a pending leg could be stranded | Acknowledged | Owner-only path, small amounts |
| RB-02 | RakeBuyer | Same pattern as C-6 for RakeBuyer | Acknowledged | Capped per window, and the keeper can be revoked |
| LV-01 | LocksleyVault | The launcher chooses the USDG recipient when it pulls | Acknowledged | No launcher is attached. Attaching one takes a 7-day timelock and can only happen once |
| AV-01 | AlmsVote | A charity can't be removed once it is eligible | Acknowledged | Eligible ids were checked against the live donate.gg pages before the deploy |
| SEAT-01 | FairCore / SheriffsSeat | `setFair` doesn't force chapter start and end onto 00:00 UTC | Acknowledged | The mainnet chapter dates are on 00:00 UTC. SheriffsSeat enforces a midnight-aligned day on chain 4663 |
| RAT-02 | RobinAmongThieves | The keeper seed reveal and player reveal windows are short, so a keeper outage cancels rounds | Acknowledged | Cancelled rounds refund in full (invariant `noUsdgStuckAfterCancel`), and anyone can call `fallbackSeed` |
| WA-01 | watcher | No alert when one of the two swap simulations is unusable | Acknowledged | Monitoring only. Onchain floors still bound `minOut` |
| WA-02 | watcher | Several detection gaps were reported but not confirmed line by line | Acknowledged | Monitoring only, with no fund risk. Kept in the watcher backlog |

Later fix-review rounds on the relayer looked at send safety: ambiguous broadcast errors, timeouts, nonce gaps, shared-store errors and claim hold times. Every issue they raised that could double-send or double-charge was fixed and rechecked before the relayer work was merged ([`2f851dd`](https://github.com/GameSplits/Game-of-Splits/commit/2f851dd)).

## Info

| ID | Area | Title | Status |
|---|---|---|---|
| C-3 | FairCore | A swap route can't be set to zero | Acknowledged. The owner can replace the route, or revoke the keeper |
| C-4 | FairCore | Queued timelock operations never expire | Acknowledged. Only the Safe can execute them |
| P-2 | GameConfig | Queued updates have no expiry | Acknowledged. Same reason as C-4 |
| T-1 | SheriffsSeat | A payer can take the seat for another address | Acknowledged. The payer pays every time |
| R-1 | LastArrow | Same pattern as T-1 | Acknowledged |
| I-1 | FairCore, RakeBuyer, RAT | Daily caps can allow a burst across midnight UTC | Acknowledged. No day index ever exceeds its cap |
| I-2 | Stash | An order pre-signed at the next nonce survives a cancel of the current one | Acknowledged. This comes with sequential nonces |
| I-3 | Stash | Direct owner actions now use the nonce, so clients must re-read it | Acknowledged. The site and relayer re-read it |
| RAT-F2 | RobinAmongThieves | Entry-count decrements did nothing and cost gas | Fixed in [`81626b8`](https://github.com/GameSplits/Game-of-Splits/commit/81626b8) |
| RAT-C1 | RobinAmongThieves | Two `uint128` casts in bond and deposit truncate silently past 2^128 units | Acknowledged. Reaching it needs more than 3.4e20 whole tokens in one position, and only the caller would be hurt |

## Earlier review rounds (before the November passes)

These were found and fixed before the review candidate was cut. They are listed for completeness.

| ID | Area | Title | Status | Fix reference |
|---|---|---|---|---|
| A1-11 | FairCore | A booth added later could pull USDG from any wallet that approved FairCore (threat model item rated High) | Fixed | Per-booth, per-generation allowance (`_boothAllowance` in FairCore) |
| A1-12 | FairCore, RakeBuyer | A ratchet reset took effect immediately (threat model item rated High) | Fixed | `ResetRatchet` goes through the 48-hour timelock |
| SW-01 | RobinAmongThieves | Reputation laundering through self-approval (Medium) | Fixed | [`833f4d3`](https://github.com/GameSplits/Game-of-Splits/commit/833f4d3). Tests: `test/unit/RatSelfApproval.t.sol`, `test/fork/Rat8004SelfApproval.fork.t.sol` |
| A5-01 | AlmsVote | Sybil voting (Medium) | Fixed | `MIN_VOTE_SPEND` gate in AlmsVote |
| ES-01 | SheriffsSeat | The seat price kept sliding during a pause (Low) | Fixed | [`833f4d3`](https://github.com/GameSplits/Game-of-Splits/commit/833f4d3). Test: `test/unit/SeatPausePrice.t.sol` |

Earlier external AI-assisted review sets are also kept as regression tests: `test/audit/Audit36.t.sol`, `test/audit/ReviewLowsRegression.t.sol`, `test/audit/ReviewSweepRegression.t.sol` and `test/audit/FlashPass.fork.t.sol`.
