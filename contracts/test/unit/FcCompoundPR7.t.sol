// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Base} from "../Base.t.sol";
import {FairCore} from "../../src/FairCore.sol";

/// FC-01 regression: the three ledgers share one anchor. A per-swap 2% cap compounds across a keeper pass.
/// The cap is now one 2% raise per 4-hour window.
contract FcCompoundPR7 is Base {
    uint256 constant RATE = 781_250e12;
    uint256 constant IN = 50e6;

    function setUp() public override {
        super.setUp();
        openFair();
        shot(ana, 1, 200_000e6);
        reseed(RATE * 1e18); // A1-12: through the timelock (restarts the decay clock after the 48h wait)
    }

    function _minOut() internal view returns (uint256 m, bool ok) {
        uint256 quote = IN * route.rate();
        uint256 floor = IN * core.ratchetFloorRate() / 1e18;
        if (quote < floor) return (0, false);
        m = quote * 9850 / 10_000;
        if (m < floor) m = floor;
        ok = true;
    }

    function _buy(uint8 l) internal returns (bool) {
        (uint256 m, bool ok) = _minOut();
        if (!ok) return false;
        vm.prank(keeper);
        if (l == 0) {
            try core.burnBuyToken(FairCore.BurnSource.Bonfire, 0, IN, m) {
                return true;
            } catch {
                return false;
            }
        } else if (l == 1) {
            try core.burnBuyToken(FairCore.BurnSource.Vault, 0, IN, m) {
                return true;
            } catch {
                return false;
            }
        } else {
            try core.buyForVault(0, IN, m) {
                return true;
            } catch {
                return false;
            }
        }
    }

    /// One attacked pass used to compound to about 6.1% and stall honest buys. It now stops at 2%.
    function test_threeLedgerPass_doesNotCompound() public {
        uint256 a0 = core.decayedAnchor();
        uint256 base = core.raiseBase();
        for (uint8 l; l < 3; ++l) {
            route.setRate(RATE * 16_000 / 10_000);
            assertTrue(_buy(l), "manipulated buy lands");
            route.setRate(RATE);
        }
        uint256 a1 = core.anchorRate();
        assertLe(a1, base * 10_200 / 10_000, "three ledgers share one 2% window");
        assertLe((a1 - a0) * 10_000 / a0, 200, "one pass rises at most 2%");
        vm.warp(vm.getBlockTimestamp() + 50 minutes);
        (, bool ok) = _minOut();
        assertTrue(ok, "honest quote still clears the floor");
    }

    /// Repeating the pass every 50 minutes used to build a multi-hour freeze. Inside the window it does not.
    function test_repeatedPasses_doNotBuildFreeze() public {
        uint256 base = core.raiseBase();
        for (uint256 pass; pass < 3; ++pass) {
            uint256 landed;
            for (uint8 l; l < 3; ++l) {
                route.setRate(RATE * 16_000 / 10_000);
                if (_buy(l)) ++landed;
                route.setRate(RATE);
            }
            assertEq(landed, 3, "every manipulated buy in the pass lands");
            assertLe(core.anchorRate(), base * 10_200 / 10_000);
            vm.warp(vm.getBlockTimestamp() + 50 minutes);
        }
        (, bool ok) = _minOut();
        assertTrue(ok, "no stall after three attacked passes");
        assertEq(core.raiseBase(), base, "still inside the first window");
    }

    /// After the window, the next cap is 2% above the decayed anchor, so the ceiling falls with the 1%/hour decay.
    function test_windowRoll_nextCapFollowsDecay() public {
        route.setRate(RATE * 16_000 / 10_000);
        assertTrue(_buy(0), "first window fills the 2% cap");
        route.setRate(RATE);
        uint256 peak = core.anchorRate();
        vm.warp(vm.getBlockTimestamp() + 4 hours);
        route.setRate(RATE * 16_000 / 10_000);
        assertTrue(_buy(0), "the same ledger can buy again after the window");
        assertLe(core.anchorRate(), core.raiseBase() * 10_200 / 10_000);
        assertLt(core.anchorRate(), peak, "decay pulls the ceiling down across windows");
    }
}
