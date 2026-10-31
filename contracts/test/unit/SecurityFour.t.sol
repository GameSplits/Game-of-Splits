// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

// Unit + fuzz tests for fix/security-four (A1-11/12/14, A2-13, A3-09/10/19, A5-01, K-A01/A02/B05/C01/C02/D01).

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Base} from "../Base.t.sol";
import {RatBase} from "../RatBase.t.sol";
import {FairCore} from "../../src/FairCore.sol";
import {RakeBuyer} from "../../src/RakeBuyer.sol";
import {AlmsVote} from "../../src/AlmsVote.sol";
import {FeeSplitter} from "../../src/FeeSplitter.sol";
import {SheriffsSeat} from "../../src/SheriffsSeat.sol";
import {FairLens} from "../../src/FairLens.sol";
import {LastArrow} from "../../src/LastArrow.sol";
import {RobinAmongThieves} from "../../src/RobinAmongThieves.sol";
import {SafeHandover} from "../../src/SafeHandover.sol";
import {IFairCore, IGameConfig} from "../../src/interfaces/IFair.sol";
import {IVaultView} from "../../src/FairLens.sol";
import {MockToken} from "../mocks/Mocks.sol";
import {DeployBase} from "../../script/Deploy.s.sol";

contract BoothR {
    IFairCore public immutable core;

    constructor(IFairCore c) {
        core = c;
    }

    function pull(address payer, address player, uint256 key, uint256 gross) external {
        core.collect(payer, player, key, gross);
    }
}

contract SafeStub {}

contract FutureSeat {
    function day0() external view returns (uint256) {
        return block.timestamp + 1;
    }
}

