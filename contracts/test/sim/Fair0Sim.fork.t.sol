// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FairPass} from "../../src/FairPass.sol";
import {FairCore} from "../../src/FairCore.sol";
import {LastArrow} from "../../src/LastArrow.sol";
import {SheriffsSeat} from "../../src/SheriffsSeat.sol";
import {AlmsVote} from "../../src/AlmsVote.sol";
import {LocksleyVault} from "../../src/LocksleyVault.sol";
import {FairLens} from "../../src/FairLens.sol";
import {PoolKey, IV4Quoter, QuoteExactSingleParams} from "../../src/interfaces/IV4Minimal.sol";
import {MockArbSys} from "../mocks/Mocks.sol";
import {Chapter0Dates} from "../../script/Chapter0Dates.sol";

/// Fair 0, the Nottingham Fair, end to end on a fork of Robinhood Chain mainnet with the real USDG, $wif, pools and
/// hooks. The deploy and the Safe's accept batch run first as real `forge script --broadcast` steps on a local node
/// (script/e2e/fair0_sim.sh); this test then plays the whole of Chapter 0 in 10-minute ticks on that node, then the Alms
/// vote ends (all times from script/Chapter0Dates.sol).
contract Fair0Sim is Test {
    // ---------------------------------------------------------------- chain
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant WIF = 0x5173b8eA6923c2d40267890D45C46a3480954773;
    address constant QUOTER = 0x8Dc178eFB8111BB0973Dd9d722ebeFF267c98F94;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    // Chapter 0 and Alms times from script/Chapter0Dates.sol, the same values DeployMainnet sets.
    uint64 constant START = Chapter0Dates.FAIR_START;
    uint64 constant END = Chapter0Dates.FAIR_END;
    uint64 constant SUGGEST = Chapter0Dates.ALMS_SUGGEST;
    uint64 constant VOTE = Chapter0Dates.ALMS_VOTE;
    uint64 constant VOTE_END = Chapter0Dates.ALMS_END; // after the chapter ends
    uint64 constant PAUSE_AT = START + 1 days + 4 hours; // day two 04:00-06:00 UTC emergency pause
    bytes32 constant RED = keccak256("red-cross-campaign");
    bytes32 constant BLUE = keccak256("blue-ocean-fund");
    bytes32 constant GREEN = keccak256("green-forest-trust");

    // ---------------------------------------------------------------- system
    FairPass pass;
    FairCore core;
    LastArrow arrow;
    SheriffsSeat seat;
    AlmsVote alms;
    LocksleyVault vault;
    FairLens lens;
    MockArbSys arb;
    address safe;
    address almsSafe;
    address keeper;
    address routeA;
    address routeB;
    uint256 almsSafeStart;
    uint256 tollStart;

    // ---------------------------------------------------------------- players
    uint256 constant N = 30;
    address[N] p;
    uint256 nonce;

    // ---------------------------------------------------------------- tallies
    uint256 spentArrow;
    uint256 spentSeat;
    uint256 shots;
    uint256 takes;
    uint256 claimed;
    uint256 almsReleased;
    uint256 tollOut;
    uint256 swappedUsdg;
    uint256 burnedWif;
    uint256 vaultWif;
    uint256 swapsOk;
    uint256 keeperSkipsBelowFloor;
    uint256 arrowSettledByKeeper;
    uint256 seatSettledByKeeper;
    uint256 fairEndRound;
    mapping(bytes4 => uint256) reverts; // why plays were refused
    bytes4[] reasonList;
    mapping(bytes4 => bool) seenReason;
    uint256 deadStart;
    uint256 almsExpected; // per-play rounding, exactly as FairCore splits each shot
    uint256 pauseRound;
    uint256 pauseRoundDeadline;

    // ================================================================== setup

    /// Needs a node where the real deploy and the Safe's accept batch already ran (script/e2e/fair0_sim.sh does it):
    /// SIM_RPC = that node, SIM_DEPLOYMENT = its deployments/4663.json, OWNER_SAFE, ALMS_SAFE, KEEPER.
    function setUp() public {
        if (bytes(vm.envOr("SIM_RPC", string(""))).length == 0) return; // plain `forge test`: skipped below
        vm.createSelectFork(vm.envString("SIM_RPC"));
        vm.etch(address(0x64), address(new MockArbSys()).code); // stand-in so each play can be its own L2 block
        arb = MockArbSys(address(0x64));
        arb.set(1_000_000);
        // forge 1.8.x runs Arbitrum's real ArbSys natively on Robinhood forks: frozen at the fork block, immune to
        // vm.roll and vm.etch. Every play after the first would then look like a same-block repeat. Use forge 1.5.x.
        require(arb.arbBlockNumber() == 1_000_000, "this forge emulates ArbSys natively: run the sim with forge 1.5.x");

        safe = vm.envAddress("OWNER_SAFE");
        almsSafe = vm.envAddress("ALMS_SAFE");
        keeper = vm.envAddress("KEEPER");

        string memory j = vm.readFile(vm.envString("SIM_DEPLOYMENT"));
        core = FairCore(vm.parseJsonAddress(j, ".fairCore"));
        pass = FairPass(vm.parseJsonAddress(j, ".fairPass"));
        arrow = LastArrow(vm.parseJsonAddress(j, ".lastArrow"));
        seat = SheriffsSeat(vm.parseJsonAddress(j, ".sheriffsSeat"));
        alms = AlmsVote(vm.parseJsonAddress(j, ".almsVote"));
        vault = LocksleyVault(vm.parseJsonAddress(j, ".locksleyVault"));
        lens = FairLens(vm.parseJsonAddress(j, ".fairLens"));
        routeA = vm.parseJsonAddress(j, ".routeA");
        routeB = vm.parseJsonAddress(j, ".routeB");
        assertEq(core.owner(), safe, "the Safe's accept batch has run");
        assertGt(core.anchorRate(), 0, "anchor seeded");
        almsSafeStart = IERC20(USDG).balanceOf(almsSafe);
        tollStart = IERC20(USDG).balanceOf(vm.envAddress("TOLL_RECIPIENT"));

        for (uint256 i; i < N; ++i) {
            p[i] = makeAddr(string.concat("player", vm.toString(i)));
            deal(USDG, p[i], 3_000e6);
            deal(WIF, p[i], 5_000e18);
            vm.startPrank(p[i]);
            IERC20(USDG).approve(address(core), type(uint256).max);
            IERC20(WIF).approve(address(pass), type(uint256).max);
            vm.stopPrank();
        }
        deal(USDG, p[27], 20_000e6); // p27 also pays for other players' shots (payer != player), like a zap
        deadStart = IERC20(WIF).balanceOf(DEAD);
    }

    // ================================================================== the run

    function test_fair0_fullSimulation() public {
        if (address(core) == address(0)) {
            vm.skip(true); // needs the prepared node: run script/e2e/fair0_sim.sh
            return;
        }
        _preFair();
        for (uint256 t = START; t < END; t += 10 minutes) {
            _tick(t);
        }
        _fairEndAndAfter();
        _finalChecks();
    }

    function _preFair() internal {
        vm.warp(START - 23 hours); // 1 Nov 01:00 (the deploy ran earlier, before the 1 Nov 11:00 deadline)
        for (uint256 i; i < N; ++i) {
            if (i == 29) continue; // p29 locks late (after suggestions open): can play, can't vote
            vm.prank(p[i]);
            pass.lock(WIF, 5_000e18);
        }
        // Before the Fair: nothing can be played.
        _shootAs(p[0], p[0]);
        _takeAs(p[0], p[0]);
        assertEq(reverts[FairCore.NoActiveFair.selector], 2, "no play before the Fair");
        console2.log("== deployed with seed, Safe accepted and re-seeded; 29 passes locked 1 Nov 01:00 UTC");
        console2.log("anchor ($wif per USDG):", core.anchorRate() / 1e30);
    }

    function _tick(uint256 t) internal {
        vm.warp(t);
        _events(t);
        uint256 n = _arrowIntensity(t);
        for (uint256 k; k < n; ++k) {
            _randomShot(t + k * 7);
        }
        if (_seatScheduled(t)) _randomTake();
        if ((t - START) % 1 hours == 0) {
            _keeperBuys();
            _keeperSettles();
        }
        if ((t - START) % 1 days == 0 && t != START) _dailyLog(t);
    }

    // ---------------------------------------------------------------- schedule

    /// How many Last Arrow shots land in this 10-minute tick.
    function _arrowIntensity(uint256 t) internal returns (uint256) {
        uint256 h = (t - START) / 1 hours; // hours since the Fair opened
        if (h >= 12 && h < 14) return 0; // 2 Nov 12:00-14:00 quiet: the round ends on its clock
        if (h == 14 && t % 1 hours < 40 minutes) return 1; // a short round: 4 shots, then quiet
        if (h >= 14 && h < 20) return 0;
        if (h >= 20 && h < 28) return 1 + _rnd() % 2; // 2 Nov 20:00 -> 3 Nov 04:00 non-stop: one round, no hard end
        if (h >= 40 && h < 44) return 0; // 3 Nov 16:00-20:00 quiet: the round ends
        if (t >= END - 1 hours) return 2; // the final hour is busy
        return _rnd() % 2; // otherwise about half the ticks
    }

    /// Seat takes: every 2 hours on 2 and 3 Nov; a bidding war on 2 Nov at 15:00.
    function _seatScheduled(uint256 t) internal returns (bool) {
        if (t == START + 15 hours) {
            for (uint256 k; k < 6; ++k) {
                _randomTake(); // six takes in six blocks: the price climbs 1.5x each time
            }
            return false;
        }
        return (t - START) % 2 hours == 0;
    }

    /// One-off events at fixed times.
    function _events(uint256 t) internal {
        if (t == START) _unlockHoldCheck();
        if (t == SUGGEST + 6 hours) {
            vm.prank(p[29]);
            pass.lock(WIF, 5_000e18); // late lock: plays from now on, but can't vote
        }
        if (t == SUGGEST) _suggestions();
        if (t == VOTE) _votes();
        if (t == PAUSE_AT) {
            _randomShot(t); // make sure a round is live when the pause hits
            pauseRound = arrow.currentRound();
            pauseRoundDeadline = arrow.effectiveDeadline(pauseRound);
            assertGt(pauseRoundDeadline, block.timestamp, "a round is live at the pause");
            vm.prank(safe);
            core.pauseSales(true); // 3 Nov 04:00-06:00 emergency pause
            console2.log("== 3 Nov 04:00 Safe pauses sales");
        }
        if (t == PAUSE_AT + 2 hours) {
            vm.prank(safe);
            core.pauseSales(false);
            assertEq(arrow.effectiveDeadline(pauseRound), pauseRoundDeadline + 2 hours, "Arrow clock shifted 2h");
            console2.log("   the live Arrow round's deadline moved exactly 2h; round", pauseRound);
            console2.log("== 3 Nov 06:00 Safe unpauses");
        }
    }

    // ---------------------------------------------------------------- plays

    function _rnd() internal returns (uint256) {
        return uint256(keccak256(abi.encode(nonce++)));
    }

    function _noteRevert(bytes memory e) internal {
        bytes4 s = e.length >= 4 ? bytes4(e) : bytes4(0);
        if (!seenReason[s]) {
            seenReason[s] = true;
            reasonList.push(s);
        }
        ++reverts[s];
    }

    function _shootAs(address payer, address player) internal returns (bool ok) {
        arb.set(arb.n() + 1);
        uint256 maxP = arrow.currentPrice() * 101 / 100; // front-run guard
        uint256 before = IERC20(USDG).balanceOf(payer);
        uint256 r11 = arrow.nextShotRound();
        vm.prank(payer);
        try arrow.shoot(maxP, player, r11) returns (uint256) {
            uint256 g = before - IERC20(USDG).balanceOf(payer);
            spentArrow += g;
            almsExpected += (g - g * 6000 / 10_000) * 2000 / 10_000;
            ++shots;
            ok = true;
        } catch (bytes memory e) {
            _noteRevert(e);
        }
    }

    function _randomShot(uint256 salt) internal {
        uint256 id = arrow.currentRound();
        address last = arrow.roundState(id).lastShooter;
        uint256 i = (_rnd() ^ salt) % 28; // p0-p27; p28 never plays; p29 plays only once it has locked (below)
        if (p[i] == last) i = (i + 1) % 28;
        if ((_rnd() % 20) == 0 && p[i] != p[27]) _shootAs(p[27], p[i]); // zap-style: p27 pays, p[i] gets the credit
        else _shootAs(p[i], p[i]);
        if (block.timestamp >= SUGGEST + 6 hours && _rnd() % 15 == 0 && last != p[29]) _shootAs(p[29], p[29]);
    }

    function _takeAs(address payer, address player) internal returns (bool ok) {
        arb.set(arb.n() + 1);
        uint256 before = IERC20(USDG).balanceOf(payer);
        vm.prank(payer);
        try seat.take(type(uint256).max, player, "for the greenwood", uint8(_rnd() % 8)) returns (uint256) {
            uint256 g = before - IERC20(USDG).balanceOf(payer);
            spentSeat += g;
            almsExpected += (g - g * 6000 / 10_000) * 2000 / 10_000;
            ++takes;
            ok = true;
        } catch (bytes memory e) {
            _noteRevert(e);
        }
    }

    function _randomTake() internal {
        (address holder,,) = seat.holderOf(seat.today());
        uint256 i = _rnd() % 28;
        if (p[i] == holder) i = (i + 1) % 28;
        _takeAs(p[i], p[i]);
    }

    // ---------------------------------------------------------------- keeper

    function _quoteA(uint256 usdgIn) internal returns (uint256) {
        PoolKey memory up = PoolKey(address(0), USDG, 0x800000, 10, 0x06a889870C8f83640D6816319f72e2aA579b6080);
        PoolKey memory wp = PoolKey(address(0), WIF, 0, 200, 0xE5e702641Ea86F4ae6cC3cDaeD2B886f976Be044);
        (uint256 eth,) = IV4Quoter(QUOTER).quoteExactInputSingle(QuoteExactSingleParams(up, false, uint128(usdgIn), ""));
        (uint256 w,) = IV4Quoter(QUOTER).quoteExactInputSingle(QuoteExactSingleParams(wp, true, uint128(eth), ""));
        return w;
    }

    /// Route B's output for a ledger, by running it on a snapshot and rolling back.
    function _dryRunB(uint256 ledger, uint256 amt) internal returns (uint256 out) {
        uint256 floorMin = amt * core.ratchetFloorRate() / 1e18;
        uint256 snap = vm.snapshotState();
        vm.prank(keeper);
        try this.extSwap(ledger, 1, amt, floorMin) returns (uint256 o) {
            out = o;
        } catch {}
        vm.revertToState(snap);
    }

    function extSwap(uint256 ledger, uint256 route, uint256 amt, uint256 minOut) external returns (uint256) {
        vm.prank(keeper);
        if (ledger == 2) return core.buyForVault(route, amt, minOut);
        return
            core.burnBuyToken(ledger == 0 ? FairCore.BurnSource.Bonfire : FairCore.BurnSource.Vault, route, amt, minOut);
    }

    /// The v2 keeper's rules: per ledger, quote both routes, take the better, minOut = quote - 3%, skip if that is
    /// below the onchain floor, skip below 5 USDG. TooSoon / DailyCap are skips.
    function _keeperBuys() internal {
        for (uint256 l; l < 3; ++l) {
            uint256 pending = l == 0 ? core.bonfirePending() : l == 1 ? core.vaultBurnPending() : core.vaultBuyPending();
            if (pending < 5e6) continue;
            uint256 amt = pending < 250e6 ? pending : 250e6;
            uint256 qa = _quoteA(amt);
            uint256 qb = _dryRunB(l, amt);
            (uint256 route, uint256 q) = qb > qa ? (uint256(1), qb) : (uint256(0), qa);
            uint256 minOut = q * 97 / 100;
            if (minOut < amt * core.ratchetFloorRate() / 1e18) {
                ++keeperSkipsBelowFloor;
                continue;
            }
            uint256 deadBefore = IERC20(WIF).balanceOf(DEAD);
            uint256 vaultBefore = IERC20(WIF).balanceOf(address(vault));
            try this.extSwap(l, route, amt, minOut) returns (uint256) {
                ++swapsOk;
                swappedUsdg += amt;
                burnedWif += IERC20(WIF).balanceOf(DEAD) - deadBefore;
                vaultWif += IERC20(WIF).balanceOf(address(vault)) - vaultBefore;
            } catch (bytes memory e) {
                _noteRevert(e);
            }
        }
    }

    function _keeperSettles() internal {
        uint256 cr = arrow.currentRound();
        for (uint256 r = 1; r <= cr; ++r) {
            LastArrow.Round memory R = arrow.roundState(r);
            if (!R.settled && block.timestamp >= arrow.effectiveDeadline(r)) {
                arrow.settle(r);
                ++arrowSettledByKeeper;
            }
        }
        uint256 today = seat.today();
        for (uint256 d = seat.dayId(START); d < today; ++d) {
            if (!seat.isSettled(d) && core.pot(address(seat), d) != 0) {
                seat.settle(d);
                ++seatSettledByKeeper;
            }
        }
    }

    // ---------------------------------------------------------------- edge events

    /// p5 locked 1 Nov 01:00. At 2 Nov 00:00 the hold isn't over; at 01:00 it is. Unlocked, p5 can't play.
    function _unlockHoldCheck() internal {
        vm.prank(p[5]);
        vm.expectRevert(abi.encodeWithSelector(FairPass.HoldNotOver.selector, uint256(START - 23 hours) + 24 hours));
        pass.unlock();
        vm.warp(START + 1 hours);
        vm.prank(p[5]);
        pass.unlock();
        assertEq(IERC20(WIF).balanceOf(p[5]), 5_000e18, "p5 got exactly 5k back");
        _shootAs(p[5], p[5]);
        assertGt(reverts[LastArrow.NoPass.selector], 0, "no pass, no shot");
        vm.prank(p[5]);
        pass.lock(WIF, 5_000e18); // relocks before suggestions open (12:00): still a voter
        vm.warp(START);
        console2.log("== 2 Nov 00:00 p5: unlock refused (24h hold); 01:00 unlocked, shot refused, relocked");
    }

    function _suggestions() internal {
        vm.prank(p[0]);
        alms.suggest(0, RED);
        vm.prank(p[1]);
        alms.suggest(0, BLUE);
        vm.prank(p[2]);
        alms.suggest(0, GREEN);
        vm.prank(p[28]); // has a pass from before, never played
        vm.expectRevert(AlmsVote.NotPlayed.selector);
        alms.suggest(0, RED);
        console2.log("== 2 Nov 12:00 suggestions: RED, BLUE, GREEN; p28 (never played) refused");
    }

    function _votes() internal {
        uint256 cast_;
        uint256 notPlayed;
        for (uint256 i; i < 26; ++i) {
            bytes32 c = i < 12 ? BLUE : i < 21 ? RED : GREEN;
            if (!core.playedIn(0, p[i])) {
                ++notPlayed;
                continue;
            }
            vm.prank(p[i]);
            alms.vote(0, c);
            ++cast_;
        }
        vm.prank(p[0]);
        vm.expectRevert(AlmsVote.AlreadyVoted.selector);
        alms.vote(0, RED);
        vm.prank(p[29]); // played, but locked after suggestions opened
        vm.expectRevert(AlmsVote.NotEligibleVoter.selector);
        alms.vote(0, BLUE);
        console2.log("== 3 Nov 12:00 votes cast:", cast_, "skipped (never played):", notPlayed);
        console2.log("   p0 second vote refused; p29 (late lock) refused");
    }

    function _finalizeAndFirstTranche() internal {
        alms.finalize(0);
        (,,,,, bytes32 winner,) = alms.results(0);
        assertEq(winner, BLUE, "BLUE has the most votes");
        uint256 a = alms.releaseAlms(0);
        almsReleased += a;
        console2.log("== 4 Nov 12:00 vote over, finalize: BLUE wins; Alms to the Alms Safe (USDG):", a / 1e6);
    }

    // ---------------------------------------------------------------- end of the Fair

    function _fairEndAndAfter() internal {
        // The last shot lands at 23:59:50; the Fair's end freezes the round on it.
        vm.warp(END - 10);
        address lastP = p[3] == arrow.roundState(arrow.currentRound()).lastShooter ? p[4] : p[3];
        assertTrue(_shootAs(lastP, lastP), "last shot before the end");
        fairEndRound = arrow.currentRound();
        vm.warp(END + 5);
        uint256 before = reverts[FairCore.NoActiveFair.selector];
        _shootAs(p[6], p[6]);
        _takeAs(p[6], p[6]);
        assertEq(reverts[FairCore.NoActiveFair.selector], before + 2, "nothing lands after the Fair");

        vm.warp(END + 1 hours + 1);
        _keeperSettles();
        _keeperBuys();
        (, address winnerOfLast) = _lastWinner(fairEndRound);
        assertEq(winnerOfLast, lastP, "the Fair-end round went to the last shot before the end");

        // Timeline A1: the Fair is over before the vote ends. Finalize at 4 Nov 12:00, one tranche with all of it.
        vm.expectRevert(AlmsVote.WrongWindow.selector);
        alms.finalize(0);
        vm.warp(VOTE_END);
        _finalizeAndFirstTranche();
        assertEq(core.almsByFair(0), 0, "all of Fair 0's Alms released");
        assertEq(alms.releaseAlms(0), 0, "nothing left for a second tranche");
        vm.prank(safe);
        alms.postReceipt(0, 1, bytes32(uint256(1)), "https://donate.gg/receipt/example");

        // Everyone claims; the Safe withdraws the Toll.
        for (uint256 i; i < N; ++i) {
            uint256 c = core.claimable(p[i]);
            if (c == 0) continue;
            vm.prank(p[i]);
            core.claim();
            claimed += c;
        }
        uint256 tp = core.tollPending();
        vm.prank(safe);
        core.withdrawToll(tp);
        tollOut = tp;

        // Everyone unlocks (every hold is over by now) and gets exactly 5k back.
        for (uint256 i; i < N; ++i) {
            if (!pass.hasPass(p[i])) continue;
            vm.prank(p[i]);
            pass.unlock();
        }
    }

    function _lastWinner(uint256 r) internal view returns (bool settled, address last) {
        LastArrow.Entry[] memory e = arrow.lastShots(r);
        return (arrow.roundState(r).settled, e[0].shooter);
    }

    // ---------------------------------------------------------------- checks and logs

    function _finalChecks() internal view {
        uint256 bal = IERC20(USDG).balanceOf(address(core));
        uint256 spent = spentArrow + spentSeat;
        console2.log("");
        console2.log("================ FINAL ================");
        console2.log("shots:", shots, "takes:", takes);
        console2.log("rounds:", arrow.currentRound());
        console2.log("spent on Last Arrow (USDG):", spentArrow / 1e6);
        console2.log("spent on the Seat (USDG):  ", spentSeat / 1e6);
        console2.log("claimed by winners:        ", claimed / 1e6);
        console2.log("Alms to the Alms Safe:     ", almsReleased / 1e6);
        console2.log("Toll withdrawn:            ", tollOut / 1e6);
        console2.log("USDG swapped for $wif:     ", swappedUsdg / 1e6, "in swaps:", swapsOk);
        console2.log("$wif burned:               ", burnedWif / 1e18);
        console2.log("$wif bought for the Vault: ", vaultWif / 1e18);
        console2.log("keeper skips below floor:  ", keeperSkipsBelowFloor);
        console2.log("keeper settles: arrow", arrowSettledByKeeper, "seat", seatSettledByKeeper);
        console2.log("left in FairCore (USDG, 6dp):", bal);
        console2.log("  vault ledgers:", core.vaultLiqUsdg() + core.vaultFairsBurnUsdg());
        console2.log("  buyback ledgers:", core.bonfirePending() + core.vaultBurnPending() + core.vaultBuyPending());
        console2.log("  rollovers:", core.rollover(address(arrow)) + core.rollover(address(seat)));
        console2.log("anchor at end ($wif per USDG):", core.anchorRate() / 1e30);
        for (uint256 i; i < reasonList.length; ++i) {
            console2.log(
                "refused plays, selector", vm.toString(abi.encodePacked(reasonList[i])), reverts[reasonList[i]]
            );
        }

        // 1. Exact solvency, and every USDG accounted for.
        assertEq(bal, core.accounted(), "FairCore holds exactly what it owes");
        assertEq(spent, claimed + almsReleased + tollOut + swappedUsdg + bal, "USDG in == USDG out + held");
        uint256 ledgers = core.vaultLiqUsdg() + core.vaultFairsBurnUsdg() + core.bonfirePending()
            + core.vaultBurnPending() + core.vaultBuyPending() + core.tollPending() + core.rollover(address(arrow))
            + core.rollover(address(seat)) + core.almsByFair(0) + core.almsByFair(1);
        assertEq(bal, ledgers, "nothing owed outside the ledgers (no unclaimed, no open pots)");
        // 2. Every round and day with money is settled; nobody left unclaimed.
        for (uint256 r = 1; r <= arrow.currentRound(); ++r) {
            assertTrue(arrow.roundState(r).settled, "round settled");
        }
        for (uint256 d = seat.dayId(START); d < seat.dayId(END); ++d) {
            assertEq(core.pot(address(seat), d), 0, "no Seat pot left");
        }
        for (uint256 i; i < N; ++i) {
            assertEq(core.claimable(p[i]), 0);
        }
        // 3. $wif: every fill reached its destination; the Pass holds nothing after unlocks.
        assertEq(IERC20(WIF).balanceOf(DEAD) - deadStart, burnedWif, "burned $wif all at 0xdEaD");
        assertEq(IERC20(WIF).balanceOf(address(vault)), vaultWif, "Vault holds exactly what it bought");
        assertEq(IERC20(WIF).balanceOf(address(pass)), 0, "every pass returned");
        assertEq(pass.totalLocked(WIF), 0);
        for (uint256 i; i < N; ++i) {
            assertEq(IERC20(WIF).balanceOf(p[i]), 5_000e18, "everyone has their 5k back");
        }
        // 3b. The Seat on 3 Nov (takes from 00:00, paused 04:00-06:00): exactly 22h credited across all holders.
        uint256 d5 = seat.dayId(START + 1 days);
        uint256 credited;
        for (uint256 i; i < N; ++i) {
            credited += seat.secsOf(d5, p[i]);
        }
        assertEq(credited, 22 hours, "paused time never credited");
        // 4. Alms: all of Fair 0's Alms went to the Alms Safe for BLUE.
        assertEq(IERC20(USDG).balanceOf(almsSafe) - almsSafeStart, almsReleased, "Alms Safe got exactly the Alms");
        assertEq(
            IERC20(USDG).balanceOf(vm.envAddress("TOLL_RECIPIENT")) - tollStart, tollOut, "Toll recipient got the Toll"
        );
        assertEq(almsReleased, almsExpected, "Alms = 8% of every play, rounded per play as FairCore does");
        // 5. Routes hold nothing.
        assertEq(IERC20(USDG).balanceOf(routeA) + IERC20(USDG).balanceOf(routeB), 0, "routes hold no USDG");
        assertEq(IERC20(WIF).balanceOf(routeA) + IERC20(WIF).balanceOf(routeB), 0, "routes hold no $wif");
        console2.log("ALL MONEY CHECKS PASS");
    }

    function _dailyLog(uint256 t) internal view {
        FairLens.Greenwood memory g = lens.greenwood();
        console2.log("-- end of day", (t - START) / 1 days, "(UTC date: Nov", 1 + (t - START) / 1 days);
        console2.log("   shots", shots, "takes", takes);
        console2.log("   rounds so far", arrow.currentRound(), "swaps ok", swapsOk);
        console2.log("   accounted (USDG)", g.accounted / 1e6, "solvent", g.solvent);
        console2.log("   Alms this Fair", g.almsThisFair / 1e6, "anchor $wif/USDG", core.anchorRate() / 1e30);
    }
}
