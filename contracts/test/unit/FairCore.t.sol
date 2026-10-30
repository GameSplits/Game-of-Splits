// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Base} from "../Base.t.sol";
import {IGameConfig, Split, Tokens} from "../../src/interfaces/IFair.sol";
import {FairCore} from "../../src/FairCore.sol";
import {StubBooth} from "../mocks/Mocks.sol";
import {IFairCore} from "../../src/interfaces/IFair.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract FairCoreTest is Base {
    // ---------------------------------------------------------------- split

    function test_split_oneUsdg_matchesSpecTable() public {
        openFair();
        shot(ana, 1, 1e6);
        assertEq(core.pot(address(booth), 1), 600_000, "Purse 60%");
        assertEq(core.almsByFair(0), 80_000, "Alms 8%");
        assertEq(core.bonfirePending(), 70_000, "Bonfire 7%");
        assertEq(core.tollPending(), 70_000, "Toll 7%");
        assertEq(core.vaultBuyPending(), 45_000, "Vault $wif held 4.5%");
        assertEq(core.vaultLiqUsdg(), 45_000, "Vault USDG 4.5%");
        assertEq(core.vaultBurnPending(), 45_000, "Vault $wif burn 4.5%");
        assertEq(core.vaultFairsBurnUsdg(), 45_000, "Vault $FAIRS burn 4.5%");
        assertEq(core.accounted(), 1e6);
        assertTrue(core.playedIn(0, ana));
    }

    function test_exampleDay_31115_13() public {
        openFair();
        shot(ana, 1, 29_115_130_000); // Last Arrow day
        shot(bob, 2, 2_000_000_000); // Seat day
        uint256 gross = 31_115_130_000;
        assertEq(gross - core.pot(address(booth), 1) - core.pot(address(booth), 2), 12_446_052_000, "Greenwood");
        assertEq(core.almsByFair(0), 2_489_210_400);
        assertEq(core.bonfirePending(), 2_178_059_100);
        uint256 vault =
            core.vaultBuyPending() + core.vaultLiqUsdg() + core.vaultBurnPending() + core.vaultFairsBurnUsdg();
        assertEq(vault, 5_600_723_400, "Vault 18%");
        assertSolvent();
    }

    function testFuzz_splitSumsToGross(uint256 gross) public {
        gross = bound(gross, 1, 1e15);
        openFair();
        usdg.mint(ana, gross);
        shot(ana, 7, gross);
        assertEq(core.pot(address(booth), 7) + ledgers(), gross, "every unit accounted for");
        assertEq(core.accounted(), gross);
    }

    // ---------------------------------------------------------------- payer vs player

    function test_fundsAlwaysFromPayer_creditToPlayer() public {
        openFair();
        uint256 anaBefore = usdg.balanceOf(ana);
        uint256 bobBefore = usdg.balanceOf(bob);
        vm.prank(bob); // bob pays, ana is credited
        booth.shot(ana, 1, 5e6);
        assertEq(usdg.balanceOf(ana), anaBefore, "player's USDG never moves");
        assertEq(usdg.balanceOf(bob), bobBefore - 5e6);
        assertTrue(core.playedIn(0, ana));
        assertFalse(core.playedIn(0, bob));
    }

    function test_onlyBoothsCollectAndAward() public {
        openFair();
        vm.expectRevert(FairCore.NotBooth.selector);
        core.collect(ana, ana, 1, 1e6);
        vm.expectRevert(FairCore.NotBooth.selector);
        core.award(1, new address[](0), new uint256[](0));
    }

    function test_noShotsOutsideAFair() public {
        vm.prank(ana);
        vm.expectRevert(FairCore.NoActiveFair.selector);
        booth.shot(ana, 1, 1e6); // before the Fair opens
        vm.warp(T0 + 6 days);
        vm.prank(ana);
        vm.expectRevert(FairCore.NoActiveFair.selector);
        booth.shot(ana, 1, 1e6); // after it ends
    }

    // ---------------------------------------------------------------- award, rollover, claim

    function _arr(address a, address b) internal pure returns (address[] memory w) {
        w = new address[](2);
        (w[0], w[1]) = (a, b);
    }

    function _amt(uint256 a, uint256 b) internal pure returns (uint256[] memory x) {
        x = new uint256[](2);
        (x[0], x[1]) = (a, b);
    }

    function test_award_claim_and_rolloverSeedsNextRound() public {
        openFair();
        shot(ana, 1, 10e6); // pot 6
        shot(bob, 1, 10e6); // pot 12
        booth.settle(1, _arr(ana, bob), _amt(7e6, 3e6)); // 2 unpaid -> rollover
        assertEq(core.claimable(ana), 7e6);
        assertEq(core.rollover(address(booth)), 2e6);
        assertEq(core.pot(address(booth), 1), 0);

        vm.expectRevert(FairCore.AlreadyAwarded.selector);
        booth.settle(1, _arr(ana, bob), _amt(1, 1));

        shot(cat, 2, 10e6); // seeds round 2 with the 2 USDG
        assertEq(core.pot(address(booth), 2), 6e6 + 2e6, "own 60% + exactly the rollover");
        assertEq(core.rollover(address(booth)), 0);
        shot(cat, 2, 10e6); // doesn't seed again
        assertEq(core.pot(address(booth), 2), 12e6 + 2e6);

        uint256 before = usdg.balanceOf(ana);
        vm.prank(ana);
        core.claim();
        assertEq(usdg.balanceOf(ana) - before, 7e6);
        vm.prank(ana);
        vm.expectRevert(FairCore.NothingToClaim.selector);
        core.claim();
        assertSolvent();
    }

    function test_award_cannotExceedPot() public {
        openFair();
        shot(ana, 1, 10e6);
        vm.expectRevert(FairCore.OverPot.selector);
        booth.settle(1, _arr(ana, bob), _amt(5e6, 2e6));
    }

    function test_award_skipsZeroWinner_intoRollover() public {
        openFair();
        shot(ana, 1, 10e6);
        booth.settle(1, _arr(ana, address(0)), _amt(4e6, 2e6));
        assertEq(core.claimable(ana), 4e6);
        assertEq(core.rollover(address(booth)), 2e6);
    }

    function test_award_boundedArrays() public {
        openFair();
        shot(ana, 1, 10e6);
        vm.expectRevert(FairCore.BadArrays.selector);
        booth.settle(1, new address[](13), new uint256[](13));
        vm.expectRevert(FairCore.BadArrays.selector);
        booth.settle(1, new address[](2), new uint256[](1));
    }

    function test_rolloverIsPerBooth() public {
        openFair();
        StubBooth other = new StubBooth(IFairCore(address(core)));
        // adding a booth after setup needs the timelock
        vm.prank(owner);
        core.queue(FairCore.Op.AddBooth, 0, address(other));
        vm.warp(block.timestamp + 48 hours);
        vm.prank(owner);
        core.execute(FairCore.Op.AddBooth, 0, address(other));

        shot(ana, 1, 10e6);
        booth.settle(1, new address[](0), new uint256[](0)); // whole 6 rolls over in `booth`
        vm.prank(bob);
        core.approveBooth(address(other), 10e6); // A1-11: a booth added after setup needs a per-booth approval
        vm.prank(bob);
        other.shot(bob, 1, 10e6);
        assertEq(core.pot(address(other), 1), 6e6, "other booth not seeded by booth's rollover");
        assertEq(core.rollover(address(booth)), 6e6);
    }

    // ---------------------------------------------------------------- pause

    function test_pause_blocksShotsOnly() public {
        openFair();
        shot(ana, 1, 10e6);
        booth.settle(1, _arr(ana, address(0)), _amt(6e6, 0));
        vm.prank(owner);
        core.pauseSales(true);
        vm.prank(bob);
        vm.expectRevert(FairCore.Paused.selector);
        booth.shot(bob, 2, 1e6);
        vm.prank(ana);
        core.claim(); // still works
        uint256 full = 0.7e6 * route.rate();
        vm.prank(keeper);
        core.burnBuyToken(FairCore.BurnSource.Bonfire, 0, 0.7e6, full); // keeper still works
        vm.prank(owner);
        core.revokeKeeper(); // revoke works while paused
        assertEq(core.keeper(), address(0));
    }

    // ---------------------------------------------------------------- keeper swaps and guards

    function _fillBonfire() internal {
        openFair();
        shot(ana, 1, 10_000e6); // Bonfire 700, Vault quarters 450 each
    }

    function test_burnBuyToken_toDead_andLedger() public {
        _fillBonfire();
        uint256 full = 250e6 * route.rate();
        vm.prank(keeper);
        uint256 out = core.burnBuyToken(FairCore.BurnSource.Bonfire, 0, 250e6, full);
        assertEq(out, 250e6 * route.rate());
        assertEq(wif.balanceOf(core.DEAD()), out);
        assertEq(core.bonfirePending(), 450e6);
        uint256 minOut = 100e6 * route.rate() * 97 / 100; // keeper rule: quote - 3%
        vm.prank(keeper);
        core.burnBuyToken(FairCore.BurnSource.Vault, 0, 100e6, minOut);
        assertEq(core.vaultBurnPending(), 350e6);
        assertSolvent();
    }

    function test_buyForVault_holdsInVault() public {
        _fillBonfire();
        uint256 full = 200e6 * route.rate();
        vm.prank(keeper);
        uint256 out = core.buyForVault(0, 200e6, full);
        assertEq(wif.balanceOf(vaultAddr), out);
        assertEq(core.vaultBuyPending(), 250e6);
    }

    function test_guards_cap_zeroMinOut_ledger_route() public {
        _fillBonfire();
        uint256 full = 1e6 * route.rate();
        vm.startPrank(keeper);
        vm.expectRevert(FairCore.OverCap.selector);
        core.burnBuyToken(FairCore.BurnSource.Bonfire, 0, 251e6, 1);
        vm.expectRevert(FairCore.ZeroMinOut.selector);
        core.burnBuyToken(FairCore.BurnSource.Bonfire, 0, 1e6, 0);
        vm.expectRevert(FairCore.OverLedger.selector);
        core.burnBuyToken(FairCore.BurnSource.Bonfire, 0, 701e6, 1);
        vm.expectRevert(FairCore.NoRoute.selector);
        core.burnBuyToken(FairCore.BurnSource.Bonfire, 2, 1e6, full); // a minOut at the floor reaches the route check
        vm.stopPrank();
        vm.prank(ana);
        vm.expectRevert(FairCore.NotKeeper.selector);
        core.burnBuyToken(FairCore.BurnSource.Bonfire, 0, 1e6, 1);
    }

    function test_shortFill_reverts() public {
        _fillBonfire();
        route.setShortchange(true);
        uint256 minOut = 10e6 * route.rate(); // read first: an external call would consume expectRevert
        vm.prank(keeper);
        vm.expectPartialRevert(FairCore.ShortFill.selector);
        core.burnBuyToken(FairCore.BurnSource.Bonfire, 0, 10e6, minOut);
    }

    function _gap() internal {
        vm.warp(vm.getBlockTimestamp() + 50 minutes);
    }

    /// A stolen keeper key can't pass a loose minimum once a price is on record.
    function test_ratchet_tripsAndSafeResets() public {
        _fillBonfire();
        uint256 r = route.rate();
        vm.prank(keeper);
        core.burnBuyToken(FairCore.BurnSource.Bonfire, 0, 100e6, 100e6 * r); // fills at the seeded price
        _gap();
        vm.prank(keeper);
        vm.expectPartialRevert(FairCore.RatchetTripped.selector);
        core.burnBuyToken(FairCore.BurnSource.Bonfire, 0, 100e6, 1); // minOut 1 is far below the floor
        uint256 floorMin = 100e6 * core.ratchetFloorRate() / 1e18;
        vm.prank(keeper);
        core.burnBuyToken(FairCore.BurnSource.Bonfire, 0, 100e6, floorMin); // at the floor: ok

        route.setRate(r / 2); // a genuine $wif rally: buys stall, USDG waits
        _gap();
        uint256 halfMin = 10e6 * r / 2;
        vm.prank(keeper);
        vm.expectPartialRevert(FairCore.RatchetTripped.selector);
        core.burnBuyToken(FairCore.BurnSource.Bonfire, 0, 10e6, halfMin);
        // A1-12: the Safe follows the price through the timelock. A 50% drop is past MAX_RESET_BPS, so it takes two
        // queued resets: one to the bound, then the current price (N2: never no floor).
        vm.startPrank(owner);
        core.queue(FairCore.Op.ResetRatchet, r / 2 * 1e18, address(0));
        vm.warp(vm.getBlockTimestamp() + core.timelockDelay());
        vm.expectPartialRevert(FairCore.ResetOutOfBounds.selector);
        core.execute(FairCore.Op.ResetRatchet, r / 2 * 1e18, address(0));
        core.cancel(core.pendingReset()); // one pending reset at a time: clear the refused one first
        vm.stopPrank();
        (uint256 lo,) = core.resetBounds();
        reseed(lo);
        reseed(r / 2 * 1e18);
        assertEq(core.anchorRate(), r / 2 * 1e18);
        vm.prank(keeper);
        core.burnBuyToken(FairCore.BurnSource.Bonfire, 0, 10e6, halfMin);
    }

    /// Audit N2: a reset never leaves the next fill unprotected.
    function test_N2_resetRatchet_keepsAFloor() public {
        _fillBonfire();
        vm.startPrank(owner);
        core.queue(FairCore.Op.ResetRatchet, 0, address(0));
        vm.warp(vm.getBlockTimestamp() + core.timelockDelay());
        vm.expectRevert(FairCore.ZeroAmount.selector);
        core.execute(FairCore.Op.ResetRatchet, 0, address(0));
        core.cancel(core.pendingReset());
        vm.stopPrank();
        reseed(route.rate() * 1e18);
        vm.prank(keeper);
        vm.expectPartialRevert(FairCore.RatchetTripped.selector);
        core.burnBuyToken(FairCore.BurnSource.Bonfire, 0, 100e6, 1); // a 1-wei minOut is refused right after a reset
    }

    /// Audit N1: the floor stops decaying at 70% of the anchor (63% floor), however long the Safe takes.
    function test_N1_decayStopsAt70percent() public {
        _fillBonfire();
        uint256 full = 100e6 * route.rate();
        vm.prank(keeper);
        core.burnBuyToken(FairCore.BurnSource.Bonfire, 0, 100e6, full);
        uint256 a = core.anchorRate();
        vm.warp(vm.getBlockTimestamp() + 1000 hours);
        assertEq(core.decayedAnchor(), a * 7000 / 10_000);
        assertEq(core.ratchetFloorRate(), a * 7000 / 10_000 * 9500 / 10_000);
        uint256 floorMin = 100e6 * core.ratchetFloorRate() / 1e18;
        vm.prank(keeper);
        vm.expectPartialRevert(FairCore.RatchetTripped.selector);
        core.burnBuyToken(FairCore.BurnSource.Bonfire, 0, 100e6, floorMin - 1);
    }

    /// The pause log measures pauses inside any window.
    /// The second pause starts a full `MIN_PAUSE_GAP` after the first. Overlaps are the same shape as before
    /// (100s closed, then 100s of a pause that is still running).
    function test_pausedBetween() public {
        uint256 t = vm.getBlockTimestamp();
        uint256 gap = core.MIN_PAUSE_GAP();
        vm.startPrank(owner);
        core.pauseSales(true);
        vm.warp(t + 100);
        core.pauseSales(false);
        vm.warp(t + gap); // the earliest the next pause may start
        core.pauseSales(true); // still running
        vm.stopPrank();
        vm.warp(t + gap + 100);
        assertEq(core.pauseCount(), 2);
        assertEq(core.pausedBetween(0, t, t + gap + 100), 100 + 100);
        assertEq(core.pausedBetween(0, t + 50, t + gap + 50), 50 + 50);
        assertEq(core.pausedBetween(1, t, t + gap + 100), 100, "from index 1 only");
        // The second entry starts at the window end, so the scan stops and it contributes nothing.
        assertEq(core.pausedBetween(0, t, t + gap), 100, "break at the second pause start");
        // The first entry ended at the window start, so it is skipped.
        assertEq(core.pausedBetween(0, t + 100, t + gap + 100), 100, "skip a pause that ended at from");
    }

    // ---------------------------------------------------------------- audit H1: keeper rate limits

    /// The audit's attack: many keeper calls in one block. Only the first per ledger lands.
    function test_H1_sameBlockRepeat_reverts_perLedger() public {
        openFair();
        shot(ana, 1, 200_000e6); // big ledgers
        uint256 full = 250e6 * route.rate();
        vm.startPrank(keeper);
        core.burnBuyToken(FairCore.BurnSource.Bonfire, 0, 250e6, full);
        vm.expectPartialRevert(FairCore.TooSoon.selector);
        core.burnBuyToken(FairCore.BurnSource.Bonfire, 0, 250e6, full);
        // the other two ledgers have their own clocks
        uint256 floorMin = 250e6 * core.ratchetFloorRate() / 1e18;
        core.burnBuyToken(FairCore.BurnSource.Vault, 0, 250e6, floorMin);
        core.buyForVault(0, 250e6, floorMin);
        vm.expectPartialRevert(FairCore.TooSoon.selector);
        core.buyForVault(0, 250e6, floorMin);
        vm.stopPrank();
        vm.warp(vm.getBlockTimestamp() + 50 minutes - 1);
        vm.prank(keeper);
        vm.expectPartialRevert(FairCore.TooSoon.selector);
        core.burnBuyToken(FairCore.BurnSource.Bonfire, 0, 250e6, floorMin);
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.prank(keeper);
        core.burnBuyToken(FairCore.BurnSource.Bonfire, 0, 250e6, floorMin);
    }

    /// Bad fills can't walk the floor down: it only falls with time, about 1% per hour.
    function test_H1_floorDoesNotFollowFillsDown() public {
        openFair();
        shot(ana, 1, 200_000e6);
        uint256 full = 250e6 * route.rate();
        vm.prank(keeper);
        core.burnBuyToken(FairCore.BurnSource.Bonfire, 0, 250e6, full);
        uint256 anchor = core.anchorRate();
        uint256 r = route.rate();
        // A thief's route that returns 90.5% of fair value (just above the floor), once every 50 minutes
        route.setRate(r * 905 / 1000);
        for (uint256 i; i < 6; ++i) {
            _gap();
            uint256 floorMin = 250e6 * core.ratchetFloorRate() / 1e18;
            vm.prank(keeper);
            try core.burnBuyToken(FairCore.BurnSource.Bonfire, 0, 250e6, floorMin) {} catch {}
        }
        assertEq(core.anchorRate(), anchor, "worse fills never lower the anchor");
        // after 5 hours of decay the floor is ~95% of 90% of the anchor: still near fair value
        assertGe(core.ratchetFloorRate(), anchor * 85 / 100);
    }

    function test_H1_anchorRisesWithBetterFill_andDecaysWithTime() public {
        openFair();
        shot(ana, 1, 200_000e6);
        uint256 full = 100e6 * route.rate();
        vm.prank(keeper);
        core.burnBuyToken(FairCore.BurnSource.Bonfire, 0, 100e6, full);
        uint256 a0 = core.anchorRate();
        route.setRate(route.rate() * 2); // $wif got cheaper
        _gap();
        uint256 minOut = 100e6 * route.rate(); // read first: an external call would consume the prank
        uint256 quotePx = minOut * 1e18 / 100e6;
        uint256 base = core.raiseBase();
        uint256 cap = base * (10_000 + core.MAX_ANCHOR_RAISE_BPS()) / 10_000;
        uint256 expected = quotePx < cap ? quotePx : cap;
        vm.prank(keeper);
        core.burnBuyToken(FairCore.BurnSource.Bonfire, 0, 100e6, minOut);
        // The quote is 2x. The whole window, all ledgers, may only reach min(quote, 1.02 x the window base).
        assertEq(core.raiseBase(), base, "the window base does not move inside the 4 hours");
        assertEq(core.anchorRate(), expected, "min(quote, 1.02 x the window base)");
        assertLt(expected, a0 * 2, "a 2x quote does not land in one swap");
        uint256 raised = core.anchorRate();
        uint256 f0 = core.ratchetFloorRate();
        vm.warp(vm.getBlockTimestamp() + 10 hours);
        assertApproxEqRel(core.ratchetFloorRate(), f0 * 90 / 100, 1e15, "10 hours: -10%");
        vm.warp(vm.getBlockTimestamp() + 100 hours);
        assertEq(core.ratchetFloorRate(), raised * 7000 / 10_000 * 9500 / 10_000, "decay stops at 70% (N1)");
    }

    function test_H1_dailyCap_reverts() public {
        openFair();
        shot(ana, 1, 200_000e6);
        uint256 day = vm.getBlockTimestamp() / 1 days;
        // 24 calls 50 minutes apart = 20 hours: fits in one day if we start at 00:00
        uint256 start = (day + 1) * 1 days;
        for (uint256 i; i < 12; ++i) {
            vm.warp(start + i * 50 minutes);
            uint256 m = 250e6 * core.ratchetFloorRate() / 1e18;
            vm.prank(keeper);
            core.burnBuyToken(FairCore.BurnSource.Bonfire, 0, 250e6, m == 0 ? 1 : m);
        }
        assertEq(core.swappedOnDay(0, day + 1), 3_000e6);
        vm.warp(start + 12 * 50 minutes);
        vm.prank(keeper);
        vm.expectRevert(FairCore.DailyCap.selector);
        core.burnBuyToken(FairCore.BurnSource.Bonfire, 0, 1e6, 1);
    }

    // ---------------------------------------------------------------- v3.6: no buyback before the seed

    function _unseededCore() internal returns (FairCore c, StubBooth b) {
        c = new FairCore(usdg, IGameConfig(address(config)), pass, owner, 48 hours);
        b = new StubBooth(IFairCore(address(c)));
        vm.startPrank(owner);
        c.setupSet(FairCore.Op.AddBooth, 0, address(b));
        c.setupSet(FairCore.Op.SetKeeper, 0, keeper);
        c.setupSet(FairCore.Op.SetVault, 0, vaultAddr);
        c.setupSet(FairCore.Op.SetRoute, 0, address(route));
        c.finishSetup();
        c.setFair(0, T0 + 1 hours, T0 + 6 days);
        vm.stopPrank();
        openFair();
        vm.startPrank(ana);
        usdg.approve(address(c), type(uint256).max);
        b.shot(ana, 1, 10_000e6); // Bonfire 700, each Vault quarter 450
        vm.stopPrank();
    }

    /// Every buyback path reverts NotSeeded until the Safe seeds the anchor; after the seed they all work.
    function test_v36_everySwapPath_needsTheSeed() public {
        (FairCore c,) = _unseededCore();
        assertEq(c.anchorRate(), 0);
        uint256 full = 100e6 * route.rate();
        vm.startPrank(keeper);
        vm.expectRevert(FairCore.NotSeeded.selector);
        c.burnBuyToken(FairCore.BurnSource.Bonfire, 0, 100e6, full);
        vm.expectRevert(FairCore.NotSeeded.selector);
        c.burnBuyToken(FairCore.BurnSource.Vault, 0, 100e6, full);
        vm.expectRevert(FairCore.NotSeeded.selector);
        c.buyForVault(0, 100e6, full);
        vm.stopPrank();

        reseedCore(c, route.rate() * 1e18); // no live anchor yet: unbounded, but timelocked (A1-12)
        vm.startPrank(keeper);
        c.burnBuyToken(FairCore.BurnSource.Bonfire, 0, 100e6, full);
        c.burnBuyToken(FairCore.BurnSource.Vault, 0, 100e6, full);
        c.buyForVault(0, 100e6, full);
        vm.stopPrank();
    }

    /// Fuzz: before the seed, no amount, minimum, source or route gets a swap through.
    function testFuzz_v36_noSwapBeforeSeed(uint256 amt, uint256 minOut, uint8 src, uint8 r) public {
        (FairCore c,) = _unseededCore();
        amt = bound(amt, 1, 250e6);
        minOut = bound(minOut, 1, type(uint128).max);
        vm.prank(keeper);
        if (src % 3 == 2) {
            vm.expectRevert(FairCore.NotSeeded.selector);
            c.buyForVault(r % 2, amt, minOut);
        } else {
            vm.expectRevert(FairCore.NotSeeded.selector);
            c.burnBuyToken(src % 3 == 0 ? FairCore.BurnSource.Bonfire : FairCore.BurnSource.Vault, r % 2, amt, minOut);
        }
    }

    /// A seed so small its floor rounds to zero counts as not seeded too.
    function test_v36_dustSeed_isNotASeed() public {
        (FairCore c,) = _unseededCore();
        reseedCore(c, 1); // 1 * 9500 / 10000 = 0
        uint256 full = 100e6 * route.rate();
        vm.prank(keeper);
        vm.expectRevert(FairCore.NotSeeded.selector);
        c.burnBuyToken(FairCore.BurnSource.Bonfire, 0, 100e6, full);
    }

    // ---------------------------------------------------------------- audit M1, M2

    /// Scheduling a second future Fair while one is live is refused, so the live Fair can't be switched off.
    function test_M1_onlyOneFutureFair() public {
        vm.startPrank(owner);
        core.setFair(1, T0 + 6 days, T0 + 36 days); // one ahead: ok
        vm.expectRevert(FairCore.BadFair.selector);
        core.setFair(2, T0 + 36 days, T0 + 66 days); // two ahead: refused
        vm.stopPrank();
        openFair();
        shot(ana, 1, 1e6); // Fair 0 still live
        vm.warp(T0 + 6 days); // Fair 0 over, Fair 1 live
        vm.prank(owner);
        core.setFair(2, T0 + 36 days, T0 + 66 days); // now allowed
        (bool active, uint256 id) = core.activeFair();
        assertTrue(active);
        assertEq(id, 1);
    }

    /// K16-A05: the Alms Safe moved from setup-only to the timelock; the Vault and AlmsVote stay setup-only.
    function test_M2_vaultAlmsVote_areSetupOnly_almsSafeIsTimelocked() public {
        vm.startPrank(owner);
        core.queue(FairCore.Op.SetAlmsSafe, 0, ana);
        vm.expectPartialRevert(FairCore.TooEarly.selector);
        core.execute(FairCore.Op.SetAlmsSafe, 0, ana);
        vm.expectRevert(FairCore.SetupOnly.selector);
        core.queue(FairCore.Op.SetVault, 0, ana);
        vm.expectRevert(FairCore.SetupOnly.selector);
        core.queue(FairCore.Op.SetAlmsVote, 0, ana);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- pause clock bookkeeping

    function test_pausedSeconds_accumulate() public {
        vm.startPrank(owner);
        core.pauseSales(true);
        vm.warp(vm.getBlockTimestamp() + 100);
        assertEq(core.pausedSeconds(), 100);
        core.pauseSales(true); // pausing again doesn't reset
        vm.warp(vm.getBlockTimestamp() + 50);
        core.pauseSales(false);
        vm.warp(vm.getBlockTimestamp() + 500);
        assertEq(core.pausedSeconds(), 150);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- Alms, Toll, Vault USDG

    function test_alms_onlyAlmsVote_toSafe_tranches() public {
        openFair();
        shot(ana, 1, 100e6);
        vm.expectRevert(FairCore.NotAlmsVote.selector);
        core.releaseAlms(0);
        vm.prank(almsVoteAddr);
        assertEq(core.releaseAlms(0), 8e6);
        shot(bob, 1, 50e6); // later shots keep feeding Fair 0
        vm.prank(almsVoteAddr);
        assertEq(core.releaseAlms(0), 4e6);
        assertEq(usdg.balanceOf(almsSafe), 12e6);
    }

    function test_toll_ownerToFixedRecipient() public {
        openFair();
        shot(ana, 1, 100e6);
        vm.prank(ana);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, ana));
        core.withdrawToll(1);
        vm.prank(owner);
        vm.expectRevert(FairCore.OverLedger.selector);
        core.withdrawToll(7e6 + 1);
        vm.prank(owner);
        core.withdrawToll(7e6);
        assertEq(usdg.balanceOf(toll), 7e6);
    }

    function test_vaultUsdg_onlyVault() public {
        openFair();
        shot(ana, 1, 100e6);
        vm.prank(owner);
        vm.expectRevert(FairCore.NotVault.selector);
        core.releaseVaultUsdg(owner);
        vm.prank(vaultAddr);
        assertEq(core.releaseVaultUsdg(vaultAddr), 9e6);
    }

    function test_sweepExcess_neverTouchesOwed() public {
        openFair();
        shot(ana, 1, 100e6);
        usdg.mint(address(core), 3e6); // sent by mistake
        vm.expectEmit(true, true, false, true, address(core));
        emit FairCore.ExcessSwept(address(usdg), owner, 3e6); // v3.6.1: visible to the Safe's post-deploy scan
        vm.prank(owner);
        core.sweepExcess(usdg, owner);
        assertEq(usdg.balanceOf(owner), 3e6);
        assertEq(usdg.balanceOf(address(core)), core.accounted());
    }

    // ---------------------------------------------------------------- setup, timelock, fairs

    function test_setupClosed_thenTimelock() public {
        vm.startPrank(owner);
        vm.expectRevert(FairCore.SetupClosed.selector);
        core.setupSet(FairCore.Op.SetKeeper, 0, ana);
        core.queue(FairCore.Op.SetKeeper, 0, ana);
        vm.expectPartialRevert(FairCore.TooEarly.selector);
        core.execute(FairCore.Op.SetKeeper, 0, ana);
        vm.warp(block.timestamp + 48 hours);
        core.execute(FairCore.Op.SetKeeper, 0, ana);
        vm.stopPrank();
        assertEq(core.keeper(), ana);
        vm.prank(owner);
        vm.expectRevert(FairCore.NotQueued.selector);
        core.execute(FairCore.Op.SetKeeper, 0, ana); // can't replay
    }

    function test_cancelQueuedOp() public {
        vm.startPrank(owner);
        bytes32 id = core.queue(FairCore.Op.SetTollRecipient, 0, ana);
        core.cancel(id);
        vm.warp(block.timestamp + 48 hours);
        vm.expectRevert(FairCore.NotQueued.selector);
        core.execute(FairCore.Op.SetTollRecipient, 0, ana);
        vm.stopPrank();
    }

    function test_mainnetEnforces48hTimelock() public {
        vm.chainId(4663);
        vm.expectPartialRevert(FairCore.TooEarly.selector);
        new FairCore(usdg, IGameConfig(address(config)), pass, owner, 0);
    }

    function test_fairs_sequential_noOverlap_frozenOnceStarted() public {
        vm.startPrank(owner);
        vm.expectRevert(FairCore.BadFair.selector);
        core.setFair(2, T0 + 10 days, T0 + 11 days); // must be id 1 next
        vm.expectRevert(FairCore.BadFair.selector);
        core.setFair(1, T0 + 5 days, T0 + 9 days); // overlaps Fair 0
        core.setFair(1, T0 + 6 days, T0 + 36 days);
        core.setFair(0, T0 + 2 hours, T0 + 6 days); // editable before it starts
        vm.warp(T0 + 2 hours);
        vm.expectRevert(FairCore.FairStarted.selector);
        core.setFair(0, T0 + 3 hours, T0 + 6 days);
        vm.stopPrank();
        (bool active, uint256 id) = core.activeFair();
        assertTrue(active);
        assertEq(id, 0);
        vm.warp(T0 + 7 days);
        (active, id) = core.activeFair();
        assertTrue(active);
        assertEq(id, 1);
    }

    function test_fairLength_atMost35Days() public {
        vm.startPrank(owner);
        uint64 start = T0 + 7 days; // after Fair 0
        vm.expectRevert(FairCore.BadFair.selector);
        core.setFair(1, start, start + 36 days);
        vm.expectRevert(FairCore.BadFair.selector);
        core.setFair(1, start, start + 35 days + 1);
        vm.expectRevert(FairCore.BadFair.selector);
        core.setFair(1, start, start * 1000); // an end in milliseconds
        core.setFair(1, start, start + 35 days);
        vm.stopPrank();
        (uint64 s, uint64 e) = core.fairs(1);
        assertEq(e - s, 35 days);
    }

    function test_renounceDisabled() public {
        vm.prank(owner);
        vm.expectRevert(FairCore.RenounceDisabled.selector);
        core.renounceOwnership();
    }
}

