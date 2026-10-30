// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// R1: the pause log is append-only. Settle must stay cheap after a day of the fastest pause spam the rate limit allows.
import {Base} from "../Base.t.sol";
import {FairCore} from "../../src/FairCore.sol";
import {SheriffsSeat} from "../../src/SheriffsSeat.sol";
import {IFairCore} from "../../src/interfaces/IFair.sol";
import {MockArbSys} from "../mocks/Mocks.sol";
import {console} from "forge-std/console.sol";

contract PauseScanBoundTest is Base {
    SheriffsSeat seat;
    MockArbSys arb;
    uint256 day0;

    struct RefPause {
        uint64 start;
        uint64 end; // 0 while that pause is still running
    }

    function wireBooths() internal override {
        day0 = (uint256(T0) / 1 days + 1) * 1 days;
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
        vm.warp(day0);
    }

    function takeAs(address who) internal returns (uint256 paid) {
        arb.set(arb.n() + 1);
        vm.prank(who);
        paid = seat.take(type(uint256).max, address(0), "", 0);
    }

    /// Zero-length pause/unpause pairs, spaced by the minimum gap. Unpause stays in the same timestamp.
    function pausePairs(uint256 n) internal {
        vm.startPrank(owner);
        for (uint256 i; i < n; ++i) {
            if (i != 0) vm.warp(vm.getBlockTimestamp() + core.MIN_PAUSE_GAP());
            core.pauseSales(true);
            core.pauseSales(false);
        }
        vm.stopPrank();
    }

    function _naive(RefPause[] memory log, uint256 fromIdx, uint256 from, uint256 to, uint256 nowTs)
        internal
        pure
        returns (uint256 total)
    {
        uint256 n = log.length;
        for (uint256 i = fromIdx; i < n; ++i) {
            uint256 s = log[i].start > from ? log[i].start : from;
            uint256 e = log[i].end == 0 ? nowTs : log[i].end;
            if (e > to) e = to;
            if (e > s) total += e - s;
        }
    }

    function _check(RefPause[] memory log, uint256 fromIdx, uint256 from, uint256 to, uint256 nowTs) internal view {
        assertEq(core.pausedBetween(fromIdx, from, to), _naive(log, fromIdx, from, to, nowTs));
    }

    // ---------------------------------------------------------------- rate limit

    /// The first pause is immediate. A second new pause in the same minute reverts. Unpause in between is free.
    function test_rapidSecondPause_revertsPauseTooSoon() public {
        assertEq(core.pauseCount(), 0);
        vm.startPrank(owner);
        core.pauseSales(true); // emergency pause, no prior entry
        assertTrue(core.salesPaused());
        assertEq(core.pauseCount(), 1);
        core.pauseSales(false);
        vm.expectRevert(FairCore.PauseTooSoon.selector);
        core.pauseSales(true);
        vm.stopPrank();
        assertFalse(core.salesPaused());
        assertEq(core.pauseCount(), 1, "the reverted pause wrote nothing");
    }

    /// After the gap a new pause succeeds. Unpause is allowed at once, repeatedly, and inside the gap.
    function test_pauseAfterGap_succeeds_andUnpauseNeverBlocked() public {
        uint256 t = vm.getBlockTimestamp();
        vm.startPrank(owner);
        core.pauseSales(true);
        core.pauseSales(true); // already paused: not a new entry
        assertEq(core.pauseCount(), 1);
        core.pauseSales(false); // same timestamp as the pause
        core.pauseSales(false); // already unpaused: still not blocked
        vm.warp(t + core.MIN_PAUSE_GAP() - 1);
        vm.expectRevert(FairCore.PauseTooSoon.selector);
        core.pauseSales(true);
        core.pauseSales(false); // unpause while a new pause is still refused
        vm.warp(t + core.MIN_PAUSE_GAP());
        core.pauseSales(true);
        assertTrue(core.salesPaused());
        assertEq(core.pauseCount(), 2);
        vm.warp(t + core.MIN_PAUSE_GAP() + 1);
        core.pauseSales(false); // one second into the pause, not ten minutes
        assertFalse(core.salesPaused());
        vm.stopPrank();
        assertEq(core.pausedSeconds(), 1, "the one-second pause is the whole second entry");
    }

    // ---------------------------------------------------------------- R1: a day of spam cannot brick settle or the next take

    /// 144 is the most new pauses one day can hold (86400 / 10 minutes). They all sit after day 0, so they
    /// used to be scanned for nothing. Settle and the next take must both land under the PoC's 3M gas cap.
    function test_pauseSpam144_settleAndTake_succeedUnderGasCap() public {
        atDayStart();
        takeAs(ana);
        uint256 start = day0 + 1 days + 10;
        vm.warp(start);
        pausePairs(144);
        assertEq(core.pauseCount(), 144);
        // One more start inside that same 24h window is still inside the gap.
        vm.warp(start + 1 days - 1);
        vm.prank(owner);
        vm.expectRevert(FairCore.PauseTooSoon.selector);
        core.pauseSales(true);

        uint256 cap = 3_000_000;
        uint256 snap = vm.snapshotState();

        vm.cool(address(core));
        vm.cool(address(seat));
        uint256 g = gasleft();
        seat.settle(0);
        g -= gasleft();
        console.log("settle gas, 144 trailing pauses:", g);
        assertEq(seat.secsOf(0, ana), 1 days, "zero-length pauses after the day do not change seconds");
        assertTrue(seat.isSettled(0));
        // Unbounded, this was ~622k. The break must keep it next to the 0-entry settle (~231k).
        assertLt(g, 300_000, "settle walked pauses that start after the day");

        vm.revertToState(snap);
        vm.cool(address(core));
        vm.cool(address(seat));
        (bool ok,) = address(seat).call{gas: cap}(abi.encodeCall(SheriffsSeat.settle, (0)));
        assertTrue(ok, "settle under cap");
        assertTrue(seat.isSettled(0));

        vm.revertToState(snap);
        arb.set(arb.n() + 1);
        vm.cool(address(core));
        vm.cool(address(seat));
        vm.prank(bob);
        g = gasleft();
        seat.take(type(uint256).max, address(0), "", 0);
        g -= gasleft();
        console.log("take gas, 144 trailing pauses:", g);
        assertTrue(seat.isSettled(0), "take settled the previous day");
        // Unbounded, this was ~857k. 0-entry take is ~466k.
        assertLt(g, 560_000, "take walked pauses that start after the day");

        vm.revertToState(snap);
        arb.set(arb.n() + 1);
        vm.cool(address(core));
        vm.cool(address(seat));
        vm.prank(bob);
        (ok,) = address(seat).call{gas: cap}(
            abi.encodeCall(SheriffsSeat.take, (type(uint256).max, address(0), "", 0))
        );
        assertTrue(ok, "take under cap");
        assertTrue(seat.isSettled(0));
    }

    function atDayStart() internal {
        vm.warp(day0);
    }

    // ---------------------------------------------------------------- gas table: 0, 10 and 144 entries, cold

    function _arm(uint256 pairs) internal {
        atDayStart();
        takeAs(ana);
        vm.warp(day0 + 1 days + 10);
        pausePairs(pairs);
    }

    function test_gas_settle_0() public {
        _arm(0);
        _logSettle(0);
    }

    function test_gas_settle_10() public {
        _arm(10);
        _logSettle(10);
    }

    function test_gas_settle_144() public {
        _arm(144);
        _logSettle(144);
    }

    function test_gas_take_0() public {
        _arm(0);
        _logTake(0);
    }

    function test_gas_take_10() public {
        _arm(10);
        _logTake(10);
    }

    function test_gas_take_144() public {
        _arm(144);
        _logTake(144);
    }

    function _logSettle(uint256 pairs) internal {
        vm.cool(address(core));
        vm.cool(address(seat));
        uint256 g = gasleft();
        seat.settle(0);
        g -= gasleft();
        console.log("AFTER settle", pairs, g);
        assertEq(seat.secsOf(0, ana), 1 days);
        if (pairs == 144) assertLt(g, 300_000, "144 trailing entries must not be scanned");
    }

    function _logTake(uint256 pairs) internal {
        arb.set(arb.n() + 1);
        vm.cool(address(core));
        vm.cool(address(seat));
        vm.prank(bob);
        uint256 g = gasleft();
        seat.take(type(uint256).max, address(0), "", 0);
        g -= gasleft();
        console.log("AFTER take", pairs, g);
        assertTrue(seat.isSettled(0));
        if (pairs == 144) assertLt(g, 560_000, "144 trailing entries must not be scanned");
    }

    function test_gas_pauseSalesAndUnpause() public {
        vm.cool(address(core));
        vm.prank(owner);
        uint256 g = gasleft();
        core.pauseSales(true);
        g -= gasleft();
        console.log("AFTER pauseSales first", g);

        vm.cool(address(core));
        vm.prank(owner);
        g = gasleft();
        core.pauseSales(false);
        g -= gasleft();
        console.log("AFTER unpause", g);

        vm.warp(vm.getBlockTimestamp() + core.MIN_PAUSE_GAP());
        vm.startPrank(owner);
        core.pauseSales(true);
        core.pauseSales(false);
        vm.stopPrank();
        vm.warp(vm.getBlockTimestamp() + core.MIN_PAUSE_GAP());
        vm.cool(address(core));
        vm.prank(owner);
        g = gasleft();
        core.pauseSales(true);
        g -= gasleft();
        console.log("AFTER pauseSales later", g);

        vm.cool(address(core));
        vm.prank(owner);
        g = gasleft();
        core.pauseSales(false);
        g -= gasleft();
        console.log("AFTER unpause later", g);
    }

    // ---------------------------------------------------------------- fuzz against a naive full scan

    /// Random append-only logs (open or closed, including zero-length) and random windows, including
    /// inverted ones and `from == 0` so a running pause is never confused with `end == 0`.
    /// Time is read with `vm.getBlockTimestamp`: via_ir may cache `block.timestamp` across `vm.warp`.
    function testFuzz_pausedBetween_matchesNaive(uint8 nRaw, uint256 seed, uint64 rndFrom, uint64 rndTo, uint8 idxRaw)
        public
    {
        uint256 n = bound(nRaw, 0, 10);
        RefPause[] memory log = new RefPause[](n);
        vm.startPrank(owner);
        for (uint256 i; i < n; ++i) {
            if (i != 0) {
                uint256 ts = vm.getBlockTimestamp();
                uint256 earliest = uint256(log[i - 1].start) + core.MIN_PAUSE_GAP();
                uint256 extra = uint256(keccak256(abi.encode(seed, i, bytes32("gap")))) % 6 hours;
                uint256 nextT = earliest + extra;
                if (nextT < ts) nextT = ts;
                vm.warp(nextT);
            }
            uint64 start = uint64(vm.getBlockTimestamp());
            core.pauseSales(true);
            bool leaveOpen = (i + 1 == n) && (seed % 2 == 1);
            if (leaveOpen) {
                log[i] = RefPause(start, 0);
            } else {
                uint256 dur = uint256(keccak256(abi.encode(seed, i, bytes32("dur")))) % 3 hours;
                if (uint256(keccak256(abi.encode(seed, i, bytes32("z")))) % 5 == 0) dur = 0;
                if (dur != 0) vm.warp(vm.getBlockTimestamp() + dur);
                core.pauseSales(false);
                log[i] = RefPause(start, uint64(vm.getBlockTimestamp()));
            }
        }
        vm.stopPrank();
        assertEq(core.pauseCount(), n);

        uint256 nowTs = vm.getBlockTimestamp();
        uint256 fromIdx = bound(idxRaw, 0, n + 1);
        _check(log, fromIdx, rndFrom, rndTo, nowTs);
        // `from == 0` with `end == 0` still running: skipping on `end <= from` would drop this pause.
        _check(log, 0, 0, type(uint64).max, nowTs);

        uint256 origin = n == 0 ? nowTs : log[0].start;
        uint256 past = nowTs + 3 days;
        uint256 span = past - origin;
        _check(log, fromIdx, origin + (uint256(rndFrom) % (span + 1)), origin + (uint256(rndTo) % (span + 1)), nowTs);
        _check(log, n, origin, past, nowTs);
        _check(log, 0, past, origin, nowTs); // inverted window
        if (n != 0) {
            uint256 end0 = log[0].end == 0 ? nowTs : log[0].end;
            _check(log, 0, end0, past, nowTs);
            _check(log, 0, origin > 0 ? origin - 1 : 0, log[0].start, nowTs);
            _check(log, fromIdx, log[n - 1].start, past, nowTs);
        }
    }
}
