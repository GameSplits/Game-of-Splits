// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Base} from "../Base.t.sol";
import {FairCore} from "../../src/FairCore.sol";
import {RakeBuyer} from "../../src/RakeBuyer.sol";
import {IGameConfig} from "../../src/interfaces/IFair.sol";

/// M-2 (review findings G-2, F2): a keeper quote just above the decayed anchor used to re-anchor there and restart the
/// decay, so the floor walked 70% -> 49% -> 34% -> 24% of the seed in 120h with no Safe action. The high-water
/// `anchorBase` keeps `decayedAnchor()` at or above 70% of the last high, and reset bounds are measured from it.
contract FairCoreHighWaterTest is Base {
    uint256 constant STOP_BPS = 7000;
    uint256 constant FLOOR_STOP_BPS = 6650; // 95% of 70%

    function setUp() public override {
        super.setUp();
        openFair();
        shot(ana, 1, 10_000e6); // Bonfire 700 USDG
    }

    /// The route pays exactly the keeper's quote `px` (buy-token wei per USDG unit, x1e18).
    function _burnAt(uint256 usdgIn, uint256 px) internal {
        uint256 minOut = usdgIn * px / 1e18;
        if (minOut == 0) minOut = 1;
        uint256 rate = (minOut + usdgIn - 1) / usdgIn;
        if (rate == 0) rate = 1;
        route.setRate(rate);
        vm.prank(keeper);
        core.burnBuyToken(FairCore.BurnSource.Bonfire, 0, usdgIn, minOut);
    }

    function _seedHigh() internal returns (uint256 a0) {
        _burnAt(100e6, route.rate() * 1e18);
        a0 = core.anchorRate();
        assertEq(core.anchorBase(), a0, "the seed/first quote sets the high-water mark");
    }

    /// The review PoC, unchanged: four 1-USDG swaps 30h apart at decayed+1. It used to end below 70% of a0.
    function test_reviewPoc_walkStopsAt70() public {
        uint256 a0 = _seedHigh();
        for (uint256 i; i < 4; i++) {
            vm.warp(vm.getBlockTimestamp() + 30 hours);
            uint256 cur = core.decayedAnchor();
            uint256 minOut = 1e6 * cur / 1e18 + 1;
            vm.prank(keeper);
            core.burnBuyToken(FairCore.BurnSource.Bonfire, 0, 1e6, minOut);
            assertGe(core.decayedAnchor(), a0 * STOP_BPS / 10_000, "decayed anchor >= 70% of the high");
        }
        vm.warp(vm.getBlockTimestamp() + 30 days);
        assertGe(core.decayedAnchor(), a0 * STOP_BPS / 10_000, "still >= 70% a month later");
        assertGe(core.ratchetFloorRate(), a0 * FLOOR_STOP_BPS / 10_000, "floor >= 66.5% of the high");
        assertEq(core.anchorBase(), a0, "low writes never lower the high-water mark");
    }

    /// A walked-down anchor no longer shrinks the reset range: the Safe can always restore the high.
    function test_resetBounds_fromTheHigh() public {
        uint256 a0 = _seedHigh();
        for (uint256 i; i < 4; i++) {
            vm.warp(vm.getBlockTimestamp() + 30 hours);
            uint256 minOut = 1e6 * core.decayedAnchor() / 1e18 + 1; // just above the decayed anchor: re-anchors
            route.setRate((minOut + 1e6 - 1) / 1e6);
            vm.prank(keeper);
            core.burnBuyToken(FairCore.BurnSource.Bonfire, 0, 1e6, minOut);
        }
        assertLt(core.anchorRate(), a0, "the stored anchor did walk down");
        (uint256 lo, uint256 hi) = core.resetBounds();
        assertEq(lo, a0 * 7000 / 10_000);
        assertEq(hi, a0 * 13_000 / 10_000);
        reseed(a0); // back to the high in one timelocked step
        assertEq(core.anchorRate(), a0);
        assertEq(core.anchorBase(), a0);
    }

    /// A genuine raise (within the 2%/4h cap) lifts the high-water mark with it.
    function test_raiseLiftsTheHigh() public {
        uint256 a0 = _seedHigh();
        reseed(a0); // opens a raise window at a0
        _burnAt(1e6, a0 * 2); // capped at 1.02 x a0
        assertGt(core.anchorBase(), a0);
        assertEq(core.anchorBase(), core.anchorRate());
    }

    /// A Safe reset sets the high-water mark, down as well as up.
    function test_resetSetsTheHigh() public {
        uint256 a0 = _seedHigh();
        uint256 lower = a0 * 8000 / 10_000;
        reseed(lower);
        assertEq(core.anchorBase(), lower);
        assertEq(core.decayedAnchor(), lower);
    }

    /// Any run of keeper quotes the floor accepts, at any spacing, keeps the decayed anchor >= 70% of the high, and
    /// the high never falls without the Safe.
    function testFuzz_walkNeverBelow70(uint256 seed, uint8 hops) public {
        uint256 a0 = _seedHigh();
        uint256 n = bound(hops, 1, 24);
        uint256 hi = a0;
        for (uint256 i; i < n; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            vm.warp(vm.getBlockTimestamp() + bound(seed % 1e9, 50 minutes, 96 hours));
            uint256 floorRate = core.ratchetFloorRate();
            uint256 px = bound(seed >> 64, floorRate + 1, floorRate * 2);
            _burnAt(1e6, px);
            assertGe(core.anchorBase(), hi, "the high never falls");
            hi = core.anchorBase();
            assertGe(core.decayedAnchor(), hi * STOP_BPS / 10_000, "decayed anchor >= 70% of the high");
            assertGe(core.anchorBase(), core.anchorRate(), "the high is at least the stored anchor");
        }
        assertGe(core.decayedAnchor(), a0 * STOP_BPS / 10_000);
    }
}