/// FairCore: per-booth allowances, RemoveBooth, claimTo, collect-after-award, bounded resets.
contract SecurityFourFairCoreTest is Base {
    BoothR late;
    address payer = makeAddr("payer");

    function setUp() public override {
        super.setUp();
        late = new BoothR(IFairCore(address(core)));
        vm.prank(owner);
        core.queue(FairCore.Op.AddBooth, 0, address(late));
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        vm.prank(owner);
        core.execute(FairCore.Op.AddBooth, 0, address(late));
        fund(payer);
    }

    function test_lateBooth_isNotLaunchBooth_launchBoothNeedsNoApproval() public {
        assertTrue(core.isBooth(address(late)));
        assertFalse(core.isLaunchBooth(address(late)));
        assertTrue(core.isLaunchBooth(address(booth)));
        shot(ana, 1, 10e6); // launch booth: the FairCore approval alone is enough (unchanged UX)
    }

    function test_approveBooth_emitsAndSets() public {
        vm.expectEmit(true, true, false, true, address(core));
        emit FairCore.BoothApproval(payer, address(late), 7e6);
        vm.prank(payer);
        core.approveBooth(address(late), 7e6);
        assertEq(core.boothAllowance(payer, address(late)), 7e6);
    }

    function testFuzz_lateBoothPull_boundByAllowance(uint256 allowance, uint256 gross) public {
        allowance = bound(allowance, 0, 1_000e6);
        gross = bound(gross, 1e6, 1_000e6);
        vm.prank(payer);
        core.approveBooth(address(late), allowance);
        uint256 before = usdg.balanceOf(payer);
        if (gross > allowance) {
            vm.expectRevert(FairCore.BoothNotApproved.selector);
            late.pull(payer, payer, 1, gross);
            assertEq(usdg.balanceOf(payer), before);
            assertEq(core.boothAllowance(payer, address(late)), allowance);
        } else {
            late.pull(payer, payer, 1, gross);
            assertEq(usdg.balanceOf(payer), before - gross);
            assertEq(core.boothAllowance(payer, address(late)), allowance - gross);
        }
        assertSolvent();
    }

    function test_maxBoothAllowance_isNotSpent() public {
        vm.prank(payer);
        core.approveBooth(address(late), type(uint256).max);
        late.pull(payer, payer, 1, 5e6);
        assertEq(core.boothAllowance(payer, address(late)), type(uint256).max);
    }

    function test_removeBooth_onlyViaTimelock_andCannotRemoveTwice() public {
        vm.prank(owner);
        vm.expectRevert(FairCore.SetupClosed.selector);
        core.setupSet(FairCore.Op.RemoveBooth, 0, address(late));
        vm.startPrank(owner);
        core.queue(FairCore.Op.RemoveBooth, 0, address(booth)); // a launch booth can be removed too
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        core.execute(FairCore.Op.RemoveBooth, 0, address(booth));
        vm.stopPrank();
        assertFalse(core.isBooth(address(booth)));
        assertFalse(core.isLaunchBooth(address(booth)));
        vm.prank(ana);
        vm.expectRevert(FairCore.NotBooth.selector);
        booth.shot(ana, 1, 10e6);
    }

    function test_claimTo_zeroAddress_andNothing() public {
        vm.prank(ana);
        vm.expectRevert(FairCore.ZeroAddress.selector);
        core.claimTo(address(0));
        vm.prank(ana);
        vm.expectRevert(FairCore.NothingToClaim.selector);
        core.claimTo(bob);
    }

    function testFuzz_claimTo_movesExactlyClaimable(uint256 gross, address to) public {
        vm.assume(to != address(0) && to != address(core));
        gross = bound(gross, 1e6, 10_000e6);
        openFair();
        shot(ana, 1, gross);
        address[] memory w = new address[](1);
        uint256[] memory a = new uint256[](1);
        w[0] = ana;
        a[0] = core.pot(address(booth), 1);
        booth.settle(1, w, a);
        uint256 acc = core.accounted();
        uint256 before = usdg.balanceOf(to);
        vm.expectEmit(true, true, false, true, address(core));
        emit FairCore.ClaimedTo(ana, to, a[0]);
        vm.prank(ana);
        core.claimTo(to);
        assertEq(usdg.balanceOf(to), before + a[0]);
        assertEq(core.claimable(ana), 0);
        assertEq(core.accounted(), acc - a[0]);
        assertSolvent();
    }

    function test_collectAfterAward_reverts_noShotsRoundToo() public {
        openFair();
        address[] memory w = new address[](0);
        uint256[] memory a = new uint256[](0);
        booth.settle(5, w, a); // an empty round is marked awarded
        vm.prank(ana);
        vm.expectRevert(FairCore.AlreadyAwarded.selector);
        booth.shot(ana, 5, 1e6);
    }

    function testFuzz_resetBounds_postSetup(uint256 x) public {
        uint256 a0 = core.anchorRate();
        x = bound(x, 1, a0 * 2);
        (uint256 lo, uint256 hi) = core.resetBounds();
        assertEq(lo, a0 * 7000 / 10_000);
        assertEq(hi, a0 * 13_000 / 10_000);
        vm.startPrank(owner);
        core.queue(FairCore.Op.ResetRatchet, x, address(0));
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        if (x < lo || x > hi) {
            vm.expectPartialRevert(FairCore.ResetOutOfBounds.selector);
            core.execute(FairCore.Op.ResetRatchet, x, address(0));
            assertEq(core.anchorRate(), a0);
        } else {
            core.execute(FairCore.Op.ResetRatchet, x, address(0));
            assertEq(core.anchorRate(), x);
        }
        vm.stopPrank();
    }

    function test_resetRatchet_needsTimelockAfterSetup() public {
        uint256 a0 = core.anchorRate();
        vm.startPrank(owner);
        bytes32 id = core.queue(FairCore.Op.ResetRatchet, a0, address(0));
        vm.expectPartialRevert(FairCore.TooEarly.selector);
        core.execute(FairCore.Op.ResetRatchet, a0, address(0));
        core.cancel(id);
        vm.stopPrank();
    }

    function test_handOver_onlyOwner() public {
        address safe = address(new SafeStub());
        vm.prank(ana);
        vm.expectPartialRevert(bytes4(keccak256("OwnableUnauthorizedAccount(address)")));
        core.handOver(safe);
    }

    function test_handOver_clearsPendingOffer() public {
        address safe = address(new SafeStub());
        vm.startPrank(owner);
        core.transferOwnership(bob);
        assertEq(core.pendingOwner(), bob);
        core.handOver(safe);
        vm.stopPrank();
        assertEq(core.owner(), safe);
        assertEq(core.pendingOwner(), address(0), "no stale offer survives");
        vm.prank(bob);
        vm.expectPartialRevert(bytes4(keccak256("OwnableUnauthorizedAccount(address)")));
        core.acceptOwnership();
    }

    /// K-D01: a seat can't start in the future; FairLens refuses a seat that hasn't started.
    function test_seat_futureDay0_reverts_lensRejectsUnstartedSeat() public {
        uint256 today = (vm.getBlockTimestamp() / 1 days) * 1 days;
        vm.expectRevert(SheriffsSeat.BadConfig.selector);
        new SheriffsSeat(IFairCore(address(core)), today + 1 days, 1 days);
        SheriffsSeat ok = new SheriffsSeat(IFairCore(address(core)), today, 1 days);
        assertEq(ok.day0(), today);
        address future = address(new FutureSeat()); // deploy first so expectRevert targets the FairLens constructor
        vm.expectRevert(FairLens.SeatNotStarted.selector);
        new FairLens(core, LastArrow(address(0)), SheriffsSeat(future), IVaultView(address(0)));
    }
}

