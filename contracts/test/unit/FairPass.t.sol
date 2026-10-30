// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Base} from "../Base.t.sol";
import {FairPass} from "../../src/FairPass.sol";
import {IGameConfig} from "../../src/interfaces/IFair.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockToken, FeeToken, BreakableConfig} from "../mocks/Mocks.sol";

contract FairPassTest is Base {
    function test_lock_unlock_roundTrip() public {
        uint256 before = wif.balanceOf(ana);
        vm.prank(ana);
        pass.lock(address(wif), PASS_LOCK);
        assertTrue(pass.hasPass(ana));
        assertEq(pass.heldSince(ana), T0);
        assertEq(pass.totalLocked(address(wif)), PASS_LOCK);
        assertEq(wif.balanceOf(address(pass)), PASS_LOCK);

        vm.warp(T0 + 3 days);
        vm.prank(ana);
        pass.unlock();
        assertFalse(pass.hasPass(ana));
        assertEq(pass.heldSince(ana), 0);
        assertEq(wif.balanceOf(ana), before, "exactly 5k back");
    }

    function test_cannotLockTwice_orUnlockWithout() public {
        vm.startPrank(ana);
        pass.lock(address(wif), PASS_LOCK);
        vm.expectRevert(FairPass.AlreadyLocked.selector);
        pass.lock(address(wif), PASS_LOCK);
        vm.stopPrank();
        vm.prank(bob);
        vm.expectRevert(FairPass.NoPass.selector);
        pass.unlock();
    }

    /// v3.6: no unlock before 24 hours (kills flash-loaned passes and per-second recycling of one stack).
    function test_minHold_24h() public {
        vm.prank(ana);
        pass.lock(address(wif), PASS_LOCK);
        assertEq(pass.unlockableAt(ana), T0 + 24 hours);
        vm.prank(ana);
        vm.expectRevert(abi.encodeWithSelector(FairPass.HoldNotOver.selector, T0 + 24 hours));
        pass.unlock(); // same second
        vm.warp(T0 + 24 hours - 1);
        vm.prank(ana);
        vm.expectRevert(abi.encodeWithSelector(FairPass.HoldNotOver.selector, T0 + 24 hours));
        pass.unlock();
        vm.warp(T0 + 24 hours);
        vm.prank(ana);
        pass.unlock();
        assertFalse(pass.hasPass(ana));
        assertEq(pass.unlockableAt(ana), 0);
    }

    /// The hold can't be extended by anyone: the owner has no lever, and a pause doesn't touch FairPass.
    function test_minHold_unlockWorksWhilePaused() public {
        vm.prank(ana);
        pass.lock(address(wif), PASS_LOCK);
        vm.prank(owner);
        core.pauseSales(true);
        vm.warp(T0 + 24 hours);
        vm.prank(ana);
        pass.unlock();
    }

    /// Each wallet's hold runs on its own clock: one wallet's lock never moves another's.
    function test_minHold_perWallet() public {
        vm.prank(ana);
        pass.lock(address(wif), PASS_LOCK);
        vm.warp(T0 + 10 hours);
        vm.prank(bob);
        pass.lock(address(wif), PASS_LOCK);
        vm.warp(T0 + 24 hours);
        vm.prank(ana);
        pass.unlock(); // ana's 24h are up
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(FairPass.HoldNotOver.selector, T0 + 34 hours));
        pass.unlock(); // bob's aren't
        assertEq(pass.unlockableAt(bob), T0 + 34 hours);
    }

    function test_relock_resetsHeldSince() public {
        vm.prank(ana);
        pass.lock(address(wif), PASS_LOCK);
        vm.warp(T0 + 1 days);
        vm.startPrank(ana);
        pass.unlock();
        pass.lock(address(wif), PASS_LOCK);
        vm.stopPrank();
        assertEq(pass.heldSince(ana), T0 + 1 days);
        assertEq(pass.unlockableAt(ana), T0 + 2 days, "the new lock starts a new 24h hold");
    }

    function test_ownerCanOnlySweepExcess() public {
        vm.prank(ana);
        pass.lock(address(wif), PASS_LOCK);
        vm.prank(bob);
        pass.lock(address(wif), PASS_LOCK);
        wif.mint(address(pass), 5e18); // sent by mistake
        vm.prank(owner);
        pass.sweepExcess(wif, owner);
        assertEq(wif.balanceOf(owner), 5e18);
        assertEq(wif.balanceOf(address(pass)), 2 * PASS_LOCK, "locked $wif untouched");
        vm.warp(T0 + 24 hours);
        vm.prank(ana);
        pass.unlock(); // still works
    }

    function test_renounceDisabled() public {
        vm.prank(owner);
        vm.expectRevert(FairPass.RenounceDisabled.selector);
        pass.renounceOwnership();
    }
}

