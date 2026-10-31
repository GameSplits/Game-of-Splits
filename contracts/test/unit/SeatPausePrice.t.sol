// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Base} from "../Base.t.sol";
import {FairCore} from "../../src/FairCore.sol";
import {FairLens, IVaultView} from "../../src/FairLens.sol";
import {LastArrow} from "../../src/LastArrow.sol";
import {SheriffsSeat} from "../../src/SheriffsSeat.sol";
import {IFairCore} from "../../src/interfaces/IFair.sol";
import {MockArbSys} from "../mocks/Mocks.sol";

/// The seat price slides over live time only: while sales are paused the slide stops, the same way the holder's
/// clock stops, so a pause can't strip the holder's price protection.
contract SeatPausePriceTest is Base {
    SheriffsSeat seat;
    MockArbSys arb;
    uint256 day0;

    function wireBooths() internal override {
        day0 = (uint256(T0) / 1 days + 1) * 1 days;
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
        vm.warp(day0 + 1 hours);
    }

    function now_() internal view returns (uint256) {
        return vm.getBlockTimestamp();
    }

    function skip_(uint256 secs) internal {
        vm.warp(now_() + secs);
    }

    function takeAs(address who) internal returns (uint256 paid) {
        arb.set(arb.n() + 1);
        vm.prank(who);
        paid = seat.take(type(uint256).max, address(0), "x", 1);
    }

    function pause(bool on) internal {
        vm.prank(owner);
        core.pauseSales(on);
    }

    /// Build lastPaid up with quick takes; returns the last price paid.
    function _buildUp() internal returns (uint256 lastPaid) {
        address[3] memory people = [ana, bob, cat];
        for (uint256 i; i < 8; ++i) {
            lastPaid = takeAs(people[i % 3]);
            skip_(1);
        }
    }

    /// The price formula for `live` unpaused seconds since the last take.
    function _expected(uint256 live) internal view returns (uint256) {
        (,, uint128 lastPaid) = seat.holderOf(seat.today());
        if (live >= 1 hours) return 1e6;
        uint256 s = uint256(lastPaid) * 3 / 2;
        return 1e6 + (s - 1e6) * (1 hours - live) / 1 hours;
    }

    function _other(address holder) internal view returns (address) {
        return holder == ana ? bob : ana;
    }

    // ---------------------------------------------------------------- basics

    function test_noPause_priceStaysHigh() public {
        uint256 lastPaid = _buildUp();
        assertGt(seat.price(), lastPaid * 14 / 10, "price protection intact");
    }

    function test_noPause_sameFormula() public {
        _buildUp();
        skip_(30 minutes);
        (, uint64 since,) = seat.holderOf(0);
        assertEq(seat.price(), _expected(now_() - since), "wall clock == live clock without pauses");
    }

    /// A one-hour pause right after a take leaves the price where it was, and the next taker pays it.
    function test_pauseKeepsPriceProtection() public {
        _buildUp();
        (address holder,,) = seat.holderOf(0);
        uint256 before = seat.price();
        pause(true);
        skip_(1 hours);
        pause(false);
        assertEq(seat.price(), before, "paused hour did not decay the price");
        assertGt(before, seat.FLOOR());
        assertEq(takeAs(_other(holder)), before, "next taker pays the pre-pause price");
        assertLt(seat.secsOf(0, holder), 10, "paused hour not credited either");
    }

    function test_pauseFreezesPrice() public {
        _buildUp();
        uint256 before = seat.price();
        pause(true);
        skip_(30 minutes);
        assertEq(seat.price(), before, "frozen while paused");
        skip_(90 minutes);
        pause(false);
        assertEq(seat.price(), before, "unchanged at unpause");
        assertGt(seat.price(), 20e6, "protection kept");
    }

    function test_partialPause_onlyLiveTimeSlides() public {
        _buildUp();
        uint256 p0 = seat.price();
        skip_(20 minutes);
        uint256 p20 = seat.price();
        pause(true);
        skip_(2 hours);
        pause(false);
        assertEq(seat.price(), p20, "paused time not counted");
        skip_(40 minutes - 2); // 20m + 1s live before the pause
        assertGt(seat.price(), seat.FLOOR(), "1s of live slide left");
        skip_(1);
        assertEq(seat.price(), seat.FLOOR(), "floor after 1h live");
        assertLt(p20, p0);
    }

    // ---------------------------------------------------------------- several pauses, midnight, lens, gas

    /// live 10m, paused 15m, live 5m, paused 20m, live 5m: the price is the 20-minute live slide.
    function test_severalPausesInOneReign() public {
        _buildUp();
        (address holder,,) = seat.holderOf(0);
        uint256 credit0 = seat.secsOf(0, holder); // earlier short reigns from the build-up
        uint256 p0 = seat.price();
        skip_(10 minutes);
        pause(true);
        skip_(15 minutes);
        pause(false);
        skip_(5 minutes);
        pause(true);
        skip_(20 minutes);
        assertEq(seat.price(), _expected(15 minutes + 1), "frozen inside the second pause");
        pause(false);
        skip_(5 minutes);
        uint256 p = seat.price();
        assertEq(p, _expected(20 minutes + 1), "only the 20 live minutes slid");
        assertLt(p, p0);
        assertGt(p, seat.FLOOR());
        assertEq(takeAs(_other(holder)), p);
        assertEq(seat.secsOf(0, holder) - credit0, 20 minutes + 1, "credit matches the price clock");
    }

    /// A pause that runs past midnight: the new day starts at the floor, the old holder is credited live time only,
    /// and the old day's pause does not touch the new day's slide.
    function test_pauseAcrossMidnight() public {
        vm.warp(day0 + 1 days - 40 minutes);
        _buildUp();
        (address holder, uint64 since,) = seat.holderOf(0);
        uint256 credit0 = seat.secsOf(0, holder); // earlier short reigns from the build-up
        uint256 before = seat.price();
        skip_(10 minutes);
        pause(true);
        uint256 pausedAt = now_();
        vm.warp(day0 + 1 days + 20 minutes);
        assertEq(seat.today(), 1);
        assertEq(seat.price(), seat.FLOOR(), "a new day starts at the floor, paused or not");
        pause(false);
        assertEq(seat.price(), seat.FLOOR());

        seat.settle(0);
        assertEq(seat.secsOf(0, holder) - credit0, pausedAt - since, "only the live part of the reign is credited");
        assertGt(before, seat.FLOOR());

        assertEq(takeAs(_other(holder)), seat.FLOOR(), "first take of the new day");
        skip_(10 minutes);
        assertEq(seat.price(), _expected(10 minutes), "the old day's pause doesn't count against the new reign");
        pause(true);
        skip_(1 hours);
        pause(false);
        assertEq(seat.price(), _expected(10 minutes), "frozen through a pause on the new day");
    }

    function test_fairLens_frozenDuringOpenPause() public {
        FairLens lens = new FairLens(core, LastArrow(address(0)), seat, IVaultView(address(0)));
        _buildUp();
        skip_(12 minutes);
        uint256 before = seat.price();
        assertEq(lens.seatNow().price, before);
        pause(true);
        skip_(45 minutes);
        assertEq(seat.price(), before, "seat frozen during the open pause");
        assertEq(lens.seatNow().price, before, "lens shows the frozen price");
        skip_(3 hours);
        assertEq(lens.seatNow().price, before, "still frozen hours later");
        pause(false);
        assertEq(lens.seatNow().price, before);
    }

    /// The busiest pause log one reign can see inside a day: a pause every MIN_PAUSE_GAP (143 fit after a 00:00 take).
    /// price() and take() both scan it from the reign's start; both stay far below a block.
    function test_gas_reignWith143Pauses_sameDay() public {
        vm.warp(day0);
        takeAs(ana);
        uint256 gap = core.MIN_PAUSE_GAP();
        for (uint256 i; i < 143; ++i) {
            skip_(1);
            pause(true);
            skip_(gap - 2);
            pause(false);
            skip_(1);
        }
        assertEq(core.pauseCount(), 143);
        assertEq(seat.today(), 0, "still day 0");
        uint256 live = 143 * 2;
        assertEq(seat.price(), _expected(live), "price counts the 286 live seconds only");

        vm.cool(address(seat));
        vm.cool(address(core));
        uint256 g = gasleft();
        uint256 p = seat.price();
        uint256 priceGas = g - gasleft();
        assertEq(p, _expected(live));

        vm.cool(address(seat));
        vm.cool(address(core));
        arb.set(arb.n() + 1);
        vm.prank(bob);
        g = gasleft();
        uint256 paid = seat.take(type(uint256).max, address(0), "x", 1);
        uint256 takeGas = g - gasleft();
        assertEq(paid, p);
        assertEq(seat.secsOf(0, ana), live, "credit matches the price clock");

        emit log_named_uint("price() gas, 143 pauses in the reign", priceGas);
        emit log_named_uint("take() gas, 143 pauses in the reign", takeGas);
        assertLt(priceGas, 1_000_000);
        assertLt(takeGas, 2_000_000);
    }
}