/// RakeBuyer: daily cap, per-leg forward, forwardTo, reconcile totals.
contract SecurityFourRakeBuyerTest is Base {
    RakeBuyer rb;
    address vaultTo = makeAddr("vaultTo");
    uint256 constant RATE = 781_250e12;

    function setUp() public override {
        super.setUp();
        rb = new RakeBuyer(usdg, IGameConfig(address(config)), vaultTo, owner, 48 hours);
        vm.startPrank(owner);
        rb.setupSet(RakeBuyer.Op.SetKeeper, 0, keeper);
        rb.setupSet(RakeBuyer.Op.SetRoute, 0, address(route));
        rb.resetRatchet(RATE * 1e18);
        rb.finishSetup();
        vm.stopPrank();
    }

    function _buy(uint256 amt) internal {
        vm.prank(keeper);
        rb.buy(0, amt, amt * RATE * 95 / 100);
    }

    function testFuzz_dailyCap_neverExceeded(uint256 seed) public {
        usdg.mint(address(rb), 10_000e6);
        uint256 t = (vm.getBlockTimestamp() / 1 days + 1) * 1 days;
        vm.warp(t);
        uint256 day = t / 1 days;
        for (uint256 i; i < 25; ++i) {
            uint256 amt = bound(uint256(keccak256(abi.encode(seed, i))), 1e6, 50e6);
            if (rb.boughtOnDay(day) + amt > rb.DAILY_BUY_CAP()) {
                vm.prank(keeper);
                vm.expectRevert(RakeBuyer.DailyCap.selector);
                rb.buy(0, amt, 1);
            } else {
                _buy(amt);
            }
            assertLe(rb.boughtOnDay(day), rb.DAILY_BUY_CAP());
            t += 50 minutes;
            if (t / 1 days != day) break;
            vm.warp(t);
        }
        assertEq(rb.totalSpent(), rb.spentOf(rb.buyToken()));
    }

    function test_forwardTo_onlyKeyZero_onlyTimelock() public {
        address alt = makeAddr("alt");
        vm.startPrank(owner);
        vm.expectRevert(RakeBuyer.SetupClosed.selector);
        rb.setupSet(RakeBuyer.Op.SetForwardTo, 0, alt);
        rb.queue(RakeBuyer.Op.SetForwardTo, 0, alt);
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        rb.execute(RakeBuyer.Op.SetForwardTo, 0, alt);
        assertEq(rb.forwardTo(), alt);
        rb.queue(RakeBuyer.Op.SetForwardTo, 0, address(0)); // back to the vault
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        rb.execute(RakeBuyer.Op.SetForwardTo, 0, address(0));
        vm.stopPrank();
        assertEq(rb.recipient(), vaultTo);
    }

    function test_forward_tokenLegFails_usdgLegStillGoes() public {
        usdg.mint(address(rb), 100e6);
        _buy(40e6);
        address w = rb.buyToken();
        uint256 held = IERC20(w).balanceOf(address(rb));
        vm.mockCallRevert(w, abi.encodeWithSelector(IERC20.transfer.selector, vaultTo), bytes("no"));
        rb.forwardToken(w);
        vm.clearMockedCalls();
        assertEq(usdg.balanceOf(vaultTo), 40e6);
        assertEq(rb.spentOf(w), 0);
        assertEq(rb.bought(w), held, "token leg kept for a retry");
        rb.forwardToken(w);
        assertEq(IERC20(w).balanceOf(vaultTo), held);
        assertEq(rb.bought(w), 0);
    }

    function test_forward_nothing_reverts() public {
        address w = rb.buyToken();
        vm.expectRevert(RakeBuyer.NothingToForward.selector);
        rb.forwardToken(w);
    }

    function testFuzz_reconcile_completeList_keepsTotals(uint256 seized) public {
        usdg.mint(address(rb), 100e6);
        _buy(40e6);
        address w = rb.buyToken();
        seized = bound(seized, 1, 60e6);
        deal(address(usdg), address(rb), 60e6 - seized);
        address[] memory list = new address[](1);
        list[0] = w;
        vm.prank(owner);
        rb.reconcile(list);
        assertEq(rb.totalSpent(), rb.spentOf(w));
        assertLe(rb.spentOf(w), rb.legPending());
        assertEq(rb.buyPending() + rb.legPending(), 60e6 - seized);
    }

    function testFuzz_resetBounds_rakeBuyer(uint256 x) public {
        uint256 a0 = rb.anchorRate();
        x = bound(x, 1, a0 * 2);
        (uint256 lo, uint256 hi) = rb.resetBounds();
        vm.startPrank(owner);
        rb.queue(RakeBuyer.Op.ResetRatchet, x, address(0));
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        if (x < lo || x > hi) {
            vm.expectPartialRevert(RakeBuyer.ResetOutOfBounds.selector);
            rb.execute(RakeBuyer.Op.ResetRatchet, x, address(0));
        } else {
            rb.execute(RakeBuyer.Op.ResetRatchet, x, address(0));
            assertEq(rb.anchorRate(), x);
        }
        vm.stopPrank();
    }
}