/// Passes across GameConfig token updates: each lock records its own token and amount, and unlock pays exactly that.
contract FairPassTokensTest is Base {
    function test_lockedPass_afterUpdate_notCurrent_unlocksItsOwnToken() public {
        vm.prank(ana);
        pass.lock(address(wif), PASS_LOCK);
        uint256 wifBefore = wif.balanceOf(ana);
        uint256 bBefore = tokenB.balanceOf(ana);
        applyTokens(address(tokenB), 5_000e18, address(tokenB));

        assertFalse(pass.hasPass(ana), "a pass in the old play token doesn't count for play");
        assertEq(pass.heldSince(ana), T0, "lock time unchanged");
        (uint64 at, address t, uint256 amt, bool current) = pass.passOf(ana);
        assertEq(at, T0);
        assertEq(t, address(wif));
        assertEq(amt, PASS_LOCK);
        assertFalse(current);

        vm.prank(ana);
        pass.unlock();
        assertEq(wif.balanceOf(ana), wifBefore + PASS_LOCK, "exactly what was locked");
        assertEq(tokenB.balanceOf(ana), bBefore, "nothing in token B");
        assertEq(pass.totalLocked(address(wif)), 0);
        assertEq(pass.heldSince(ana), 0);
    }

    function test_totalLocked_perToken() public {
        vm.prank(ana);
        pass.lock(address(wif), PASS_LOCK);
        applyTokens(address(tokenB), 5_000e18, address(tokenB));
        vm.prank(bob);
        pass.lock(address(tokenB), 5_000e18);
        assertTrue(pass.hasPass(bob));
        assertEq(pass.totalLocked(address(wif)), PASS_LOCK);
        assertEq(pass.totalLocked(address(tokenB)), 5_000e18);
        assertEq(wif.balanceOf(address(pass)), PASS_LOCK);
        assertEq(tokenB.balanceOf(address(pass)), 5_000e18);
    }

    /// The player signed for one token and amount; if GameConfig changed before the transaction landed, nothing locks.
    function test_lock_revertsIfConfigDiffersFromWhatThePlayerSaw() public {
        applyTokens(address(tokenB), 5_000e18, address(tokenB));
        vm.startPrank(ana);
        vm.expectRevert(FairPass.TokenChanged.selector);
        pass.lock(address(wif), PASS_LOCK); // a stale page in the same block as the execute
        vm.expectRevert(FairPass.TokenChanged.selector);
        pass.lock(address(tokenB), 4_999e18); // amount above what the player allowed
        pass.lock(address(tokenB), 5_000e18); // exact
        vm.stopPrank();
        assertTrue(pass.hasPass(ana));
    }

    function test_lock_amountLowered_lowerMaxStillLocksCurrentAmount() public {
        applyTokens(address(wif), 2_500e18, address(wif));
        vm.prank(ana);
        pass.lock(address(wif), PASS_LOCK); // allowed up to 5k, locks the current 2.5k
        (,, uint256 amt,) = pass.passOf(ana);
        assertEq(amt, 2_500e18);
        assertEq(pass.totalLocked(address(wif)), 2_500e18);
    }

    function test_feeOnTransferToken_reverts() public {
        FeeToken fee = new FeeToken();
        applyTokens(address(fee), 1_000e18, address(wif));
        fee.mint(ana, 2_000e18);
        vm.startPrank(ana);
        fee.approve(address(pass), type(uint256).max);
        vm.expectRevert(FairPass.TransferMismatch.selector);
        pass.lock(address(fee), 1_000e18);
        vm.stopPrank();
        assertEq(pass.heldSince(ana), 0);
    }

    function test_sweepExcess_perToken_neverTouchesLocks() public {
        vm.prank(ana);
        pass.lock(address(wif), PASS_LOCK);
        applyTokens(address(tokenB), 5_000e18, address(tokenB));
        vm.prank(bob);
        pass.lock(address(tokenB), 5_000e18);
        wif.mint(address(pass), 7e18);
        tokenB.mint(address(pass), 3e18);
        address to = makeAddr("sweepTo");

        vm.startPrank(owner);
        pass.sweepExcess(IERC20(address(wif)), to);
        pass.sweepExcess(IERC20(address(tokenB)), to);
        pass.sweepExcess(IERC20(address(wif)), to); // nothing more to take
        vm.stopPrank();
        assertEq(wif.balanceOf(to), 7e18);
        assertEq(tokenB.balanceOf(to), 3e18);
        assertEq(wif.balanceOf(address(pass)), pass.totalLocked(address(wif)));
        assertEq(tokenB.balanceOf(address(pass)), pass.totalLocked(address(tokenB)));

        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.prank(ana);
        pass.unlock();
        vm.prank(bob);
        pass.unlock();
        assertEq(wif.balanceOf(address(pass)), 0);
        assertEq(tokenB.balanceOf(address(pass)), 0);
    }

    /// Three epochs, three lockers: each gets back their own token and amount.
    function test_threeTokens_eachLockerUnlocksTheirOwn() public {
        MockToken tokenC = new MockToken("Token C", "TKC", 18);
        tokenC.mint(cat, 1_000e18);
        vm.prank(cat);
        tokenC.approve(address(pass), type(uint256).max);

        vm.prank(ana);
        pass.lock(address(wif), PASS_LOCK);
        applyTokens(address(tokenB), 5_000e18, address(tokenB));
        vm.prank(bob);
        pass.lock(address(tokenB), 5_000e18);
        applyTokens(address(tokenC), 1_000e18, address(tokenC));
        vm.prank(cat);
        pass.lock(address(tokenC), 1_000e18);
        assertEq(config.epoch(), 2);
        assertFalse(pass.hasPass(ana));
        assertFalse(pass.hasPass(bob));
        assertTrue(pass.hasPass(cat));

        uint256[3] memory w = [wif.balanceOf(ana), tokenB.balanceOf(bob), tokenC.balanceOf(cat)];
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.prank(ana);
        pass.unlock();
        vm.prank(bob);
        pass.unlock();
        vm.prank(cat);
        pass.unlock();
        assertEq(wif.balanceOf(ana), w[0] + PASS_LOCK);
        assertEq(tokenB.balanceOf(bob), w[1] + 5_000e18);
        assertEq(tokenC.balanceOf(cat), w[2] + 1_000e18);
        assertEq(pass.totalLocked(address(wif)) + pass.totalLocked(address(tokenB)) + pass.totalLocked(address(tokenC)), 0);
    }

    /// Back to an earlier play token: passes still locked in it count again.
    function test_backToEarlierToken_oldPassCountsAgain() public {
        vm.prank(ana);
        pass.lock(address(wif), PASS_LOCK);
        applyTokens(address(tokenB), 5_000e18, address(tokenB));
        assertFalse(pass.hasPass(ana));
        applyTokens(address(wif), 20_000e18, address(wif));
        assertTrue(pass.hasPass(ana), "same token; the amount isn't re-checked");
    }

    /// unlock reads only the recorded pass: even a GameConfig that reverts can't hold funds.
    function test_unlock_neverReadsConfig() public {
        BreakableConfig bc = new BreakableConfig(address(wif), PASS_LOCK);
        FairPass p = new FairPass(IGameConfig(address(bc)), owner);
        vm.startPrank(ana);
        wif.approve(address(p), type(uint256).max);
        p.lock(address(wif), PASS_LOCK);
        vm.stopPrank();
        bc.breakIt();
        vm.expectRevert(bytes("config broken"));
        p.hasPass(ana);
        vm.warp(T0 + 1 days);
        uint256 before = wif.balanceOf(ana);
        vm.prank(ana);
        p.unlock();
        assertEq(wif.balanceOf(ana), before + PASS_LOCK);
    }

    /// Fuzz: whatever the update and its timing, a locker gets back exactly their token and amount.
    function testFuzz_unlockReturnsSnapshot(uint256 amt, uint32 lockDelay, bool sameToken) public {
        amt = bound(amt, 1, 50_000e18);
        lockDelay = uint32(bound(lockDelay, 0, 6 days));
        vm.warp(T0 + lockDelay);
        vm.prank(ana);
        pass.lock(address(wif), PASS_LOCK);
        uint256 before = wif.balanceOf(ana);
        applyTokens(sameToken ? address(wif) : address(tokenB), amt, address(tokenB));
        assertEq(pass.hasPass(ana), sameToken);
        // the update took at least the 7-day delay, so the 24h hold is long over
        vm.prank(ana);
        pass.unlock();
        assertEq(wif.balanceOf(ana), before + PASS_LOCK);
        assertEq(pass.totalLocked(address(wif)), 0);
    }
}

