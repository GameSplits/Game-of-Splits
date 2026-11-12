# Tests and rehearsals

Settings are in [`contracts/foundry.toml`](../contracts/foundry.toml):
- Fuzz: 1,000 runs per test.
- Invariants, default profile: 256 runs, depth 200.
- Invariants, `FOUNDRY_PROFILE=deep`: 1,000 runs, depth 500.

CI (`.github/workflows/ci.yml`) builds with `--sizes`, runs the size check and runs the non-fork suite on every push to `main` and on every pull request. The keeper, watcher and relayer packages run their own tests in CI.

## Foundry suite

| Run (2026) | Source | Result |
|---|---|---|
| 6 Nov, fresh clone of `main` at `a619170` | `contracts/src` identical to the deploy commit `0bd046b` | **763 passed, 0 failed, 2 skipped** (765 total). Both skips are intentional: `test_fair0_fullSimulation` needs a prepared simulation node, and `test_staleTestnetEnvRefused_pinnedEnvPasses` runs alone, gated by `ROLES_ENV_TEST=1`, because it sets process-wide env. That test passes when run on its own |
| 6 Nov, after the history cleanup | Same `contracts/src` tree | 763 passed, 0 failed, 2 skipped. Compiled bytecode was compared before and after the cleanup: 217 of 217 artifacts identical |
| 5 Nov, deploy candidate | Same `contracts/src` | Non-fork: 715 passed, 0 failed, 1 skipped (74 suites). Fork suite against the public chain 4663 RPC, read-only: 36 of 36 passed (10 suites) |
| 11 Nov, fresh clone of `main` at `5611e9f`, full `forge test` including the read-only fork tests | Same `contracts/src` as the deploy commit | **88 suites, 763 passed, 0 failed, 2 skipped** (the same two intentional skips) |

Test layout: `test/unit` (39 files), `test/fork` (12), `test/invariant` (4), `test/audit` (4 regression files for earlier reviews), `test/sim` (1).

## Invariants

**In the repository** (`contracts/test/invariant`, 4 suites):
- `Invariants.t.sol`. USDG solvency: FairCore's balance covers `accounted`, and `accounted` equals the sum of the ledgers. The two games hold no USDG. The arrow clock stays bounded. Seat seconds credited in a day never exceed the day. A pause never blocks claim or unlock. The Pass contract holds exactly the locked $wif.
- `ConfigInvariants.t.sol`. The split stays inside its caps. Token and split changes go only through the timelock, and only between chapters. Ratchet resets stay bounded.
- `RatInvariants.t.sol`. Robin Among Thieves USDG equals free balances plus reserved stakes, the Sharing Pot and pending rake. The contract never owns an ERC-8004 identity.
- `StashInvariants.t.sol`. `balanceOf(Stash) >= totalHeld + feesAccrued`, and fee accounting is exact.

| Run (2026) | Profile | Result |
|---|---|---|
| 6 Nov, final pre-mainnet review, `contracts/src` identical to the deploy | deep: 1,000 runs × depth 500 = 500,000 calls per invariant | **4 suites, 11 of 11 passed**, 0 failed |
| 5 Nov, deploy candidate | deep | 4 suites passed. Config, Stash, RAT and Fair each made 500,000 calls |

**Extra review invariants.** For the review, 10 more invariants were written in a separate harness:
- FairPass: `unlockReturnsExactLock`, `noUnlockBeforeMinHold`, `lockedSumEqualsBalance`
- FairCore and RakeBuyer: `swapCapsRespected`
- LocksleyVault: `vaultConservation`
- AlmsVote: `almsConservation`
- RakeBuyer: `rakeBuyerHoldsNothingBetweenCalls`
- Robin Among Thieves: `passGate`, `potEqualsClaimsPlusSplit`, `noUsdgStuckAfterCancel`

They were run on the review candidate. All 10 passed at 256 runs × depth 150 (core) and 128 × 120 (RAT), and again at 1,000 runs × depth 200: 200,000 calls for the core set and 200,000 for the RAT set, with 0 reverts. Coverage checks in the handlers confirm that the actions really ran, so the invariants weren't trivially true. *These harness files are not in the repository yet.*

## Coverage

Measured on the review candidate with `forge coverage --ir-minimum`. The `via_ir` build needs that flag, and it makes the numbers approximate. RobinAmongThieves is excluded, because the coverage build hits stack-too-deep on it.

| Scope | Lines | Statements | Branches | Functions |
|---|---|---|---|---|
| All measured contracts | 89.71% (1430/1594) | 87.38% (1932/2211) | 71.63% (351/490) | 86.72% (209/241) |

Per contract (lines): GameConfig 100%, LastArrow 100%, SheriffsSeat 100%, RakeBuyer 96.4%, FairPass 96.4%, AlmsVote 95.6%, LocksleyVault 95.2%, FairCore 91.9%, BuyRouteV3V4 90.2%, BuyRouteV4 86.7%, Stash 85.0%, FeeSplitter 82.6%, FairLens 37.7% (view helpers), SafeHandover 0% (a deploy helper, exercised by the deploy rehearsals rather than unit tests).

Coverage wasn't rerun on the deploy commit. Since that run, the only changes to `contracts/src` were the Stash fixes, A-02 and RAT-01, and each came with its own tests.

## Proofs of concept

