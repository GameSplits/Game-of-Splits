// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Base} from "../Base.t.sol";
import {FairCore} from "../../src/FairCore.sol";

/// FC-01 regression: a dump before the keeper's quote must not lift the anchor by more than 2%,
/// and must not freeze later buybacks.
contract FairCoreAnchorPreQuoteTest is Base {
    uint256 constant RATE = 781_250e12;
    uint256 constant IN = 50e6;

    function setUp() public override {
        super.setUp();
        openFair();
        shot(ana, 1, 200_000e6);
        reseed(RATE * 1e18); // A1-12: through the timelock (restarts the decay clock after the 48h wait)
    }

    /// Honest keeper rule: minOut = quote - 1.5%, never below floor; skip if quote < floor.
    function _honestBuy() internal returns (bool ok) {
        uint256 quote = IN * route.rate();
        uint256 floor = IN * core.ratchetFloorRate() / 1e18;
        if (quote < floor) return false;
        uint256 minOut = quote * 9850 / 10_000;
        if (minOut < floor) minOut = floor;
        vm.prank(keeper);
        try core.burnBuyToken(FairCore.BurnSource.Bonfire, 0, IN, minOut) {
            return true;
        } catch {
            return false;
        }
    }

    function _inflate(uint256 kBps) internal {
        route.setRate(RATE * kBps / 10_000);
        assertTrue(_honestBuy(), "honest keeper buys at the manipulated quote");
        route.setRate(RATE);
    }

    function _assertCapped(uint256 before) internal view {
        uint256 cap = before * (10_000 + core.MAX_ANCHOR_RAISE_BPS()) / 10_000;
        assertLe(core.anchorRate(), cap, "anchor rose by more than 2%");
        assertGe(core.anchorRate(), before, "anchor fell below the pre-swap value");
    }

    /// k = 1.6x used to freeze buys until resetRatchet. The anchor now stops at +2%.
    function test_FC01_preQuote_1_6x_doesNotFreeze() public {
        uint256 before = core.decayedAnchor();
        _inflate(16_000);
        _assertCapped(before);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        assertTrue(_honestBuy(), "not frozen an hour later");
    }

    /// k = 1.2x used to freeze for about 11 hours.
    function test_FC01_preQuote_1_2x_doesNotFreeze() public {
        uint256 before = core.decayedAnchor();
        _inflate(12_000);
        _assertCapped(before);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        assertTrue(_honestBuy(), "not frozen");
    }

    /// A keeper that sets minOut to the manipulated fill used to freeze past max decay.
    function test_FC01_compromisedKeeper_minOutEqualsFill_doesNotFreeze() public {
        uint256 before = core.decayedAnchor();
        route.setRate(RATE * 15_100 / 10_000);
        uint256 fill = IN * route.rate();
        vm.prank(keeper);
        core.burnBuyToken(FairCore.BurnSource.Bonfire, 0, IN, fill);
        _assertCapped(before);
        route.setRate(RATE);
        vm.warp(vm.getBlockTimestamp() + 40 hours);
        assertLt(IN * core.ratchetFloorRate() / 1e18, IN * RATE, "floor is under the market after decay");
        assertTrue(_honestBuy(), "not frozen");
    }

    /// Control: a post-quote windfall (the case the quote-anchor fixed) still does not freeze.
    function test_control_postQuoteWindfall_noFreeze() public {
        uint256 quote = IN * RATE;
        route.setRate(RATE * 16 / 10);
        vm.prank(keeper);
        core.burnBuyToken(FairCore.BurnSource.Bonfire, 0, IN, quote * 9850 / 10_000);
        route.setRate(RATE);
        vm.warp(vm.getBlockTimestamp() + 50 minutes);
        assertTrue(_honestBuy(), "no freeze");
    }
}
