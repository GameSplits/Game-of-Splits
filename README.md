# Game of Splits

A $wif / USDG game fair on Robinhood Chain (World is Flat hackathon). Players lock 5,000 $wif in a **Fair Pass**
(24h minimum hold) and pay USDG to play booths: **Last Arrow** (a rising-price, last-shot-wins clock) and the
**Sheriff's Seat** (a daily throne). The same pass is required at the **Outlaw Camp** (Robin Among Thieves): the
controller must hold one to register an outlaw and to enter a round. The camp's own licence (1,000 play token,
returned on retire after 24 hours) stays as well, so camp entry is a pass plus a licence. An operator or the
ERC-8004 agent wallet may send the transaction; the pass checked is the controller's. Retiring and withdrawing
the licence, bond and budget do not require a pass. Each shot sends 60% to the round's Purse and 40% to the Greenwood: the
Locksley Vault ($wif bought and held, a $wif burn quarter, USDG held for future liquidity), the Alms (a charity the
players vote on, paid by the Safe), the Bonfire ($wif bought and burned hourly by the keeper) and the Toll.
Contract names keep the original Sherwood theme (FairCore, FairPass, ...).

The play token, the pass amount, the buy token and the shot split live in **GameConfig**, a safe-owned config with a
7-day timelock. The numbers above are the launch values. The site reads the current ones from `FairLens.configNow()`.

Buybacks (the Bonfire and the Vault) swap USDG for that buy token. The route pays FairCore, FairCore measures its own
balance, and it forwards that amount to the Locksley Vault or to the burn address. Fee-on-transfer buy tokens are
unsupported. A fee taken on the way in can drop the measured amount below `minOut`, and the swap reverts. A fee taken
on the way out can revert the transfer to the vault or the burn address, or leave that recipient with less than
what the `Burned` / `BoughtForVault` event and the return value report.

## Links

- Site: https://gameofsplits.fun
- Testnet: https://testnet.gameofsplits.fun
- Docs: https://docs.gameofsplits.fun
- Frontend: https://github.com/GameSplits/gos-site

Note: The frontend repo is private. Judges for the WIF hackathon will be invited to view it.

## Layout

```
contracts/      Foundry project (solc 0.8.38, via-IR, OZ 5.4.0, forge-std 1.11.0 as git submodules)
  src/          GameConfig, FairCore, FairPass, LastArrow, SheriffsSeat, AlmsVote, LocksleyVault, FairLens, routes/, testnet/
  test/         unit, invariant, audit PoCs, fork (live Robinhood RPC), sim (Fair 0 on a local fork)
  script/       Deploy.s.sol (Safe checks + pinned Safe address), SafeAccept.s.sol, Mainnet.s.sol, e2e/*.sh
  RUNBOOK_KEEPER.md   keeper/watcher incident runbook and go-live checklist
keeper/         hourly keeper (GitHub Actions in its own repo; DRY_RUN unless DRY_RUN=0), viem only
watcher/        Vercel cron watcher + send log + dead-man switch (no key, no GitHub credential), viem only
e2e/            keeper + watcher end to end on a local anvil fork (36 checks)
docs/           deploy, handover and lock-watcher runbooks
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
bash contracts/script/e2e/fair0_sim.sh        # Fair 0 money simulation (Foundry 1.5.x)
```

Every package has a `.env.example` listing its settings. No secrets in the repo: keys go through a masked secret entry.
Mainnet and testnet deploys both use a Foundry encrypted keystore. Mainnet account `gos-mainnet`, testnet account
`gos-testnet`: `cast wallet import <account> --interactive`, then `forge script ... --account <account> --sender <addr>`.
The password is typed at the prompt only, never written to a file or the shell history. Each deployer is a fresh
single-use EOA that holds only gas ETH. It is never a Safe signer and it never holds USDG or $wif. On testnet, signer 1
(`0xb44F…50bA`) stays a Safe owner and is not the deployer. After the Safe accepts, `SafeAcceptVerify` checks the
deployer has no power left, that `OWNER_SAFE` is the Safe pinned in the deploy script, and that FairCore logged
exactly two booths and the deployed routes (mainnet and testnet, the same checks; mainnet refuses while its pin is
still zero). Then sweep leftover gas to the Safe and delete the keystore. See `contracts/RUNBOOK_KEEPER.md`. Every testnet live run, mainnet deploy or real transaction needs the owner's explicit approval.

## Testnet deployment

Robinhood Chain testnet (chain 46630). Every contract address is in
[`contracts/deployments/46630.json`](contracts/deployments/46630.json), and the contracts are verified against
`contracts/src` in this repo.
