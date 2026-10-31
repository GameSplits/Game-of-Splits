// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {RatBase} from "../RatBase.t.sol";
import {RobinAmongThieves} from "../../src/RobinAmongThieves.sol";
import {IIdentityRegistry} from "../../src/interfaces/I8004.sol";

/// An outlaw that approves RAT on its own ERC-8004 identity makes the registry refuse RAT's write as self-feedback.
/// Settle must not let that hide a steal: a non-share payout whose write was refused that way goes to the Sharing
/// Pot. A plain registry outage (no approval) still pays as before, and a broken identity registry never blocks settle.
contract RatSelfApprovalTest is RatBase {
    RobinAmongThieves.Choice constant SH = RobinAmongThieves.Choice.Share;
    RobinAmongThieves.Choice constant ST = RobinAmongThieves.Choice.Steal;
    RobinAmongThieves.Choice constant NO = RobinAmongThieves.Choice.None;

    function _play(RobinAmongThieves.Choice ca, RobinAmongThieves.Choice cb)
        internal
        returns (uint256 a, uint256 b, uint256 r)
    {
        a = regFunded(ana, 50e6);
        b = regFunded(bob, 50e6);
        r = FIRST;
        toEntries(r);
        enterAs(ana, a, r);
        enterAs(bob, b, r);
        seedPair(r);
        if (ca != NO) commitAs(ana, a, r, ca);
        if (cb != NO) commitAs(bob, b, r, cb);
        if (ca != NO) revealAs(ana, a, r, ca);
        if (cb != NO) revealAs(bob, b, r, cb);
        toSettle(r);
    }

    function _approve(address who, uint256 id) internal {
        vm.prank(who);
        idr.approve(address(rat), id);
    }

    // ---------------------------------------------------------------- the steal can't be hidden

    function test_selfApprovedThief_forfeitsFullToPot() public {
        (uint256 a, uint256 b, uint256 r) = _play(ST, SH);
        _approve(ana, a);
        uint256 ba = bal(a);
        uint256 bb = bal(b);
        uint256 pot = rat.sharingPot();
        rat.settle(r, 1000);
        assertEq(rep.count(a, address(rat)), 0, "write still refused by the registry");
        assertEq(rep.count(b, address(rat)), 1, "victim's share recorded");
        assertEq(bal(a), ba, "thief paid nothing");
        assertEq(bal(b), bb, "victim unchanged");
        assertEq(rat.sharingPot() - pot, 9_500_000 + 200_000, "FULL went to the pot");
        ledgersOk();
    }

    /// Approving before entering is not refused at enter, and still forfeits at settle.
    function test_approveBeforeEnter_stillForfeitsAtSettle() public {
        uint256 a = regFunded(ana, 50e6);
        uint256 b = regFunded(bob, 50e6);
        uint256 r = FIRST;
        _approve(ana, a);
        toEntries(r);
        enterAs(ana, a, r);
        assertEq(openRoundOf(a), r);
        enterAs(bob, b, r);
        seedPair(r);
        commitAs(ana, a, r, ST);
        commitAs(bob, b, r, SH);
        revealAs(ana, a, r, ST);
        revealAs(bob, b, r, SH);
        toSettle(r);
        uint256 ba = bal(a);
        rat.settle(r, 1000);
        assertEq(bal(a), ba);
        ledgersOk();
    }

    function test_thiefPaidWhenWriteLands() public {
        (uint256 a,, uint256 r) = _play(ST, SH);
        uint256 ba = bal(a);
        rat.settle(r, 1000);
        assertEq(rep.count(a, address(rat)), 1);
        assertEq(bal(a) - ba, 9_500_000, "unchanged behaviour");
        ledgersOk();
    }

    function test_sharerStillPaidWhenWriteRefused() public {
        (uint256 a, uint256 b, uint256 r) = _play(SH, SH);
        _approve(ana, a);
        _approve(bob, b);
        uint256 ba = bal(a);
        uint256 bb = bal(b);
        rat.settle(r, 1000);
        assertEq(bal(a) - ba, 4_750_000);
        assertEq(bal(b) - bb, 4_750_000);
        ledgersOk();
    }

    function test_noRevealForfeitsWhenWriteRefused() public {
        (uint256 a, uint256 b, uint256 r) = _play(NO, NO);
        _approve(ana, a);
        uint256 ba = bal(a);
        uint256 bb = bal(b);
        rat.settle(r, 1000);
        assertEq(bal(a), ba, "non-revealer with a refused write forfeits HALF");
        assertEq(bal(b) - bb, 4_750_000);
        ledgersOk();
    }

    // ---------------------------------------------------------------- registry outage

    function test_registryRevertsWhileApproved_thiefForfeits() public {
        (uint256 a, uint256 b, uint256 r) = _play(ST, SH);
        _approve(ana, a);
        rep.setMode(1); // every write reverts
        uint256 ba = bal(a);
        uint256 bb = bal(b);
        uint256 pot = rat.sharingPot();
        rat.settle(r, 1000);
        assertEq(rep.writes(), 0);
        assertEq(bal(a), ba, "approved thief forfeits FULL during an outage");
        assertEq(bal(b), bb);
        assertEq(rat.sharingPot() - pot, 9_500_000 + 200_000);
        ledgersOk();
    }

    function test_registryRevertsWhileApproved_sharerStillPaid() public {
        (uint256 a, uint256 b, uint256 r) = _play(SH, SH);
        _approve(ana, a);
        vm.prank(bob);
        idr.setApprovalForAll(address(rat), true);
        rep.setMode(1);
        uint256 ba = bal(a);
        uint256 bb = bal(b);
        rat.settle(r, 1000);
        assertEq(bal(a) - ba, 4_750_000);
        assertEq(bal(b) - bb, 4_750_000);
        ledgersOk();
    }

    function test_registryRevertsUnapproved_thiefPaid() public {
        (uint256 a,, uint256 r) = _play(ST, SH);
        rep.setMode(1);
        uint256 ba = bal(a);
        rat.settle(r, 1000);
        assertEq(bal(a) - ba, 9_500_000, "an outage alone forfeits nothing");
        ledgersOk();
    }

    function test_registryBurnsGasWhileApproved_forfeits() public {
        (uint256 a,, uint256 r) = _play(ST, SH);
        _approve(ana, a);
        rep.setMode(2);
        uint256 ba = bal(a);
        rat.settle(r, 1000);
        assertEq(bal(a), ba);
        ledgersOk();
    }

    // ---------------------------------------------------------------- approval variants

    function test_setApprovalForAll_forfeits() public {
        (uint256 a,, uint256 r) = _play(ST, SH);
        vm.prank(ana);
        idr.setApprovalForAll(address(rat), true);
        uint256 ba = bal(a);
        rat.settle(r, 1000);
        assertEq(rep.count(a, address(rat)), 0);
        assertEq(bal(a), ba);
        ledgersOk();
    }

    function test_transferIdentityToRat_forfeits() public {
        (uint256 a,, uint256 r) = _play(ST, SH);
        vm.prank(ana);
        idr.transferFrom(ana, address(rat), a); // plain transfer, no receiver hook
        uint256 ba = bal(a);
        rat.settle(r, 1000);
        assertEq(rep.count(a, address(rat)), 0);
        assertEq(bal(a), ba, "RAT owns the identity, so the write is refused and the payout forfeited");
        ledgersOk();
    }

    /// The thief settles itself: approve, settle, revoke. Approval is read inside settle.
    function test_atomicApproveSettleRevoke_forfeits() public {
        (uint256 a,, uint256 r) = _play(ST, SH);
        uint256 ba = bal(a);
        vm.startPrank(ana);
        idr.approve(address(rat), a);
        rat.settle(r, 1000);
        idr.approve(address(0), a);
        vm.stopPrank();
        assertEq(bal(a), ba);
        ledgersOk();
    }

    /// Revoking before settle lets the write land: the thief is paid and the steal is recorded.
    function test_approveThenRevokeBeforeSettle_recorded() public {
        uint256 a = regFunded(ana, 50e6);
        uint256 b = regFunded(bob, 50e6);
        uint256 r = FIRST;
        _approve(ana, a);
        toEntries(r);
        enterAs(ana, a, r);
        enterAs(bob, b, r);
        seedPair(r);
        commitAs(ana, a, r, ST);
        commitAs(bob, b, r, SH);
        revealAs(ana, a, r, ST);
        revealAs(bob, b, r, SH);
        vm.prank(ana);
        idr.approve(address(0), a);
        toSettle(r);
        uint256 ba = bal(a);
        rat.settle(r, 1000);
        assertEq(rep.count(a, address(rat)), 1, "steal recorded");
        assertEq(rep.lastValue(a), 0);
        assertEq(bal(a) - ba, 9_500_000);
    }

    // ---------------------------------------------------------------- settle gas limit can't be used to escape

    /// Sweeps the settle gas limit. An escape = settle succeeds, the thief's record is missing, and it got paid.
    function _sweep(bool thiefIsAna, uint8 mode, uint256 step)
        internal
        returns (uint256 succ, uint256 escaped, uint256 minOk)
    {
        (uint256 a, uint256 b, uint256 r) = thiefIsAna ? _play(ST, SH) : _play(SH, ST);
        uint256 t = thiefIsAna ? a : b;
        vm.prank(thiefIsAna ? ana : bob);
        idr.approve(address(rat), t);
        if (mode != 0) rep.setMode(mode);
        uint256 bt = bal(t);
        uint256 snap = vm.snapshotState();
        for (uint256 g = 200_000; g <= 900_000; g += step) {
            (bool ok,) = address(rat).call{gas: g}(abi.encodeCall(rat.settle, (r, 1000)));
            if (ok) {
                succ++;
                if (minOk == 0) minOk = g;
                if (rep.count(t, address(rat)) == 0 && bal(t) > bt) escaped++;
            }
            vm.revertToState(snap);
        }
    }

    function test_gasSweep_thiefA_cannotEscape() public {
        (uint256 s, uint256 esc, uint256 m) = _sweep(true, 0, 250);
        emit log_named_uint("successful gas limits", s);
        emit log_named_uint("min successful gas", m);
        assertGt(s, 0);
        assertEq(esc, 0, "gas limit let the thief escape");
    }

    function test_gasSweep_thiefB_cannotEscape() public {
        (uint256 s, uint256 esc, uint256 m) = _sweep(false, 0, 250);
        emit log_named_uint("successful gas limits", s);
        emit log_named_uint("min successful gas", m);
        assertGt(s, 0);
        assertEq(esc, 0, "gas limit let the thief escape");
    }

    /// Info: the registry itself burns its whole write budget (an outage, not something a player can cause).
    function test_gasSweep_thiefB_registryBurnsGas_info() public {
        (uint256 s, uint256 esc, uint256 m) = _sweep(false, 2, 2_500);
        emit log_named_uint("successful gas limits", s);
        emit log_named_uint("min successful gas", m);
        emit log_named_uint("limits where an approved thief kept its payout", esc);
    }

    // ---------------------------------------------------------------- broken identity registry never blocks settle

    function test_identityReverts_noForfeit_settles() public {
        (uint256 a,, uint256 r) = _play(ST, SH);
        vm.mockCallRevert(address(idr), abi.encodeWithSelector(IIdentityRegistry.isAuthorizedOrOwner.selector), "x");
        uint256 ba = bal(a);
        rat.settle(r, 1000);
        assertEq(bal(a) - ba, 9_500_000);
        ledgersOk();
    }

    function test_identityReturnsEmpty_noForfeit_settles() public {
        (uint256 a,, uint256 r) = _play(ST, SH);
        _approve(ana, a);
        vm.mockCall(address(idr), abi.encodeWithSelector(IIdentityRegistry.isAuthorizedOrOwner.selector), "");
        uint256 ba = bal(a);
        rat.settle(r, 1000);
        assertEq(bal(a) - ba, 9_500_000, "fail-open: no forfeit, settle continues");
        ledgersOk();
    }

    function test_identityReturnsGarbage_noForfeit_settles() public {
        (uint256 a,, uint256 r) = _play(ST, SH);
        _approve(ana, a);
        vm.mockCall(
            address(idr), abi.encodeWithSelector(IIdentityRegistry.isAuthorizedOrOwner.selector), abi.encode(uint256(2))
        );
        uint256 ba = bal(a);
        rat.settle(r, 1000);
        assertEq(bal(a) - ba, 9_500_000, "only an exact true forfeits");
        ledgersOk();
    }
}
