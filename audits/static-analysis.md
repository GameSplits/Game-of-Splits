# Static analysis

Two tools, run more than once, and every High and Medium was triaged by hand. Neither tool replaces a review. A tool result marked "false positive" here means the bad outcome the detector describes can't be reached on the paths that were checked.

Filters for every run: `lib/`, `test/`, `script/` and `src/testnet/` are excluded. `src/testnet/` is testnet-only code and is never deployed on mainnet.

## Runs

| When (2026) | Commit scanned | Slither 0.11.6 | Aderyn 0.6.8 |
|---|---|---|---|
| 4 Nov | Review candidate | 184 results | 3 High detectors, 13 Low detectors, 18 files, 4,086 nSLOC |
| 5 Nov | `main` before the final fixes | 179 results: 8 High, 44 Medium, 82 Low, 45 Informational. 0 new real findings | 3 High detectors (46 instances), 18 Low detectors (228 instances), 19 files, 4,167 nSLOC. 0 new real findings |
| 5 Nov | Deploy candidate (adds the A-02 and RAT-01 fixes) | 181 results. The new rows were 1 Medium, 1 Low and 1 Informational, all intended | Reentrancy-state-change went from 41 to 43 instances, both view calls inside `nonReentrant`. No new High |
| 10 Nov | Deploy commit `0bd046b` | 181 results, **identical** by impact, check and location to the triaged candidate scan. No new rows | Run in the same sweep. No separate Aderyn result was written down (to confirm) |

## Slither High results (all triaged)

| Detector | Location | Decision |
|---|---|---|
| arbitrary-send-erc20 | `FairCore.collect` | By design. Only registered games can call it, and the launch games pass their own `msg.sender` as the payer. A game added later is limited by a per-payer allowance |
| arbitrary-send-eth | `FeeSplitter._pay` | False positive. It pays only a recipient's own escrowed balance, or a rescue that the owner timelocked |
| weak-prng | `LastArrow.shoot` (`shots % RING`) | False positive. This is a ring index, not randomness |
| reentrancy-balance (×4) | `FairCore._swap`, `RakeBuyer.buy`, `Stash._play` (×2) | Intended. The functions are `nonReentrant`, and the balance change is checked against the expected amount. The `FairCore._swap` case was a real Low in an earlier version and was fixed in [`ed72b0a`](https://github.com/GameSplits/Game-of-Splits/commit/ed72b0a) (see findings.md, SWAP-1) |
| uninitialized-state | `SheriffsSeat.top` | False positive. It is written through a storage pointer, and a test checks the top 3 are ranked and paid |

**Medium results:** divide-before-multiply ×1 (intended floor rounding, with the remainder rolling over), incorrect-equality ×12 (sentinel and config checks, not balance equalities), reentrancy-no-eth ×6 (all `nonReentrant`, calling trusted or immutable targets), uninitialized-local ×9 (zero default intended) and unused-return ×16 (unused tuple fields, with swaps measured by balance change). None needs action.

## Aderyn results (all triaged)

| ID | Detector | Decision |
|---|---|---|
| AD-H1 | locks-ether (BuyRouteV3V4) | False positive. `receive()` only accepts ETH from WETH, and the ETH is spent in the same transaction |
| AD-H2 | reentrancy-state-change (41 sites, 43 at deploy) | False positive at every site. A script mapped each line to its function: 20 are `nonReentrant`, 11 are constructors, 5 are `onlyOwner` and 1 is both. The other 4 only make view calls to immutable addresses |
| AD-H3 | unsafe-casting | False positive. The values are bounded constants, timestamps, or come from `uint128` balances. See findings.md RAT-C1 for the one hygiene note |
| AD-L1 to AD-L13 | centralization, costly loops, literals, shadowing, modifier order, revert in loop, address checks, could-be-immutable, unchecked return, uninitialized local, low-level ERC-20 calls, public vs internal | Acknowledged. They are style issues, intended, or already checked elsewhere in the code. Loops are bounded. Centralization is the Safe behind timelocks |

## False-positive recheck

After triage, a separate fresh-eyes pass rechecked every item that had been called a false positive or dismissed. It looked at callers, reachable states, admin and keeper sequences, and how the contracts compose. Where it made sense, it wrote proof-of-concept tests that try to reach the bad outcome.

- 32 deduplicated rows, covering more than 70 raw scanner rows.
- **0 real**, 0 unproven-suspect, 29 still false positive, and 3 not rechecked (testnet-only hits, style-only lows, and duplicates of real findings).
- One hygiene note came out of it: findings.md RAT-C1.

## Secret scanning

gitleaks and trufflehog were run over the full git history of all branches in this repository and the site repository (10 Nov 2026), plus a scan of the working tree. The only hits were the `generic-api-key` rule matching public contract addresses in deployment JSON files, and a public test vector inside the OpenZeppelin library. These are false positives. No hit contained a private key or token.