/// The same for RakeBuyer.
contract RakeBuyerHighWaterTest is Base {
    RakeBuyer rb;
    uint256 constant RATE = 781_250e12;

    function setUp() public override {
        super.setUp();
        rb = new RakeBuyer(usdg, IGameConfig(address(config)), makeAddr("locksleyVault"), owner, 48 hours);
        vm.startPrank(owner);
        rb.setupSet(RakeBuyer.Op.SetKeeper, 0, keeper);
        rb.setupSet(RakeBuyer.Op.SetRoute, 0, address(route));
        rb.resetRatchet(RATE * 1e18);
        rb.finishSetup();
        vm.stopPrank();
        usdg.mint(address(rb), 1_000e6); // buy() syncs: half to the buy ledger
    }

    function _buyAt(uint256 usdgIn, uint256 px) internal {
        uint256 minOut = usdgIn * px / 1e18;
        if (minOut == 0) minOut = 1;
        uint256 rate = (minOut + usdgIn - 1) / usdgIn;
        if (rate == 0) rate = 1;
        route.setRate(rate);
        vm.prank(keeper);
        rb.buy(0, usdgIn, minOut);
    }

    function test_reviewPoc_walkStopsAt70() public {
        uint256 a0 = rb.anchorRate();
        assertEq(rb.anchorBase(), a0);
        for (uint256 i; i < 4; i++) {
            vm.warp(vm.getBlockTimestamp() + 30 hours);
            uint256 cur = rb.decayedAnchor();
            uint256 minOut = 1e6 * cur / 1e18 + 1;
            route.setRate((minOut + 1e6 - 1) / 1e6);
            vm.prank(keeper);
            rb.buy(0, 1e6, minOut);
            assertGe(rb.decayedAnchor(), a0 * 7000 / 10_000);
        }
        assertGe(rb.ratchetFloorRate(), a0 * 6650 / 10_000);
        assertEq(rb.anchorBase(), a0);
        (uint256 lo, uint256 hi) = rb.resetBounds();
        assertEq(lo, a0 * 7000 / 10_000);
        assertEq(hi, a0 * 13_000 / 10_000);
        reseedRb(rb, a0);
        assertEq(rb.anchorRate(), a0);
    }

    function testFuzz_walkNeverBelow70(uint256 seed, uint8 hops) public {
        uint256 a0 = rb.anchorRate();
        uint256 n = bound(hops, 1, 24);
        uint256 hi = a0;
        for (uint256 i; i < n; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            vm.warp(vm.getBlockTimestamp() + bound(seed % 1e9, 50 minutes, 96 hours));
            uint256 floorRate = rb.ratchetFloorRate();
            _buyAt(1e6, bound(seed >> 64, floorRate + 1, floorRate * 2));
            assertGe(rb.anchorBase(), hi);
            hi = rb.anchorBase();
            assertGe(rb.decayedAnchor(), hi * 7000 / 10_000);
            assertGe(rb.anchorBase(), rb.anchorRate());
        }
    }
}
