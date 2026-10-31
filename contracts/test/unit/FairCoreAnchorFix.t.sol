// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Base} from "../Base.t.sol";
import {FairCore} from "../../src/FairCore.sol";

/// The buyback anchor follows the keeper's quote. A fill above that quote must not lift it.
contract FairCoreAnchorFixTest is Base {
    uint256 constant RATE = 781_250e12;

    function setUp() public override {
        super.setUp();
        openFair();
        shot(ana, 1, 200_000e6); // Bonfire 14,000 USDG
        reseed(RATE * 1e18); // A1-12: through the timelock (restarts the decay clock after the 48h wait)
    }

    /// A fill above the keeper's quote used to lift the anchor. After max decay the floor still sat above the
    /// market, and every later buy reverted RatchetTripped. The anchor now follows minOut.
    function test_windfallFill_doesNotFreezeBuys() public {
        route.setRate(RATE * 16 / 10);
        vm.prank(keeper);
        uint256 out = core.burnBuyToken(FairCore.BurnSource.Bonfire, 0, 50e6, 50e6 * RATE);
        assertEq(out, 50e6 * RATE * 16 / 10, "the route still pays the windfall");
        assertEq(core.anchorRate(), RATE * 1e18, "anchor stays on the keeper's quote");

        route.setRate(RATE);
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        assertLt(core.ratchetFloorRate(), RATE * 1e18, "floor is under the market after max decay");
        vm.prank(keeper);
        core.burnBuyToken(FairCore.BurnSource.Bonfire, 0, 50e6, 50e6 * RATE);
    }

    /// Fill multiple in bps (10_000 = the quote, 16_000 = 1.6x). The anchor stays on minOut, and a buy at the
    /// market rate still clears the floor.
    function testFuzz_fillMultiple_anchorStaysOnQuote(uint256 multipleBps) public {
        multipleBps = bound(multipleBps, 10_000, 100_000);
        uint256 usdgIn = 50e6;
        uint256 quote = usdgIn * RATE;
        route.setRate(RATE * multipleBps / 10_000);
        vm.prank(keeper);
        uint256 out = core.burnBuyToken(FairCore.BurnSource.Bonfire, 0, usdgIn, quote);
        assertEq(out, usdgIn * RATE * multipleBps / 10_000, "the route pays the multiple");
        if (multipleBps > 10_000) assertGt(out, quote, "the fill beats the quote");
        assertEq(core.anchorRate(), RATE * 1e18, "anchor stays on the keeper's quote");

        route.setRate(RATE);
        vm.warp(vm.getBlockTimestamp() + 50 minutes);
        vm.prank(keeper);
        core.burnBuyToken(FairCore.BurnSource.Bonfire, 0, usdgIn, quote);
    }

    /// Inside one raise window the anchor never exceeds 1.02x the window base, on any ledger.
    function testFuzz_anchorStaysWithinWindowBase(uint16 bumpBps, uint8 hops, uint8 ledger) public {
        hops = uint8(bound(hops, 1, 4)); // 3 gaps of 50 minutes stay inside the 4-hour window
        bumpBps = uint16(bound(bumpBps, 0, 30_000));
        ledger = uint8(bound(ledger, 0, 2));
        uint256 base = core.raiseBase();
        uint256 cap = base * (10_000 + core.MAX_ANCHOR_RAISE_BPS()) / 10_000;
        uint256 usdgIn = 40e6;
        for (uint256 i; i < hops; ++i) {
            if (i != 0) vm.warp(vm.getBlockTimestamp() + 50 minutes);
            uint256 cur = core.decayedAnchor();
            uint256 quote = cur * (10_000 + bumpBps) / 10_000;
            if (quote == 0) quote = 1;
            uint256 minOut = usdgIn * quote / 1e18;
            uint256 floor = usdgIn * core.ratchetFloorRate() / 1e18;
            if (minOut < floor) minOut = floor;
            if (minOut == 0) minOut = 1;
            uint256 rate = (minOut + usdgIn - 1) / usdgIn;
            if (rate == 0) rate = 1;
            route.setRate(rate);
            vm.prank(keeper);
            if (ledger == 2) {
                core.buyForVault(0, usdgIn, minOut);
            } else {
                core.burnBuyToken(
                    ledger == 0 ? FairCore.BurnSource.Bonfire : FairCore.BurnSource.Vault, 0, usdgIn, minOut
                );
            }
            assertEq(core.raiseBase(), base, "the window base is fixed for 4 hours");
            assertLe(core.anchorRate(), cap, "anchor never exceeds 1.02x the window base");
            assertGe(core.anchorRate(), cur, "a swap does not store a price below the decayed anchor");
        }
    }
}
