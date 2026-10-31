// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Base} from "../Base.t.sol";
import {RakeBuyer} from "../../src/RakeBuyer.sol";
import {IGameConfig} from "../../src/interfaces/IFair.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// RakeBuyer's anchor follows FairCore: at most +2% per 4-hour window, off the decayed base.
contract RakeBuyerAnchorCapTest is Base {
    RakeBuyer rb;
    uint256 constant RATE = 781_250e12;
    uint256 constant IN = 10e6;

    function setUp() public override {
        super.setUp();
        rb = new RakeBuyer(usdg, IGameConfig(address(config)), makeAddr("locksleyVault"), owner, 48 hours);
        vm.startPrank(owner);
        rb.setupSet(RakeBuyer.Op.SetKeeper, 0, keeper);
        rb.setupSet(RakeBuyer.Op.SetRoute, 0, address(route));
        rb.resetRatchet(RATE * 1e18);
        rb.finishSetup();
        vm.stopPrank();
    }

    function _cap(uint256 base) internal view returns (uint256) {
        return base * (rb.BPS() + rb.MAX_ANCHOR_RAISE_BPS()) / rb.BPS();
    }

    /// Keeper quote at `px` (buy-token wei per USDG unit, x1e18). The route pays that quote.
    function _buyAt(uint256 px) internal returns (uint256 out) {
        uint256 minOut = IN * px / 1e18;
        if (minOut == 0) minOut = 1;
        uint256 rate = (minOut + IN - 1) / IN;
        if (rate == 0) rate = 1;
        route.setRate(rate);
        vm.prank(keeper);
        out = rb.buy(0, IN, minOut);
    }

    function _fund(uint256 n) internal {
        usdg.mint(address(rb), IN * 2 * n);
    }

    /// One manipulated quote, any size, stops at 2% above the window base.
    function test_hugeQuote_raisesAtMostTwoPercent() public {
        _fund(1);
        uint256 base = rb.raiseBase();
        uint256 cap = _cap(base);
        uint256 quote = base * 10;
        _buyAt(quote);
        assertEq(rb.raiseBase(), base, "the window base does not move inside the 4 hours");
        assertEq(rb.raiseWindowStart(), block.timestamp, "resetRatchet opened this window");
        assertEq(rb.anchorRate(), cap, "min(quote, 1.02 x the window base)");
        assertLt(rb.anchorRate(), quote, "a 10x quote does not land");
    }

    /// A quote under the cap still lands on the quote. The cap is a ceiling, not a fixed step.
    function test_quoteUnderTheCap_landsOnTheQuote() public {
        _fund(1);
        uint256 base = rb.raiseBase();
        uint256 quote = base * 10_100 / 10_000; // +1%
        _buyAt(quote);
        assertEq(rb.anchorRate(), quote, "a +1% quote is inside the +2% cap");
        assertEq(rb.raiseBase(), base, "the window base does not move inside the 4 hours");
    }

    /// Buys 50 minutes apart, all inside one 4-hour window, share one 2% ceiling.
    function test_repeatedBuys_stayCappedForTheWholeWindow() public {
        uint256 buys = 5; // t = 0, 50, 100, 150, 200 minutes; 200 < 240
        _fund(buys);
        uint256 base = rb.raiseBase();
        uint64 windowStart = rb.raiseWindowStart();
        uint256 cap = _cap(base);
        for (uint256 i; i < buys; ++i) {
            if (i != 0) vm.warp(block.timestamp + 50 minutes);
            assertLt(block.timestamp, uint256(windowStart) + rb.RAISE_WINDOW(), "still inside the first window");
            _buyAt(base * 10);
            assertEq(rb.raiseBase(), base, "the window base is fixed for 4 hours");
            assertEq(rb.raiseWindowStart(), windowStart, "the window does not restart early");
            assertEq(rb.anchorRate(), cap, "repeated quotes do not compound past +2%");
        }
    }

    /// After RAISE_WINDOW the next ceiling is 2% above the decayed anchor, not above the old peak.
    function test_newWindow_allowsAnotherTwoPercentFromDecayedBase() public {
        _fund(2);
        uint256 base = rb.raiseBase();
        _buyAt(base * 10);
        uint256 peak = rb.anchorRate();
        assertEq(peak, _cap(base), "the first window fills the 2% cap");

        vm.warp(block.timestamp + rb.RAISE_WINDOW());
        uint256 cur = rb.decayedAnchor();
        assertEq(cur, peak * (rb.BPS() - 4 * rb.ANCHOR_DECAY_BPS_PER_HOUR()) / rb.BPS(), "4 hours, 1% each");
        _buyAt(peak * 10);
        assertEq(rb.raiseBase(), cur, "the new window starts at the decayed anchor");
        assertEq(rb.raiseWindowStart(), block.timestamp, "the window restarts");
        assertEq(rb.anchorRate(), _cap(cur), "another 2% from the decayed base");
        assertLt(rb.anchorRate(), peak, "decay pulls the ceiling down across windows");
    }

    /// The view is unchanged: 1% per hour, and never below 70% of the stored anchor.
    function test_decay_stillOnePercentPerHour_andStopsAtSeventy() public {
        _fund(1);
        uint256 base = rb.raiseBase();
        _buyAt(base * 10);
        uint256 raised = rb.anchorRate();
        vm.warp(block.timestamp + 10 hours);
        assertEq(rb.decayedAnchor(), raised * 90 / 100, "1% per hour");
        assertEq(rb.ratchetFloorRate(), rb.decayedAnchor() * rb.RATCHET_BPS() / rb.BPS(), "floor stays 95%");
        vm.warp(block.timestamp + 100 hours);
        assertEq(rb.decayedAnchor(), raised * 70 / 100, "at most 30%");
    }

    /// The Safe's reset restarts the anchor and the raise window together, the way FairCore does.
    /// The constructor leaves both unset; only resetRatchet (and a buy into an expired window) writes them.
    function test_resetRatchet_restartsAnchorAndWindow() public {
        RakeBuyer fresh = new RakeBuyer(usdg, IGameConfig(address(config)), makeAddr("v2"), owner, 48 hours);
        assertEq(fresh.raiseBase(), 0, "constructor leaves raiseBase unset");
        assertEq(fresh.raiseWindowStart(), 0, "constructor leaves the window unset");

        _fund(2);
        _buyAt(rb.raiseBase() * 10);
        assertEq(rb.anchorRate(), _cap(RATE * 1e18), "the cap filled before the reset");

        uint256 freshAnchor = rb.anchorRate() * 75 / 100; // inside MAX_RESET_BPS (A1-12)
        vm.warp(block.timestamp + 1 hours);
        vm.prank(owner);
        rb.queue(RakeBuyer.Op.ResetRatchet, freshAnchor, address(0));
        vm.warp(block.timestamp + rb.timelockDelay());
        uint256 opened = block.timestamp;
        vm.prank(owner);
        rb.execute(RakeBuyer.Op.ResetRatchet, freshAnchor, address(0));
        assertEq(rb.anchorRate(), freshAnchor);
        assertEq(rb.anchorAt(), opened);
        assertEq(rb.anchorEpoch(), config.epoch());
        assertEq(rb.raiseBase(), freshAnchor, "the window base is the Safe's price, not the old cap");
        assertEq(rb.raiseWindowStart(), opened, "the window starts at the reset");

        // Three hours later the window is still the reset's. A huge quote stops at +2% of the reset price.
        vm.warp(block.timestamp + 3 hours);
        assertLt(block.timestamp, opened + rb.RAISE_WINDOW(), "still inside the reset window");
        _buyAt(freshAnchor * 10);
        assertEq(rb.raiseBase(), freshAnchor, "decay does not move the base inside the window");
        assertEq(rb.anchorRate(), _cap(freshAnchor), "the cap is 2% above the reset, not the old peak");
        assertLt(rb.anchorRate(), _cap(RATE * 1e18));

        vm.prank(owner);
        vm.expectRevert(RakeBuyer.SetupClosed.selector);
        rb.resetRatchet(freshAnchor);
        vm.prank(ana);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, ana));
        rb.resetRatchet(freshAnchor);
    }

    /// Quote size and the gap before each buy. A quote above the decayed anchor settles at min(quote, cap).
    function testFuzz_quoteAndGap_anchorNeverExceedsCap(uint256 bumpBps, uint32 gapSecs, uint8 hops) public {
        hops = uint8(bound(hops, 1, 8));
        bumpBps = bound(bumpBps, 0, 50_000);
        gapSecs = uint32(bound(gapSecs, 50 minutes, 48 hours));
        _fund(hops);

        for (uint256 i; i < hops; ++i) {
            if (i != 0) vm.warp(block.timestamp + gapSecs);
            uint256 prev = rb.anchorRate();
            uint256 cur = rb.decayedAnchor();
            uint256 base = rb.raiseBase();
            if (block.timestamp >= uint256(rb.raiseWindowStart()) + rb.RAISE_WINDOW()) base = cur;
            uint256 cap = _cap(base);

            uint256 px = cur + cur * bumpBps / 10_000;
            uint256 floorRate = rb.ratchetFloorRate();
            if (px < floorRate) px = floorRate;
            uint256 minOut = IN * px / 1e18;
            if (minOut < IN * floorRate / 1e18) minOut = IN * floorRate / 1e18;
            if (minOut == 0) minOut = 1;
            uint256 rate = (minOut + IN - 1) / IN;
            if (rate == 0) rate = 1;
            route.setRate(rate);
            vm.prank(keeper);
            rb.buy(0, IN, minOut);

            uint256 quoted = minOut * 1e18 / IN;
            uint256 anchor = rb.anchorRate();
            assertEq(rb.raiseBase(), base, "raiseBase is the window base the cap was taken from");
            if (quoted > cur) {
                uint256 expect = quoted > cap ? cap : quoted;
                assertEq(anchor, expect, "anchor becomes min(quote, cap)");
                assertLe(anchor, cap, "anchor never exceeds the cap");
            } else {
                assertEq(anchor, prev, "a quote at or under the decayed anchor does not move it");
                assertLe(anchor, prev > cap ? prev : cap, "anchor never exceeds the cap");
            }
        }
    }
}
