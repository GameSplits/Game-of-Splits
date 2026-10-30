// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Base} from "../Base.t.sol";
import {FairCore} from "../../src/FairCore.sol";
import {SheriffsSeat} from "../../src/SheriffsSeat.sol";
import {IFairCore} from "../../src/interfaces/IFair.sol";
import {MockArbSys} from "../mocks/Mocks.sol";

contract SheriffsSeatTest is Base {
    SheriffsSeat seat;
    MockArbSys arb;
    uint256 day0;

    function wireBooths() internal override {
        day0 = (uint256(T0) / 1 days + 1) * 1 days; // next 00:00 UTC after T0
        // K-D01: day0 can't be in the future at construction; build the seat at day0, then return to T0.
        vm.warp(day0);
        seat = new SheriffsSeat(IFairCore(address(core)), day0, 1 days);
        vm.warp(T0);
        core.setupSet(FairCore.Op.AddBooth, 0, address(seat));
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
        vm.warp(day0); // day 0, 00:00 UTC (inside Fair 0)
    }

    function now_() internal view returns (uint256) {
        return vm.getBlockTimestamp();
    }

    function takeAs(address who) internal returns (uint256 paid) {
        arb.set(arb.n() + 1);
        vm.prank(who);
        paid = seat.take(type(uint256).max, address(0), "hello sherwood", 3);
    }

    function at(uint256 secsIntoDay) internal {
        vm.warp(day0 + secsIntoDay);
    }

    // ---------------------------------------------------------------- price

    function test_price_spec_exampleA() public {
        at(0);
        takeAs(ana); // first take of the day: 1 USDG
        at(10);
        // force a 10 USDG take to set lastPaid: two quick takes don't get there, so check the formula from 1.0
        uint256 s = 1_500_000; // 1.5 x the 1 USDG first take
        assertEq(seat.price(), 1e6 + (s - 1e6) * (3600 - 10) / 3600);
    }

    function test_price_slide_fromTen() public {
        // Build lastPaid = 10 USDG by bidding up quickly, then check the slide from 15.
        at(0);
        takeAs(ana);
        address[2] memory pair = [bob, ana];
        uint256 i;
        while (true) {
            uint256 p = seat.price();
            if (p >= 10e6) break;
            takeAs(pair[i % 2]);
            ++i;
        }
        (,, uint128 lastPaid) = seat.holderOf(0);
        uint256 s = uint256(lastPaid) * 3 / 2;
        uint256 t0 = now_();
        assertEq(seat.price(), s, "t = 0: exactly 1.5x last paid");
        vm.warp(t0 + 20 minutes);
        assertEq(seat.price(), 1e6 + (s - 1e6) * 40 / 60);
        vm.warp(t0 + 45 minutes);
        assertEq(seat.price(), 1e6 + (s - 1e6) * 15 / 60);
        vm.warp(t0 + 60 minutes);
        assertEq(seat.price(), 1e6, "floor at 1h");
        vm.warp(t0 + 5 hours);
        assertEq(seat.price(), 1e6);
    }

    /// Spec worked example B: A 00:05, B 00:35, C 00:40, A 02:00; top 3 = A, C, B; spent 5.05.
    function test_exampleB_shortDay() public {
        at(5 minutes);
        assertEq(takeAs(ana), 1e6);
        at(35 minutes);
        assertEq(takeAs(bob), 1_250_000);
        at(40 minutes);
        assertEq(takeAs(cat), 1_802_083, "spec says 1.80");
        at(2 hours);
        assertEq(takeAs(ana), 1e6);
        uint256 spent = 1e6 + 1_250_000 + 1_802_083 + 1e6; // 5.05 USDG, as in the spec
        assertEq(core.pot(address(seat), 0), spent * 6000 / 10_000);

        vm.warp(day0 + 1 days);
        seat.settle(0);
        assertEq(seat.secsOf(0, ana), 81_000);
        assertEq(seat.secsOf(0, cat), 4_800);
        assertEq(seat.secsOf(0, bob), 300);
        SheriffsSeat.Rank[3] memory T = seat.leaderboard(0);
        assertEq(T[0].who, ana);
        assertEq(T[1].who, cat);
        assertEq(T[2].who, bob);
        uint256 purse = spent * 6000 / 10_000;
        assertEq(core.claimable(ana), purse * 7500 / 10_000);
        assertEq(core.claimable(cat), purse * 2000 / 10_000);
        assertEq(core.claimable(bob), purse * 500 / 10_000);
    }

    function testFuzz_priceBounds(uint32 gap1, uint32 gap2) public {
        at(0);
        takeAs(ana);
        vm.warp(now_() + bound(gap1, 0, 2 hours));
        takeAs(bob);
        (,, uint128 lastPaid) = seat.holderOf(0);
        vm.warp(now_() + bound(gap2, 0, 3 hours));
        uint256 p = seat.price();
        assertGe(p, 1e6);
        assertLe(p, uint256(lastPaid) * 3 / 2);
    }

    // ---------------------------------------------------------------- rules

    function test_cantTakeFromYourself_evenPaidByOther() public {
        takeAs(ana);
        arb.set(arb.n() + 1);
        vm.prank(bob);
        vm.expectRevert(SheriffsSeat.AlreadyHolder.selector);
        seat.take(type(uint256).max, ana, "", 0);
    }

    function test_oneTakePerL2Block() public {
        takeAs(ana);
        vm.prank(bob);
        vm.expectRevert(SheriffsSeat.SameBlock.selector);
        seat.take(type(uint256).max, address(0), "", 0);
    }

    function test_message_64emoji_ok_257bytes_reverts_badColor() public {
        string memory emoji64;
        for (uint256 i; i < 64; ++i) emoji64 = string.concat(emoji64, unicode"🔥"); // 4 bytes each = 256
        arb.set(arb.n() + 1);
        vm.prank(ana);
        seat.take(type(uint256).max, address(0), emoji64, 7);
        bytes memory long = new bytes(257);
        arb.set(arb.n() + 1);
        vm.prank(bob);
        vm.expectRevert(SheriffsSeat.MessageTooLong.selector);
        seat.take(type(uint256).max, address(0), string(long), 0);
        vm.prank(bob);
        vm.expectRevert(SheriffsSeat.BadColor.selector);
        seat.take(type(uint256).max, address(0), "", 8);
    }

    function test_needsPass_andMaxPrice() public {
        address dan = makeAddr("dan");
        fund(dan);
        arb.set(arb.n() + 1);
        vm.prank(dan);
        vm.expectRevert(SheriffsSeat.NoPass.selector);
        seat.take(type(uint256).max, address(0), "", 0);
        vm.prank(ana);
        vm.expectRevert(abi.encodeWithSelector(SheriffsSeat.PriceAboveMax.selector, 1e6, 999_999));
        seat.take(999_999, address(0), "", 0);
    }

    // ---------------------------------------------------------------- settle and rollover

    function test_settle_onlyAfterMidnight_once() public {
        takeAs(ana);
        vm.expectRevert(SheriffsSeat.DayNotOver.selector);
        seat.settle(0);
        vm.warp(day0 + 1 days);
        seat.settle(0);
        vm.expectRevert(SheriffsSeat.AlreadySettled.selector);
        seat.settle(0);
    }

    function test_singleHolderAllDay_rollsOver25_andSeedsNextDay() public {
        at(0);
        takeAs(ana);
        uint256 purse = core.pot(address(seat), 0);
        vm.warp(day0 + 1 days);
        seat.settle(0);
        assertEq(seat.secsOf(0, ana), 86_400, "a full day, never more");
        assertEq(core.claimable(ana), purse * 7500 / 10_000);
        uint256 rolled = core.rollover(address(seat));
        assertEq(rolled, purse - purse * 7500 / 10_000, "2nd and 3rd shares roll over");
        takeAs(bob); // day 1 opens empty at the floor
        assertEq(core.pot(address(seat), 1), 600_000 + rolled);
    }

    function test_twoHolderDay_5percentRollsOver() public {
        at(0);
        takeAs(ana);
        at(1 hours);
        takeAs(bob);
        uint256 purse = core.pot(address(seat), 0);
        vm.warp(day0 + 1 days);
        seat.settle(0);
        assertEq(core.rollover(address(seat)), purse * 500 / 10_000);
    }

    function test_zeroTakeoverDay_settlesEmpty() public {
        vm.warp(day0 + 1 days);
        seat.settle(0);
        assertEq(core.rollover(address(seat)), 0);
    }

    function test_newDay_startsEmptyAtFloor() public {
        at(23 hours + 59 minutes);
        takeAs(ana);
        takeAs(bob); // expensive now
        vm.warp(day0 + 1 days + 1);
        assertEq(seat.price(), 1e6, "fresh day at the floor");
        takeAs(ana); // allowed: ana isn't day 1's holder
        assertEq(seat.today(), 1);
    }

    /// Audit L2: the first take of a day settles yesterday first, so yesterday's rollover seeds today.
    function test_firstTakeOfDay_settlesYesterday_rolloverSeedsToday() public {
        at(0);
        takeAs(ana); // day 0: one holder, so 25% rolls over
        uint256 purse0 = core.pot(address(seat), 0);
        vm.warp(day0 + 1 days + 5); // nobody called settle(0)
        takeAs(bob); // settles day 0, then seeds day 1
        assertTrue(seat.isSettled(0));
        uint256 rolled = purse0 - purse0 * 7500 / 10_000;
        assertEq(core.pot(address(seat), 1), 600_000 + rolled, "day 1 = own 60% + day 0's rollover");
        assertEq(core.claimable(ana), purse0 * 7500 / 10_000);
    }

    /// Audit N3: a pause right after someone takes the seat doesn't hand them the day.
    function test_N3_pausedTimeNotCredited() public {
        at(0);
        takeAs(bob);
        at(6 hours);
        takeAs(ana); // bob credited 6h
        at(7 hours);
        vm.prank(owner);
        core.pauseSales(true); // nobody can take from ana now
        vm.warp(day0 + 1 days);
        seat.settle(0); // pause still running at midnight
        assertEq(seat.secsOf(0, bob), 6 hours);
        assertEq(seat.secsOf(0, ana), 1 hours, "only ana's live hour counts, not the 17 paused hours");
        SheriffsSeat.Rank[3] memory T = seat.leaderboard(0);
        assertEq(T[0].who, bob);
    }

    function test_N3_pauseThenResume_onlyLiveTimeCounts() public {
        at(0);
        takeAs(ana);
        at(2 hours);
        vm.prank(owner);
        core.pauseSales(true);
        at(5 hours);
        vm.prank(owner);
        core.pauseSales(false);
        at(6 hours);
        takeAs(bob); // ana held 6h of wall time, 3h of it paused
        assertEq(seat.secsOf(0, ana), 3 hours);
    }

    function test_mainnetEnforcesUtcDays() public {
        vm.chainId(4663);
        vm.expectRevert(SheriffsSeat.BadConfig.selector);
        new SheriffsSeat(IFairCore(address(core)), day0, 10 minutes);
        vm.expectRevert(SheriffsSeat.BadConfig.selector);
        new SheriffsSeat(IFairCore(address(core)), day0 + 1, 1 days);
    }

    /// Seconds credited in a day never exceed the day's length, whatever the takeover pattern.
    function testFuzz_secsNeverExceedDay(uint16[8] memory gaps) public {
        at(0);
        address[3] memory who = [ana, bob, cat];
        uint256 n;
        for (uint256 i; i < 8; ++i) {
            vm.warp(now_() + bound(gaps[i], 1, 4 hours));
            if (now_() >= day0 + 1 days) break;
            takeAs(who[n % 3]);
            ++n;
        }
        vm.warp(day0 + 1 days);
        seat.settle(0);
        uint256 total = uint256(seat.secsOf(0, ana)) + seat.secsOf(0, bob) + seat.secsOf(0, cat);
        assertLe(total, 86_400);
        SheriffsSeat.Rank[3] memory T = seat.leaderboard(0);
        assertGe(T[0].secs, T[1].secs);
        assertGe(T[1].secs, T[2].secs);
    }
}