/// FeeSplitter: escrow accounting, claimEscrow, rescue lifecycle, conservation fuzz.
contract SecurityFourFeeSplitterTest is Test {
    MockToken t;
    FeeSplitter fs;
    address owner = makeAddr("ownerSafe");
    address purses = makeAddr("purses");
    address vault = makeAddr("vault");
    address rebate = makeAddr("rebate");
    address burnBuyer = makeAddr("burnBuyer");
    address ops = makeAddr("ops");

    function setUp() public {
        t = new MockToken("USDG", "USDG", 6);
        fs = new FeeSplitter(
            address(new MockToken("WIF", "WIF", 18)),
            owner,
            FeeSplitter.Recipients(purses, vault, rebate, burnBuyer, ops),
            FeeSplitter.FeeSplit(4000, 2500, 1500, 1000, 1000)
        );
    }

    function _escrowOps(uint256 amt) internal {
        t.mint(address(fs), amt);
        vm.mockCallRevert(address(t), abi.encodeWithSelector(IERC20.transfer.selector, ops), bytes("blocked"));
        fs.distribute(address(t));
        vm.clearMockedCalls();
    }

    function test_claimEscrow_paysOnlyTheOwedRecipient() public {
        _escrowOps(1_000e6);
        uint256 owedOps = fs.owed(address(t), ops);
        assertEq(owedOps, 100e6);
        vm.prank(makeAddr("anyone"));
        fs.claimEscrow(address(t), ops);
        assertEq(t.balanceOf(ops), 100e6);
        assertEq(fs.escrowTotal(address(t)), 0);
        vm.expectRevert(FeeSplitter.ZeroAmount.selector);
        fs.claimEscrow(address(t), ops);
    }

    function test_rescue_lifecycle() public {
        _escrowOps(1_000e6);
        address to = makeAddr("newOps");
        vm.prank(ops);
        vm.expectPartialRevert(bytes4(keccak256("OwnableUnauthorizedAccount(address)")));
        fs.queueRescue(address(t), ops, to, 100e6);
        vm.prank(owner);
        vm.expectRevert(FeeSplitter.NotQueued.selector);
        fs.executeRescue(address(t), ops, to, 100e6);
        vm.prank(owner);
        bytes32 id = fs.queueRescue(address(t), ops, to, 100e6);
        assertEq(id, fs.rescueId(address(t), ops, to, 100e6));
        vm.prank(owner);
        fs.cancel(id);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        vm.prank(owner);
        vm.expectRevert(FeeSplitter.NotQueued.selector);
        fs.executeRescue(address(t), ops, to, 100e6);
        vm.prank(owner);
        fs.queueRescue(address(t), ops, to, 100e6);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        vm.prank(owner);
        fs.executeRescue(address(t), ops, to, 100e6);
        assertEq(t.balanceOf(to), 100e6);
        // nothing left: K16-C-A01, a rescue can't be queued for escrow that isn't owed
        vm.prank(owner);
        vm.expectRevert(FeeSplitter.BadValue.selector);
        fs.queueRescue(address(t), ops, to, 100e6);
    }

    function test_distribute_lowGas_revertsInsteadOfEscrowing() public {
        t.mint(address(fs), 1_000e6);
        vm.expectRevert(FeeSplitter.InsufficientGas.selector);
        fs.distribute{gas: 150_000}(address(t));
        assertEq(fs.escrowTotal(address(t)), 0);
    }

    function testFuzz_distribute_conservesAndSplits(uint256 amt, uint8 failMask) public {
        amt = bound(amt, 1, 1e30);
        t.mint(address(fs), amt);
        address[5] memory rs = [purses, vault, rebate, burnBuyer, ops];
        for (uint256 i; i < 5; ++i) {
            if (failMask & (1 << i) != 0) {
                vm.mockCallRevert(address(t), abi.encodeWithSelector(IERC20.transfer.selector, rs[i]), bytes("x"));
            }
        }
        fs.distribute(address(t));
        vm.clearMockedCalls();
        uint256 paid;
        for (uint256 i; i < 5; ++i) {
            paid += t.balanceOf(rs[i]);
            if (failMask & (1 << i) != 0) assertEq(t.balanceOf(rs[i]), 0);
            else assertEq(fs.owed(address(t), rs[i]), 0);
        }
        assertEq(paid + t.balanceOf(address(fs)), amt, "conserved");
        assertGe(t.balanceOf(address(fs)), fs.escrowTotal(address(t)), "escrow backed");
        uint256 sumOwed;
        for (uint256 i; i < 5; ++i) sumOwed += fs.owed(address(t), rs[i]);
        assertEq(sumOwed, fs.escrowTotal(address(t)));
        // purses get 40% of the whole, escrowed or paid
        assertEq(t.balanceOf(purses) + fs.owed(address(t), purses), amt * 4000 / 10_000);
    }
}

