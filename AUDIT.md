# Internal review

This file is the internal review record for the contracts in this repository. No audit firm has issued a report. Treat the contracts as unaudited. The public docs say the same thing: https://docs.gameofsplits.fun/security

## Static analysis

The production contracts were reviewed with Slither and Aderyn.

Slither 0.11.6 was run at medium and high, with informational and low results excluded, and with `lib`, `test`, `script` and `src/testnet` filtered out. The triage, including which results are intended and which were fixed in the source, is [contracts/SLITHER.md](contracts/SLITHER.md). Re-runs through the v3.6 contracts are in that file. The last recorded Slither set there is 21 medium or high results, each with a verdict.

Aderyn was run in the same internal pass. This file does not attach an Aderyn finding list. Neither tool is a substitute for a firm review.

## Invariant and fuzz testing

Fuzz and invariant settings are in `contracts/foundry.toml`.

- Fuzz: 1,000 runs per test
- Invariant, default profile: 256 runs, depth 200, `fail_on_revert` off
- Invariant, `FOUNDRY_PROFILE=deep`: 1,000 runs, depth 500

On 31 Oct 2026 UTC, Foundry 1.8.6 reported 631 passed, 0 failed and 1 skipped across the two commands in the README (599 plus 1 skip outside `test/fork`, and 32 passed inside `test/fork`). The non-fork run includes the fuzz tests and these invariant suites:

- `contracts/test/invariant/Invariants.t.sol`. Solvency: the USDG balance of FairCore covers `accounted`, and `accounted` equals the sum of purses, rollovers, claims, Alms, toll, Bonfire and the vault ledgers. Booths hold no USDG. The arrow deadline stays within an hour of the last shot plus pause time. Seat seconds credited in a day do not exceed the day. A pause does not block claim or unlock. The pass contract holds exactly the locked $WIF.
- `contracts/test/invariant/ConfigInvariants.t.sol`. The split stays inside the caps. Token and split updates execute only through the timelock and only while no chapter is active. A ratchet reset stays inside its bounds. The anchor epoch does not run ahead of GameConfig.
- `contracts/test/invariant/RatInvariants.t.sol`. Robin Among Thieves USDG equals free balances, reserved stakes, the Sharing Pot and pending rake. Licences match the locked play token. The contract does not own or get approved for an ERC-8004 identity.

The skipped test is `contracts/test/sim/Fair0Sim.fork.t.sol`, which needs the prepared node from `contracts/script/e2e/fair0_sim.sh`.

Fork tests in `contracts/test/fork` are the second command, against the public Robinhood RPC. They were written for Foundry 1.5.x. On this 1.8.6 run, 32 passed and none failed.

## External AI-assisted reviews

External reviews of this code were AI-assisted. They were not an engagement with an audit firm, and no firm signed the result.

The fixed findings are kept as regression tests. A passing test means the reviewed case now holds:

- `contracts/test/audit/Audit36.t.sol`, findings dated 25 Oct 2026 in the file comment, including the unseeded-anchor case
- `contracts/test/audit/ReviewLowsRegression.t.sol`, the low-severity set marked K16 in the tests
- `contracts/test/audit/ReviewSweepRegression.t.sol`, the external review sweep recorded against commit `af57910`
- `contracts/test/audit/FlashPass.fork.t.sol`, the pass flash-loan case

Slither notes and these tests are the written record. Review reports beyond this file have not been published in the repo.

## FairCore swap accounting

Severity: Low.

Status: fixed in [pull request 2](https://github.com/GameSplits/Game-of-Splits/pull/2), merged to `main` on 31 Oct 2026 UTC. The 46630 deployment predates the fix and runs the earlier FairCore.

`FairCore._swap` measured the buy-token balance change on the recipient. The recipient is LocksleyVault or the dead address `0x000000000000000000000000000000000000dEaD`. Permissionless calls can add to those balances while a route is running: `RakeBuyer.forward`, `FeeSplitter.distribute` and `RobinAmongThieves.flushBondBurn`. A route that delivered less than `minOut` could still pass the check, and `Burned` or `BoughtForVault` could report a larger fill than the route delivered.

The change in pull request 2 pays the route output to FairCore, measures the increase on FairCore's own balance, requires that increase to be at least `minOut`, and then transfers exactly that amount to the recipient. Routes, the price floor and the caps are unchanged. The pull request adds `contracts/test/unit/MaliciousRoute.t.sol`.

The pull request also makes FeeSplitter reject FairCore and RakeBuyer as legs and rescue targets, makes RakeBuyer reject FairCore as its vault or `forwardTo`, and makes SafeAccept require that legs, the rake vault and `forwardTo` have no code or are allowlisted. The residual risk is in [SECURITY.md](SECURITY.md#swap-payee-residual). The full suite count above includes these tests. The deep invariant profile passed 7 of 7 (1,000 runs, depth 500).
