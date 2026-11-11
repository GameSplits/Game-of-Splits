# How the contracts were checked

**No third-party audit.** No audit firm has reviewed or signed off on these contracts. Treat them as unaudited, and don't put in more than you can afford to lose.

This folder records what was done instead: static analysis, tests, independent AI-assisted review passes, internal review, rehearsals on testnet and a mainnet fork, and onchain checks after the deploy. It is a summary, not a guarantee. A passing check means the case that was checked holds. It doesn't mean the code is free of bugs.

All times are UTC unless a line says otherwise.

## What was checked

| Item | Value |
|---|---|
| Contracts | `contracts/src`: FairCore, FairPass, FairLens, GameConfig, LastArrow, SheriffsSeat, RobinAmongThieves, AlmsVote, LocksleyVault, RakeBuyer, FeeSplitter, Stash, SafeHandover and `src/routes` |
| Off-chain code | `relayer/`, `keeper/` (including the lockwatch Worker) and `watcher/` in this repo. The site is in its own repository and is summarised in [site-and-infra.md](site-and-infra.md) |
| Deployed source | Commit [`0bd046b`](https://github.com/GameSplits/Game-of-Splits/commit/0bd046b), Robinhood Chain mainnet (chain id 4663). `contracts/src` has not changed since [`81626b8`](https://github.com/GameSplits/Game-of-Splits/commit/81626b8), and it is the same on `main` today |
| Addresses | [`contracts/deployments/4663.json`](../contracts/deployments/4663.json) |
| Owner | The multisig Safe [`0x7c0fc9869f2D41D88CCA675A9A270214d59DA36a`](https://robinhoodchain.blockscout.com/address/0x7c0fc9869f2D41D88CCA675A9A270214d59DA36a) |
| Toolchain | Foundry 1.8.6, solc 0.8.38, `via_ir`, optimizer 200 runs, EVM `cancun`, OpenZeppelin 5.4.0 |

## Methods

1. **Static analysis.** Slither (0.11.6) and Aderyn (0.6.8) were run on the review candidate and again on the exact deploy commit. Every High and Medium was triaged by hand as fixed, by design or a false positive. Later, a separate fresh-eyes pass rechecked every result that had been dismissed. Details are in [static-analysis.md](static-analysis.md).
2. **Foundry tests.** Unit, fuzz (1,000 runs per test), invariant and fork tests. On contract source identical to the deployed code, the full suite gave **763 passed, 0 failed, 2 skipped** (6 Nov, and again on 11 Nov on `main`, fork tests included). The deep invariant profile (1,000 runs × depth 500, 500,000 calls per invariant) gave **11 of 11 passed**. Details and coverage are in [test-results.md](test-results.md).
3. **Review passes.** The contracts were reviewed in two passes, by area, using independent AI-assisted review. Every reported item was then checked by hand against the code, and each Medium was reproduced with a proof-of-concept test before it was rated. After that came an internal review of the ratings, a review of each fix diff (several rounds for the relayer), a review of the RAT-01 fix, a fresh-eyes recheck of every false positive, and a final read-only review of the deploy commit. A separate pass covered the off-chain services and the site.
4. **Fixes are tested.** Every fixed finding has a test that fails on the old code and passes on the fix, or a regression test under `contracts/test/audit` and `contracts/test/unit`.
5. **Testnet end to end.** Before mainnet, the full deploy was broadcast on Robinhood Chain testnet (46 of 46 transactions), and then the fee splitter deploy, the Safe accept check (run twice), the watcher, and explorer source verification of FairCore, with the exact compiler settings.
6. **Mainnet fork rehearsal.** On a local fork of chain 4663, with a throwaway deployer and nothing sent to the real chain: the deploy ran in 42 transactions. The guards refused a stale testnet environment with the deployer nonce still at 0. The Safe accept check passed twice. A deploy that was killed partway resumed cleanly, and a second resume did nothing.
7. **Live mainnet checks.** After the deploy, read-only calls on chain 4663 (10 Nov 2026) confirmed:
   - `owner()` is the Safe and `pendingOwner()` is zero on all 8 owned contracts: GameConfig, FairPass, FairCore, AlmsVote, LocksleyVault, RobinAmongThieves, RakeBuyer and FeeSplitter;
   - the deployer holds no role;
   - the timelocks are live: 48 hours on FairCore, RakeBuyer and RobinAmongThieves, 7 days on GameConfig, FeeSplitter and the Vault launcher;
   - the FeeSplitter split and legs match the docs;
   - the Stash fee wallet and cap raiser are the Safe.
   
   On 10 Nov, Slither on the deploy commit matched the triaged scan row for row. On 11 Nov, all 8 owned contracts were confirmed to have verified source on Blockscout: 6 exact matches and 2 partial matches (GameConfig, AlmsVote). The links are in [test-results.md](test-results.md#onchain-checks-after-the-mainnet-deploy).
8. **Secret scanning.** gitleaks and trufflehog ran over the full git history of every branch in this repository and the site repository. The only hits were public contract addresses in deployment files, which are false positives. The only env files tracked in git are `.env.example` files with placeholders.
9. **Dependency audit.** `npm audit` reports 0 vulnerabilities in `relayer`, `keeper`, `keeper/lockwatch-cf`, `watcher` and `e2e` (10 Nov 2026).

## Findings at a glance

The full table is in [findings.md](findings.md). No Critical or High finding that could steal funds was found.

| Severity | Found | Fixed | Acknowledged |
|---|---|---|---|
| Critical / High | 0 | – | – |
| Medium | 4 (A-01, RAT-01, relayer N-1, N-2) | 4 | 0 |
| Low | 26 | 7 | 19 |
| Info | 10 | 1 | 9 |

These counts cover the November review passes on the contracts, relayer and watcher. Earlier fixed rounds are listed separately at the end of findings.md. Site findings are in site-and-infra.md.

Acknowledged items need a compromised key, an owner (Safe) action, or a design choice to matter, or they cost the attacker more than they cost anyone else. Each one has its reason in the table.

Tool results that were triaged as false positives are listed in [static-analysis.md](static-analysis.md). They aren't counted above.

## Files

| File | What it covers |
|---|---|
| [findings.md](findings.md) | Every confirmed finding, with severity, status and fix reference |
| [static-analysis.md](static-analysis.md) | Slither and Aderyn results and triage, and the false-positive recheck |
| [test-results.md](test-results.md) | Test counts, run sizes, invariants, coverage, rehearsals |
| [site-and-infra.md](site-and-infra.md) | Site, relayer, watcher and hosting checks, at a summary level |
| [../contracts/SLITHER.md](../contracts/SLITHER.md) | The earlier Slither triage kept with the contracts |
| [../SECURITY.md](../SECURITY.md) | Scope, admin model, timelocks, known limitations and how to report |

## What was not done

- No audit firm review and no formal verification. Symbolic checks (Halmos) were planned as optional and were not run.
- Line coverage for RobinAmongThieves wasn't measured. The coverage build fails with stack-too-deep on that contract. Its behaviour is covered by unit, fuzz and invariant tests instead.
- Coverage was measured on the review candidate, not rerun on the deploy commit.
- Randomness in Robin Among Thieves uses a committed seed chain mixed with the block hash. The sequencer can still influence it, which comes with the chain and isn't something the contracts can remove.
- The ERC-8004 identity and reputation registries, Uniswap pools and hooks, donate.gg and the Safe singleton are third-party code. Calls into them were reviewed. Their own code was not.

## Reporting

See [SECURITY.md](../SECURITY.md#how-to-report). Email support@gameofsplits.fun with `Security:` in the title.