/// AlmsVote: 5 USDG minimum spend per Fair.
contract SecurityFourAlmsTest is Base {
    AlmsVote alms;
    bytes32 constant C = keccak256("charity");

    function setUp() public override {
        super.setUp();
        alms = new AlmsVote(IFairCore(address(core)), owner, 24 hours, 24 hours);
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = C;
        vm.prank(owner);
        alms.setEligible(ids);
    }

    function testFuzz_minSpend_gatesSuggestAndVote(uint256 g1, uint256 g2) public {
        g1 = bound(g1, 1e6, 10e6);
        g2 = bound(g2, 1e6, 10e6);
        lockPass(ana);
        lockPass(bob);
        openFair();
        shot(ana, 1, g1);
        shot(ana, 2, g2); // spend accumulates across shots
        shot(bob, 1, 5e6);
        assertEq(core.spentIn(0, ana), g1 + g2);
        uint64 ss = uint64(vm.getBlockTimestamp() + 1 days);
        vm.prank(owner);
        alms.setAlmsWindows(0, ss, ss + 1 days, ss + 2 days);
        vm.warp(ss);
        vm.prank(bob);
        alms.suggest(0, C);
        vm.warp(ss + 1 days);
        if (g1 + g2 < alms.MIN_VOTE_SPEND()) {
            vm.expectRevert(abi.encodeWithSelector(AlmsVote.BelowMinSpend.selector, g1 + g2, 5e6));
        }
        vm.prank(ana);
        alms.vote(0, C);
    }
}

