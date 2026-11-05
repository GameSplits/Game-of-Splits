# Chapter 0 simulation report (v3.6.1, 25 Oct 2026)

> **Superseded dates (30 Oct):** this report ran the old 2–7 Nov Chapter. Chapter 0 now runs 2–4 Nov (timeline A1) and `test/sim/Fair0Sim.fork.t.sol` is updated to match. Re-run `bash script/e2e/fair0_sim.sh` to regenerate the numbers below.

**Result: pass.** The whole of Chapter 0 ran end to end on a copy of Robinhood Chain mainnet. Every USDG and $wif is accounted for to the last unit, and every rule refused what it should. Nothing touched the real chain and no keys were used.

Reproduce with `bash script/e2e/fair0_sim.sh` (forge 1.5.x; see "limits" for why not 1.8.x).

## What ran

The setup was a local anvil fork of Robinhood Chain mainnet: real USDG (Paxos), real $wif, the real v4 PoolManager, the Pons and Fables hooks, and the v3 USDG/WETH pool.

**Before the chapter, as real broadcasts** (the same commands mainnet will use):
1. `QuoteAnchor` → `DeployMainnet --broadcast`, with the live seed, the three test charities and Chapter 0's real dates.
2. `SafeAcceptBatch` → the Safe executes the 5-tx batch → `SafeAcceptVerify` passes: the Safe owns all four contracts and the anchor is re-seeded.

> **Changed since (A1-14):** there is no accept batch any more. The deploy hands all seven contracts to the Safe in the same broadcast, and step 2 is now `SafeAcceptVerify` alone. `script/e2e/fair0_sim.sh` runs that flow against the real pinned Safe on the fork.

**Then `test/sim/Fair0Sim.fork.t.sol`** played the chapter on that node.
- **Players:** 30.
- **Timing:** 10-minute ticks from 2 Nov 00:00 to 7 Nov 00:00 UTC.
- **Keeper:** an hourly model of the v2 keeper rules:
  - quote both routes and take the better;
  - `minOut` = quote − 3%;
  - skip if below the onchain floor, and skip below 5 USDG;
  - an hourly settle sweep.

## Totals

| | |
|---|---|
| Last Arrow shots / rounds | 570 shots in 36 rounds (1 round ran the full 24h and hit the hard end this run still had; that hard end is gone) |
| Seat takes | 53 over 4 days, including a 6-take bidding war on 3 Nov |
| Spent by players | 851 USDG (784 Last Arrow, 67 Seat) |
| Paid to winners (claimed) | 511 USDG |
| Alms to the Alms Safe (BLUE won the vote) | 68 USDG in 2 tranches: 53 at the vote, 15 after the chapter |
| Toll to the Toll recipient | 59 USDG |
| Keeper buybacks | 24 swaps, 131 USDG: 71,134 $wif burned at 0xdEaD and 27,765 $wif bought into the Vault |
| Keeper skips below the floor | 0. The anchor stayed at 750–753 $wif per USDG all Chapter |
| Left in FairCore | 81.59 USDG = 76.72 in the Vault ledgers (held for the $FAIRS launch) + 4.87 in buyback ledgers (each under the 5 USDG minimum) + 9 units of rollover dust |

## The money checks (all pass)

1. **Exact solvency:** FairCore's USDG balance equals `accounted`.
2. **USDG in = USDG out + held:** 851 spent = 511 claimed + 68 Alms + 59 Toll + 131 swapped + 81.59 held. These figures are rounded down to whole USDG; the test's check is exact to the unit.
3. **Nothing owed outside the ledgers:** no unclaimed winnings, no open pots, every round and every Seat day settled.
4. **Alms:** exactly 8% of every play, rounded per play as FairCore does. All of it reached the Alms Safe, for the charity the players voted for.
5. **$wif:** the burned $wif all sits at 0xdEaD; the Vault holds exactly what it bought; both routes hold nothing; FairPass holds 0 after the unlocks; every player has exactly their Pass back. The launch lock is 5,000 $wif (decided 29 Oct). The 25 Oct run that produced the USDG totals above locked 10,000 $wif and returned that amount.

## The edge cases it hit

| Case | What happened |
|---|---|
| Before the chapter | A shot and a take on 1 Nov were refused (`NoActiveFair`). |
| 24h hold | p5 locked 1 Nov 12:00. An unlock at 2 Nov 11:00 was refused (`HoldNotOver`); at 12:00 it worked. With no pass, p5's shot was refused (`NoPass`). p5 relocked. |
| Round ends on its clock | Quiet stretches on 2 Nov and 4 Nov ended rounds after an hour, including a short 4-shot round whose unfilled late shares rolled into the next round. |
| 24h hard end (removed since this run) | Non-stop shooting from 2 Nov 20:00 to 4 Nov 08:00 hit the old 24h wall. A round now has no hard end: it keeps going while shots come in and ends 1h after the last shot. |
| Payer ≠ player | About 1 shot in 20 was paid by p27 for someone else (zap-style); the credit went to the player. |
| Alms suggestions (3 Nov) | RED, BLUE, GREEN were suggested. p28 (holds a pass, never played) was refused (`NotPlayed`). |
| Alms vote (4 Nov) | 26 votes; BLUE won 12–9–5. p0's second vote was refused (`AlreadyVoted`). p29 (locked after suggestions opened) was refused (`NotEligibleVoter`). |
| Finalize and tranches | 5 Nov 00:00: BLUE finalized, 53 USDG released. 7 Nov: the late tranche of 15 USDG went to the same winner. A receipt was posted. |
| Quiet Seat day (v3.6 fix) | No takes on 4 Nov. The first take on 5 Nov settled 3 Nov, so the new "settle the last day with a take" path ran. |
| Emergency pause | 5 Nov 10:00–12:00. The live Last Arrow round's deadline moved exactly 2h. The Seat credited exactly 22h for 5 Nov (24h minus the 2h pause). 6 plays were refused (`Paused`). |
| End of the chapter | The last shot landed at 23:59:50 and won its round. A shot and a take at 00:00:05 were refused (`NoActiveFair`). |
| After the chapter | The keeper sweep settled the last round, every winner claimed, the Safe withdrew the Toll, and everyone unlocked. |

## What this doesn't cover

- **The block-number contract is a stand-in.** On a local fork, the chain's built-in block number (used for "one shot per L2 block") doesn't advance, so the simulation swaps in a small stand-in that ticks once per play. Forge 1.8.x can't do this at all, because it runs the real one frozen at the fork block, so the simulation needs forge 1.5.x. Unit tests cover the same-block rule itself.
- **No sequencer timing or latency.** Round ends on the real chain are speed races; here they're simply the next tick.
- **No other traders.** Pool prices moved only from our own buybacks, so the anchor-pump case and real volatility weren't exercised (the runbook covers them).
- **The keeper is a model** of the v2 rules inside the test, not the real keeper script on its host.
- **The Safe is a stand-in contract** acting as the owner, not a real multisig Safe with signatures. The testnet rehearsal covers that.
- **No site, wallets or Para.**
- **Volume is modest** (851 USDG). This run was about mechanics and accounting, not load. One seeded scenario; deterministic.
