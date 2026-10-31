// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {RatBase} from "../RatBase.t.sol";
import {RobinAmongThieves} from "../../src/RobinAmongThieves.sol";
import {MockArbSys} from "../mocks/Mocks.sol";

contract RatMixAudit is RatBase {
    uint256 constant H = 8;
    uint256 constant K = 3;
    uint256[] ids;
    address[] ws;
    uint256[] cx;
    address[] cw;

    function setUp() public override {
        super.setUp();
        for (uint256 i; i < H; ++i) {
            ws.push(address(uint160(0x70000 + i)));
            ratFund(ws[i]);
            ids.push(regFunded(ws[i], 50e6));
        }
        for (uint256 i; i < K; ++i) {
            cw.push(address(uint160(0x7BAD0 + i)));
            ratFund(cw[i]);
            cx.push(regFunded(cw[i], 50e6));
        }
    }

    function arb() internal pure returns (MockArbSys) {
        return MockArbSys(address(0x64));
    }

    function _enterAll(uint256[] memory order) internal {
        toEntries(FIRST);
        for (uint256 i; i < H; ++i) {
            enterAs(ws[i], ids[i], FIRST);
        }
        for (uint256 i; i < order.length; ++i) {
            enterAs(cw[order[i]], cx[order[i]], FIRST);
        }
        vm.warp(rat.closeTime(FIRST));
    }

    function _fingerprint() internal view returns (bytes32 f) {
        for (uint256 i; i < H; ++i) {
            f = keccak256(abi.encode(f, rat.matchOf(FIRST, ids[i])));
        }
        for (uint256 i; i < K; ++i) {
            f = keccak256(abi.encode(f, rat.matchOf(FIRST, cx[i])));
        }
    }

    function _all() internal pure returns (uint256[] memory o) {
        o = new uint256[](3);
        (o[0], o[1], o[2]) = (0, 1, 2);
    }

    /// Revealing and pairing in the same L2 block never mixes a hash: pair reverts.
    function test_samePairBlockReverts() public {
        _enterAll(_all());
        rat.revealSeed(FIRST, chain[1]);
        vm.expectRevert(RobinAmongThieves.SeedHashUnavailable.selector);
        rat.pair(FIRST, 1000);
    }

    /// The XOR accumulator ignores entry order. The shuffle still walks `entrants` in entry order,
    /// so the same subset in another order is not the same pairing.
    function test_xorIgnoresOrder_shuffleUsesEntryArray() public {
        uint256 s = vm.snapshotState();
        _enterAll(_all());
        uint256 rb = arb().n();
        rat.revealSeed(FIRST, chain[1]);
        arb().setHash(rb, keccak256("H"));
        advanceL2();
        (bytes32 accA,,,,,,,,,,,,,,,,,) = rat.rounds(FIRST);
        rat.pair(FIRST, 1000);
        bytes32 pairA = _fingerprint();
        vm.revertToState(s);
        uint256[] memory o = new uint256[](3);
        (o[0], o[1], o[2]) = (2, 0, 1);
        _enterAll(o);
        rat.revealSeed(FIRST, chain[1]);
        arb().setHash(rb, keccak256("H"));
        advanceL2();
        (bytes32 accB,,,,,,,,,,,,,,,,,) = rat.rounds(FIRST);
        assertEq(accB, accA, "XOR accumulator ignores order");
        rat.pair(FIRST, 1000);
        assertTrue(_fingerprint() != pairA, "shuffle walks entrants in entry order");
    }

    /// The hash matters: same entrants, different reveal-block hash => pairing changes (for some hash).
    function test_hashChangesPairing() public {
        uint256 s = vm.snapshotState();
        _enterAll(_all());
        uint256 rb = arb().n();
        rat.revealSeed(FIRST, chain[1]);
        arb().setHash(rb, keccak256("H0"));
        advanceL2();
        rat.pair(FIRST, 1000);
        bytes32 a = _fingerprint();
        uint256 differ;
        for (uint256 j = 1; j < 6; ++j) {
            vm.revertToState(s);
            s = vm.snapshotState();
            _enterAll(_all());
            rat.revealSeed(FIRST, chain[1]);
            arb().setHash(rb, keccak256(abi.encode("H", j)));
            advanceL2();
            rat.pair(FIRST, 1000);
            if (_fingerprint() != a) ++differ;
        }
        assertGt(differ, 3);
    }

    /// Mixed exactly once: pairing in batches across many blocks (even past the 256-block window) equals a
    /// single-call pairing.
    function test_mixOnce_batchedEqualsSingle() public {
        uint256 s = vm.snapshotState();
        _enterAll(_all());
        uint256 rb = arb().n();
        rat.revealSeed(FIRST, chain[1]);
        arb().setHash(rb, keccak256("H"));
        advanceL2();
        rat.pair(FIRST, 1000);
        bytes32 a = _fingerprint();
        vm.revertToState(s);
        _enterAll(_all());
        rat.revealSeed(FIRST, chain[1]);
        arb().setHash(rb, keccak256("H"));
        advanceL2();
        rat.pair(FIRST, 0); // zero steps still mixes
        arb().set(arb().n() + 300);
        arb().setHash(rb, keccak256("OTHER")); // must not be re-read
        uint256 calls;
        for (uint256 i; i < 40; ++i) {
            try rat.pair(FIRST, 1) {
                ++calls;
            } catch {
                break;
            }
            arb().set(arb().n() + 1);
        }
        assertGt(calls, 3);
        assertEq(_fingerprint(), a);
    }

    /// 257 blocks after the reveal: pair reverts, round cancels cleanly, every stake is refunded.
    function test_windowExpiry_cleanCancel() public {
        uint256 free0 = rat.freeBalances();
        uint256 res0 = rat.reservedStakes();
        _enterAll(_all());
        rat.revealSeed(FIRST, chain[1]);
        arb().set(arb().n() + 257);
        vm.expectRevert(RobinAmongThieves.SeedHashUnavailable.selector);
        rat.pair(FIRST, 1000);
        vm.expectRevert(); // too early to cancel
        rat.cancelRound(FIRST, 1000);
        vm.warp(rat.closeTime(FIRST) + 8 minutes);
        rat.cancelRound(FIRST, 1000);
        assertEq(rat.freeBalances(), free0);
        assertEq(rat.reservedStakes(), res0);
        for (uint256 i; i < H; ++i) {
            assertEq(openRoundOf(ids[i]), 0);
        }
        for (uint256 i; i < K; ++i) {
            assertEq(openRoundOf(cx[i]), 0);
        }
    }

    function test_window256_ok() public {
        _enterAll(_all());
        rat.revealSeed(FIRST, chain[1]);
        arb().set(arb().n() + 256);
        rat.pair(FIRST, 1000);
        (,,,,,, uint32 matches,,,,,,,,,,, bool seedMixed) = rat.rounds(FIRST);
        assertTrue(seedMixed);
        assertGt(matches, 0);
    }
}