/// RAT: timeout fallback seed, lockPairing, lapse counting.
contract SecurityFourRatTest is RatBase {
    function _status(uint256 r) internal view returns (RobinAmongThieves.Status s) {
        (,,,,,,,,,, s,,,,,,,) = rat.rounds(r);
    }

    function _two(uint256 r) internal returns (uint256 a, uint256 b) {
        a = regFunded(ana, 100e6);
        b = regFunded(bob, 100e6);
        toEntries(r);
        enterAs(ana, a, r);
        enterAs(bob, b, r);
    }

    function test_fallbackSeed_windows() public {
        uint256 r = FIRST;
        _two(r);
        vm.warp(rat.closeTime(r) + 3 minutes - 1);
        vm.expectRevert(RobinAmongThieves.WrongWindow.selector);
        rat.fallbackSeed(r);
        vm.warp(rat.closeTime(r) + 8 minutes);
        vm.expectRevert(RobinAmongThieves.WrongWindow.selector);
        rat.fallbackSeed(r);
        rat.cancelRound(r, 100);
        assertEq(uint8(_status(r)), uint8(RobinAmongThieves.Status.Cancelled));
        assertEq(rat.pairingLapses(), 0, "never seeded: not a lapse");
    }

    function test_fallbackSeed_afterKeeperReveal_reverts() public {
        uint256 r = FIRST;
        _two(r);
        seedPair(r);
        vm.warp(rat.closeTime(r) + 3 minutes);
        vm.expectRevert();
        rat.fallbackSeed(r);
    }

    function test_fallbackSeed_keeperRevoked_cancels() public {
        uint256 r = FIRST;
        _two(r);
        vm.prank(owner);
        rat.revokeKeeper();
        vm.warp(rat.closeTime(r) + 3 minutes);
        vm.expectRevert(RobinAmongThieves.NotKeeper.selector);
        rat.fallbackSeed(r);
        vm.warp(rat.closeTime(r) + 8 minutes);
        rat.cancelRound(r, 100);
        ledgersOk();
    }

    function test_lockPairing_sameBlock_reverts_thenLapseCounted() public {
        uint256 r = FIRST;
        _two(r);
        vm.warp(rat.closeTime(r) + 3 minutes);
        rat.fallbackSeed(r);
        vm.expectRevert(RobinAmongThieves.SeedHashUnavailable.selector);
        rat.lockPairing(r);
        MockArbSysLike(address(0x64)).set(MockArbSysLike(address(0x64)).n() + 300); // hash out of reach
        vm.expectRevert(RobinAmongThieves.SeedHashUnavailable.selector);
        rat.lockPairing(r);
        vm.warp(rat.closeTime(r) + 8 minutes);
        rat.cancelRound(r, 100);
        assertEq(rat.pairingLapses(), 1);
        ledgersOk();
    }

    function test_locked_cannotBeCancelled_pairUntil8m() public {
        uint256 r = FIRST;
        _two(r);
        vm.warp(rat.closeTime(r) + 3 minutes);
        rat.fallbackSeed(r);
        advanceL2();
        rat.lockPairing(r);
        vm.expectRevert(RobinAmongThieves.AlreadyLocked.selector);
        rat.lockPairing(r);
        vm.warp(rat.closeTime(r) + 8 minutes - 1);
        vm.expectRevert(RobinAmongThieves.WrongWindow.selector);
        rat.cancelRound(r, 100);
        rat.pair(r, 1000);
        assertEq(uint8(_status(r)), uint8(RobinAmongThieves.Status.Paired));
    }

    function testFuzz_withheldSeed_playableAnywhereInWindow(uint256 at) public {
        uint256 r = FIRST;
        _two(r);
        at = bound(at, 3 minutes, 7 minutes - 2); // K16-B-1: the fallback closes MIN_LOCK_WINDOW before cancel
        vm.warp(rat.closeTime(r) + at);
        rat.fallbackSeed(r);
        advanceL2();
        vm.warp(vm.getBlockTimestamp() + 1);
        rat.lockPairing(r);
        rat.pair(r, 1000);
        assertEq(uint8(_status(r)), uint8(RobinAmongThieves.Status.Paired));
        ledgersOk();
    }
}

