// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

// Regressions for the external review sweep of commit af57910. Each test replays that review's PoC against the fixed
// contracts: a passing test = the attack now fails (or is contained).

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Base} from "../Base.t.sol";
import {RatBase} from "../RatBase.t.sol";
import {FairCore} from "../../src/FairCore.sol";
import {RakeBuyer} from "../../src/RakeBuyer.sol";
import {AlmsVote} from "../../src/AlmsVote.sol";
import {FeeSplitter} from "../../src/FeeSplitter.sol";
import {RobinAmongThieves} from "../../src/RobinAmongThieves.sol";
import {SafeHandover} from "../../src/SafeHandover.sol";
import {IFairCore, IGameConfig} from "../../src/interfaces/IFair.sol";

/// A booth that passes an arbitrary payer (what any booth the Safe adds is able to do).
contract RogueBoothR {
    IFairCore public immutable core;

    constructor(IFairCore c) {
        core = c;
    }

    function pull(address payer, address player, uint256 key, uint256 gross) external {
        core.collect(payer, player, key, gross);
    }

    function payout(uint256 key, address[] calldata w, uint256[] calldata a) external {
        core.award(key, w, a);
    }
}

/// A USDG-like token with an issuer blocklist (USDG / Paxos-style freeze).
contract FreezableTokenR is ERC20 {
    mapping(address => bool) public frozen;

    constructor() ERC20("Global Dollar", "USDG") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 a) external {
        _mint(to, a);
    }

    function freeze(address a, bool f) external {
        frozen[a] = f;
    }

    function _update(address from, address to, uint256 v) internal override {
        require(!frozen[from] && !frozen[to], "frozen");
        super._update(from, to, v);
    }
}

/// Stands in for the owner Safe (handOver only needs a contract).
contract FakeSafeR {}