/// FairCore across GameConfig updates: the buy token, the epoch-bound anchor and the split.
contract FairCoreConfigTest is Base {
    function setUp() public override {
        super.setUp();
        openFair();
        shot(ana, 1, 100_000e6); // Bonfire 7,000; Vault buy and burn 4,500 each
    }

    function _toB() internal {
        applyTokens(address(tokenB), 5_000e18, address(tokenB));
    }

    function _reseedB() internal {
        reseed(routeB.rate() * 1e18); // a new epoch: unbounded, but timelocked (A1-12)
    }

    function test_buyToken_followsConfig() public {
        assertEq(core.buyToken(), address(wif));
        _toB();
        assertEq(core.buyToken(), address(tokenB));
    }

    /// A new epoch closes every buyback path until the Safe seeds an anchor for it.
    function test_newEpoch_needsReseed_thenWorks() public {
        _toB();
        assertTrue(core.anchorStale());
        assertEq(core.decayedAnchor(), 0);
        assertEq(core.ratchetFloorRate(), 0);
        assertGt(core.anchorRate(), 0, "the old anchor is still on record, but it no longer counts");
        uint256 full = 250e6 * routeB.rate();
        vm.startPrank(keeper);
        vm.expectRevert(FairCore.NotSeeded.selector);
        core.burnBuyToken(FairCore.BurnSource.Bonfire, 1, 250e6, full);
        vm.expectRevert(FairCore.NotSeeded.selector);
        core.burnBuyToken(FairCore.BurnSource.Vault, 1, 250e6, full);
        vm.expectRevert(FairCore.NotSeeded.selector);
        core.buyForVault(1, 250e6, full);
        vm.stopPrank();

        _reseedB();
        assertFalse(core.anchorStale());
        assertEq(core.anchorEpoch(), 1);
        vm.prank(keeper);
        vm.expectEmit(address(core));
        emit FairCore.Burned(address(tokenB), uint8(FairCore.BurnSource.Bonfire), 1, 250e6, full, full);
        core.burnBuyToken(FairCore.BurnSource.Bonfire, 1, 250e6, full);
        assertEq(tokenB.balanceOf(core.DEAD()), full);
        assertEq(wif.balanceOf(core.DEAD()), 0);
        assertSolvent();
    }

    /// Changing only the pass amount still starts a new epoch: buybacks stay closed until a fresh seed (fail closed).
    function test_passLockOnlyUpdate_alsoNeedsReseed() public {
        applyTokens(address(wif), 2_500e18, address(wif));
        uint256 full = 250e6 * route.rate();
        vm.prank(keeper);
        vm.expectRevert(FairCore.NotSeeded.selector);
        core.burnBuyToken(FairCore.BurnSource.Bonfire, 0, 250e6, full);
    }

    /// An anchor set before the update can't be carried into the new epoch, even within the same block.
    function test_resetBeforeExecute_doesNotCount() public {
        uint256 seed = core.anchorRate(); // still epoch 0, so the reset must sit inside MAX_RESET_BPS (A1-12)
        vm.startPrank(owner);
        config.queueTokens(Tokens(address(tokenB), 5_000e18, address(tokenB)));
        core.queue(FairCore.Op.ResetRatchet, seed, address(0));
        vm.warp(config.tokensEta());
        core.execute(FairCore.Op.ResetRatchet, seed, address(0)); // epoch 0
        config.executeTokens(); // epoch 1
        vm.stopPrank();
        assertTrue(core.anchorStale());
        uint256 full = 250e6 * routeB.rate();
        vm.prank(keeper);
        vm.expectRevert(FairCore.NotSeeded.selector);
        core.burnBuyToken(FairCore.BurnSource.Bonfire, 1, 250e6, full);
    }

    function test_routeForAnotherToken_reverts() public {
        _toB();
        _reseedB();
        uint256 full = 250e6 * routeB.rate();
        vm.startPrank(keeper);
        vm.expectRevert(FairCore.RouteTokenMismatch.selector);
        core.burnBuyToken(FairCore.BurnSource.Bonfire, 0, 250e6, full);
        vm.expectRevert(FairCore.RouteTokenMismatch.selector);
        core.buyForVault(0, 250e6, full);
        vm.stopPrank();
    }

    /// The fill is measured in the buy token: a route that pays something else lands nothing and reverts.
    function test_routePaysWrongToken_shortFill() public {
        _toB();
        _reseedB();
        routeB.setPayIn(wif);
        uint256 full = 250e6 * routeB.rate();
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(FairCore.ShortFill.selector, 0, full));
        core.burnBuyToken(FairCore.BurnSource.Bonfire, 1, 250e6, full);
        assertEq(core.bonfirePending(), 7_000e6, "ledger untouched");
    }

    function test_vaultBuy_eventsCarryToken() public {
        uint256 fullA = 100e6 * route.rate();
        vm.prank(keeper);
        vm.expectEmit(address(core));
        emit FairCore.BoughtForVault(address(wif), 0, 100e6, fullA, fullA);
        core.buyForVault(0, 100e6, fullA);

        _toB();
        _reseedB();
        uint256 fullB = 100e6 * routeB.rate();
        vm.prank(keeper);
        vm.expectEmit(address(core));
        emit FairCore.BoughtForVault(address(tokenB), 1, 100e6, fullB, fullB);
        core.buyForVault(1, 100e6, fullB);
        assertEq(wif.balanceOf(vaultAddr), fullA);
        assertEq(tokenB.balanceOf(vaultAddr), fullB);
    }

    /// A split update executes between Fairs and applies to shots after it; nothing already in a ledger moves.
    function test_splitUpdate_onlyNewShots() public {
        vm.prank(owner);
        core.setFair(1, T0 + 8 days, T0 + 20 days);
        uint256[9] memory b = _snap(1);
        vm.prank(owner);
        config.queueSplit(Split(7000, 3000, 2000, 2000, 2000, 2000, 2000));
        vm.warp(config.splitEta()); // between Fair 0 and Fair 1
        vm.prank(owner);
        config.executeSplit();
        uint256[9] memory m = _snap(1);
        for (uint256 i; i < 9; ++i) {
            assertEq(m[i], b[i], "executing a split moves nothing");
        }
        vm.warp(T0 + 8 days); // Fair 1 opens with the new split

        shot(bob, 2, 1e6);
        assertEq(core.pot(address(booth), 2), 700_000, "Purse 70%");
        assertEq(core.almsByFair(1), 90_000);
        assertEq(core.bonfirePending() - b[2], 60_000);
        assertEq(core.tollPending() - b[3], 60_000);
        assertEq(core.vaultBuyPending() - b[4], 18_000);
        assertEq(core.vaultLiqUsdg() - b[5], 18_000);
        assertEq(core.vaultBurnPending() - b[6], 18_000);
        assertEq(core.vaultFairsBurnUsdg() - b[7], 36_000, "Vault remainder");
        assertEq(core.accounted(), b[8] + 1e6);
        assertEq(
            core.pot(address(booth), 1) + core.pot(address(booth), 2) + core.almsByFair(1) + ledgers(),
            core.accounted(),
            "every unit placed"
        );
        assertSolvent();
    }

    /// Fuzz: any valid split places every unit of every shot, and only new shots use it.
    function testFuzz_anyValidSplit_partsSumToGross(uint16[6] memory r, uint256 gross) public {
        Split memory s = _validSplit(r);
        gross = bound(gross, 1, 900_000e6); // bob holds 1M USDG
        vm.prank(owner);
        core.setFair(1, T0 + 8 days, T0 + 20 days);
        vm.startPrank(owner);
        config.queueSplit(s);
        vm.warp(config.splitEta()); // between Fairs
        config.executeSplit();
        vm.stopPrank();
        vm.warp(T0 + 8 days);
        uint256 before = core.accounted();
        shot(bob, 2, gross);
        assertEq(core.accounted(), before + gross);
        uint256 sum = core.pot(address(booth), 1) + core.pot(address(booth), 2) + core.almsByFair(1) + ledgers();
        assertEq(sum, core.accounted(), "parts == gross");
        assertSolvent();
    }

    /// Fuzz: an update queued at any point of a Fair and executed at any point after it never moves owed money.
    function testFuzz_updateNeverMovesOwedMoney(uint32 queueAt, uint32 execAfter, bool alsoSplit, bool alsoBuy) public {
        // round 1 settled with a partial award (claimable + rollover), round 2 still open
        address[] memory w = new address[](1);
        uint256[] memory a = new uint256[](1);
        (w[0], a[0]) = (ana, core.pot(address(booth), 1) / 2);
        booth.settle(1, w, a);
        shot(bob, 2, 3_333e6);
        if (alsoBuy) {
            uint256 full = 100e6 * route.rate();
            vm.prank(keeper);
            core.buyForVault(0, 100e6, full);
        }
        uint256[9] memory b = _snap(0);
        uint256 cl = core.claimable(ana);
        uint256 ro = core.rollover(address(booth));
        uint256 p2 = core.pot(address(booth), 2);
        uint256 bal = usdg.balanceOf(address(core));

        vm.warp(bound(queueAt, vm.getBlockTimestamp(), T0 + 6 days - 1));
        vm.startPrank(owner);
        config.queueTokens(Tokens(address(tokenB), 5_000e18, address(tokenB)));
        if (alsoSplit) config.queueSplit(Split(7000, 3000, 2000, 2000, 2000, 2000, 2000));
        vm.warp(config.tokensEta() + bound(execAfter, 0, 60 days));
        config.executeTokens();
        if (alsoSplit) config.executeSplit();
        vm.stopPrank();

        uint256[9] memory m = _snap(0);
        for (uint256 i; i < 9; ++i) {
            assertEq(m[i], b[i]);
        }
        assertEq(core.claimable(ana), cl);
        assertEq(core.rollover(address(booth)), ro);
        assertEq(core.pot(address(booth), 2), p2);
        assertEq(usdg.balanceOf(address(core)), bal);
        assertSolvent();
    }

    function _snap(uint256 fairId) internal view returns (uint256[9] memory v) {
        v = [
            core.pot(address(booth), 1),
            core.almsByFair(fairId),
            core.bonfirePending(),
            core.tollPending(),
            core.vaultBuyPending(),
            core.vaultLiqUsdg(),
            core.vaultBurnPending(),
            core.vaultFairsBurnUsdg(),
            core.accounted()
        ];
        if (fairId != 0) v[1] = core.almsByFair(0); // Fair 0's Alms must not move either
    }

    /// Build a split that GameConfig accepts from six random numbers.
    function _validSplit(uint16[6] memory r) internal pure returns (Split memory s) {
        s.purseBps = uint16(5000 + r[0] % 3001);
        s.almsBps = uint16(1000 + r[1] % 4001);
        uint256 left = 10_000 - s.almsBps; // bonfire + toll + Vault share
        uint256 bMax = left < 5000 ? left : 5000;
        s.bonfireBps = uint16(r[2] % (bMax + 1));
        left -= s.bonfireBps;
        uint256 tMin = left > 5000 ? left - 5000 : 0; // the Vault share (remainder) is capped at 5000
        uint256 tMax = left < 5000 ? left : 5000;
        s.tollBps = uint16(tMin + r[3] % (tMax - tMin + 1));
        s.vBuyBps = uint16(r[4] % 5001);
        uint256 vl = 10_000 - s.vBuyBps;
        uint256 lMax = vl < 5000 ? vl : 5000;
        s.vLiqBps = uint16(r[5] % (lMax + 1));
        vl -= s.vLiqBps;
        uint256 uMin = vl > 5000 ? vl - 5000 : 0;
        uint256 uMax = vl < 5000 ? vl : 5000;
        s.vBurnBps = uint16(uMin + (uint256(r[0]) * 7 + r[5]) % (uMax - uMin + 1));
    }
}
