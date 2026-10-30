// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Base} from "../Base.t.sol";
import {IGameConfig} from "../../src/interfaces/IFair.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FairCore} from "../../src/FairCore.sol";
import {FairPass} from "../../src/FairPass.sol";
import {SheriffsSeat} from "../../src/SheriffsSeat.sol";
import {IFairCore} from "../../src/interfaces/IFair.sol";
import {MockArbSys, StubBooth} from "../mocks/Mocks.sol";

/// Full-audit findings (25 Oct), flipped in v3.6 to assert the fixed behaviour, plus the follow-up review of them.
contract AnchorSeedAudit is Base {
    /// F-2 fixed: an unseeded core refuses every buyback, so a stolen keeper key can't set its own floor.
    function test_F2_unseededAnchor_thiefIsRefused() public {
        FairCore c = new FairCore(usdg, IGameConfig(address(config)), pass, owner, 48 hours);
        StubBooth b = new StubBooth(IFairCore(address(c)));
        vm.startPrank(owner);
        c.setupSet(FairCore.Op.AddBooth, 0, address(b));
        c.setupSet(FairCore.Op.SetKeeper, 0, keeper);
        c.setupSet(FairCore.Op.SetRoute, 0, address(route));
        c.finishSetup();
        c.setFair(0, T0 + 1 hours, T0 + 6 days);
        vm.stopPrank();
        openFair();
        vm.startPrank(ana);
        usdg.approve(address(c), type(uint256).max);
        b.shot(ana, 1, 100_000e6);
        vm.stopPrank();

        route.setRate(1); // the thief's ~0% fill
        vm.prank(keeper);
        vm.expectRevert(FairCore.NotSeeded.selector);
        c.burnBuyToken(FairCore.BurnSource.Bonfire, 0, 250e6, 1);
        assertEq(c.anchorRate(), 0, "the thief couldn't write an anchor");
    }

    /// Seeded (as every v3.6 deploy is before the first buyback): the thief's bad fill trips the floor.
    function test_F2_seededAnchor_blocksIt() public {
        openFair();
        shot(ana, 1, 100_000e6);
        route.setRate(1);
        vm.prank(keeper);
        vm.expectPartialRevert(FairCore.RatchetTripped.selector);
        core.burnBuyToken(FairCore.BurnSource.Bonfire, 0, 250e6, 1);
    }

    /// F-2 across GameConfig epochs: a token update closes buybacks again, and a thief can't use the old anchor or
    /// the gap before the Safe re-seeds.
    function test_F2_newEpoch_thiefIsRefusedUntilReseed() public {
        openFair();
        shot(ana, 1, 100_000e6);
        applyTokens(address(tokenB), 5_000e18, address(tokenB));
        routeB.setRate(1); // the thief's ~0% fill on token B's route
        vm.startPrank(keeper);
        vm.expectRevert(FairCore.NotSeeded.selector);
        core.burnBuyToken(FairCore.BurnSource.Bonfire, 1, 250e6, 1);
        vm.expectRevert(FairCore.NotSeeded.selector);
        core.buyForVault(1, 250e6, 1);
        vm.stopPrank();
        assertTrue(core.anchorStale());

        reseed(100e12 * 1e18); // the Safe seeds at the real price (A1-12: queued, 48h, unbounded in a new epoch)
        vm.prank(keeper);
        vm.expectPartialRevert(FairCore.RatchetTripped.selector);
        core.burnBuyToken(FairCore.BurnSource.Bonfire, 1, 250e6, 1);
    }

    /// Review note: the daily cap is per UTC day, so a window spanning midnight fits 2x the cap per ledger. Documented in the
    /// runbook; this pins the number (24 calls, 6,000 USDG on one ledger within 20h).
    function test_rolling24h_acrossMidnight_is2xDailyCap() public {
        openFair();
        shot(ana, 1, 200_000e6); // Bonfire 14,000
        uint256 midnight = (vm.getBlockTimestamp() / 1 days + 1) * 1 days;
        uint256 start = midnight - 12 * 50 minutes; // 12 calls before midnight, 12 after
        uint256 total;
        for (uint256 i; i < 24; ++i) {
            vm.warp(start + i * 50 minutes);
            uint256 m = 250e6 * core.ratchetFloorRate() / 1e18;
            vm.prank(keeper);
            core.burnBuyToken(FairCore.BurnSource.Bonfire, 0, 250e6, m);
            total += 250e6;
        }
        assertEq(total, 6_000e6);
        assertLt(uint256(23 * 50 minutes), uint256(20 hours));
    }
}

