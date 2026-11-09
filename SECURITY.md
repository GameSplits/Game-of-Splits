# Security

This note is the scope, the report path, the admin model, and the limitations a reviewer should know before reading the contracts. The review record is [AUDIT.md](AUDIT.md). No audit firm has issued a report on this repository.

Game of Splits is not affiliated with Robinhood Markets.

## Scope

In scope:

- `contracts/src`, including FairCore, RakeBuyer, FeeSplitter, RobinAmongThieves, GameConfig, FairLens, FairPass, LastArrow, SheriffsSeat, AlmsVote, LocksleyVault, SafeHandover, and `contracts/src/routes`
- `contracts/src/testnet` as testnet-only code. `TestToken` and `TestRoute` revert if they are constructed on chain id 4663
- `keeper/` and `watcher/` where they send or watch those contracts

Out of scope for a report filed here:

- `contracts/lib`, including OpenZeppelin and forge-std
- the site repository at https://github.com/GameSplits/gos-site
- Uniswap v3 and v4 pools and hooks, the ERC-8004 identity and reputation registries, donate.gg, and the Safe singleton

The contracts are live on Robinhood Chain mainnet (chain id 4663). Addresses are in [`contracts/deployments/4663.json`](contracts/deployments/4663.json) and the table in [README.md](README.md). The testnet (chain id 46630) set is in `contracts/deployments/46630.json`.

## How to report

This repository is private. If you have access, open a GitHub issue on GameSplits/Game-of-Splits. Otherwise email support@gameofsplits.fun. Title it `Security:` plus one line on the impact. Include the contract, the function, the chain id, what you expected, what happened, and the smallest reproduction that shows it.

Leave the maintainers time to answer before you describe the same issue on a public site.

## Safe and timelocks