contract ReviewRegressionFairCoreTest is Base {
    address attacker = makeAddr("attacker");
    address victim = makeAddr("victim");

    function _addRogue() internal returns (RogueBoothR rogue) {
        rogue = new RogueBoothR(IFairCore(address(core)));
        vm.prank(owner);
        core.queue(FairCore.Op.AddBooth, 0, address(rogue));
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        vm.prank(owner);
        core.execute(FairCore.Op.AddBooth, 0, address(rogue));
    }

    /// A1-11: a booth added after setup can no longer pull a victim's FairCore approval; RemoveBooth switches it off.
    function test_A1_11_addedBoothCannotPullWithoutBoothApproval_andCanBeRemoved() public {
        RogueBoothR rogue = _addRogue();
        usdg.mint(victim, 10_000e6);
        vm.prank(victim);
        usdg.approve(address(core), type(uint256).max); // the site's "approve once" UX
        vm.expectRevert(FairCore.BoothNotApproved.selector);
        rogue.pull(victim, attacker, 7, 10_000e6);
        assertEq(usdg.balanceOf(victim), 10_000e6, "victim untouched");

        // the attacker paying for himself is fine (his own allowance), but can't touch anyone else
        vm.prank(owner);
        core.queue(FairCore.Op.RemoveBooth, 0, address(rogue));
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        vm.prank(owner);
        core.execute(FairCore.Op.RemoveBooth, 0, address(rogue));
        assertFalse(core.isBooth(address(rogue)), "removed");
        vm.prank(victim);
        core.approveBooth(address(rogue), type(uint256).max); // even a careless approval is now useless
        vm.expectRevert(FairCore.NotBooth.selector);
        rogue.pull(victim, attacker, 7, 1e6);
        address[] memory w = new address[](0);
        uint256[] memory a = new uint256[](0);
        vm.expectRevert(FairCore.NotBooth.selector);
        rogue.payout(7, w, a);
    }

    /// A1-12: the instant post-setup reset is gone; a queued reset far from the anchor is rejected.
    function test_A1_12_resetToTwo_isClosedAndOutOfBounds() public {
        openFair();
        shot(ana, 1, 1_000e6);
        vm.prank(owner);
        vm.expectRevert(FairCore.SetupClosed.selector);
        core.resetRatchet(2);
        vm.startPrank(owner);
        core.queue(FairCore.Op.ResetRatchet, 2, address(0));
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        vm.expectPartialRevert(FairCore.ResetOutOfBounds.selector);
        core.execute(FairCore.Op.ResetRatchet, 2, address(0));
        vm.stopPrank();
        uint256 pend = core.vaultBuyPending();
        route.setRate(1); // a drained / manipulated pool
        vm.prank(keeper);
        vm.expectRevert();
        core.buyForVault(0, pend, 1); // the floor still protects
    }

    function test_A1_12_resetHuge_isClosedAndOutOfBounds() public {
        vm.prank(owner);
        vm.expectRevert(FairCore.SetupClosed.selector);
        core.resetRatchet(type(uint128).max);
        vm.startPrank(owner);
        core.queue(FairCore.Op.ResetRatchet, type(uint128).max, address(0));
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        vm.expectPartialRevert(FairCore.ResetOutOfBounds.selector);
        core.execute(FairCore.Op.ResetRatchet, type(uint128).max, address(0));
        vm.stopPrank();
    }

    /// A1-14: handOver gives ownership straight to the Safe; the deployer keeps nothing and nothing is pending.
    function test_A1_14_handOver_leavesDeployerPowerless() public {
        address safe = address(new FakeSafeR());
        vm.prank(owner); // owner plays the deployer EOA
        core.handOver(safe);
        assertEq(core.owner(), safe);
        assertEq(core.pendingOwner(), address(0));
        vm.startPrank(owner);
        vm.expectPartialRevert(bytes4(keccak256("OwnableUnauthorizedAccount(address)")));
        core.pauseSales(true);
        vm.expectPartialRevert(bytes4(keccak256("OwnableUnauthorizedAccount(address)")));
        core.transferOwnership(owner);
        vm.stopPrank();
        // the Safe can't use the shortcut (it has code): its own transfers stay two-step
        address other = address(new FakeSafeR());
        vm.prank(safe);
        vm.expectRevert(SafeHandover.HandOverFromEoaOnly.selector);
        core.handOver(other);
    }

    function test_A1_14_handOverToEoa_reverts() public {
        vm.prank(owner);
        vm.expectRevert(SafeHandover.HandOverToContractOnly.selector);
        core.handOver(makeAddr("notASafe"));
    }

    /// K-A01: a booth can't take shots into a round it already awarded.
    function test_K_A01_collectIntoAwardedRound_reverts() public {
        openFair();
        shot(ana, 1, 10e6);
        address[] memory w = new address[](1);
        uint256[] memory a = new uint256[](1);
        w[0] = ana;
        a[0] = core.pot(address(booth), 1);
        booth.settle(1, w, a);
        vm.prank(bob);
        vm.expectRevert(FairCore.AlreadyAwarded.selector);
        booth.shot(bob, 1, 10e6);
        shot(bob, 2, 10e6); // the next round is fine
    }

    /// A6-04 / K-A02: a frozen player wallet can redirect its winnings with claimTo.
    function test_K_A02_claimTo_redirectsWinnings() public {
        openFair();
        shot(ana, 1, 100e6);
        address[] memory w = new address[](1);
        uint256[] memory a = new uint256[](1);
        w[0] = ana;
        a[0] = core.pot(address(booth), 1);
        booth.settle(1, w, a);
        address cold = makeAddr("anaCold");
        vm.mockCallRevert(address(usdg), abi.encodeWithSelector(IERC20.transfer.selector, ana), bytes("frozen"));
        vm.prank(ana);
        vm.expectRevert(bytes("frozen"));
        core.claim();
        vm.prank(ana);
        core.claimTo(cold);
        vm.clearMockedCalls();
        assertEq(usdg.balanceOf(cold), a[0]);
        assertEq(core.claimable(ana), 0);
        assertSolvent();
    }
}

