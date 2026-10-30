// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// Regressions for the low-severity review findings (K16). Each test is the matching review PoC, ported so
// it now asserts the fixed behaviour, plus fuzz on the value-moving paths the fixes touch.

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Base} from "../Base.t.sol";
import {RatBase} from "../RatBase.t.sol";
import {FeeSplitter} from "../../src/FeeSplitter.sol";
import {FairCore} from "../../src/FairCore.sol";
import {RakeBuyer} from "../../src/RakeBuyer.sol";
import {AlmsVote} from "../../src/AlmsVote.sol";
import {RobinAmongThieves} from "../../src/RobinAmongThieves.sol";
import {IFairCore, IGameConfig} from "../../src/interfaces/IFair.sol";
import {MockToken} from "../mocks/Mocks.sol";
import {SafeHandover} from "../../src/SafeHandover.sol";
import {DeployBase} from "../../script/Deploy.s.sol";

contract BoothQ {
    IFairCore public immutable core;

    constructor(IFairCore c) {
        core = c;
    }

    function pull(address payer, address player, uint256 key, uint256 gross) external {
        core.collect(payer, player, key, gross);
    }
}

/// K16-A01 / K16-C-A02 reset walk: one pending reset at a time, so ±30% is per timelock delay.
contract ReviewLowsResetWalkFixed is Base {
    function test_fairCore_secondQueuedReset_reverts_walkTakesOneDelayPerStep() public {
        uint256 a0 = core.anchorRate();
        uint256 a1 = a0 * 7000 / 10_000;
        uint256 a2 = a1 * 7000 / 10_000;
        vm.startPrank(owner);
        bytes32 id1 = core.queue(FairCore.Op.ResetRatchet, a1, address(0));
        assertEq(core.pendingReset(), id1);
        vm.expectRevert(abi.encodeWithSelector(FairCore.ResetPending.selector, id1));
        core.queue(FairCore.Op.ResetRatchet, a2, address(0));
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        core.execute(FairCore.Op.ResetRatchet, a1, address(0));
        assertEq(core.pendingReset(), bytes32(0));
        // the next step needs its own full delay
        core.queue(FairCore.Op.ResetRatchet, a2, address(0));
        vm.expectPartialRevert(FairCore.TooEarly.selector);
        core.execute(FairCore.Op.ResetRatchet, a2, address(0));
        vm.stopPrank();
        assertEq(core.anchorRate(), a1, "one 30% step per 48h");
    }

    function test_fairCore_cancelFreesTheSlot() public {
        uint256 a0 = core.anchorRate();
        vm.startPrank(owner);
        bytes32 id1 = core.queue(FairCore.Op.ResetRatchet, a0 * 9 / 10, address(0));
        core.cancel(id1);
        assertEq(core.pendingReset(), bytes32(0));
        core.queue(FairCore.Op.ResetRatchet, a0 * 8 / 10, address(0));
        vm.stopPrank();
    }

    function test_rakeBuyer_secondQueuedReset_reverts() public {
        RakeBuyer rb = new RakeBuyer(usdg, IGameConfig(address(config)), makeAddr("v"), owner, 48 hours);
        vm.startPrank(owner);
        rb.setupSet(RakeBuyer.Op.SetKeeper, 0, keeper);
        rb.setupSet(RakeBuyer.Op.SetRoute, 0, address(route));
        rb.resetRatchet(1e24);
        rb.finishSetup();
        uint256 a1 = 1e24 * 7000 / 10_000;
        uint256 a2 = a1 * 7000 / 10_000;
        bytes32 id1 = rb.queue(RakeBuyer.Op.ResetRatchet, a1, address(0));
        vm.expectRevert(abi.encodeWithSelector(RakeBuyer.ResetPending.selector, id1));
        rb.queue(RakeBuyer.Op.ResetRatchet, a2, address(0));
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        rb.execute(RakeBuyer.Op.ResetRatchet, a1, address(0));
        rb.queue(RakeBuyer.Op.ResetRatchet, a2, address(0));
        vm.expectPartialRevert(RakeBuyer.TooEarly.selector);
        rb.execute(RakeBuyer.Op.ResetRatchet, a2, address(0));
        vm.stopPrank();
        assertEq(rb.anchorRate(), a1);
    }

    /// Fuzz: whatever the owner queues, after one delay the anchor is within ±30% of where it started.
    function testFuzz_oneDelay_boundsTheWalk(uint256 s1, uint256 s2, uint256 s3) public {
        uint256 a0 = core.anchorRate();
        uint256[3] memory k = [bound(s1, a0 * 7 / 10, a0 * 13 / 10), bound(s2, 1, a0 * 2), bound(s3, 1, a0 * 2)];
        vm.startPrank(owner);
        for (uint256 i; i < 3; ++i) {
            try core.queue(FairCore.Op.ResetRatchet, k[i], address(0)) {} catch {}
        }
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        for (uint256 i; i < 3; ++i) {
            try core.execute(FairCore.Op.ResetRatchet, k[i], address(0)) {} catch {}
        }
        vm.stopPrank();
        uint256 a = core.anchorRate();
        assertGe(a, a0 * 7000 / 10_000);
        assertLe(a, a0 * 13_000 / 10_000 + 1);
    }
}

