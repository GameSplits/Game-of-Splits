# Five minute tour

Repos for judges (both private):

- Contracts / keeper / watcher: this repo ([GameSplits/Game-of-Splits](https://github.com/GameSplits/Game-of-Splits))
- Site frontend: [GameSplits/gos-site](https://github.com/GameSplits/gos-site)

Chain: Robinhood Chain testnet, chain id 46630. Gas is ETH. Explorer: https://explorer.testnet.chain.robinhood.com. Addresses: [`contracts/deployments/46630.json`](contracts/deployments/46630.json) and the table in [README.md](README.md).

Times below are UTC. The play token and the buy token on this deployment are tWIF, the test stand-in for $WIF. Shots are paid in tUSDG.

## What to click

1. Open https://testnet.gameofsplits.fun and connect a wallet on chain 46630. The public RPC is `https://rpc.testnet.chain.robinhood.com`.
2. Open [Test tokens](https://testnet.gameofsplits.fun/faucet). The header link is Test tokens. `faucet()` on tUSDG mints 1,000 tUSDG. `faucet()` on tWIF mints 50,000 tWIF. Each address can mint each token once an hour. You need tWIF for a pass and tUSDG to shoot.
3. Open [Pass](https://testnet.gameofsplits.fun/pass). This is the Toll Gate on the map. Approve tWIF and lock 5,000. The hold is 24 hours. Unlock returns 5,000 tWIF to the same wallet. A lock does not need a live Chapter, so this transaction still works after Chapter 0.
4. Open [Last Arrow](https://testnet.gameofsplits.fun/last-arrow) and [Sheriff's Seat](https://testnet.gameofsplits.fun/sheriffs-seat). Read the price, the clock and the purse. A new shot or take reverts `NoActiveFair` until the Safe sets another Chapter. Chapter 0 ran from 30 Oct 2026 14:00 UTC to 30 Oct 2026 20:00 UTC. `salesPaused()` was false on 31 Oct 2026 UTC. The revert on a new shot is `NoActiveFair`.
5. Open [Alms](https://testnet.gameofsplits.fun/alms), [Bonfire](https://testnet.gameofsplits.fun/bonfire) and [Locksley Vault](https://testnet.gameofsplits.fun/vault). These pages read the Greenwood ledgers. The vault launcher is the zero address, so the page cannot pull funds.
6. Open [Robin Among Thieves](https://testnet.gameofsplits.fun/robin). `entriesPaused()` is true on the deployed contract, so `enter` reverts `EntriesArePaused`. You can still read the licence amount, which is 1,000 tWIF, and the rake sink, which is RakeBuyer.
7. Skip the Trading Post as a proof. https://testnet.gameofsplits.fun/trading-post is a preview. FeeSplitter is not in the 46630 file, so that page does not move these contracts.

The Sheriff's Seat day on this deployment is 7,200 seconds, and `day0` is 30 Oct 2026 00:00 UTC. Mainnet days end at 00:00 UTC and last 86,400 seconds.

## Contracts to read first

Read in this order. The explorer link is the deployed testnet contract. The file is the source in this repo.

1. [GameConfig](https://explorer.testnet.chain.robinhood.com/address/0x6d0e02dEb629a3DB9f8e8fFf1A3fcA18A0263B15) in `contracts/src/GameConfig.sol`. Call `tokens()` and `split()`. On this deployment both tokens are tWIF, the pass is 5,000 tWIF, and the split is the launch row in the README.
2. [FairCore](https://explorer.testnet.chain.robinhood.com/address/0xeEC601586e54727b248423692D0747d7173aD7A7) in `contracts/src/FairCore.sol`. Read `collect`, `award`, `claim`, `burnBuyToken`, `buyForVault` and `_swap`. This is the USDG book.
3. [FairLens](https://explorer.testnet.chain.robinhood.com/address/0x030dA2A56C49D4d2183ED52088B27E6557c90F66) in `contracts/src/FairLens.sol`. Call `configNow()`, `greenwood()` and `arrowNow()`. If a lens number disagrees with FairCore, FairCore is the source of truth. The lens holds nothing.
4. [LastArrow](https://explorer.testnet.chain.robinhood.com/address/0x42bB9623B81B85B36ec580c18869eD98Ec678B02) and [SheriffsSeat](https://explorer.testnet.chain.robinhood.com/address/0xA4bC35DD176be475141d871Afde0E91a7f6b9369). They keep score and send USDG straight to FairCore. Their USDG balance should stay 0.
5. [FairPass](https://explorer.testnet.chain.robinhood.com/address/0x97AC01c46714ED68f19B7839E3125B9e102781E4) in `contracts/src/FairPass.sol`. The 24 hour hold and the exact-amount check are here.
6. [RobinAmongThieves](https://explorer.testnet.chain.robinhood.com/address/0xfB1E167CDA749f7acd8E6FDC8a8Db7FF4a9c36e9) and [RakeBuyer](https://explorer.testnet.chain.robinhood.com/address/0x6016C88358aC81B3FdcD77d5C583902Bb41689ce). Rake leaves the camp through `flushRake` and arrives at RakeBuyer.
7. [LocksleyVault](https://explorer.testnet.chain.robinhood.com/address/0x9AAE8E5C86a0634212D23a886E19401cF25Fd6b3). `launcher()` is the zero address.
8. Routes. This deployment uses `contracts/src/testnet/TestTokens.sol` (`TestRoute` mints at `RATE`). Mainnet uses `contracts/src/routes/BuyRouteV4.sol` and `contracts/src/routes/BuyRouteV3V4.sol`.
9. `contracts/src/FeeSplitter.sol` for the integrator-fee design. It has no address on 46630.

## How to verify the flywheel onchain

Chapter 0 left one shot and no keeper buy. The booking is still in the ledgers. A log search on 31 Oct 2026 UTC, from deploy block 145373467, found one `Shot` and no `Burned`, `BoughtForVault`, `Received`, `Bought` or `Forwarded` events.

### The shot

[Shot transaction](https://explorer.testnet.chain.robinhood.com/tx/0xca21133864147a79aaddf41f5c232984b08d32f4d75f46507af3294412373eff) on FairCore.

`Shot` arguments, in tUSDG base units (6 decimals):

| Field | Value |
| --- | --- |
| fairId | 0 |
| booth | Sheriff's Seat |
| roundKey | 8 |
| gross | 1,000,000 (1 tUSDG) |
| purse | 600,000 |
| greenwood | 400,000 |

That is the 60 / 40 split. The same transaction emits `Seeded` with amount 0, because the round had no rollover yet.

### Where the purse and the Alms went

[Award transaction](https://explorer.testnet.chain.robinhood.com/tx/0x0f7bc3a68f2e18345034bcd4ec55a973beb63545d592041c9e8a98771b4b1025). `Awarded` pays 450,000 and `RolledOver` books 150,000. 450,000 + 150,000 = 600,000, the whole purse. No `Claimed` log had followed it at the time of the search, and `accounted()` was still the full shot, so that purse had not left FairCore. The 150,000 is `rollover` for the Sheriff's Seat.

[Alms carry](https://explorer.testnet.chain.robinhood.com/tx/0xbc9e11b81757aecfca1ee79c694aa94a3f6d9a899886f0ee8916ec78da14cb00). `AlmsCarried` moves 80,000, which is 8% of the shot. There was no `AlmsReleased` log. A chapter with no votes carries the Alms forward instead of paying the Safe.

### Ledgers still waiting on the keeper

Read these on FairCore. Values below were the balances on 31 Oct 2026 UTC, in tUSDG base units, and they match 7% and 4.5% of the 1 tUSDG shot:

| Call | Value | Meaning |
| --- | --- | --- |
| `bonfirePending()` | 70,000 | waiting for `burnBuyToken(Bonfire, ...)` |
| `tollPending()` | 70,000 | waiting for `withdrawToll` |
| `vaultBuyPending()` | 45,000 | waiting for `buyForVault` |
| `vaultBurnPending()` | 45,000 | waiting for `burnBuyToken(Vault, ...)` |
| `vaultLiqUsdg()` | 45,000 | stays in FairCore until a launcher exists |
| `vaultFairsBurnUsdg()` | 45,000 | stays in FairCore until a launcher exists |
| `accounted()` | 1,000,000 | equals the tUSDG balance of FairCore |

`greenwood()` on FairLens returns the same ledgers plus `solvent`, which is true when the tUSDG balance is at least `accounted`.

When the keeper does run, look for:

- `Burned(token, source, route, usdgIn, out, minOut)` on FairCore. `source` 0 is the Bonfire. `source` 1 is the vault dead-address ledger. `token` should be tWIF. On this testnet the route mints tWIF to the dead address. On mainnet the route buys $WIF from the pools and FairCore checks the recipient balance.
- `BoughtForVault(token, route, usdgIn, out, minOut)` on FairCore. The recipient is LocksleyVault. Then `heldOf` on the vault, or `vaultBuyTokenHeld` on the lens, should show the tWIF.
- `TollWithdrawn` when the Safe withdraws the toll.
- `RakeFlushed` on Robin Among Thieves, then `Received`, `Bought` and `Forwarded` on RakeBuyer. `Forwarded` should name LocksleyVault.

The dead address is `0x000000000000000000000000000000000000dEaD`. Its tWIF balance is the sum of `Burned` outputs on this testnet, because `TestRoute` mints to the recipient instead of pulling from a pool.

## Where tests and invariants live

| Path | What it covers |
| --- | --- |
| `contracts/test/unit` | FairCore, FairPass, both booths, GameConfig, RakeBuyer, Robin Among Thieves, FeeSplitter, deploy checks |
| `contracts/test/invariant/Invariants.t.sol` | USDG solvency (`invariant_I1_solventAndAccountedExact`), empty booths, the arrow clock, seat seconds, pass balance, claims and unlocks during a pause |
| `contracts/test/invariant/ConfigInvariants.t.sol` | Split caps, token updates only through the timelock, no update during a chapter, anchor reset bounds |
| `contracts/test/invariant/RatInvariants.t.sol` | USDG conservation, licence locks, the contract never owning an ERC-8004 identity |
| `contracts/test/audit` | Regression tests for the internal and external reviews. See [AUDIT.md](AUDIT.md) |
| `contracts/test/fork` | Read-only checks against the live Robinhood RPC |
| `contracts/test/sim/Fair0Sim.fork.t.sol` | Chapter 0 money simulation. Skipped unless the prepared node is running |

Run notes and the 31 Oct 2026 UTC counts are in the README. Fuzz runs and invariant depth are set in `contracts/foundry.toml`.