contract ReviewRegressionRakeBuyerTest is Base {
    RakeBuyer rb;
    address vaultTo = makeAddr("locksleyVault");
    uint256 constant RATE = 781_250e12;

    function setUp() public override {
        super.setUp();
        rb = new RakeBuyer(usdg, IGameConfig(address(config)), vaultTo, owner, 48 hours, address(core));
        vm.startPrank(owner);
        rb.setupSet(RakeBuyer.Op.SetKeeper, 0, keeper);
        rb.setupSet(RakeBuyer.Op.SetRoute, 0, address(route));
        rb.resetRatchet(RATE * 1e18); // A1-12: the seed only goes in before finishSetup now
        rb.finishSetup();
        vm.stopPrank();
    }

    /// A3-19: the keeper can no longer push ~1,450 USDG a day; DAILY_BUY_CAP stops it at 500.
    function test_A3_19_dailyCapStopsTheEleventhBuy() public {
        usdg.mint(address(rb), 10_000e6);
        uint256 dayStart = (vm.getBlockTimestamp() / 1 days + 1) * 1 days;
        uint256 t = dayStart;
        vm.warp(t);
        uint256 spent;
        for (uint256 i; i < 10; ++i) {
            vm.prank(keeper);
            rb.buy(0, 50e6, 50e6 * RATE * 95 / 100);
            spent += 50e6;
            t += 50 minutes;
            vm.warp(t);
        }
        assertEq(spent, rb.DAILY_BUY_CAP());
        vm.prank(keeper);
        vm.expectRevert(RakeBuyer.DailyCap.selector);
        rb.buy(0, 50e6, 50e6 * RATE * 95 / 100);
        vm.prank(keeper);
        vm.expectRevert(RakeBuyer.DailyCap.selector);
        rb.buy(0, 1, 1); // not even 1 unit
        vm.warp(dayStart + 1 days); // the next UTC day resets
        vm.prank(keeper);
        rb.buy(0, 50e6, 50e6 * RATE * 95 / 100);
        assertEq(rb.boughtOnDay((dayStart + 1 days) / 1 days), 50e6);
    }

    function test_A1_12_rakeBuyer_resetToTwo_isClosedAndOutOfBounds() public {
        vm.prank(owner);
        vm.expectRevert(RakeBuyer.SetupClosed.selector);
        rb.resetRatchet(2);
        vm.startPrank(owner);
        rb.queue(RakeBuyer.Op.ResetRatchet, 2, address(0));
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        vm.expectPartialRevert(RakeBuyer.ResetOutOfBounds.selector);
        rb.execute(RakeBuyer.Op.ResetRatchet, 2, address(0));
        vm.stopPrank();
    }

    /// K-C01: a blocklisted vault no longer strands the bought token; the USDG leg waits and can go to a timelocked
    /// alternate recipient.
    function test_K_C01_vaultBlocklisted_tokenForwards_legWaitsForAlternate() public {
        usdg.mint(address(rb), 100e6);
        vm.prank(keeper);
        rb.buy(0, 40e6, 40e6 * RATE * 95 / 100);
        address w = rb.buyToken();
        uint256 held = IERC20(w).balanceOf(address(rb));
        assertGt(held, 0);
        vm.mockCallRevert(address(usdg), abi.encodeWithSelector(IERC20.transfer.selector, vaultTo), bytes("blocked"));
        vm.expectEmit(true, true, true, true, address(rb));
        emit RakeBuyer.ForwardFailed(w, address(usdg), vaultTo, 40e6);
        rb.forwardToken(w);
        assertEq(IERC20(w).balanceOf(vaultTo), held, "the bought token is not stranded");
        assertEq(rb.bought(w), 0);
        assertEq(rb.spentOf(w), 40e6, "the leg stays ledgered");
        assertEq(rb.totalSpent(), 40e6);
        // nothing left that can move: reverts instead of a no-op
        vm.expectRevert(RakeBuyer.NothingToForward.selector);
        rb.forwardToken(w);

        address alt = makeAddr("altVault");
        vm.startPrank(owner);
        rb.queue(RakeBuyer.Op.SetForwardTo, 0, alt);
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        rb.execute(RakeBuyer.Op.SetForwardTo, 0, alt);
        vm.stopPrank();
        assertEq(rb.recipient(), alt);
        rb.forwardToken(w);
        vm.clearMockedCalls();
        assertEq(usdg.balanceOf(alt), 40e6, "leg reaches the alternate recipient");
        assertEq(rb.spentOf(w), 0);
        assertEq(rb.totalSpent(), 0);
        assertGe(usdg.balanceOf(address(rb)), rb.buyPending() + rb.legPending());
    }

    /// K-C02: an incomplete reconcile list is rejected; the complete one repairs and the forward works.
    function test_K_C02_reconcileIncompleteList_rejected() public {
        usdg.mint(address(rb), 100e6); // buyPending 50, legPending 50
        vm.prank(keeper);
        rb.buy(0, 40e6, 40e6 * RATE * 95 / 100); // buyPending 10, spentOf 40, balance 60
        address w = rb.buyToken();
        deal(address(usdg), address(rb), 35e6); // issuer seizes 25
        address[] memory none = new address[](0);
        vm.prank(owner);
        vm.expectRevert(RakeBuyer.BadTokens.selector);
        rb.reconcile(none);
        address[] memory list = new address[](1);
        list[0] = w;
        vm.prank(owner);
        rb.reconcile(list);
        assertEq(rb.buyPending(), 0);
        assertEq(rb.legPending(), 35e6);
        assertEq(rb.spentOf(w), 35e6);
        assertEq(rb.totalSpent(), 35e6);
        rb.forwardToken(w); // no underflow
        assertEq(usdg.balanceOf(vaultTo), 35e6);
        assertEq(rb.legPending(), 0);
        assertEq(rb.totalSpent(), 0);
    }
}