/// K16-A03 / K16-A04: booth approvals are keyed by booth generation; increase / decrease helpers.
contract ReviewLowsBoothFixed is Base {
    BoothQ late;
    address payer = makeAddr("payer");

    function _add() internal {
        vm.startPrank(owner);
        core.queue(FairCore.Op.AddBooth, 0, address(late));
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        core.execute(FairCore.Op.AddBooth, 0, address(late));
        vm.stopPrank();
    }

    function _remove() internal {
        vm.startPrank(owner);
        core.queue(FairCore.Op.RemoveBooth, 0, address(late));
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        core.execute(FairCore.Op.RemoveBooth, 0, address(late));
        vm.stopPrank();
    }

    function setUp() public override {
        super.setUp();
        late = new BoothQ(IFairCore(address(core)));
        fund(payer);
    }

    function test_staleAllowance_isGoneAfterRemoveReAdd() public {
        _add();
        vm.prank(payer);
        core.approveBooth(address(late), type(uint256).max);
        _remove();
        _add();
        assertEq(core.boothAllowance(payer, address(late)), 0, "old opt-in no longer live");
        openFair();
        vm.expectRevert(FairCore.BoothNotApproved.selector);
        late.pull(payer, payer, 1, 1e6);
        // a fresh opt-in works for the new generation
        vm.prank(payer);
        core.approveBooth(address(late), 2e6);
        late.pull(payer, payer, 1, 1e6);
        assertEq(core.boothAllowance(payer, address(late)), 1e6);
    }

    function testFuzz_increaseDecrease(uint256 start, uint256 up, uint256 down) public {
        _add();
        vm.startPrank(payer);
        core.approveBooth(address(late), start);
        core.increaseBoothAllowance(address(late), up);
        uint256 afterUp = type(uint256).max - start < up ? type(uint256).max : start + up;
        assertEq(core.boothAllowance(payer, address(late)), afterUp, "saturating add");
        core.decreaseBoothAllowance(address(late), down);
        assertEq(core.boothAllowance(payer, address(late)), afterUp > down ? afterUp - down : 0, "floors at 0");
        vm.stopPrank();
    }

    /// Fuzz: the booth never pulls more than the allowance it was given, whatever the order of approve and pulls.
    function testFuzz_pullsNeverExceedAllowance(uint256 allow, uint256 g1, uint256 g2) public {
        _add();
        openFair();
        allow = bound(allow, 0, 100e6);
        g1 = bound(g1, 1, 60e6);
        g2 = bound(g2, 1, 60e6);
        vm.prank(payer);
        core.increaseBoothAllowance(address(late), allow);
        uint256 before = usdg.balanceOf(payer);
        try late.pull(payer, payer, 1, g1) {} catch {}
        try late.pull(payer, payer, 1, g2) {} catch {}
        assertLe(before - usdg.balanceOf(payer), allow);
        assertEq(before - usdg.balanceOf(payer) + core.boothAllowance(payer, address(late)), allow);
    }
}

