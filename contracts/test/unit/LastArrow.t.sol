// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Base} from "../Base.t.sol";
import {FairCore} from "../../src/FairCore.sol";
import {LastArrow} from "../../src/LastArrow.sol";
import {FairLens, IVaultView} from "../../src/FairLens.sol";
import {SheriffsSeat} from "../../src/SheriffsSeat.sol";
import {IFairCore} from "../../src/interfaces/IFair.sol";
import {MockArbSys} from "../mocks/Mocks.sol";

/// A contract wallet (smart wallet, zap, batcher) shooting for a user.
contract Shooter {
    function fire(LastArrow la, address usdg, address core, uint256 maxPrice, address player) external {
        (bool ok,) = usdg.call(abi.encodeWithSignature("approve(address,uint256)", core, maxPrice));
        require(ok);
        la.shoot(maxPrice, player, la.nextShotRound());
    }
}

/// FairLens only reads day0() from the seat at construction; arrowNow() never touches it.
contract SeatDay0Stub {
    function day0() external pure returns (uint256) {
        return 0;
    }
}

contract LastArrowTest is Base {
    LastArrow la;
    MockArbSys arb;

    function wireBooths() internal override {
        la = new LastArrow(IFairCore(address(core)));
        core.setupSet(FairCore.Op.AddBooth, 0, address(la));
    }

    function setUp() public override {
        super.setUp();
        vm.etch(address(0x64), address(new MockArbSys()).code);
        arb = MockArbSys(address(0x64));
        arb.set(1_000_000);
        address[3] memory people = [ana, bob, cat];
        for (uint256 i; i < 3; ++i) {
            vm.prank(people[i]);
            pass.lock(address(wif), PASS_LOCK);
        }
        openFair();
    }

    /// Next L2 block, then shoot as `who` (paying for themselves).
    function fire(address who) internal returns (uint256 price) {
        arb.set(arb.n() + 1);
        uint256 r1 = la.nextShotRound();
        vm.prank(who);
        price = la.shoot(type(uint256).max, address(0), r1);
    }

    /// Alternate ana / bob for n shots.
    function volley(uint256 n) internal {
        for (uint256 i; i < n; ++i) {
            fire(i % 2 == 0 ? ana : bob);
        }
    }

    // ---------------------------------------------------------------- price

    function test_price_startsAt1_andRisesHalfPercent() public {
        assertEq(fire(ana), 1e6);
        assertEq(fire(bob), 1_005_000);
        assertEq(fire(ana), 1_010_025);
    }

    /// Spec table: shot 100 ~1.64, shot 1000 ~145.85, round total through 1000 ~29,115.13 (integer rounding drifts
    /// a little below the closed form).
    function test_price_shot1000_matchesSpec() public {
        uint256 p = 1e6;
        uint256 total;
        for (uint256 k = 1; k <= 1000; ++k) {
            if (k == 100) assertApproxEqAbs(p, 1_640_000, 5_000);
            total += p;
            if (k < 1000) p = p * 1005 / 1000;
        }
        assertApproxEqAbs(p, 145_850_000, 100_000, "shot 1000 ~145.85");
        assertApproxEqAbs(total, 29_115_130_000, 15_000_000, "round total ~29,115");
    }

    function test_maxPrice_frontRunGuard() public {
        fire(ana);
        arb.set(arb.n() + 1);
        uint256 r2 = la.nextShotRound();
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(LastArrow.PriceAboveMax.selector, 1_005_000, 1_004_999));
        la.shoot(1_004_999, address(0), r2);
    }

    // ---------------------------------------------------------------- K16-D-A02 expectedRound

    /// The round ana saw lapses before her tx lands: her shot reverts instead of opening a fresh round at 1 USDG.
    function test_K16DA02_lapsedRound_staleExpected_reverts() public {
        fire(bob);
        uint256 seen = la.nextShotRound();
        assertEq(seen, 1);
        vm.warp(vm.getBlockTimestamp() + 1 hours + 1); // round 1 lapses while ana's tx is pending
        arb.set(arb.n() + 1);
        vm.prank(ana);
        vm.expectRevert(abi.encodeWithSelector(LastArrow.WrongRound.selector, 1, 2));
        la.shoot(type(uint256).max, address(0), seen);
        // shooting into the new round on purpose works
        uint256 next = la.nextShotRound();
        assertEq(next, 2);
        vm.prank(ana);
        assertEq(la.shoot(type(uint256).max, address(0), next), 1e6);
    }

    function test_K16DA02_futureRound_reverts() public {
        fire(bob);
        arb.set(arb.n() + 1);
        vm.prank(ana);
        vm.expectRevert(abi.encodeWithSelector(LastArrow.WrongRound.selector, 2, 1));
        la.shoot(type(uint256).max, address(0), 2);
    }

    function testFuzz_K16DA02_onlyTheLiveRoundIsAccepted(uint256 expected, uint256 dt) public {
        fire(bob);
        dt = bound(dt, 0, 3 hours);
        vm.warp(vm.getBlockTimestamp() + dt);
        arb.set(arb.n() + 1);
        uint256 want = la.nextShotRound();
        expected = bound(expected, 0, 5);
        vm.prank(ana);
        if (expected != want) {
            vm.expectPartialRevert(LastArrow.WrongRound.selector);
            la.shoot(type(uint256).max, address(0), expected);
        } else {
            la.shoot(type(uint256).max, address(0), expected);
            assertEq(la.currentRound(), want);
        }
    }

    // ---------------------------------------------------------------- timer

    function test_timer_opens1h_bumps10min_capped1h() public {
        fire(ana);
        LastArrow.Round memory R = la.roundState(1);
        assertEq(R.hardEnd, 0, "no hard end");
        assertEq(R.deadline, vm.getBlockTimestamp() + 1 hours, "first shot can't push past 1h");
        vm.warp(vm.getBlockTimestamp() + 30 minutes); // 30 min left
        fire(bob);
        assertEq(la.roundState(1).deadline, vm.getBlockTimestamp() + 40 minutes, "+10 min");
        fire(ana);
        fire(bob);
        fire(ana); // would be +70 min; capped at 1h
        assertEq(la.roundState(1).deadline, vm.getBlockTimestamp() + 1 hours);
    }

    /// No fixed maximum length: shots past 24h keep the same round alive, and it ends 1h after the last shot.
    function test_timer_runsPast24h_endsOneHourAfterLastShot() public {
        uint256 start = vm.getBlockTimestamp();
        uint256 n;
        for (uint256 i; i < 160; ++i) {
            uint256 t = start + i * 10 minutes;
            if (t > start + 25 hours) break;
            vm.warp(t);
            fire(i % 2 == 0 ? ana : bob);
            n = i + 1;
            assertEq(la.currentRound(), 1, "shots keep this round open past 24h");
            assertEq(la.roundState(1).hardEnd, 0);
        }
        uint256 lastShot = vm.getBlockTimestamp();
        assertGt(lastShot, start + 24 hours, "played past the old 24h wall");
        LastArrow.Round memory R = la.roundState(1);
        assertEq(R.shots, n);
        assertEq(R.deadline, lastShot + 1 hours, "clock is 1h from the last shot");
        assertEq(la.timeLeft(), 1 hours);
        vm.warp(lastShot + 1 hours - 1);
        vm.expectRevert(LastArrow.NotEnded.selector);
        la.settle(1);
        vm.warp(lastShot + 1 hours);
        la.settle(1);
        assertTrue(la.roundState(1).settled);
        assertEq(la.effectiveDeadline(1), lastShot + 1 hours);
        assertEq(la.roundState(1).hardEnd, 0);
    }

    function test_shotAtDeadlineSecond_opensNewRound() public {
        fire(ana);
        vm.warp(la.roundState(1).deadline);
        fire(bob);
        assertEq(la.currentRound(), 2, "deadline second belongs to the next round");
        assertTrue(la.roundState(1).settled);
    }

    // ---------------------------------------------------------------- bot rules

    function test_noBackToBack_evenWhenPaidBySomeoneElse() public {
        fire(ana);
        arb.set(arb.n() + 1);
        uint256 r3 = la.nextShotRound();
        vm.prank(ana);
        vm.expectRevert(LastArrow.BackToBack.selector);
        la.shoot(type(uint256).max, address(0), r3);
        uint256 r4 = la.nextShotRound();
        vm.prank(bob); // bob pays, ana is credited: still back-to-back for ana
        vm.expectRevert(LastArrow.BackToBack.selector);
        la.shoot(type(uint256).max, ana, r4);
    }

    function test_oneShotPerL2Block_evenFromDifferentWallets() public {
        fire(ana);
        uint256 r5 = la.nextShotRound();
        vm.prank(bob); // same L2 block
        vm.expectRevert(LastArrow.SameBlock.selector);
        la.shoot(type(uint256).max, address(0), r5);
        vm.roll(block.number + 100); // block.number (the L1 estimate) is not what gates it
        uint256 r6 = la.nextShotRound();
        vm.prank(bob);
        vm.expectRevert(LastArrow.SameBlock.selector);
        la.shoot(type(uint256).max, address(0), r6);
    }

    function test_needsFairPass_forThePlayer() public {
        address dan = makeAddr("dan");
        fund(dan);
        arb.set(arb.n() + 1);
        uint256 r7 = la.nextShotRound();
        vm.prank(dan);
        vm.expectRevert(LastArrow.NoPass.selector);
        la.shoot(type(uint256).max, address(0), r7);
        uint256 r8 = la.nextShotRound();
        vm.prank(dan); // dan pays for ana, who has a pass: allowed
        la.shoot(type(uint256).max, ana, r8);
    }

    function test_contractCaller_canShoot_forAUser() public {
        Shooter s = new Shooter();
        usdg.mint(address(s), 10e6);
        uint256 anaBefore = usdg.balanceOf(ana);
        arb.set(arb.n() + 1);
        s.fire(la, address(usdg), address(core), 2e6, ana);
        assertEq(usdg.balanceOf(ana), anaBefore, "USDG came from the contract, not ana");
        assertEq(la.countOf(1, ana), 1);
        assertTrue(core.playedIn(0, ana));
    }

    function testFuzz_payerNeverMovesPlayersUsdg(address payer) public {
        vm.assume(payer != address(0) && payer != ana && payer.code.length == 0 && payer != address(core));
        usdg.mint(payer, 10e6);
        vm.prank(payer);
        usdg.approve(address(core), type(uint256).max);
        uint256 anaBefore = usdg.balanceOf(ana);
        arb.set(arb.n() + 1);
        uint256 r9 = la.nextShotRound();
        vm.prank(payer);
        la.shoot(type(uint256).max, ana, r9);
        assertEq(usdg.balanceOf(ana), anaBefore);
    }

    // ---------------------------------------------------------------- settle and payouts

    function test_settle_onlyAfterDeadline_once() public {
        fire(ana);
        vm.expectRevert(LastArrow.NotEnded.selector);
        la.settle(1);
        vm.warp(la.roundState(1).deadline);
        la.settle(1);
        vm.expectRevert(LastArrow.AlreadySettled.selector);
        la.settle(1);
        vm.expectRevert(LastArrow.NoRound.selector);
        la.settle(9);
    }

    /// 20-shot round, ana and bob alternating; cat fires shot 21 last.
    function test_payouts_50_35_15() public {
        volley(20);
        fire(cat);
        uint256 purse = core.pot(address(la), 1);
        vm.warp(la.roundState(1).deadline);
        la.settle(1);

        // last shot: cat
        assertEq(core.claimable(cat), purse * 5000 / 10_000, "50% to the last shot");
        // shots 11..20 (ana took the odd ones, bob the even ones) share 35% by price; leader = ana (10 shots, first)
        uint256 lateSum;
        uint256 anaLate;
        uint256 p = 1e6;
        for (uint256 k = 1; k <= 20; ++k) {
            if (k >= 11) {
                lateSum += p;
                if (k % 2 == 1) anaLate += p;
            }
            p = p * 1005 / 1000;
        }
        uint256 late = purse * 3500 / 10_000;
        assertApproxEqAbs(
            core.claimable(ana),
            late * anaLate / lateSum + purse * 1500 / 10_000,
            5,
            "ana: late + most (5 rounded shares)"
        );
        assertApproxEqAbs(core.claimable(bob), late * (lateSum - anaLate) / lateSum, 5, "bob: late");
        assertLe(core.claimable(ana) + core.claimable(bob) + core.claimable(cat), purse);
        assertLe(core.rollover(address(la)), 12, "only rounding dust (< 1 unit per share) rolls over");
        assertSolvent();
    }

    /// 1 shot: last 50% + most 15% to the shooter; the whole 35% rolls over and seeds round 2.
    function test_oneShotRound_35rollsOver_andSeedsNext() public {
        fire(ana);
        uint256 purse = core.pot(address(la), 1);
        vm.warp(la.roundState(1).deadline);
        la.settle(1);
        assertEq(core.claimable(ana), purse * 5000 / 10_000 + purse * 1500 / 10_000);
        uint256 rolled = core.rollover(address(la));
        assertEq(rolled, purse - core.claimable(ana));
        fire(bob); // round 2
        assertEq(core.pot(address(la), 2), 600_000 + rolled, "own 60% + exactly the rollover");
    }

    /// 6 shots: 5 late shots take 5/10 of the 35%, pro-rata; the other 5/10 roll over.
    function test_sixShotRound_halfOfLateRollsOver() public {
        volley(6);
        uint256 purse = core.pot(address(la), 1);
        vm.warp(la.roundState(1).deadline);
        la.settle(1);
        uint256 paid = core.claimable(ana) + core.claimable(bob);
        uint256 expectedRoll = purse * 3500 / 10_000 / 2;
        assertApproxEqAbs(core.rollover(address(la)), expectedRoll, 6);
        assertApproxEqAbs(paid + core.rollover(address(la)), purse, 0);
    }

    /// Review ask: once a new round starts, the last round's winners are locked in.
    function test_newRoundAutoSettlesOld_andWinnersStayLocked() public {
        volley(4);
        vm.warp(la.roundState(1).deadline + 1);
        fire(cat); // opens round 2 and settles round 1 on the way
        assertTrue(la.roundState(1).settled);
        uint256 bobWon = core.claimable(bob);
        assertGt(bobWon, 0, "bob fired round 1's last shot");
        volley(10); // lots of round-2 play
        assertEq(core.claimable(bob), bobWon, "round-1 winnings unchanged by round 2");
        vm.prank(bob);
        core.claim();
        vm.expectRevert(LastArrow.AlreadySettled.selector);
        la.settle(1);
    }

    function test_mostShots_tieStaysWithFirst() public {
        fire(ana);
        fire(bob);
        fire(ana);
        fire(bob); // 2-2: ana reached 2 first
        assertEq(la.roundState(1).leader, ana);
    }

    function test_lastShots_newestFirst() public {
        volley(13);
        LastArrow.Entry[] memory e = la.lastShots(1);
        assertEq(e.length, 11);
        assertEq(e[0].shooter, ana, "shot 13 (odd count from 0) is ana");
        assertGt(e[0].price, e[1].price);
    }

    /// Audit L1: pausing stops the clock, so a pause can't end a round on a chosen shot.
    function test_pause_freezesClock_thenResumes() public {
        fire(ana);
        uint256 left = la.timeLeft(); // 1h
        vm.prank(owner);
        core.pauseSales(true);
        vm.warp(vm.getBlockTimestamp() + 3 hours); // far past the old deadline
        arb.set(arb.n() + 1);
        uint256 r10 = la.nextShotRound();
        vm.prank(bob);
        vm.expectRevert(FairCore.Paused.selector);
        la.shoot(type(uint256).max, address(0), r10);
        vm.expectRevert(LastArrow.NotEnded.selector);
        la.settle(1); // the clock is frozen
        assertEq(la.timeLeft(), left, "no time lost while paused");
        vm.prank(owner);
        core.pauseSales(false);
        fire(bob); // round 1 is still live after the pause
        assertEq(la.currentRound(), 1);
        vm.warp(la.effectiveDeadline(1));
        la.settle(1);
        vm.prank(bob);
        core.claim();
    }

    /// A pause after settle does not move that round's deadline. A pause while it was live still does.
    function test_LA02_settledDeadlineDoesNotGrow() public {
        fire(ana);
        uint256 raw = la.roundState(1).deadline;
        vm.prank(owner);
        core.pauseSales(true);
        vm.warp(vm.getBlockTimestamp() + 30 minutes);
        vm.prank(owner);
        core.pauseSales(false);
        uint256 live = la.effectiveDeadline(1);
        assertEq(live, raw + 30 minutes, "a pause during the round still extends the live clock");
        vm.warp(live);
        la.settle(1);
        uint256 snap = la.effectiveDeadline(1);
        assertEq(snap, live, "settle snapshots the deadline");
        vm.prank(owner);
        core.pauseSales(true);
        vm.warp(vm.getBlockTimestamp() + 5 hours);
        assertEq(la.effectiveDeadline(1), snap, "later pauses do not move a settled round");
        assertTrue(la.roundState(1).settled);
    }

    /// A pause that starts after a round ended never revives it.
    function test_pauseAfterEnd_doesNotReviveRound() public {
        fire(ana);
        vm.warp(la.roundState(1).deadline + 10);
        vm.prank(owner);
        core.pauseSales(true);
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        assertEq(la.timeLeft(), 0);
        la.settle(1);
        assertTrue(la.roundState(1).settled);
    }

    function test_claimWorksWhilePaused() public {
        fire(ana);
        vm.warp(la.roundState(1).deadline);
        la.settle(1);
        vm.prank(owner);
        core.pauseSales(true);
        vm.prank(ana);
        core.claim();
    }

    function testFuzz_deadlineNeverPastCaps(uint8 n, uint16 gap) public {
        n = uint8(bound(n, 1, 60));
        for (uint256 i; i < n; ++i) {
            vm.warp(vm.getBlockTimestamp() + bound(gap, 0, 59 minutes));
            if (vm.getBlockTimestamp() >= la.roundState(la.currentRound()).deadline && la.currentRound() != 0) break;
            fire(i % 2 == 0 ? ana : bob);
            uint256 lastShotTime = vm.getBlockTimestamp();
            LastArrow.Round memory R = la.roundState(la.currentRound());
            uint256 pausedSince = core.pausedSeconds() - R.pauseMark;
            assertLe(R.deadline, lastShotTime + 1 hours + pausedSince);
            assertEq(R.hardEnd, 0);
        }
    }

    /// Random gaps, including a round that runs past 24h, never push the deadline past now + 1h.
    function testFuzz_shotTimings_deadlineNeverPastNowPlus1h(uint8 n, uint32 gap) public {
        n = uint8(bound(n, 1, 80));
        uint256 fairEnd = T0 + 6 days;
        for (uint256 i; i < n; ++i) {
            uint256 step = bound(uint256(keccak256(abi.encode(gap, i))), 0, 3 hours);
            if (vm.getBlockTimestamp() + step >= fairEnd) break;
            vm.warp(vm.getBlockTimestamp() + step);
            fire(i % 2 == 0 ? ana : bob);
            uint256 lastShotTime = vm.getBlockTimestamp();
            LastArrow.Round memory R = la.roundState(la.currentRound());
            uint256 pausedSince = core.pausedSeconds() - R.pauseMark;
            assertLe(R.deadline, lastShotTime + 1 hours + pausedSince);
            assertLe(R.deadline, vm.getBlockTimestamp() + 1 hours);
            assertEq(R.hardEnd, 0);
        }
    }

    /// A pause freezes the clock, then a shot shifts the deadline by that pause and caps it at now + 1h.
    /// hardEnd stays 0, so the pause add cannot overflow or look like a timestamp.
    function testFuzz_pauseThenShoot_shiftsDeadline_hardEndStaysZero(uint32 pauseFor, uint32 waitBefore) public {
        pauseFor = uint32(bound(pauseFor, 1, 5 hours));
        waitBefore = uint32(bound(waitBefore, 0, 50 minutes));
        fire(ana);
        uint256 openedAt = vm.getBlockTimestamp();
        LastArrow.Round memory before = la.roundState(1);
        assertEq(before.hardEnd, 0);
        assertEq(before.deadline, openedAt + 1 hours);
        if (waitBefore != 0) vm.warp(openedAt + waitBefore);

        uint256 pauseStart = vm.getBlockTimestamp();
        vm.prank(owner);
        core.pauseSales(true);
        vm.warp(pauseStart + pauseFor);
        assertEq(la.roundState(1).hardEnd, 0, "a pause does not invent a hard end");
        assertEq(la.effectiveDeadline(1), before.deadline + pauseFor);
        vm.expectRevert(LastArrow.NotEnded.selector);
        la.settle(1);

        vm.prank(owner);
        core.pauseSales(false);
        assertEq(la.roundState(1).hardEnd, 0);
        assertEq(la.effectiveDeadline(1), before.deadline + pauseFor);

        uint256 shotAt = vm.getBlockTimestamp();
        fire(bob);
        LastArrow.Round memory bumped = la.roundState(1);
        assertEq(la.currentRound(), 1, "the pause did not end the round");
        assertEq(bumped.hardEnd, 0);
        uint256 expected = before.deadline + pauseFor + 10 minutes;
        uint256 cap = shotAt + 1 hours;
        if (expected > cap) expected = cap;
        assertEq(bumped.deadline, expected, "deadline shifted by the pause, then bumped and capped");
        assertLe(bumped.deadline, shotAt + 1 hours);
    }

    /// settle reverts while the effective deadline (raw deadline plus any pause) is still ahead, and works after it.
    function testFuzz_settle_revertsBeforeEffectiveDeadline_worksAfter(uint32 early, uint32 late, uint32 pauseFor)
        public
    {
        fire(ana);
        pauseFor = uint32(bound(pauseFor, 0, 4 hours));
        uint256 raw = la.roundState(1).deadline;
        if (pauseFor > 0) {
            vm.prank(owner);
            core.pauseSales(true);
            vm.warp(block.timestamp + pauseFor);
            vm.prank(owner);
            core.pauseSales(false);
        }
        uint256 endAt = la.effectiveDeadline(1);
        assertEq(endAt, raw + pauseFor);
        assertEq(la.roundState(1).hardEnd, 0);
        uint256 nowTs = vm.getBlockTimestamp();
        uint256 room = endAt - nowTs;
        early = uint32(bound(early, 0, room - 1));
        vm.warp(nowTs + early);
        vm.expectRevert(LastArrow.NotEnded.selector);
        la.settle(1);

        late = uint32(bound(late, 0, 12 hours));
        vm.warp(endAt + late);
        la.settle(1);
        assertTrue(la.roundState(1).settled);
        LastArrow.Round memory R = la.roundState(1);
        assertEq(R.hardEnd, 0);
        assertEq(R.deadline, raw + pauseFor, "settle folds the pause into the deadline and leaves hardEnd at 0");
    }

    /// L-6 (KF-D-01): the lens says which round a shot sent now lands in, before the first round and after a lapse.
    function test_lens_expectedRound() public {
        FairLens lens = new FairLens(
            core, la, SheriffsSeat(address(new SeatDay0Stub())), IVaultView(address(0))
        );
        FairLens.ArrowView memory a = lens.arrowNow();
        assertEq(a.roundId, 0);
        assertEq(a.expectedRound, 1, "before the first round, shoot into round 1");
        assertFalse(a.live);
        fire(bob);
        a = lens.arrowNow();
        assertEq(a.roundId, 1);
        assertEq(a.expectedRound, 1);
        assertTrue(a.live);
        vm.warp(vm.getBlockTimestamp() + 1 hours + 1);
        a = lens.arrowNow();
        assertEq(a.roundId, 1, "the lapsed round is still the current one");
        assertEq(a.expectedRound, 2, "but a shot now opens round 2");
        assertFalse(a.live);
        arb.set(arb.n() + 1);
        vm.prank(ana);
        la.shoot(type(uint256).max, address(0), a.expectedRound);
    }
}