contract ReviewRegressionFeeSplitterTest is Test {
    FreezableTokenR usdgF;
    FeeSplitter fs;
    address owner = makeAddr("ownerSafe");
    address purses = makeAddr("purses");
    address vault = makeAddr("vault");
    address rebate = makeAddr("rebate");
    address burnBuyer = makeAddr("burnBuyer");
    address ops = makeAddr("ops");
    address newOps = makeAddr("newOps");

    function setUp() public {
        usdgF = new FreezableTokenR();
        fs = new FeeSplitter(
            address(new FreezableTokenR()),
            owner,
            FeeSplitter.Recipients(purses, vault, rebate, burnBuyer, ops),
            FeeSplitter.FeeSplit(4000, 2500, 1500, 1000, 1000),
            makeAddr("fairCore"),
            makeAddr("rakeBuyer")
        );
    }

    /// A3-09: one frozen recipient no longer blocks the other four legs for the 7-day timelock.
    function test_A3_09_oneFrozenRecipient_othersPaid_legEscrowed_rescued() public {
        usdgF.mint(address(fs), 1_000e6);
        usdgF.freeze(ops, true);
        fs.distribute(address(usdgF));
        assertEq(usdgF.balanceOf(purses), 400e6);
        assertEq(usdgF.balanceOf(vault), 250e6);
        assertEq(usdgF.balanceOf(rebate), 150e6);
        assertEq(usdgF.balanceOf(burnBuyer), 100e6);
        assertEq(fs.owed(address(usdgF), ops), 100e6);
        assertEq(fs.escrowTotal(address(usdgF)), 100e6);
        // the escrow is not split again
        vm.expectRevert(FeeSplitter.ZeroAmount.selector);
        fs.distribute(address(usdgF));
        // a retry to the frozen recipient fails and keeps the escrow
        vm.expectRevert(bytes("frozen"));
        fs.claimEscrow(address(usdgF), ops);
        // the Safe moves it after the timelock
        vm.prank(owner);
        fs.queueRescue(address(usdgF), ops, newOps, 100e6);
        vm.prank(owner);
        vm.expectPartialRevert(FeeSplitter.TooEarly.selector);
        fs.executeRescue(address(usdgF), ops, newOps, 100e6);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        vm.prank(makeAddr("stranger"));
        vm.expectPartialRevert(bytes4(keccak256("OwnableUnauthorizedAccount(address)")));
        fs.executeRescue(address(usdgF), ops, newOps, 100e6);
        vm.prank(owner);
        fs.executeRescue(address(usdgF), ops, newOps, 100e6);
        assertEq(usdgF.balanceOf(newOps), 100e6);
        assertEq(fs.escrowTotal(address(usdgF)), 0);
        assertEq(usdgF.balanceOf(address(fs)), 0);
    }

    /// A3-10: the splitter itself frozen still can't be rescued on-chain, but distribute no longer reverts and
    /// the legs are escrowed; once the issuer unfreezes, each recipient's escrow can be claimed.
    function test_A3_10_splitterItselfFrozen_escrows_thenClaimAfterUnfreeze() public {
        usdgF.mint(address(fs), 1_000e6);
        usdgF.freeze(address(fs), true);
        fs.distribute(address(usdgF));
        assertEq(fs.escrowTotal(address(usdgF)), 1_000e6);
        assertEq(usdgF.balanceOf(address(fs)), 1_000e6);
        usdgF.freeze(address(fs), false);
        fs.claimEscrow(address(usdgF), purses);
        fs.claimEscrow(address(usdgF), vault);
        assertEq(usdgF.balanceOf(purses), 400e6);
        assertEq(usdgF.balanceOf(vault), 250e6);
        assertEq(fs.escrowTotal(address(usdgF)), 350e6);
    }
}

