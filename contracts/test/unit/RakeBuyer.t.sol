// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Base} from "../Base.t.sol";
import {RakeBuyer} from "../../src/RakeBuyer.sol";
import {IGameConfig} from "../../src/interfaces/IFair.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract RakeBuyerTest is Base {
    RakeBuyer rb;
    address vaultTo = makeAddr("locksleyVault");
    uint256 constant RATE = 781_250e12; // MockRoute default: wif wei per USDG unit

    function setUp() public override {
        super.setUp();
        rb = new RakeBuyer(usdg, IGameConfig(address(config)), vaultTo, owner, 48 hours, address(core));
        vm.startPrank(owner);
        rb.setupSet(RakeBuyer.Op.SetKeeper, 0, keeper);
        rb.setupSet(RakeBuyer.Op.SetRoute, 0, address(route));
        rb.setupSet(RakeBuyer.Op.SetRoute, 1, address(routeB));
        rb.resetRatchet(RATE * 1e18);
        rb.finishSetup();
        vm.stopPrank();
    }

    function _rake(uint256 amt) internal {
        usdg.mint(address(rb), amt);
    }

    function _buy(uint256 usdgIn) internal returns (uint256) {
        vm.prank(keeper);
        return rb.buy(0, usdgIn, usdgIn * RATE);
    }

    // ---------------------------------------------------------------- split and buy

    function test_sync_splitsHalfHalf_oddUnitToLeg() public {
        _rake(300_001);
        rb.sync();
        assertEq(rb.buyPending(), 150_000);
        assertEq(rb.legPending(), 150_001);
        rb.sync(); // nothing new
        assertEq(rb.buyPending() + rb.legPending(), 300_001);
    }

    function test_buy_happyPath_andForward() public {
        _rake(100e6);
        uint256 out = _buy(50e6);
        assertEq(out, 50e6 * RATE);
        assertEq(rb.bought(address(wif)), out);
        assertEq(rb.buyPending(), 0);
        assertEq(rb.legPending(), 50e6);
        assertEq(rb.spentOf(address(wif)), 50e6);
        rb.forward(); // permissionless
        assertEq(wif.balanceOf(vaultTo), out, "the bought leg");
        assertEq(usdg.balanceOf(vaultTo), 50e6, "the matching USDG leg");
        assertEq(rb.legPending(), 0);
        assertEq(rb.bought(address(wif)), 0);
        vm.expectRevert(RakeBuyer.NothingToForward.selector);
        rb.forward();
    }

    function test_buy_guards() public {
        _rake(200e6);
        uint256 full = 10e6 * RATE;
        vm.startPrank(keeper);
        vm.expectRevert(RakeBuyer.ZeroAmount.selector);
        rb.buy(0, 0, 1);
        vm.expectRevert(RakeBuyer.OverCap.selector);
        rb.buy(0, 50e6 + 1, 1);
        vm.expectRevert(RakeBuyer.ZeroMinOut.selector);
        rb.buy(0, 10e6, 0);
        vm.expectRevert(abi.encodeWithSelector(RakeBuyer.RatchetTripped.selector, 1, 10e6 * RATE * 95 / 100));
        rb.buy(0, 10e6, 1);
        vm.expectRevert(RakeBuyer.NoRoute.selector);
        rb.buy(5, 10e6, full);
        vm.expectRevert(RakeBuyer.RouteTokenMismatch.selector);
        rb.buy(1, 10e6, full); // route 1 buys token B, not the buy token
        vm.stopPrank();
        vm.prank(ana);
        vm.expectRevert(RakeBuyer.NotKeeper.selector);
        rb.buy(0, 10e6, full);
        // ledger: only half of the rake can be spent
        _buy(50e6);
        vm.warp(vm.getBlockTimestamp() + 50 minutes);
        _buy(50e6);
        vm.warp(vm.getBlockTimestamp() + 50 minutes);
        vm.prank(keeper);
        vm.expectRevert(RakeBuyer.OverLedger.selector);
        rb.buy(0, 1e6, 1e6 * RATE);
    }

    function test_buy_50minuteGap() public {
        _rake(200e6);
        _buy(10e6);
        uint256 next = vm.getBlockTimestamp() + 50 minutes;
        vm.warp(next - 1);
        uint256 full = 10e6 * RATE;
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(RakeBuyer.TooSoon.selector, next));
        rb.buy(0, 10e6, full);
        vm.warp(next);
        _buy(10e6);
    }

    function test_buy_shortFill() public {
        _rake(100e6);
        route.setShortchange(true);
        uint256 full = 10e6 * RATE;
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(RakeBuyer.ShortFill.selector, full / 2, full));
        rb.buy(0, 10e6, full);
    }

    function test_buy_routePaysOtherToken_shortFill() public {
        _rake(100e6);
        route.setPayIn(tokenB);
        uint256 full = 10e6 * RATE;
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(RakeBuyer.ShortFill.selector, 0, full));
        rb.buy(0, 10e6, full);
    }

    // ---------------------------------------------------------------- ratchet

    function test_ratchet_unseeded_and_staleEpoch() public {
        RakeBuyer fresh = new RakeBuyer(usdg, IGameConfig(address(config)), vaultTo, owner, 0, address(core));
        vm.startPrank(owner);
        fresh.setupSet(RakeBuyer.Op.SetKeeper, 0, keeper);
        fresh.setupSet(RakeBuyer.Op.SetRoute, 0, address(route));
        vm.stopPrank();
        usdg.mint(address(fresh), 100e6);
        uint256 full = 10e6 * RATE;
        vm.prank(keeper);
        vm.expectRevert(RakeBuyer.NotSeeded.selector);
        fresh.buy(0, 10e6, full);
        // a GameConfig token update makes the old anchor stale
        _rake(100e6);
        applyTokens(address(wif), 2_500e18, address(wif));
        assertEq(rb.ratchetFloorRate(), 0);
        vm.prank(keeper);
        vm.expectRevert(RakeBuyer.NotSeeded.selector);
        rb.buy(0, 10e6, full);
        reseedRb(rb, RATE * 1e18);
        _buy(10e6);
    }

    function test_ratchet_decaysAndRises() public {
        _rake(200e6);
        uint256 a0 = rb.anchorRate();
        vm.warp(vm.getBlockTimestamp() + 10 hours);
        assertEq(rb.decayedAnchor(), a0 * 90 / 100, "1% per hour");
        vm.warp(vm.getBlockTimestamp() + 100 hours);
        assertEq(rb.decayedAnchor(), a0 * 70 / 100, "at most 30%");
        // a fill at the route's rate is above the decayed anchor: the window rolls, and the anchor
        // rises by at most 2% above that decayed base
        uint256 cur = rb.decayedAnchor();
        _buy(10e6);
        uint256 cap = cur * (rb.BPS() + rb.MAX_ANCHOR_RAISE_BPS()) / rb.BPS();
        assertEq(rb.raiseBase(), cur, "the new window starts at the decayed anchor");
        assertEq(rb.anchorRate(), cap, "a quote above the cap stops at +2%");
        // a worse fill doesn't pull it down
        vm.warp(vm.getBlockTimestamp() + 50 minutes);
        uint256 low = rb.decayedAnchor() * 96 / 100;
        uint256 m = 10e6 * low / 1e18;
        route.setRate((m + 10e6 - 1) / 10e6);
        vm.prank(keeper);
        rb.buy(0, 10e6, m);
        assertEq(rb.anchorRate(), cap, "worse fills never lower the anchor");
    }

    function test_resetRatchet_rules() public {
        vm.prank(owner);
        vm.expectRevert(RakeBuyer.SetupClosed.selector); // A1-12: after setup only through the timelock
        rb.resetRatchet(RATE * 1e18);
        vm.startPrank(owner);
        rb.queue(RakeBuyer.Op.ResetRatchet, 0, address(0));
        vm.warp(vm.getBlockTimestamp() + rb.timelockDelay());
        vm.expectRevert(RakeBuyer.ZeroAmount.selector);
        rb.execute(RakeBuyer.Op.ResetRatchet, 0, address(0));
        vm.stopPrank();
        vm.prank(ana);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, ana));
        rb.resetRatchet(1);
        vm.prank(ana);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, ana));
        rb.queue(RakeBuyer.Op.ResetRatchet, 1, address(0));
    }

    // ---------------------------------------------------------------- forward across epochs

    function test_forwardToken_earlierEpochToken() public {
        _rake(100e6);
        uint256 out = _buy(20e6);
        applyTokens(address(tokenB), 5_000e18, address(tokenB));
        // forward() now looks at token B, which has nothing yet
        vm.expectRevert(RakeBuyer.NothingToForward.selector);
        rb.forward();
        rb.forwardToken(address(wif));
        assertEq(wif.balanceOf(vaultTo), out);
        assertEq(usdg.balanceOf(vaultTo), 20e6);
        // the new buy token, through its own route
        reseedRb(rb, 100e12 * 1e18);
        vm.warp(vm.getBlockTimestamp() + 50 minutes);
        vm.prank(keeper);
        uint256 outB = rb.buy(1, 10e6, 10e6 * 100e12);
        rb.forward();
        assertEq(tokenB.balanceOf(vaultTo), outB);
        assertEq(usdg.balanceOf(vaultTo), 30e6);
    }

    // ---------------------------------------------------------------- owner

    function test_ops_setup_then48h() public {
        vm.startPrank(owner);
        vm.expectRevert(RakeBuyer.SetupClosed.selector);
        rb.setupSet(RakeBuyer.Op.SetKeeper, 0, ana);
        vm.expectRevert(RakeBuyer.SetupClosed.selector);
        rb.finishSetup();
        bytes32 id = rb.queue(RakeBuyer.Op.SetRoute, 2, address(route));
        uint256 eta = rb.queuedAt(id);
        vm.warp(eta - 1);
        vm.expectRevert(abi.encodeWithSelector(RakeBuyer.TooEarly.selector, eta));
        rb.execute(RakeBuyer.Op.SetRoute, 2, address(route));
        vm.warp(eta);
        rb.execute(RakeBuyer.Op.SetRoute, 2, address(route));
        assertEq(address(rb.routes(2)), address(route));
        id = rb.queue(RakeBuyer.Op.SetRoute, 3, address(0));
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        vm.expectRevert(RakeBuyer.ZeroAddress.selector);
        rb.execute(RakeBuyer.Op.SetRoute, 3, address(0));
        rb.cancel(id);
        vm.expectRevert(RakeBuyer.NotQueued.selector);
        rb.cancel(id);
        vm.expectRevert(RakeBuyer.RenounceDisabled.selector);
        rb.renounceOwnership();
        rb.revokeKeeper();
        vm.stopPrank();
        assertEq(rb.keeper(), address(0));
        RakeBuyer fresh = new RakeBuyer(usdg, IGameConfig(address(config)), vaultTo, owner, 48 hours, address(core));
        vm.prank(owner);
        vm.expectRevert(RakeBuyer.SetupOpen.selector);
        fresh.queue(RakeBuyer.Op.SetKeeper, 0, ana);
    }

    function test_constructor_checks() public {
        vm.expectRevert(RakeBuyer.ZeroAddress.selector);
        new RakeBuyer(usdg, IGameConfig(address(config)), address(0), owner, 0, address(core));
        vm.expectRevert(RakeBuyer.ZeroAddress.selector);
        new RakeBuyer(usdg, IGameConfig(address(config)), vaultTo, owner, 0, address(0));
        vm.expectRevert(RakeBuyer.BadOpValue.selector);
        new RakeBuyer(usdg, IGameConfig(address(config)), address(core), owner, 0, address(core));
        vm.chainId(4663);
        vm.expectRevert(abi.encodeWithSelector(RakeBuyer.TooEarly.selector, 48 hours));
        new RakeBuyer(usdg, IGameConfig(address(config)), vaultTo, owner, 1 hours, address(core));
    }

    function test_queueForwardTo_fairCore_revertsBeforeStore() public {
        bytes32 id = rb.opId(RakeBuyer.Op.SetForwardTo, 0, address(core));
        vm.prank(owner);
        vm.expectRevert(RakeBuyer.BadOpValue.selector);
        rb.queue(RakeBuyer.Op.SetForwardTo, 0, address(core));
        assertEq(rb.queuedAt(id), 0);
        assertEq(rb.forwardTo(), address(0));
    }

    function test_sweepExcess_onlyAboveLedgers() public {
        _rake(100e6);
        _buy(10e6);
        wif.mint(address(rb), 5e18); // stray tokens
        address to = makeAddr("to");
        vm.startPrank(owner);
        rb.sweepExcess(address(wif), to);
        rb.sweepExcess(address(usdg), to); // every USDG that arrives is rake: nothing to sweep
        vm.stopPrank();
        assertEq(wif.balanceOf(to), 5e18);
        assertEq(usdg.balanceOf(to), 0);
        assertEq(wif.balanceOf(address(rb)), rb.bought(address(wif)));
        assertEq(usdg.balanceOf(address(rb)), rb.buyPending() + rb.legPending());
    }

    // ---------------------------------------------------------------- fuzz

    function testFuzz_buy_forward_conservation(uint256 rake, uint256 usdgIn) public {
        rake = bound(rake, 2, 10_000e6);
        _rake(rake);
        rb.sync();
        uint256 maxIn = rb.buyPending() < 50e6 ? rb.buyPending() : 50e6;
        usdgIn = bound(usdgIn, 1, maxIn);
        uint256 out = _buy(usdgIn);
        assertEq(out, usdgIn * RATE);
        assertEq(usdg.balanceOf(address(rb)), rb.buyPending() + rb.legPending());
        assertGe(rb.legPending(), rb.spentOf(address(wif)), "the leg always covers what was spent");
        rb.forward();
        assertEq(usdg.balanceOf(vaultTo), usdgIn);
        assertEq(wif.balanceOf(vaultTo), out);
        assertEq(usdg.balanceOf(address(rb)) + usdgIn + usdgIn, rake, "everything accounted: leg + spent + left");
    }

    function testFuzz_buy_floorAlwaysEnforced(uint256 minOut, uint32 hoursLater) public {
        _rake(100e6);
        vm.warp(vm.getBlockTimestamp() + bound(hoursLater, 0, 60) * 1 hours);
        uint256 floor = 10e6 * rb.ratchetFloorRate() / 1e18;
        minOut = bound(minOut, 1, 10e6 * RATE);
        vm.prank(keeper);
        if (minOut < floor) {
            vm.expectRevert(abi.encodeWithSelector(RakeBuyer.RatchetTripped.selector, minOut, floor));
            rb.buy(0, 10e6, minOut);
        } else {
            rb.buy(0, 10e6, minOut);
        }
    }
}
