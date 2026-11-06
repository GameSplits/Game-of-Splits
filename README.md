# Game of Splits

A $wif / USDG game chapter on Robinhood Chain (World is Flat hackathon). Players lock 5,000 $wif in a **Pass**
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

- Site: https://gameofsplits.fun
- Testnet: https://testnet.gameofsplits.fun
- Docs: https://docs.gameofsplits.fun
- Frontend (private): https://github.com/GameSplits/gos-site
- Judge tour: [JUDGES.md](JUDGES.md)

This repo is the contracts, keeper, and watcher source. The Next.js site lives in [GameSplits/gos-site](https://github.com/GameSplits/gos-site). WIF hackathon judges are invited to those two private repos only.

## Layout

```
contracts/      Foundry project (solc 0.8.38, via-IR, OZ 5.4.0, forge-std 1.11.0 as git submodules)
  src/          GameConfig, FairCore, FairPass, LastArrow, SheriffsSeat, AlmsVote, LocksleyVault, FairLens, routes/, testnet/
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
The password is typed at the prompt only, never written to a file or the shell history. Each deployer is a fresh
single-use EOA that holds only gas ETH. It is never a Safe signer and it never holds USDG or $wif. After ownership
moves to the Safe in the same broadcast, `SafeAcceptVerify` checks the deployer has no power left, that `OWNER_SAFE`
is the Safe pinned in the deploy script, and that FairCore logged exactly two booths and the deployed routes (mainnet
and testnet, the same checks, each pinned to its Safe so any other Safe is refused). Then sweep leftover gas to the
Safe and delete the keystore. See `docs/OPERATIONS.md`.

## Testnet deployment

Robinhood Chain testnet (chain 46630). Every contract address is in
[`contracts/deployments/46630.json`](contracts/deployments/46630.json), and the contracts are verified against
`contracts/src` in this repo. This file is the 7555 testnet set. FairCore is
`0xc76d5ED46786e67Fb5925928af18C08da7078Cf0`.

## Stash

Stash holds a player's USDG so a session key can shoot Last Arrow and take the Sheriff's Seat without a wallet popup. The player deposits from the main wallet. Withdrawals always return to that same wallet.

The launch cap is 50,000 USDG across every balance. One address can raise the cap and can renounce. Nobody can lower the cap, pause Stash, upgrade it, or move a balance. Tokens sent to Stash by a plain transfer stay there. There is no rescue.

A relayed shot or take costs 0.05 USDG. A relayed withdrawal costs 1 USDG. A direct call from the main wallet pays the player's own gas and no Stash fee. Fees are fixed at deploy. The contract rejects a shot fee above 0.25 USDG or a withdrawal fee above 2 USDG. Fees go to the fee recipient chosen at deploy.

A session lasts at most 7 days. The player sets a spend limit, and the fee counts toward that limit. Whole balance uses the unlimited sentinel. Revoke takes effect in the same transaction. A new key voids older key signatures. The key cannot withdraw, change the limit, or authorize another key.

The site signs a max price at the live price plus 15 percent for Last Arrow and plus 50 percent for the Sheriff's Seat. The degen toggle may sign up to the remaining session limit. Stash never pays more than the signed max price. Seat text is a preset id.

Shown funds are the Stash balance plus FairCore claimable for that wallet. Winnings stay on FairCore until the wallet claims them. The site can batch a claim with a deposit or with a direct withdrawal. That direct withdrawal pays no Stash fee.

Deploy on testnet 46630 only, from `contracts/`. The script reads FairCore, Last Arrow, the Sheriff's Seat and USDG from `deployments/46630.json` and reverts unless they are the 7555 addresses.

```
forge script script/DeployStash.s.sol --rpc-url robinhood_testnet
```

Set `STASH_FEE_WALLET` and `STASH_CAP_RAISER` in the environment first. Add `--broadcast` and `--private-key` only for a real testnet deploy. The script reverts on every other chain. Do not write the deployer key into the repo.

The relayer in `relayer/` submits signed Shoot, Take, Withdraw, AuthorizeKey, SetLimit, and RevokeKey payloads. It checks the chain and the Stash address, checks the signature, simulates with `eth_call`, and sends with a priority fee. A failed send is tried once more. See `relayer/README.md`.