contract ReviewRegressionAlmsVoteTest is Base {
    AlmsVote alms;
    address funder = makeAddr("funder");
    bytes32 constant GOOD = keccak256("good-charity");
    bytes32 constant SYBIL = keccak256("attacker-picked");

    function setUp() public override {
        super.setUp();
        alms = new AlmsVote(IFairCore(address(core)), owner, 24 hours, 24 hours);
        bytes32[] memory ids = new bytes32[](2);
        (ids[0], ids[1]) = (GOOD, SYBIL);
        vm.prank(owner);
        alms.setEligible(ids);
        fund(funder);
    }

    /// A5-01: 1-USDG sybils can no longer suggest or vote; the honest players (5 USDG or more) still decide.
    function test_A5_01_oneUsdgSybils_cantVote() public {
        address[3] memory honest = [ana, bob, cat];
        for (uint256 i; i < 3; ++i) lockPass(honest[i]);
        uint256 N = 10;
        address[] memory s = new address[](N);
        for (uint256 i; i < N; ++i) {
            s[i] = makeAddr(string(abi.encodePacked("sybil", vm.toString(i))));
            vm.prank(funder);
            wif.transfer(s[i], PASS_LOCK);
            vm.prank(s[i]);
            wif.approve(address(pass), type(uint256).max);
            lockPass(s[i]);
        }
        openFair();
        for (uint256 i; i < 3; ++i) shot(honest[i], 1, 5e6);
        for (uint256 i; i < N; ++i) {
            vm.prank(funder);
            booth.shot(s[i], 1, 1e6);
        }
        uint64 ss = uint64(vm.getBlockTimestamp() + 1 days);
        vm.prank(owner);
        alms.setAlmsWindows(0, ss, ss + 1 days, ss + 2 days);
        vm.warp(ss);
        vm.prank(ana);
        alms.suggest(0, GOOD);
        vm.prank(s[0]);
        vm.expectRevert(abi.encodeWithSelector(AlmsVote.BelowMinSpend.selector, 1e6, 5e6));
        alms.suggest(0, SYBIL);
        vm.prank(bob);
        alms.suggest(0, SYBIL); // a real player suggests it, so the sybils have something to vote for
        vm.warp(ss + 1 days);
        for (uint256 i; i < 2; ++i) {
            vm.prank(honest[i]);
            alms.vote(0, GOOD);
        }
        for (uint256 i; i < N; ++i) {
            vm.prank(s[i]);
            vm.expectRevert(abi.encodeWithSelector(AlmsVote.BelowMinSpend.selector, 1e6, 5e6));
            alms.vote(0, SYBIL);
        }
        vm.warp(ss + 2 days);
        alms.finalize(0);
        (,,,,, bytes32 winner,) = alms.results(0);
        assertEq(winner, GOOD, "sybils no longer pick the charity");
    }
}

contract ReviewRegressionRatTest is RatBase {
    function _status(uint256 r) internal view returns (RobinAmongThieves.Status s) {
        (,,,,,,,,,, s,,,,,,,) = rat.rounds(r);
    }

    /// A2-13: a withheld seed no longer cancels the round. After T+3m anyone seeds it from the entrants and a
    /// future block hash; the round pairs, and it cannot be cancelled before T+8m.
    function test_A2_13_keeperWithholdsSeed_roundStillPlays() public {
        uint256 a = regFunded(ana, 100e6);
        uint256 b = regFunded(bob, 100e6);
        uint256 r = FIRST;
        toEntries(r);
        enterAs(ana, a, r);
        enterAs(bob, b, r);
        vm.warp(rat.closeTime(r) + 3 minutes); // keeper never calls revealSeed
        vm.expectRevert(RobinAmongThieves.WrongStatus.selector);
        rat.pair(r, 1000);
        vm.expectRevert(RobinAmongThieves.WrongWindow.selector);
        rat.cancelRound(r, 100); // no veto by timeout before T+8m
        rat.fallbackSeed(r);
        advanceL2();
        rat.lockPairing(r);
        rat.pair(r, 1000);
        assertEq(uint8(_status(r)), uint8(RobinAmongThieves.Status.Paired));
        assertEq(openRoundOf(a), r, "still in the round");
        vm.warp(rat.closeTime(r) + 9 minutes);
        vm.expectRevert(RobinAmongThieves.WrongStatus.selector);
        rat.cancelRound(r, 100);
        ledgersOk();
    }
}
