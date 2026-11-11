# Game of Splits

A $wif / USDG game chapter live on Robinhood Chain mainnet, chain id 4663 (World is Flat hackathon). Players lock 5,000 $wif in a **Pass**
(24h minimum hold) and pay USDG to play booths: **Last Arrow** (a rising-price, last-shot-wins clock) and the
**Sheriff's Seat** (a daily throne). The same pass is required at the **Outlaw Camp** (Robin Among Thieves): the
controller must hold one to register an outlaw and to enter a round. The camp's own licence (1,000 play token,
returned on retire after 24 hours) stays as well, so camp entry is a pass plus a licence. An operator or the
ERC-8004 agent wallet may send the transaction; the pass checked is the controller's. Retiring and withdrawing
the licence, bond and budget do not require a pass. Each shot sends 60% to the round's Purse and 40% to the Greenwood: the
Locksley Vault ($wif bought and held, a $wif burn quarter, USDG held for future liquidity), the Alms (a charity the
players vote on, paid by the Safe), the Bonfire ($wif bought and burned hourly by the keeper) and the Toll.

The play token, the pass amount, the buy token and the shot split live in **GameConfig**, a safe-owned config with a
7-day timelock. The numbers above are the launch values. The site reads the current ones from `FairLens.configNow()`.

## Links

- Site (mainnet, chain 4663): https://gameofsplits.fun
- Docs: https://docs.gameofsplits.fun (addresses at https://docs.gameofsplits.fun/contracts)
- Explorer: https://robinhoodchain.blockscout.com
- Testnet (chain 46630): https://testnet.gameofsplits.fun
- Frontend (private): https://github.com/GameSplits/gos-site
- Judge tour: [JUDGES.md](JUDGES.md)