/// K16-D-A01: MIN_VOTE_SPEND counts net spend (credited shots minus winnings from that Fair's rounds).
contract ReviewLowsWashFixed is Base {
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

    function _win(address who, uint256 key) internal returns (uint256 won) {
        address[] memory w = new address[](1);
        uint256[] memory a = new uint256[](1);
        w[0] = who;
        a[0] = won = core.pot(address(booth), key);
        booth.settle(key, w, a);
    }

    function test_washedShot_doesNotQualify() public {
        address sybil = makeAddr("sybil");
        fund(sybil);
        lockPass(sybil);
        openFair();
        shot(sybil, 1, 5e6); // the only shooter in its round
        assertEq(core.spentIn(0, sybil), 5e6, "gross still recorded");
        _win(sybil, 1); // the whole purse back
        assertEq(core.netSpentIn(0, sybil), 2e6, "net is the 40% really spent");
        uint64 ss = uint64(vm.getBlockTimestamp() + 1 days);
        vm.prank(owner);
        alms.setAlmsWindows(0, ss, ss + 1 days, ss + 2 days);
        vm.warp(ss);
        vm.prank(sybil);
        vm.expectRevert(abi.encodeWithSelector(AlmsVote.BelowMinSpend.selector, 2e6, 5e6));
        alms.suggest(0, C);
    }

    function test_honestLoser_stillQualifies() public {
        lockPass(ana);
        lockPass(bob);
        openFair();
        shot(ana, 1, 5e6);
        shot(bob, 1, 5e6);
        _win(bob, 1);
        assertEq(core.netSpentIn(0, ana), 5e6);
        uint64 ss = uint64(vm.getBlockTimestamp() + 1 days);
        vm.prank(owner);
        alms.setAlmsWindows(0, ss, ss + 1 days, ss + 2 days);
        vm.warp(ss);
        vm.prank(ana);
        alms.suggest(0, C);
    }

    /// Fuzz: net = gross - winnings from that Fair, floored at 0, and winnings land on the round's Fair.
    function testFuzz_netSpent(uint256 g1, uint256 g2, uint256 wonShare) public {
        g1 = bound(g1, 1e6, 50e6);
        g2 = bound(g2, 1e6, 50e6);
        lockPass(ana);
        lockPass(bob);
        openFair();
        shot(ana, 1, g1);
        shot(bob, 1, g2);
        uint256 p = core.pot(address(booth), 1);
        uint256 w = bound(wonShare, 0, p);
        address[] memory ws = new address[](1);
        uint256[] memory as_ = new uint256[](1);
        (ws[0], as_[0]) = (ana, w);
        booth.settle(1, ws, as_);
        assertEq(core.wonIn(0, ana), w);
        assertEq(core.netSpentIn(0, ana), g1 > w ? g1 - w : 0);
        assertEq(core.netSpentIn(0, bob), g2);
        assertSolvent();
    }
}