Each Medium, and most Lows, were reproduced with a test before they were rated. On 4 Nov 2026 all Foundry proofs of concept and verification tests passed (16 tests), along with the relayer proofs of concept (2 of 2) and the site support proof of concept (1 of 1). Each fix was then checked by rerunning its proof of concept against the fix. For RAT-01, the original proof of concept passes on the old code (2 of 2) and fails on the fix with `TooManyEntries()`. The RAT-01 fix review added 10 more tests, all passing.

## Off-chain packages

| Package | Result |
|---|---|
| relayer | 137 tests: 136 passed, 1 skipped (mainnet config branch, 5 Nov) |
| keeper (including lockwatch) | 54 passed, with lockwatch 8 of 8 (6 Nov) |
| watcher | 50 of 50 (6 Nov) |
| `npm audit` | 0 vulnerabilities in relayer, keeper, keeper/lockwatch-cf, watcher and e2e (10 Nov) |

## Rehearsals

**Testnet (chain 46630), real broadcasts:**
- the deploy ran 46 of 46 transactions, then the FeeSplitter deploy;
- a rerun of the FeeSplitter deploy correctly sent nothing;
- the Safe accept check passed twice;
- the watcher saw the setup events.

Explorer source verification was rehearsed on the testnet FairCore with the exact compiler settings (solc 0.8.38, optimizer 200, `viaIR`, `cancun`).

**Mainnet fork (local fork of chain 4663, throwaway deployer, nothing sent to the real chain):**
- the guards refused a stale testnet keeper, toll recipient or charity list, with the deployer nonce still 0;
- the deploy completed in 42 transactions, followed by the FeeSplitter deploy;
- the Safe accept check passed twice;
- a broadcast killed partway resumed cleanly, and a second resume was a no-op.

The fork used the real Safe address. The gas estimate was about 32.65M.

## Onchain checks after the mainnet deploy

Read-only calls on chain 4663 on 10 Nov 2026 (the block is noted in [SECURITY.md](../SECURITY.md)):
- `owner()` is the Safe and `pendingOwner()` is zero on GameConfig, FairPass, FairCore, AlmsVote, LocksleyVault, RobinAmongThieves, RakeBuyer and FeeSplitter;
- the Safe runs v1.5.0 with no modules and no guard, and the deployer isn't an owner and holds no role;
- the timelocks are live as listed in SECURITY.md;
- the FeeSplitter split is 0/5000/0/4000/1000 (purses/vault/rebate/burn/ops). The vault leg is LocksleyVault, and the other legs are the Safe;
- on Stash, the fee wallet and cap raiser are the Safe, and the core, arrow and seat match the deployment file;
- LastArrow, SheriffsSeat and FairLens have no owner, by design;
- LocksleyVault has no launcher attached, and RakeBuyer has no forward recipient.

**Source verification on Blockscout (checked in a browser, 11 Nov 2026).** All 8 owned mainnet contracts show verified source. None are proxies. Compiler v0.8.38, EVM `cancun`, optimizer 200 runs.

| Contract | Address | Match |
|---|---|---|
| GameConfig | [`0xfCEE3b97e94516668300c649212822dbe4eC5191`](https://robinhoodchain.blockscout.com/address/0xfCEE3b97e94516668300c649212822dbe4eC5191?tab=contract) | Partial (source and ABI shown, metadata differs) |
| FairPass | [`0xdB75122e1e53215f77F6C1F3B9D7E51d9D983709`](https://robinhoodchain.blockscout.com/address/0xdB75122e1e53215f77F6C1F3B9D7E51d9D983709?tab=contract) | Exact |
| FairCore | [`0x4fbfdaAE32BC1C8F43Ce8BDBE25445C6B8718458`](https://robinhoodchain.blockscout.com/address/0x4fbfdaAE32BC1C8F43Ce8BDBE25445C6B8718458?tab=contract) | Exact |
| AlmsVote | [`0xaA3Ce43Bf69E1e76beBE56d014Fe659175EAbA71`](https://robinhoodchain.blockscout.com/address/0xaA3Ce43Bf69E1e76beBE56d014Fe659175EAbA71?tab=contract) | Partial (source and ABI shown, metadata differs) |
| LocksleyVault | [`0x794A1D6dFD20b4da712B35AffDf7938861a2Dea2`](https://robinhoodchain.blockscout.com/address/0x794A1D6dFD20b4da712B35AffDf7938861a2Dea2?tab=contract) | Exact |
| RobinAmongThieves | [`0x586d69120F27e04933684fe38f903ae86Bde7c2F`](https://robinhoodchain.blockscout.com/address/0x586d69120F27e04933684fe38f903ae86Bde7c2F?tab=contract) | Exact |
| RakeBuyer | [`0xdd5127199C68B5bE28671ade6af1D66BD9f7af3A`](https://robinhoodchain.blockscout.com/address/0xdd5127199C68B5bE28671ade6af1D66BD9f7af3A?tab=contract) | Exact |
| FeeSplitter | [`0x142c0A0a19E85165Aadb8310E7a2A6081122F5ef`](https://robinhoodchain.blockscout.com/address/0x142c0A0a19E85165Aadb8310E7a2A6081122F5ef?tab=contract) | Exact |

A partial match means the verified source and ABI are shown, but the compiler metadata hash differs from the deployed bytecode's.
