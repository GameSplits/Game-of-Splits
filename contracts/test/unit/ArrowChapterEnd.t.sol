// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Base} from "../Base.t.sol";
import {FairCore} from "../../src/FairCore.sol";
import {LastArrow} from "../../src/LastArrow.sol";
import {IFairCore} from "../../src/interfaces/IFair.sol";
import {MockArbSys} from "../mocks/Mocks.sol";

/// @notice A-02: refuse to OPEN a new Last Arrow round when the chapter ends within OPEN_TIME.
///         A round that is already live is unaffected and still ends at the chapter hard stop.
contract ArrowChapterEndTest is Base {
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

    function fire(address who) internal returns (uint256 price) {
        arb.set(arb.n() + 1);
        uint256 r1 = la.nextShotRound();
        vm.prank(who);
        price = la.shoot(type(uint256).max, address(0), r1);
    }

    /// External wrapper so `vm.expectRevert` can catch the shoot revert.
    function fireExternal(address who) external {
        fire(who);
    }

    // ── regression (PoC part b): open blocked in the last hour ──────────────

    /// PoC_ArrowFairEnd part (b): a shot at fairEnd-1 must not open a new round seeded with rollover.
    function test_refuseOpen_inLastSecondOfChapter() public {
        fire(ana);
        vm.warp(la.roundState(1).deadline);
        la.settle(1);
        uint256 rolled = core.rollover(address(la));
        assertGt(rolled, 0, "setup: rollover after 1-shot round");

        uint256 fairEnd = T0 + 6 days;
        vm.warp(fairEnd - 1);
        uint256 before = la.currentRound();
        vm.expectRevert(LastArrow.ChapterEndingSoon.selector);
        this.fireExternal(ana);
        assertEq(la.currentRound(), before, "no new round opened");
        assertEq(core.rollover(address(la)), rolled, "rollover still parked for the next chapter");
    }

    /// Opening exactly OPEN_TIME before chapter end is refused (`now + OPEN_TIME >= end`).
    function test_refuseOpen_exactlyOpenTimeBeforeEnd() public {
        uint256 fairEnd = T0 + 6 days;
        vm.warp(fairEnd - 1 hours);
        vm.expectRevert(LastArrow.ChapterEndingSoon.selector);
        this.fireExternal(ana);
        assertEq(la.currentRound(), 0);
    }

    /// One second earlier still has a full OPEN_TIME window and opens.
    function test_allowOpen_justBeforeLastHour() public {
        uint256 fairEnd = T0 + 6 days;
        vm.warp(fairEnd - 1 hours - 1);
        fire(ana);
        assertEq(la.currentRound(), 1);
        LastArrow.Round memory R = la.roundState(1);
        assertEq(R.deadline, uint64(vm.getBlockTimestamp()) + 1 hours);
        assertLt(R.deadline, fairEnd);
    }

    // ── live round still finishes ───────────────────────────────────────────

    /// A round opened with room to spare still settles after the chapter ends (PoC part a stays allowed).
    function test_liveRound_settlesAfterChapterEnd() public {
        uint256 fairEnd = T0 + 6 days;
        vm.warp(fairEnd - 2 hours);
        fire(ana); // single shot: last + most both ana; 35% rolls
        uint256 purse = core.pot(address(la), 1);

        vm.warp(fairEnd); // chapter over; round still unsettled
        (bool active,) = core.activeFair();
        assertFalse(active);
        la.settle(1);
        assertTrue(la.roundState(1).settled);
        assertEq(core.claimable(ana), purse * 5000 / 10_000 + purse * 1500 / 10_000);
    }

    /// While a round is live, further shots inside the chapter still work even in the last hour.
    function test_liveRound_shotsOkInsideLastHour() public {
        uint256 fairEnd = T0 + 6 days;
        vm.warp(fairEnd - 90 minutes);
        fire(ana);
        vm.warp(fairEnd - 45 minutes); // inside last hour, before deadline (end - 30m), round still live
        fire(bob);
        assertEq(la.currentRound(), 1);
        assertEq(la.roundState(1).shots, 2);
    }

    // ── no active chapter / short chapter / rollover to next ────────────────

    function test_refuseOpen_noActiveChapter() public {
        vm.warp(T0 + 6 days); // past Base fair
        (bool active,) = core.activeFair();
        assertFalse(active);
        vm.expectRevert(FairCore.NoActiveFair.selector);
        this.fireExternal(ana);
        assertEq(la.currentRound(), 0);
    }

    /// A chapter shorter than OPEN_TIME never admits a new round (now + OPEN_TIME always >= end).
    function test_refuseOpen_chapterShorterThanOpenTime() public {
        vm.warp(T0 + 6 days + 1);
        uint64 start = uint64(T0 + 7 days);
        uint64 end = start + 30 minutes; // < OPEN_TIME
        vm.prank(owner);
        core.setFair(1, start, end);
        vm.warp(start);
        (bool active,) = core.activeFair();
        assertTrue(active);
        vm.expectRevert(LastArrow.ChapterEndingSoon.selector);
        this.fireExternal(ana);
        assertEq(la.currentRound(), 0);
    }

    /// Rollover parked at chapter end seeds the first round of the next chapter (no USDG stuck).
    function test_rollover_carriesToNextChapter() public {
        fire(ana);
        vm.warp(la.roundState(1).deadline);
        la.settle(1);
        uint256 rolled = core.rollover(address(la));
        assertGt(rolled, 0);

        uint256 fairEnd = T0 + 6 days;
        vm.warp(fairEnd); // chapter over; FairCore refuses with no active chapter
        vm.expectRevert(FairCore.NoActiveFair.selector);
        this.fireExternal(bob);
        assertEq(core.rollover(address(la)), rolled);

        uint64 nextStart = uint64(fairEnd + 1 hours);
        uint64 nextEnd = nextStart + 3 days;
        vm.prank(owner);
        core.setFair(1, nextStart, nextEnd);
        vm.warp(nextStart + 1);

        fire(bob); // first open of the next chapter
        assertEq(la.currentRound(), 2);
        assertEq(core.pot(address(la), 2), 600_000 + rolled, "own 60% + exact prior rollover");
        assertEq(core.rollover(address(la)), 0);
    }

    // ── fuzz: open time vs chapter end ──────────────────────────────────────

    function testFuzz_openWindow_vsChapterEnd(uint32 offsetFromEnd) public {
        // Offset measured backward from fairEnd; cover well before, on the boundary, and after.
        offsetFromEnd = uint32(bound(offsetFromEnd, 1, 3 hours)); // 1 = last second of the chapter
        uint256 fairEnd = T0 + 6 days;
        uint256 t = fairEnd - offsetFromEnd;
        // Stay inside the active chapter (Base starts at T0+1h).
        if (t < T0 + 1 hours) t = T0 + 1 hours;
        vm.warp(t);

        bool shouldOpen = t + 1 hours < fairEnd; // strict: now + OPEN_TIME < end
        if (shouldOpen) {
            fire(ana);
            assertEq(la.currentRound(), 1);
            assertLt(la.roundState(1).deadline, fairEnd);
        } else {
            vm.expectRevert(LastArrow.ChapterEndingSoon.selector);
            this.fireExternal(ana);
            assertEq(la.currentRound(), 0);
        }
    }
}