interface MockArbSysLike {
    function set(uint256) external;
    function n() external view returns (uint256);
}

/// A1-14 / K-B05: the deploy flow as the script runs it (minus the broadcast).
contract DeployHarness is DeployBase {
    function deployAll(address usdg, address wif, address route, address keeper, address safe, uint256 seed)
        external
        returns (Out memory o)
    {
        address me = msg.sender;
        vm.startPrank(me);
        o = _deployGame(usdg, wif, me, 48 hours, 7 days, 1 days);
        o.routeA = route;
        o.rakeRouteA = route;
        _wire(o, keeper, keeper, safe, seed);
        _deployRobin(o, keeper, 48 hours, 7 days, address(0x8004), address(0x8005));
        _wireRakeBuyer(o, keeper, seed);
        _handOver(o, safe);
        vm.stopPrank();
        _requireHandedOver(o, safe, me);
        _checkRobin(o, keeper, address(0x8004), address(0x8005), safe);
    }

    function pickSafe(address gos, address legacy) external view returns (address) {
        return _pickSafe(gos, legacy);
    }
}

contract SecurityFourDeployTest is Base {
    function test_deployFlow_handsAllSevenToSafe_entriesPaused() public {
        DeployHarness h = new DeployHarness();
        address deployer = makeAddr("freshDeployer");
        address safe = address(new SafeStub());
        vm.startPrank(deployer);
        DeployBase.Out memory o = h.deployAll(address(usdg), address(wif), address(route), keeper, safe, 781_250e30);
        vm.stopPrank();
        assertEq(o.core.owner(), safe);
        assertEq(o.rat.owner(), safe);
        assertTrue(o.rat.entriesPaused(), "K-B05: entries start paused");
        vm.prank(deployer);
        vm.expectPartialRevert(bytes4(keccak256("OwnableUnauthorizedAccount(address)")));
        o.rat.pauseEntries(false);
        vm.prank(safe);
        o.rat.pauseEntries(false);
        assertFalse(o.rat.entriesPaused());
    }

    function test_pickSafe_rules() public {
        DeployHarness h = new DeployHarness();
        address safe = address(new SafeStub());
        assertEq(h.pickSafe(safe, address(0)), safe);
        assertEq(h.pickSafe(address(0), safe), safe);
        vm.expectRevert(bytes("GOS_SAFE not set"));
        h.pickSafe(address(0), address(0));
        vm.expectRevert(bytes("GOS_SAFE has no code on this chain"));
        h.pickSafe(makeAddr("eoa"), address(0));
        address other = address(new SafeStub());
        vm.expectRevert(bytes("GOS_SAFE and OWNER_SAFE differ"));
        h.pickSafe(safe, other);
    }
}