The mainnet owner is the Safe [0x7c0fc9869f2D41D88CCA675A9A270214d59DA36a](https://robinhoodchain.blockscout.com/address/0x7c0fc9869f2D41D88CCA675A9A270214d59DA36a) (Safe v1.5.0). `getThreshold()` is 2 and `getOwners()` returns three addresses. It has no modules and no guard.

Read on chain 4663 at block 110,246,188 (10 Nov 2026):

- `owner()` is the Safe and `pendingOwner()` is the zero address on GameConfig, FairCore, FairPass, AlmsVote, LocksleyVault, RobinAmongThieves, RakeBuyer and FeeSplitter.
- LastArrow, SheriffsSeat, FairLens and Stash have no owner. Stash's cap raiser and fee recipient are the Safe.
- The Safe is `almsSafe()` and `tollRecipient()` on FairCore, and the purses, rebate, burn and ops legs of FeeSplitter. The FeeSplitter vault leg is LocksleyVault.
- The deployer `0xb92Ee980F72b25Cf892321801aaE3C663109cdF0` holds no role and is not a Safe owner. The deploy script uses `handOver`, so the deployer loses ownership in the deploy broadcast, and `SafeAcceptVerify` checks that it has no power left. The reads above confirm that on chain. Later ownership moves use Ownable2Step: the new owner must accept. `renounceOwnership` reverts on these contracts.
- The mainnet timelocks are live: GameConfig `delay()` 7 days, FairCore, RakeBuyer and RobinAmongThieves `timelockDelay()` 48 hours, RobinAmongThieves `bondDelay()` 7 days, FeeSplitter `TIMELOCK` 7 days.

Testnet (chain 46630) contracts have their own owner and keeper and are test-only. Read `owner()` and `keeper()` there rather than relying on this file.

The Safe can pause sales, revoke the keeper immediately, and queue the changes in the table. It cannot, through an owner function, take a purse, a claimable balance, locked Pass tokens, or an Alms balance that players have already been credited. Players can `claim` while sales are paused. A Pass can `unlock` after its own 24 hours while sales are paused.

| Change | Mainnet wait | Testnet 46630, read 31 Oct 2026 UTC |
| --- | --- | --- |
| GameConfig tokens or split | 7 days, and only while no chapter is active | `delay()` is 0 |
| FairCore routes, keeper, booths, toll recipient, Alms Safe, ratchet reset | 48 hours | `timelockDelay()` is 0 |
| Revoke the FairCore, RakeBuyer or Robin Among Thieves keeper | immediate | immediate |
| RakeBuyer keeper, routes, ratchet, forward recipient | 48 hours | `timelockDelay()` is 0 |
| Robin Among Thieves keeper, rake sink, licence amount, draw | 48 hours | `timelockDelay()` is 0 |
| Robin Among Thieves bonds | 7 days, and bonds start disabled | `bondDelay()` is 0 and `bondsEnabled()` is false |
| FeeSplitter recipients or split | 7 days | not deployed on 46630 |
| LocksleyVault launcher | 7 days, then one attach | `launcher()` is the zero address. The 7 day wait is a constant on every chain |
| Pass unlock | 24 hours after that wallet locked | same |
| Outlaw licence return | 24 hours after the licence | same |

On testnet the owner waits above are 0, except the vault launcher. A queued GameConfig update can be executed at once, and only while `activeFair()` is false. Mainnet constructors revert if FairCore, RakeBuyer or RobinAmongThieves are deployed with a timelock under 48 hours, or if GameConfig is deployed with a delay under 7 days, or if the bond delay is under 7 days.

The mainnet keeper is `0x4696ebA115691d7AA5A3bb810F172cdb7DCF21E5` on FairCore, RakeBuyer and RobinAmongThieves. It can settle ended rounds and call the buys inside the caps in the README. It cannot move a purse, a pass, or the Alms.

## Reviews and scans

No audit firm has issued a report, so treat the contracts as unaudited. What was done, all recorded in [AUDIT.md](AUDIT.md) and [contracts/SLITHER.md](contracts/SLITHER.md):

- Internal review passes, with accepted findings fixed and regression tests in `contracts/test/audit`.
- Unit, fuzz and invariant suites (USDG solvency, config, Robin Among Thieves conservation), plus read-only fork tests against the live mainnet RPC.
- Slither and Aderyn on the deployed contract source, with every High and Medium row triaged as known, by design or a false positive.
- A mainnet fork rehearsal of the deploy and the Safe handover before the real broadcast.
- Secret scans of the full git history and dependency audits of the keeper, watcher and relayer packages.

## Known limitations

Fee-on-transfer buy tokens are unsupported. `FairCore._swap` and `RakeBuyer.buy` credit the increase in the buy-token balance and require that increase to cover `minOut`. A token that takes a fee inside `transfer` makes the credited amount smaller than the amount the route moved, so the fill, the event and any later forward no longer describe a plain ERC-20. A rebasing buy token has the same problem. GameConfig checks that the buy token is an 18-decimal contract, and a fee-on-transfer token can still pass that check. Queue a standard ERC-20.

Fee-on-transfer USDG and fee-on-transfer play tokens fail closed. `FairCore.collect`, `FairPass.lock` and Robin Among Thieves deposits revert `TransferMismatch` unless the contract's balance rises by the exact amount.

FeeSplitter assumes a standard token. A fee taken inside `transfer` can leave a leg in `owed` instead of paying it. On mainnet it was deployed by `script/DeployFeeSplitter.s.sol` right after the main deploy and checked by SafeAcceptVerify.

A booth the Safe adds after setup can pull USDG from any wallet that approved FairCore, up to the booth allowance that wallet set for it. The launch booths are Last Arrow and the Sheriff's Seat. Those two do not use the extra allowance. Their `collect` call passes the booth's own `msg.sender` as the payer.

A keeper key can still buy, inside the caps: 250 USDG per FairCore ledger per call, 50 minutes between calls on that ledger, 3,000 USDG per ledger per UTC day, and only at or above the price floor. RakeBuyer is 50 USDG per call, 50 minutes between calls, and 500 USDG per UTC day. The Safe can set the keeper to the zero address in the same transaction it decides to.

LocksleyVault cannot pay anyone until a launcher is attached. After that, only the launcher can pull. `vaultLiqUsdg` and `vaultFairsBurnUsdg` stay inside FairCore until that pull.

A round that is still open when a chapter ends attributes the shot to the chapter that was active when the USDG was taken, and the winnings to the chapter of the round's first shot. Schedule the next chapter so no round is open across the boundary. Schedule this on every chapter change.

Testnet routes mint tWIF or tTKB at a fixed rate. They are not a price check against a pool. Mainnet routes are the v3 and v4 contracts, and they are not what 46630 runs.

Robin Among Thieves entries start paused (`entriesPaused()`). That is a switch the Safe can clear when the camp opens. It is not a timelock.

## Swap payee residual

FairCore counts a keeper swap by its own buy-token balance, then forwards that amount to the vault or to the dead address. A payment to the vault or to the dead address during the swap is not counted.

That measurement assumes nothing permissionless pays FairCore the buy token while the route runs. FeeSplitter rejects FairCore and RakeBuyer as legs and as rescue targets. RakeBuyer rejects FairCore as `forwardTo` when the change is queued, and its constructor rejects a vault equal to FairCore. `address(0)` still means the vault.

What remains: the Safe can still aim a FeeSplitter leg, or RakeBuyer's `forwardTo`, at some other contract. That takes the 7-day FeeSplitter timelock or RakeBuyer's timelock. A route that calls that contract during the swap takes FairCore's 48-hour `SetRoute` timelock. If both are in place, the contract can push buy tokens to FairCore and a short-filling route can pass `minOut`. The tokens forwarded are the payee's, not an extra mint, but the route keeps the USDG.

SafeAccept fails that shape. A leg, RakeBuyer's vault, or `forwardTo` must have no code (an EOA, the unset forward, or the dead address) or be on the allowlist passed in (the Locksley Vault, the dead address, and the Safe itself). A forwarder contract is rejected. The deployment file's `feeSplitter` must name this deploy's FairCore, RakeBuyer, $wif and Locksley Vault, be owned by the Safe with nothing pending, carry the launch split and have no queued change or rescue. On mainnet Verify fails without it.

The watcher should alert when a FeeSplitter leg or `forwardTo` is set to an address that has code. That is the signal for the timelocked misconfiguration above. It is not a substitute for the accept check.
