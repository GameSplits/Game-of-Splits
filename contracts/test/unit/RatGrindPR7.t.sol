// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {RatBase} from "../RatBase.t.sol";
import {RobinAmongThieves} from "../../src/RobinAmongThieves.sol";

/// RAT-01 regression: fixed nonces are not enough. Choosing which outlaws enter, and in what order, used to
/// grind the pairing because the keeper knows the seed. The reveal-block hash is not available in that search.
contract RatGrindPR7 is RatBase {
    /// The original free-entropy grind finding is rejected.
    function test_freeEntropyGrind_nowReverts() public {
        address colluder = address(0x7BAD);
        ratFund(colluder);
        uint256 x = regFunded(colluder, 50e6);
        toEntries(FIRST);
        vm.prank(colluder);
        vm.expectRevert(RobinAmongThieves.BadEntropy.selector);
        rat.enter(x, FIRST, keccak256(abi.encode("grind", uint256(0))));
    }

    /// The keeper knows the seed and tries ordered subsets of its outlaws. Each attempt reveals, steps one L2
    /// block, and pairs. Pairing must actually finish, and the seed must be the one mixed with the reveal-block hash.
    function test_keeperGrindsBySubsetAndOrder_pairingUsesMixedHash() public {
        uint256 H = 8;
        uint256[] memory ids = new uint256[](H);
        address[] memory ws = new address[](H);
        for (uint256 i; i < H; ++i) {
            ws[i] = address(uint160(0x70000 + i));
            ratFund(ws[i]);
            ids[i] = regFunded(ws[i], 50e6);
        }
        uint256 K = 3;
        address[] memory cw = new address[](K);
        uint256[] memory cx = new uint256[](K);
        for (uint256 i; i < K; ++i) {
            cw[i] = address(uint160(0x7BAD0 + i));
            ratFund(cw[i]);
            cx[i] = regFunded(cw[i], 50e6);
        }
        bytes32 knownSeed = chain[1];
        uint256 ran;
        for (uint256 a; a < K; ++a) {
            for (uint256 b; b <= K; ++b) {
                for (uint256 c; c <= K; ++c) {
                    if (b == a || (c != K && (c == a || c == b)) || (b == K && c != K)) continue;
                    uint256 snap = vm.snapshotState();
                    toEntries(FIRST);
                    for (uint256 i; i < H; ++i) enterAs(ws[i], ids[i], FIRST);
                    enterAs(cw[a], cx[a], FIRST);
                    if (b != K) enterAs(cw[b], cx[b], FIRST);
                    if (c != K) enterAs(cw[c], cx[c], FIRST);
                    vm.warp(rat.closeTime(FIRST));
                    rat.revealSeed(FIRST, knownSeed);
                    (, bytes32 priorSeed,,,,,,,,,,,,,,,,) = rat.rounds(FIRST);
                    advanceL2();
                    rat.pair(FIRST, 1000);
                    (
                        ,
                        bytes32 mixedSeed,
                        ,
                        ,
                        ,
                        ,
                        uint32 matches,
                        ,
                        ,
                        ,
                        RobinAmongThieves.Status status,
                        ,
                        ,
                        ,
                        ,
                        ,
                        ,
                        bool seedMixed
                    ) = rat.rounds(FIRST);
                    assertTrue(seedMixed, "reveal-block hash was mixed");
                    assertTrue(mixedSeed != priorSeed, "pairing seed changed");
                    assertGt(matches, 0, "pairing produced matches");
                    assertTrue(
                        status == RobinAmongThieves.Status.Paired || status == RobinAmongThieves.Status.Finalized
                    );
                    ++ran;
                    vm.revertToState(snap);
                }
            }
        }
        assertGt(ran, 0, "the search paired for real");
    }
}