/// K16-A05: a failed Alms transfer escrows; SetAlmsSafe is timelocked after setup; anyone flushes.
contract ReviewLowsAlmsFixed is Base {
    function test_blocklistedAlmsSafe_escrows_thenTimelockedMove_thenFlush() public {
        openFair();
        shot(ana, 1, 100e6);
        uint256 alms = core.almsByFair(0);
        assertGt(alms, 0);
        uint256 acc = core.accounted();
        vm.mockCallRevert(address(usdg), abi.encodeWithSelector(usdg.transfer.selector, almsSafe, alms), bytes("blocked"));
        vm.prank(almsVoteAddr);
        assertEq(core.releaseAlms(0), alms, "release does not stall");
        assertEq(core.almsByFair(0), 0);
        assertEq(core.almsEscrow(), alms);
        assertEq(core.accounted(), acc, "escrow stays accounted");
        assertEq(usdg.balanceOf(almsSafe), 0);
        vm.expectRevert(bytes("blocked"));
        core.flushAlms();
        // the Safe moves the Alms Safe in public view
        address next = makeAddr("newAlmsSafe");
        vm.startPrank(owner);
        core.queue(FairCore.Op.SetAlmsSafe, 0, next);
        vm.expectPartialRevert(FairCore.TooEarly.selector);
        core.execute(FairCore.Op.SetAlmsSafe, 0, next);
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        core.execute(FairCore.Op.SetAlmsSafe, 0, next);
        vm.stopPrank();
        vm.prank(makeAddr("anyone"));
        assertEq(core.flushAlms(), alms);
        assertEq(usdg.balanceOf(next), alms);
        assertEq(core.almsEscrow(), 0);
        assertEq(core.accounted(), acc - alms);
        assertSolvent();
        vm.expectRevert(FairCore.ZeroAmount.selector);
        core.flushAlms();
    }

    function test_unblockedIssuer_flushToSameSafe() public {
        openFair();
        shot(ana, 1, 100e6);
        uint256 alms = core.almsByFair(0);
        vm.mockCallRevert(address(usdg), abi.encodeWithSelector(usdg.transfer.selector, almsSafe, alms), bytes("blocked"));
        vm.prank(almsVoteAddr);
        core.releaseAlms(0);
        vm.clearMockedCalls();
        core.flushAlms();
        assertEq(usdg.balanceOf(almsSafe), alms);
    }

    function test_vaultAndAlmsVote_stillSetupOnly() public {
        vm.startPrank(owner);
        vm.expectRevert(FairCore.SetupOnly.selector);
        core.queue(FairCore.Op.SetVault, 0, ana);
        vm.expectRevert(FairCore.SetupOnly.selector);
        core.queue(FairCore.Op.SetAlmsVote, 0, ana);
        vm.stopPrank();
    }

    /// Fuzz: release then flush moves exactly the Alms, once, whether or not the first send fails.
    function testFuzz_releaseFlush_conserves(uint256 gross, bool blocked) public {
        gross = bound(gross, 1e6, 10_000e6);
        openFair();
        shot(ana, 1, gross);
        uint256 alms = core.almsByFair(0);
        uint256 acc = core.accounted();
        if (blocked) {
            vm.mockCallRevert(address(usdg), abi.encodeWithSelector(usdg.transfer.selector, almsSafe, alms), "b");
        }
        vm.prank(almsVoteAddr);
        core.releaseAlms(0);
        vm.clearMockedCalls();
        if (blocked) core.flushAlms();
        assertEq(usdg.balanceOf(almsSafe), alms);
        assertEq(core.accounted(), acc - alms);
        assertEq(core.almsEscrow(), 0);
        assertEq(ledgers() + core.pot(address(booth), 1), core.accounted());
        assertSolvent();
    }
}