/// A smart wallet or batcher: lock and play in one transaction (msg.sender is the player).
contract BatchWallet {
    function lockAndTake(FairPass pass, SheriffsSeat seat, IERC20 wif, IERC20 usdg, address core) external {
        (address t, uint256 amt,) = pass.config().tokens(); // what the site reads before building the batch
        require(t == address(wif), "play token");
        wif.approve(address(pass), amt);
        pass.lock(t, amt);
        usdg.approve(core, type(uint256).max);
        seat.take(type(uint256).max, address(0), "batched", 1);
    }

    function unlock(FairPass pass) external {
        pass.unlock();
    }
}

contract SeatAndPassAudit is Base {
    SheriffsSeat seat;
    MockArbSys arb;
    uint256 day0;

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

    function takeAs(address payer, address player) internal {
        arb.set(arb.n() + 1);
        vm.prank(payer);
        seat.take(type(uint256).max, player, "m", 0);
    }

    function at(uint256 dayN, uint256 secs) internal {
        vm.warp(day0 + dayN * 1 days + secs);
    }

    // ---------------------------------------------------------------- M-1 + the recycling case: 24h hold

    /// One 5k stack can't hop to a second wallet: the first wallet can't unlock for 24 hours.
    function test_M1_oneStackCantRecycleAcrossWallets() public {
        address w1 = makeAddr("w1");
        address w2 = makeAddr("w2");
        usdg.mint(w1, 100e6);
        wif.mint(w1, PASS_LOCK); // exactly one stack
        vm.startPrank(w1);
        usdg.approve(address(core), type(uint256).max);
        wif.approve(address(pass), type(uint256).max);
        pass.lock(address(wif), PASS_LOCK);
        vm.stopPrank();
        takeAs(w1, address(0));

        at(0, 1); // one second later
        vm.prank(w1);
        vm.expectRevert(abi.encodeWithSelector(FairPass.HoldNotOver.selector, day0 + 24 hours));
        pass.unlock();
        assertFalse(pass.hasPass(w2), "wallet 2 never gets a pass from this stack today");

        at(1, 0); // 24 hours later the stack is free again
        vm.prank(w1);
        pass.unlock();
        assertEq(wif.balanceOf(w1), PASS_LOCK);
    }

    /// Lock-and-play in one transaction still works (smart wallets, Para batches). The lock then holds 24 hours.
    function test_M1_lockAndTake_inOneTx_stillWorks() public {
        BatchWallet sw = new BatchWallet();
        usdg.mint(address(sw), 100e6);
        wif.mint(address(sw), PASS_LOCK);
        arb.set(arb.n() + 1);
        sw.lockAndTake(pass, seat, IERC20(address(wif)), IERC20(address(usdg)), address(core));
        (address holder,,) = seat.holderOf(0);
        assertEq(holder, address(sw));
        vm.expectRevert(abi.encodeWithSelector(FairPass.HoldNotOver.selector, day0 + 24 hours));
        sw.unlock(pass);
    }

    // ---------------------------------------------------------------- I-1: settle the last day with takes

    function test_I1_quietDay_settlesLastTakeDay_andRolloverSeedsToday() public {
        takeAs(ana, address(0));
        at(0, 1 hours);
        takeAs(bob, address(0)); // two holders: the 5% third share rolls over
        at(2, 1 hours); // day 1 had no takes
        takeAs(cat, address(0));
        assertTrue(seat.isSettled(0), "day 0 settled by the day-2 take");
        assertGt(core.claimable(ana), 0, "day 0 winners can claim");
        uint256 day0Pot = 2 * (1e6 * 6000 / 10_000); // two 1 USDG takes (bob's came after the 1h slide), 60% Purse
        uint256 rolled = day0Pot - day0Pot * 7500 / 10_000 - day0Pot * 2000 / 10_000;
        assertEq(core.rollover(address(seat)), 0, "nothing waiting: it went into today's Purse");
        assertEq(core.pot(address(seat), 2), rolled + 1e6 * 6000 / 10_000, "day 2 Purse = rollover + cat's take");
    }

    function test_I1_manyQuietDays_andSameDayTakes() public {
        takeAs(ana, address(0));
        at(5, 0); // four quiet days (1-4); still inside Fair 0
        takeAs(bob, address(0));
        assertTrue(seat.isSettled(0));
        at(5, 10);
        takeAs(cat, address(0)); // same day: nothing to settle again, no revert
        assertFalse(seat.isSettled(5));
        assertEq(seat.lastTakeDayPlus1(), 6);
    }

    function test_I1_manualSettleFirst_thenTake() public {
        takeAs(ana, address(0));
        at(2, 0);
        seat.settle(0); // the keeper sweep got there first
        takeAs(bob, address(0)); // must not revert AlreadySettled
        assertTrue(seat.isSettled(0));
    }

    function test_I1_firstEverTake_onDay0() public {
        assertEq(seat.lastTakeDayPlus1(), 0);
        takeAs(ana, address(0)); // sentinel 0: nothing to settle
        assertEq(seat.lastTakeDayPlus1(), 1);
        at(0, 5);
        takeAs(bob, address(0)); // day 0 again: day 0 is today, not settled
        assertFalse(seat.isSettled(0));
    }

    /// A pause that starts on day 0 and runs through quiet day 1: day 0 is settled by the next take, and the
    /// holder is credited only the unpaused part of day 0.
    function test_I1_pauseSpanningAQuietDay() public {
        takeAs(ana, address(0));
        at(0, 12 hours);
        vm.prank(owner);
        core.pauseSales(true);
        at(2, 1 hours);
        vm.prank(owner);
        core.pauseSales(false);
        at(2, 2 hours);
        takeAs(bob, address(0));
        assertTrue(seat.isSettled(0));
        assertEq(seat.secsOf(0, ana), 12 hours, "paused half of day 0 not credited");
    }

    /// Fuzz: after any take on day d, every earlier day that had takes is settled.
    function testFuzz_I1_everyEarlierTakeDaySettled(uint8[8] memory gaps) public {
        address[3] memory people = [ana, bob, cat];
        uint256 d;
        bool[16] memory hadTakes;
        for (uint256 i; i < 8; ++i) {
            d += gaps[i] % 3; // 0 = same day, 1 = next day, 2 = one quiet day between
            if (d > 4) break; // Fair 0 has days 0-4 here
            at(d, 1 hours + i * 60);
            address who = people[i % 3];
            (address holder,,) = seat.holderOf(d);
            if (holder == who) who = people[(i + 1) % 3];
            takeAs(who, address(0));
            hadTakes[d] = true;
            for (uint256 k; k < d; ++k) {
                if (hadTakes[k]) assertTrue(seat.isSettled(k), "an earlier take day was left unsettled");
            }
        }
    }

    // ---------------------------------------------------------------- L-2 (frontend fix): message attribution

    /// Still possible by design (payer vs player). The site shows "posted by <payer>" when payer != holder.
    function test_L2_messagePostedInSomeoneElsesName_isVisibleInTheEvent() public {
        address troll = makeAddr("troll");
        fund(troll);
        arb.set(arb.n() + 1);
        vm.expectEmit(true, true, true, false, address(seat));
        emit SheriffsSeat.SeatTaken(0, ana, address(0), troll, 0, "", 0);
        vm.prank(troll);
        seat.take(type(uint256).max, ana, "words ana never wrote", 0);
    }
}
