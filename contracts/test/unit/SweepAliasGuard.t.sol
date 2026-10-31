// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Base} from "../Base.t.sol";
import {FairPass} from "../../src/FairPass.sol";
import {FairCore} from "../../src/FairCore.sol";
import {SharedLedger, Facade} from "./FairPass.t.sol";

/// SWEEP-01: two addresses of one ledger, both locked. Sweeping one alias used to count the other's principal as
/// excess, and the shortfall check still passed because each alias reported the shared balance against only its own
/// totalLocked. The balance snapshot now reverts SweepTouchedLocks.
contract SweepAliasGuardTest is Base {
    function _facades() internal returns (SharedLedger L, Facade A, Facade B) {
        L = new SharedLedger();
        A = new Facade(L);
        B = new Facade(L);
        L.addFacade(address(A));
        L.addFacade(address(B));
    }

    /// Both aliases locked. sweepExcess(A) reverts, and both lockers can still withdraw their principal.
    function test_bothAliasesLocked_sweepRevertsSweepTouchedLocks() public {
        (SharedLedger L, Facade A, Facade B) = _facades();
        L.mint(ana, 1_000e18);
        L.mint(bob, 1_000e18);
        applyTokens(address(A), 1_000e18, address(wif));
        vm.prank(ana);
        pass.lock(address(A), 1_000e18);
        applyTokens(address(B), 1_000e18, address(wif));
        vm.prank(bob);
        pass.lock(address(B), 1_000e18);
        assertEq(L.bal(address(pass)), 2_000e18);

        address to = makeAddr("sweepTo");
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(FairPass.SweepTouchedLocks.selector, address(B)));
        pass.sweepExcess(IERC20(address(A)), to);
        assertEq(L.bal(to), 0, "principal not swept");
        assertEq(L.bal(address(pass)), 2_000e18);

        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.prank(ana);
        pass.unlock();
        vm.prank(bob);
        pass.unlock();
        assertEq(L.bal(ana), 1_000e18);
        assertEq(L.bal(bob), 1_000e18);
    }

    /// One alias locked, the other not. Sweeping the unlocked alias still reverts (the shortfall check).
    function test_singleAliasLocked_sweepStillReverts() public {
        (SharedLedger L, Facade A, Facade B) = _facades();
        applyTokens(address(A), 1_000e18, address(wif));
        L.mint(ana, 1_000e18);
        vm.prank(ana);
        pass.lock(address(A), 1_000e18);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(FairPass.SweepTouchedLocks.selector, address(A)));
        pass.sweepExcess(IERC20(address(B)), owner);
        assertEq(L.bal(owner), 0);
        assertEq(L.bal(address(pass)), 1_000e18);

        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.prank(ana);
        pass.unlock();
        assertEq(L.bal(ana), 1_000e18);
    }

    /// A mistaken 5e18 $wif transfer is excess and leaves. A second locked token is untouched.
    function test_mistakenWif_sweepsOnlyExcess() public {
        vm.prank(ana);
        pass.lock(address(wif), PASS_LOCK);
        applyTokens(address(tokenB), 5_000e18, address(tokenB));
        vm.prank(bob);
        pass.lock(address(tokenB), 5_000e18);
        wif.mint(address(pass), 5e18);

        address to = makeAddr("sweepTo");
        vm.prank(owner);
        pass.sweepExcess(IERC20(address(wif)), to);
        assertEq(wif.balanceOf(to), 5e18, "excess");
        assertEq(wif.balanceOf(address(pass)), PASS_LOCK);
        assertEq(tokenB.balanceOf(address(pass)), 5_000e18);
        assertEq(pass.totalLocked(address(wif)), PASS_LOCK);
        assertEq(pass.totalLocked(address(tokenB)), 5_000e18);
    }

    /// A token that was never locked can be swept in full, and the pass still unlocks.
    function test_unrelatedToken_sweepWorks() public {
        vm.prank(ana);
        pass.lock(address(wif), PASS_LOCK);
        tokenB.mint(address(pass), 5e18);
        address to = makeAddr("sweepTo");
        vm.prank(owner);
        pass.sweepExcess(IERC20(address(tokenB)), to);
        assertEq(tokenB.balanceOf(to), 5e18);
        assertEq(tokenB.balanceOf(address(pass)), 0);
        assertEq(wif.balanceOf(address(pass)), PASS_LOCK);

        vm.warp(T0 + 1 days);
        uint256 before = wif.balanceOf(ana);
        vm.prank(ana);
        pass.unlock();
        assertEq(wif.balanceOf(ana), before + PASS_LOCK);
    }

    /// PAUSE-01: a zero-length pause still arms the gap. Re-pause reverts PauseTooSoon until 600s.
    function test_PAUSE01_zeroLengthPause_blocksRepauseFor600s() public {
        assertEq(core.MIN_PAUSE_GAP(), 600);
        uint256 t = vm.getBlockTimestamp();
        vm.startPrank(owner);
        core.pauseSales(true);
        core.pauseSales(false);
        vm.expectRevert(FairCore.PauseTooSoon.selector);
        core.pauseSales(true);
        vm.warp(t + 599);
        vm.expectRevert(FairCore.PauseTooSoon.selector);
        core.pauseSales(true);
        assertFalse(core.salesPaused(), "sales stay open for 599s");
        vm.warp(t + 600);
        core.pauseSales(true);
        assertTrue(core.salesPaused());
        vm.stopPrank();
    }

    /// A pause that already ran for 600s can be started again the moment it is lifted.
    function test_PAUSE01_pauseOf600s_repauseImmediate() public {
        uint256 t = vm.getBlockTimestamp();
        vm.startPrank(owner);
        core.pauseSales(true);
        vm.warp(t + 600);
        core.pauseSales(false);
        core.pauseSales(true);
        assertTrue(core.salesPaused());
        vm.stopPrank();
    }

    /// Random lock sizes and stray balances. Whatever is swept, each locker withdraws exactly what they locked.
    function testFuzz_sweepExcess_everyLockStaysWithdrawable(
        uint128 lockWif,
        uint128 lockB,
        uint96 strayWif,
        uint96 strayB,
        uint96 strayUsdg
    ) public {
        lockWif = uint128(bound(lockWif, 1, 50_000e18));
        lockB = uint128(bound(lockB, 1, 50_000e18));

        applyTokens(address(wif), lockWif, address(wif));
        vm.prank(ana);
        pass.lock(address(wif), lockWif);
        applyTokens(address(tokenB), lockB, address(tokenB));
        vm.prank(bob);
        pass.lock(address(tokenB), lockB);

        wif.mint(address(pass), strayWif);
        tokenB.mint(address(pass), strayB);
        usdg.mint(address(pass), strayUsdg);

        address to = makeAddr("sweepTo");
        vm.startPrank(owner);
        pass.sweepExcess(IERC20(address(wif)), to);
        pass.sweepExcess(IERC20(address(tokenB)), to);
        pass.sweepExcess(usdg, to);
        vm.stopPrank();

        assertEq(wif.balanceOf(to), strayWif);
        assertEq(tokenB.balanceOf(to), strayB);
        assertEq(usdg.balanceOf(to), strayUsdg);
        assertEq(wif.balanceOf(address(pass)), lockWif);
        assertEq(tokenB.balanceOf(address(pass)), lockB);

        vm.warp(vm.getBlockTimestamp() + 1 days);
        uint256 anaBefore = wif.balanceOf(ana);
        uint256 bobBefore = tokenB.balanceOf(bob);
        vm.prank(ana);
        pass.unlock();
        vm.prank(bob);
        pass.unlock();
        assertEq(wif.balanceOf(ana), anaBefore + lockWif);
        assertEq(tokenB.balanceOf(bob), bobBefore + lockB);
        assertEq(pass.totalLocked(address(wif)), 0);
        assertEq(pass.totalLocked(address(tokenB)), 0);
    }
}