/// K16-B-1 (late fallback) and K16-B-2 (lastMet on cancel).
contract ReviewLowsRatFixed is RatBase {
    function _four(uint256 r) internal {
        address[4] memory p = [ana, bob, cat, dan];
        uint256[4] memory ids;
        for (uint256 i; i < 4; ++i) ids[i] = regFunded(p[i], 100e6);
        toEntries(r);
        for (uint256 i; i < 4; ++i) enterAs(p[i], ids[i], r);
    }

    function _status(uint256 r) internal view returns (RobinAmongThieves.Status s) {
        (,,,,,,,,,, s,,,,,,,) = rat.rounds(r);
    }

    function test_fallbackAt8mMinus1_isRefused() public {
        uint256 r = FIRST;
        _four(r);
        vm.warp(rat.closeTime(r) + 8 minutes - 1);
        vm.expectRevert(RobinAmongThieves.WrongWindow.selector);
        rat.fallbackSeed(r);
        vm.warp(rat.closeTime(r) + 7 minutes);
        vm.expectRevert(RobinAmongThieves.WrongWindow.selector);
        rat.fallbackSeed(r);
    }

    function test_lastFallback_atT7mMinus1_canStillBeLocked() public {
        uint256 r = FIRST;
        _four(r);
        vm.warp(rat.closeTime(r) + 7 minutes - 1);
        rat.fallbackSeed(r);
        advanceL2();
        vm.warp(vm.getBlockTimestamp() + 30); // the watcher's lock lands well inside the 1 minute left
        rat.lockPairing(r);
        rat.pair(r, 1000);
        assertEq(uint8(_status(r)), uint8(RobinAmongThieves.Status.Paired));
        ledgersOk();
    }

    function test_cancelledPartialPairing_rollsBackLastMet() public {
        uint256 r = FIRST;
        _four(r);
        vm.warp(rat.closeTime(r));
        rat.revealSeed(r, chain[nextLink++]);
        advanceL2();
        rat.pair(r, 1); // one match, round still Open
        (uint256 a, uint256 b,,,,,,,) = rat.matches(r, 0);
        bytes32 k = rat.pairKey(a, b);
        assertEq(rat.lastMet(k), rat.closeTime(r));
        vm.warp(rat.closeTime(r) + 8 minutes);
        rat.cancelRound(r, 100);
        assertEq(rat.lastMet(k), 0, "never played, no cooldown");
        ledgersOk();
    }

    function test_pairedRound_keepsLastMet() public {
        uint256 r = FIRST;
        _four(r);
        vm.warp(rat.closeTime(r));
        rat.revealSeed(r, chain[nextLink++]);
        advanceL2();
        rat.pair(r, 1000);
        (uint256 a, uint256 b,,,,,,,) = rat.matches(r, 0);
        assertEq(rat.lastMet(rat.pairKey(a, b)), rat.closeTime(r));
    }
}

