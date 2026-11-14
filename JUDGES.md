# Five minute tour

Repos for judges:

- Contracts, keeper and watcher: this repository ([GameSplits/Game-of-Splits](https://github.com/GameSplits/Game-of-Splits))
- Site frontend: [GameSplits/gos-site](https://github.com/GameSplits/gos-site) (private; hackathon judges are invited with read access)

Chain: **Robinhood Chain mainnet, chain id 4663.** Gas is ETH. RPC `https://rpc.mainnet.chain.robinhood.com`. Explorer: https://robinhoodchain.blockscout.com. Every address is in [`contracts/deployments/4663.json`](contracts/deployments/4663.json) (deploy start block 107503866).

The play token and the buy token are $WIF (`0x5173b8eA6923c2d40267890D45C46a3480954773`, 18 decimals). Shots are paid in USDG (`0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168`, 6 decimals). Times below are UTC.

Chapter 1 on mainnet ran from 12 Nov 2026 00:00 UTC to 14 Nov 2026 00:00 UTC (`fairs(0)` on FairCore). Chapter 2 is live from 14 Nov 2026 00:00 UTC to 21 Nov 2026 00:00 UTC (`fairs(1)`). Outside a chapter a new shot or take reverts `NoActiveFair`. Passes, claims and reads work at any time.

Chapters are numbered from 1 for players. Onchain, Chapter 1 is fairs(0) and Chapter 2 is fairs(1) in FairCore. The site and docs.gameofsplits.fun use the same names. The live window is always the one FairCore reports as active.

## What to click

1. Open https://gameofsplits.fun and connect a wallet on chain 4663. The site asks to switch network if the wallet is elsewhere. You need a little ETH for gas, USDG to play and 5,000 $WIF for a Pass. The [Trading Post](https://gameofsplits.fun/trading-post) is the in-site way to get USDG and $WIF.
2. Open the [Toll Gate](https://gameofsplits.fun/pass). Approve $WIF and lock 5,000 in FairPass. The hold is 24 hours. Unlock returns the 5,000 $WIF to the same wallet.
3. Open [Last Arrow](https://gameofsplits.fun/last-arrow) (the Archery Glade) and the [Sheriff's Seat](https://gameofsplits.fun/sheriffs-seat). Read the price, the clock and the purse, then shoot or take during a chapter. The Seat day is 86,400 seconds and ends at 00:00 UTC.
4. Open the [Satchel](https://gameofsplits.fun/satchel). It shows winnings held on FairCore and the Stash balance. `claim` works even while sales are paused.
5. Open the [Friar's Chapel](https://gameofsplits.fun/alms) (Alms vote) and [The Ledger](https://gameofsplits.fun/analytics), which reads the Greenwood ledgers from FairLens and the event history.
6. Open the [Outlaw Camp](https://gameofsplits.fun/robin) (Robin Among Thieves). Read `entriesPaused()` on the contract first: the Safe keeps entries paused until the camp opens, and `enter` reverts `EntriesArePaused` while it is set. The licence is 1,000 $WIF and the rake goes to RakeBuyer.
7. Docs: https://docs.gameofsplits.fun, with every address on https://docs.gameofsplits.fun/contracts.

## Mainnet contracts

Read on chain 4663 (block 110,246,188, 10 Nov 2026). Every address below has code, and every `owner()` is the Safe with `pendingOwner()` zero.

| Contract | Address | Source | Notes |
| --- | --- | --- | --- |
| GameConfig | [0xfCEE…5191](https://robinhoodchain.blockscout.com/address/0xfCEE3b97e94516668300c649212822dbe4eC5191) | `contracts/src/GameConfig.sol` | `tokens()` is $WIF / 5,000 / $WIF. `delay()` is 7 days |
| FairCore | [0x4fbf…8458](https://robinhoodchain.blockscout.com/address/0x4fbfdaAE32BC1C8F43Ce8BDBE25445C6B8718458) | `contracts/src/FairCore.sol` | the USDG book. `timelockDelay()` is 48 hours |
| FairPass | [0xdB75…3709](https://robinhoodchain.blockscout.com/address/0xdB75122e1e53215f77F6C1F3B9D7E51d9D983709) | `contracts/src/FairPass.sol` | 24 hour hold, exact-amount check |
| FairLens | [0x3838…0970](https://robinhoodchain.blockscout.com/address/0x3838b0C4b00919d3fEFB0F00e80468bF33960970) | `contracts/src/FairLens.sol` | read-only views, holds nothing |
| LastArrow | [0x3D50…8516](https://robinhoodchain.blockscout.com/address/0x3D50EdFa6E22d901ec567cE27842F4DBE2068516) | `contracts/src/LastArrow.sol` | game, no owner |
| SheriffsSeat | [0x61bC…5c0F](https://robinhoodchain.blockscout.com/address/0x61bC2Af907912c4279F610D82681320F96e25c0F) | `contracts/src/SheriffsSeat.sol` | game, no owner, `dayLength()` 86,400 |
| AlmsVote | [0xaA3C…bA71](https://robinhoodchain.blockscout.com/address/0xaA3Ce43Bf69E1e76beBE56d014Fe659175EAbA71) | `contracts/src/AlmsVote.sol` | |
| LocksleyVault | [0x794A…Dea2](https://robinhoodchain.blockscout.com/address/0x794A1D6dFD20b4da712B35AffDf7938861a2Dea2) | `contracts/src/LocksleyVault.sol` | `launcher()` is the zero address |
| RobinAmongThieves | [0x586d…7c2F](https://robinhoodchain.blockscout.com/address/0x586d69120F27e04933684fe38f903ae86Bde7c2F) | `contracts/src/RobinAmongThieves.sol` | `rakeSink()` RakeBuyer, `houseSink()` LocksleyVault |
| RakeBuyer | [0xdd51…af3A](https://robinhoodchain.blockscout.com/address/0xdd5127199C68B5bE28671ade6af1D66BD9f7af3A) | `contracts/src/RakeBuyer.sol` | `vault()` LocksleyVault, `forwardTo()` unset |
| Stash | [0x46d5…b3BD](https://robinhoodchain.blockscout.com/address/0x46d56Ecf2fF7C3c32be968412584B6177461b3BD) | `contracts/src/Stash.sol` | no owner. Cap 50,000 USDG |
| FeeSplitter | [0x142c…F5ef](https://robinhoodchain.blockscout.com/address/0x142c0A0a19E85165Aadb8310E7a2A6081122F5ef) | `contracts/src/FeeSplitter.sol` | swap fee split 50% Vault, 40% $WIF burn, 10% ops. 7 day timelock |
| Buy route A / B | [0xc6b5…3615](https://robinhoodchain.blockscout.com/address/0xc6b57FFa1Ad054913a8D202755135719d89D3615) / [0x883b…9352](https://robinhoodchain.blockscout.com/address/0x883bb030BD736F86f5008000A13bf23c78ec9352) | `contracts/src/routes/` | FairCore `routes(0)` and `routes(1)` |
| Rake routes A / B | [0x0F98…CaC1E](https://robinhoodchain.blockscout.com/address/0x0F98D370A01696114956c3CeB3f876f7426CaC1E) / [0x1c25…CD08](https://robinhoodchain.blockscout.com/address/0x1c258f02c906Ca03E082215Ce479EbbF4a38CD08) | `contracts/src/routes/` | RakeBuyer routes |
| Owner Safe | [0x7c0f…A36a](https://robinhoodchain.blockscout.com/address/0x7c0fc9869f2D41D88CCA675A9A270214d59DA36a) | Safe v1.5.0 | 2 of 3, no modules, no guard |

## Contracts to read first

1. GameConfig. Call `tokens()` and `split()`. The split is 60% to the round's Purse and 40% to the Greenwood.
2. FairCore. Read `collect`, `award`, `claim`, `burnBuyToken`, `buyForVault` and `_swap`. This is the USDG book, and `accounted()` should never exceed its USDG balance.
3. FairLens. Call `configNow()`, `greenwood()` and `arrowNow()`. If a lens number disagrees with FairCore, FairCore is the source of truth.
4. LastArrow and SheriffsSeat. They keep score and send USDG straight to FairCore. Their USDG balance should stay 0. `FairCore.isBooth` is true for both.
5. FairPass. The 24 hour hold and the exact-amount check are here.
6. RobinAmongThieves and RakeBuyer. Rake leaves the camp through `flushRake` and arrives at RakeBuyer, which buys $WIF for the Vault.
7. Stash. One-click play: a session key can shoot and take inside a spend limit, and withdrawals only ever go back to the depositing wallet.
8. FeeSplitter. The Trading Post integrator fee, split by `pursesBps`/`vaultBps`/`rebateBps`/`burnBps`/`opsBps` = 0/5000/0/4000/1000.

## How to verify the flywheel onchain

Each shot emits `Shot(fairId, booth, roundKey, gross, purse, greenwood)` on FairCore, with `purse` 60% and `greenwood` 40% of `gross`. Then look for:

- `Awarded` and `RolledOver` when a round settles. Together they equal the round's purse.
- `Burned(token, source, route, usdgIn, out, minOut)` on FairCore. `source` 0 is the Bonfire and `source` 1 is the Vault's dead-address ledger. `token` is $WIF and the tokens go to `0x000000000000000000000000000000000000dEaD`.
- `BoughtForVault(token, route, usdgIn, out, minOut)` on FairCore. The recipient is LocksleyVault, and `heldOf` on the vault (or the `vaultBuyTokenHeld` field of `greenwood()` on FairLens) shows the $WIF.
- `AlmsCarried` or `AlmsReleased` at the end of a chapter, and `TollWithdrawn` when the Safe withdraws the toll.
- `RakeFlushed` on Robin Among Thieves, then `Received`, `Bought` and `Forwarded` on RakeBuyer.

`greenwood()` on FairLens returns the ledgers plus `solvent`, which is true when FairCore's USDG balance is at least `accounted()`.

## Testnet (secondary)

The same contracts also run on Robinhood Chain testnet (chain 46630) at https://testnet.gameofsplits.fun, with a faucet for test USDG and test $WIF. Addresses are in [`contracts/deployments/46630.json`](contracts/deployments/46630.json), explorer https://explorer.testnet.chain.robinhood.com. Testnet timelocks are 0 and its routes mint test tokens at a fixed rate, so use mainnet for anything about prices or the timelocks.

## Where tests and invariants live

| Path | What it covers |
| --- | --- |
| `contracts/test/unit` | FairCore, FairPass, both games, GameConfig, RakeBuyer, Robin Among Thieves, FeeSplitter, deploy checks |
| `contracts/test/invariant/Invariants.t.sol` | USDG solvency (`invariant_I1_solventAndAccountedExact`), the two games hold no USDG, the arrow clock, seat seconds, pass balance, claims and unlocks during a pause |
| `contracts/test/invariant/ConfigInvariants.t.sol` | Split caps, token updates only through the timelock, no update during a chapter, anchor reset bounds |
| `contracts/test/invariant/RatInvariants.t.sol` | USDG conservation, licence locks, the contract never owning an ERC-8004 identity |
| `contracts/test/audit` | Regression tests for the internal and external reviews. See [AUDIT.md](AUDIT.md) |
| `contracts/test/fork` | Read-only checks against the live Robinhood RPC |
| `contracts/test/sim/Fair0Sim.fork.t.sol` | Chapter 1 money simulation. Skipped unless the prepared node is running |

Fuzz runs and invariant depth are set in `contracts/foundry.toml`. The review record is [AUDIT.md](AUDIT.md), the static scan triage is [contracts/SLITHER.md](contracts/SLITHER.md), and the admin model is in [SECURITY.md](SECURITY.md).

## License

Contracts are licensed under BUSL-1.1 (converts to MIT on 2030-11-12); see LICENSE.