/// Two ERC20 facades over one ledger (a double-entry token, e.g. a legacy proxy pair).
contract SharedLedger {
    mapping(address => uint256) public bal;
    mapping(address => bool) public facade;

    function addFacade(address f) external {
        facade[f] = true;
    }

    function move(address f, address t, uint256 v) external {
        require(facade[msg.sender], "not facade");
        bal[f] -= v;
        bal[t] += v;
    }

    function mint(address t, uint256 v) external {
        bal[t] += v;
    }
}

contract Facade {
    SharedLedger public L;
    uint8 public decimals = 18;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(SharedLedger l) {
        L = l;
    }

    function balanceOf(address a) external view returns (uint256) {
        return L.bal(a);
    }

    function totalSupply() external pure returns (uint256) {
        return 0;
    }

    function approve(address s, uint256 v) external returns (bool) {
        allowance[msg.sender][s] = v;
        return true;
    }

    function transfer(address t, uint256 v) external returns (bool) {
        L.move(msg.sender, t, v);
        return true;
    }

    function transferFrom(address f, address t, uint256 v) external returns (bool) {
        L.move(f, t, v);
        return true;
    }
}

/// R1: sweepExcess must not be able to take locked principal through a second address of the same ledger.
contract FairPassSweepGuardTest is Base {
    function _alias() internal returns (SharedLedger L, Facade A, Facade B) {
        L = new SharedLedger();
        A = new Facade(L);
        B = new Facade(L);
        L.addFacade(address(A));
        L.addFacade(address(B));
        applyTokens(address(A), 1_000e18, address(wif));
        L.mint(ana, 1_000e18);
        vm.prank(ana);
        pass.lock(address(A), 1_000e18);
    }

    /// Port of test_poc_F01_aliasSweepTakesPrincipal. The sweep now reverts SweepTouchedLocks and the locker is paid.
    function test_poc_F01_aliasSweepTakesPrincipal() public {
        (SharedLedger L, Facade A, Facade B) = _alias();
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(FairPass.SweepTouchedLocks.selector, address(A)));
        pass.sweepExcess(IERC20(address(B)), owner);
        assertEq(L.bal(owner), 0, "principal not swept");
        assertEq(L.bal(address(pass)), 1_000e18);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.prank(ana);
        pass.unlock();
        assertEq(L.bal(ana), 1_000e18);
    }

    function test_sweep_cannotTakePrincipalThroughAlias() public {
        (SharedLedger L, Facade A, Facade B) = _alias();
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(FairPass.SweepTouchedLocks.selector, address(A)));
        pass.sweepExcess(IERC20(address(B)), owner);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.prank(ana);
        pass.unlock();
        assertEq(L.bal(ana), 1_000e18);
    }

    /// A normal token: excess leaves, and whatever was locked is still there afterwards.
    function testFuzz_sweepExcess_neverTouchesLocks(uint96 extra, uint8 lockers) public {
        lockers = uint8(bound(lockers, 0, 3));
        address[3] memory who = [ana, bob, cat];
        for (uint256 i; i < lockers; ++i) {
            vm.prank(who[i]);
            pass.lock(address(wif), PASS_LOCK);
        }
        wif.mint(address(pass), extra);
        address to = makeAddr("sweepTo");
        vm.prank(owner);
        pass.sweepExcess(IERC20(address(wif)), to);
        assertEq(wif.balanceOf(to), extra);
        assertEq(wif.balanceOf(address(pass)), pass.totalLocked(address(wif)));
        assertEq(pass.totalLocked(address(wif)), uint256(lockers) * PASS_LOCK);
    }
}