/// K16-C-A01: a rescue snapshots its amount; it can't be pre-armed and never moves more than it was queued for.
contract ReviewLowsRescueFixed is Test {
    MockToken t;
    FeeSplitter fs;
    address owner = makeAddr("ownerSafe");
    address ops = makeAddr("ops");
    address alt = makeAddr("alt");

    function setUp() public {
        t = new MockToken("USDG", "USDG", 6);
        fs = new FeeSplitter(
            address(new MockToken("WIF", "WIF", 18)),
            owner,
            FeeSplitter.Recipients(makeAddr("p"), makeAddr("v"), makeAddr("r"), makeAddr("b"), ops),
            FeeSplitter.FeeSplit(4000, 2500, 1500, 1000, 1000)
        );
    }

    function _escrowOps(uint256 amt) internal {
        t.mint(address(fs), amt);
        vm.mockCallRevert(address(t), abi.encodeWithSelector(IERC20.transfer.selector, ops), bytes("blocked"));
        fs.distribute(address(t));
        vm.clearMockedCalls();
    }

    function test_preArmedRescue_isRefused() public {
        vm.prank(owner);
        vm.expectRevert(FeeSplitter.BadValue.selector);
        fs.queueRescue(address(t), ops, alt, 100e6); // nothing owed yet
        vm.prank(owner);
        vm.expectRevert(FeeSplitter.BadValue.selector);
        fs.queueRescue(address(t), ops, alt, 0);
    }

    function test_laterEscrow_needsItsOwnQueue() public {
        _escrowOps(1_000e6); // 100 owed
        vm.prank(owner);
        fs.queueRescue(address(t), ops, alt, 100e6);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        _escrowOps(1_000e6); // 100 more, after the notice
        assertEq(fs.owed(address(t), ops), 200e6);
        vm.prank(owner);
        fs.executeRescue(address(t), ops, alt, 100e6);
        assertEq(t.balanceOf(alt), 100e6, "only the queued amount");
        assertEq(fs.owed(address(t), ops), 100e6);
        assertEq(fs.escrowTotal(address(t)), 100e6);
        vm.prank(owner);
        vm.expectRevert(FeeSplitter.BadValue.selector);
        fs.queueRescue(address(t), ops, alt, 100e6 + 1);
    }

    /// K16v2-01 PoC (re-check): queue 100, the recipient claims it, a new 100 is escrowed, the old ETA
    /// matures. Before the fix the old rescue moved the new escrow with no notice of its own.
    function test_K16v2_01_drainedRescue_cantTakeLaterEscrow() public {
        _escrowOps(1_000e6); // 100 owed
        vm.prank(owner);
        fs.queueRescue(address(t), ops, alt, 100e6);
        fs.claimEscrow(address(t), ops); // ops can receive again, takes its 100
        _escrowOps(1_000e6); // a new 100, after the queue
        vm.warp(vm.getBlockTimestamp() + 7 days);
        vm.prank(owner);
        vm.expectRevert(FeeSplitter.NotQueued.selector);
        fs.executeRescue(address(t), ops, alt, 100e6);
        assertEq(t.balanceOf(alt), 0);
        assertEq(fs.owed(address(t), ops), 100e6, "new escrow untouched");
        // the new escrow needs its own queue and its own 7 days
        vm.prank(owner);
        fs.queueRescue(address(t), ops, alt, 100e6);
        vm.prank(owner);
        vm.expectPartialRevert(FeeSplitter.TooEarly.selector);
        fs.executeRescue(address(t), ops, alt, 100e6);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        vm.prank(owner);
        fs.executeRescue(address(t), ops, alt, 100e6);
        assertEq(t.balanceOf(alt), 100e6);
    }

    /// A partial rescue voids nothing else of value but can't be replayed at the new epoch either.
    function test_K16v2_01_rescueBumpsEpoch() public {
        _escrowOps(2_000e6); // 200 owed
        vm.prank(owner);
        fs.queueRescue(address(t), ops, alt, 100e6);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        uint256 e0 = fs.escrowEpoch(address(t), ops);
        vm.prank(owner);
        fs.executeRescue(address(t), ops, alt, 100e6);
        assertEq(fs.escrowEpoch(address(t), ops), e0 + 1);
        vm.prank(owner);
        vm.expectRevert(FeeSplitter.NotQueued.selector);
        fs.executeRescue(address(t), ops, alt, 100e6);
        assertEq(fs.owed(address(t), ops), 100e6);
    }

    /// Fuzz: execute moves min(queued, owed now); escrow stays backed and summed.
    function testFuzz_rescueMovesAtMostQueued(uint256 a1, uint256 q, uint256 a2, bool claimFirst) public {
        a1 = bound(a1, 10, 1e30);
        a2 = bound(a2, 0, 1e30);
        _escrowOps(a1);
        uint256 owed1 = fs.owed(address(t), ops);
        q = bound(q, 1, owed1);
        vm.prank(owner);
        fs.queueRescue(address(t), ops, alt, q);
        if (a2 >= 10) _escrowOps(a2);
        if (claimFirst) fs.claimEscrow(address(t), ops); // ops unblocked meanwhile and took it all
        uint256 owedNow = fs.owed(address(t), ops);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        vm.prank(owner);
        if (claimFirst) {
            // K16v2-01: a payout voids rescues queued before it
            vm.expectRevert(FeeSplitter.NotQueued.selector);
            fs.executeRescue(address(t), ops, alt, q);
            assertEq(fs.owed(address(t), ops), owedNow);
            return;
        }
        fs.executeRescue(address(t), ops, alt, q);
        uint256 moved = q < owedNow ? q : owedNow;
        assertEq(t.balanceOf(alt), moved);
        assertEq(fs.owed(address(t), ops), owedNow - moved);
        assertEq(fs.escrowTotal(address(t)), owedNow - moved);
        assertGe(t.balanceOf(address(fs)), fs.escrowTotal(address(t)));
    }
}

contract SafeStubK {}