This repo is the contracts, keeper, and watcher source. The Next.js site lives in [GameSplits/gos-site](https://github.com/GameSplits/gos-site); its README covers the site. WIF hackathon judges are invited to those two private repos only.

## Layout

```
contracts/      Foundry project (solc 0.8.38, via-IR, OZ 5.4.0, forge-std 1.11.0 as git submodules)
  src/          GameConfig, FairCore, FairPass, LastArrow, SheriffsSeat, AlmsVote, LocksleyVault, FairLens, RobinAmongThieves,
                RakeBuyer, Stash, FeeSplitter, routes/, testnet/
  test/         unit, invariant, audit PoCs, fork (live Robinhood RPC), sim (Chapter 0 on a local fork)
  script/       Deploy.s.sol (Safe checks + pinned Safe address), SafeAccept.s.sol, Mainnet.s.sol, e2e/*.sh
keeper/         hourly keeper (GitHub Actions in its own repo; DRY_RUN unless DRY_RUN=0), viem only
watcher/        Vercel cron watcher + send log + dead-man switch (no key, no GitHub credential), viem only
e2e/            keeper + watcher end to end on a local anvil fork (36 checks)
docs/           OPERATIONS.md (keeper, timelocks, pause/revoke, lock watcher) and LOCK_WATCHER.md
```

## Setup

```
git submodule update --init --recursive     # contracts/lib (forge-std, openzeppelin-contracts)
cd contracts && forge build && forge test --no-match-path "test/fork/*"
forge test --match-path "test/fork/*"        # live Robinhood mainnet RPC, read-only
cd ../keeper && npm ci --ignore-scripts && npm test
cd ../watcher && npm ci --ignore-scripts && npm test
cd .. && bash e2e/keeper_watcher.sh           # Foundry 1.5.x (1.8.x emulates ArbSys on Robinhood forks)
bash contracts/script/e2e/accept_flow.sh      # deploy + Safe accept rehearsal
bash contracts/script/e2e/fair0_sim.sh        # Chapter 0 money simulation (Foundry 1.5.x)
```

Every package has a `.env.example` listing its settings. No secrets in the repo: keys go through a masked secret entry.
Mainnet and testnet deploys both use a Foundry encrypted keystore. Mainnet account `gos-mainnet`, testnet account
`gos-testnet`: `cast wallet import <account> --interactive`, then `forge script ... --account <account> --sender <addr>`.
The password is typed at the prompt only, never written to a file or the shell history. After ownership
moves to the Safe in the same broadcast, `SafeAcceptVerify` checks the deployer has no power left, that `OWNER_SAFE`
is the Safe pinned in the deploy script, and that FairCore logged exactly two booths and the deployed routes (mainnet
and testnet, the same checks, each pinned to its Safe so any other Safe is refused). See `docs/OPERATIONS.md`.

## Mainnet deployment

Robinhood Chain mainnet (chain 4663). Every address is in
[`contracts/deployments/4663.json`](contracts/deployments/4663.json) (start block 107503866). The table below was read
on chain at block 110,246,188 (10 Nov 2026).

| Contract | Address |
| --- | --- |
| GameConfig | `0xfCEE3b97e94516668300c649212822dbe4eC5191` |
| FairCore | `0x4fbfdaAE32BC1C8F43Ce8BDBE25445C6B8718458` |
| FairPass | `0xdB75122e1e53215f77F6C1F3B9D7E51d9D983709` |
| FairLens | `0x3838b0C4b00919d3fEFB0F00e80468bF33960970` |
| LastArrow | `0x3D50EdFa6E22d901ec567cE27842F4DBE2068516` |
| SheriffsSeat | `0x61bC2Af907912c4279F610D82681320F96e25c0F` |
| AlmsVote | `0xaA3Ce43Bf69E1e76beBE56d014Fe659175EAbA71` |
| LocksleyVault | `0x794A1D6dFD20b4da712B35AffDf7938861a2Dea2` |
| RobinAmongThieves | `0x586d69120F27e04933684fe38f903ae86Bde7c2F` |
| RakeBuyer | `0xdd5127199C68B5bE28671ade6af1D66BD9f7af3A` |
| Stash | `0x46d56Ecf2fF7C3c32be968412584B6177461b3BD` |
| FeeSplitter | `0x142c0A0a19E85165Aadb8310E7a2A6081122F5ef` |
| Buy routes A / B | `0xc6b57FFa1Ad054913a8D202755135719d89D3615` / `0x883bb030BD736F86f5008000A13bf23c78ec9352` |
| Rake routes A / B | `0x0F98D370A01696114956c3CeB3f876f7426CaC1E` / `0x1c258f02c906Ca03E082215Ce479EbbF4a38CD08` |
| $WIF | `0x5173b8eA6923c2d40267890D45C46a3480954773` |
| USDG | `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168` |
| Owner Safe (2 of 3) | `0x7c0fc9869f2D41D88CCA675A9A270214d59DA36a` |

The Safe is `owner()` of every ownable contract, with nothing pending. The deployer holds no role. See
[SECURITY.md](SECURITY.md) for the admin model and [JUDGES.md](JUDGES.md) for a guided tour.

## Testnet deployment

Robinhood Chain testnet (chain 46630) runs the same contracts with zero timelocks and test-token routes. Every address
is in [`contracts/deployments/46630.json`](contracts/deployments/46630.json). FairCore is
`0xc76d5ED46786e67Fb5925928af18C08da7078Cf0`.

## Stash

Stash holds a player's USDG so a session key can shoot Last Arrow and take the Sheriff's Seat without a wallet popup. The player deposits from the main wallet. Withdrawals always return to that same wallet.

The launch cap is 50,000 USDG across every balance. One address, the cap raiser, can raise the cap, set the shot fee up to the maximum, and renounce. On mainnet the cap raiser and the fee recipient are the Safe. Nobody can lower the cap, pause Stash, upgrade it, or move a balance. Tokens sent to Stash by a plain transfer stay there. There is no rescue.

On mainnet a relayed shot or take costs 0.015 USDG (`shotFee()`), and every withdrawal, direct or relayed, costs 1 USDG (`withdrawFee()`). A direct shot or take from the main wallet pays the player's own gas and no shot fee. The withdrawal fee is fixed at deploy. The shot fee can only be changed by the cap raiser, never above 0.25 USDG, and a higher fee only applies to sessions authorized after the change. Fees collect in Stash and leave only through `flushFees` to the fee recipient chosen at deploy.

A session lasts at most 7 days. The player sets a spend limit, and the fee counts toward that limit. Whole balance uses the unlimited sentinel. Revoke takes effect in the same transaction. A new key voids older key signatures. The key cannot withdraw, change the limit, or authorize another key.

The site signs a max price at the live price plus 15 percent for Last Arrow and plus 50 percent for the Sheriff's Seat. The degen toggle may sign up to the remaining session limit. Stash never pays more than the signed max price. Seat text is a preset id.

Shown funds are the Stash balance plus FairCore claimable for that wallet. Winnings stay on FairCore until the wallet claims them. The site can batch a claim with a deposit or with a direct withdrawal.

The mainnet Stash was deployed with `script/DeployStashMainnet.s.sol`. The testnet script below deploys on 46630 only, from `contracts/`. It reads FairCore, Last Arrow, the Sheriff's Seat and USDG from `deployments/46630.json` and reverts unless they are the 7555 addresses.

```
forge script script/DeployStash.s.sol --rpc-url robinhood_testnet
```

Set `STASH_FEE_WALLET` and `STASH_CAP_RAISER` in the environment first. Add `--broadcast` and `--private-key` only for a real testnet deploy. The script reverts on every other chain. Do not write the deployer key into the repo.

The relayer in `relayer/` submits signed Shoot, Take, Withdraw, AuthorizeKey, SetLimit, and RevokeKey payloads. It checks the chain and the Stash address, checks the signature, simulates with `eth_call`, and sends with a priority fee. A failed send is tried once more. See `relayer/README.md`.