/// K16-A02: the mainnet stage order (minus the broadcast and the real pools), able to stop partway.
contract StagedDeployHarness is DeployBase {
    function run(address usdg, address wif, address route, address keeper, address safe, uint256 seed, uint256 stopAt)
        external
        returns (Out memory o)
    {
        vm.startPrank(msg.sender);
        o = _deployGame(usdg, wif, msg.sender, 48 hours, 7 days, 1 days);
        _give(o.config, safe);
        _give(o.pass, safe);
        _give(o.vault, safe);
        if (stopAt == 1) return _stop(o);
        o.routeA = route;
        o.rakeRouteA = route;
        _wire(o, keeper, keeper, safe, seed);
        o.core.setFair(0, uint64(block.timestamp + 1 days), uint64(block.timestamp + 6 days));
        _give(o.core, safe);
        if (stopAt == 2) return _stop(o);
        _give(o.alms, safe);
        _deployRobin(o, keeper, 48 hours, 7 days, address(0x8004), address(0x8005));
        if (stopAt == 3) return _stop(o);
        _give(o.rat, safe);
        _wireRakeBuyer(o, keeper, seed);
        _give(o.rakeBuyer, safe);
        _handOver(o, safe); // catch-all, a no-op here
        vm.stopPrank();
        _requireHandedOver(o, safe, msg.sender);
    }

    function _stop(Out memory o) internal returns (Out memory) {
        vm.stopPrank();
        return o;
    }

    function resume(Out memory o, address safe) external {
        SafeHandover[7] memory cs = _list(o);
        vm.startPrank(msg.sender);
        _resume(cs, safe, msg.sender);
        vm.stopPrank();
        _requireNoneOwned(cs, msg.sender);
    }

    function _list(Out memory o) internal pure returns (SafeHandover[7] memory) {
        return [
            SafeHandover(address(o.config)),
            SafeHandover(address(o.pass)),
            SafeHandover(address(o.core)),
            SafeHandover(address(o.alms)),
            SafeHandover(address(o.vault)),
            SafeHandover(address(o.rat)),
            SafeHandover(address(o.rakeBuyer))
        ];
    }
}

contract ReviewLowsDeployFixed is Base {
    StagedDeployHarness h;
    address deployer = makeAddr("freshDeployer");
    address safe;

    function setUp() public override {
        super.setUp();
        h = new StagedDeployHarness();
        safe = address(new SafeStubK());
    }

    function _run(uint256 stopAt) internal returns (DeployBase.Out memory o) {
        vm.startPrank(deployer);
        o = h.run(address(usdg), address(wif), address(route), keeper, safe, 781_250e30, stopAt);
        vm.stopPrank();
    }

    function test_fullStagedRun_handsAllToSafe() public {
        DeployBase.Out memory o = _run(0);
        assertEq(o.core.owner(), safe);
        assertEq(o.rakeBuyer.owner(), safe);
        assertEq(o.rat.owner(), safe);
    }

    function test_stopAfterGame_deployerHoldsOnlyCoreAndAlms_thenResume() public {
        DeployBase.Out memory o = _run(1);
        assertEq(o.config.owner(), safe, "config handed over at stage 1");
        assertEq(o.pass.owner(), safe);
        assertEq(o.vault.owner(), safe);
        assertEq(o.core.owner(), deployer);
        vm.startPrank(deployer);
        h.resume(o, safe);
        vm.stopPrank();
        assertEq(o.core.owner(), safe);
        assertEq(o.alms.owner(), safe);
    }

    function test_stopAfterRobin_resumeTakesRatAndRakeBuyer_andIsIdempotent() public {
        DeployBase.Out memory o = _run(3);
        assertEq(o.core.owner(), safe);
        assertEq(o.alms.owner(), safe);
        assertEq(o.rat.owner(), deployer);
        vm.startPrank(deployer);
        h.resume(o, safe);
        h.resume(o, safe); // a second run is a no-op
        vm.stopPrank();
        assertEq(o.rat.owner(), safe);
        assertEq(o.rakeBuyer.owner(), safe);
    }
}
