// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {RatBase} from "../RatBase.t.sol";
import {RobinAmongThieves} from "../../src/RobinAmongThieves.sol";

/// RAT-01 regression: one controller may enter at most MAX_ENTRIES_PER_CONTROLLER outlaws per round.
contract RatEntryCapTest is RatBase {
    function test_constantIsThree() public view {
        assertEq(rat.MAX_ENTRIES_PER_CONTROLLER(), 3);
    }

    /// PoC turned into a regression: 3 entries ok, 4th reverts, other wallets can still enter.
    function test_fourthEntryReverts_othersStillEnter() public {
        toEntries(FIRST);
        wif.mint(ana, 4 * LIC);
        uint256[4] memory ids;
        for (uint256 i; i < 4; ++i) {
            ids[i] = regFunded(ana, 5e6);
        }
        for (uint256 i; i < 3; ++i) {
            enterAs(ana, ids[i], FIRST);
            assertEq(rat.entriesByControllerOf(FIRST, ana), i + 1);
        }
        vm.prank(ana);
        vm.expectRevert(RobinAmongThieves.TooManyEntries.selector);
        rat.enter(ids[3], FIRST, keccak256(abi.encode(ids[3], FIRST)));
        assertEq(rat.entriesByControllerOf(FIRST, ana), 3);

        // A different controller can still enter.
        uint256 bobId = regFunded(bob, 5e6);
        enterAs(bob, bobId, FIRST);
        assertEq(rat.entriesByControllerOf(FIRST, bob), 1);

        // Round is not full: 4 seats used of 256.
        (,, uint32 entrants,,,,,,,,,,,,,,,) = rat.rounds(FIRST);
        assertEq(entrants, 4);
    }

    /// Same controller, different agentIds: the cap is on the controller, not the agent.
    function test_capIsPerControllerNotAgent() public {
        toEntries(FIRST);
        wif.mint(ana, 4 * LIC);
        uint256 a1 = regFunded(ana, 5e6);
        uint256 a2 = regFunded(ana, 5e6);
        uint256 a3 = regFunded(ana, 5e6);
        uint256 a4 = regFunded(ana, 5e6);
        enterAs(ana, a1, FIRST);
        enterAs(ana, a2, FIRST);
        enterAs(ana, a3, FIRST);
        vm.prank(ana);
        vm.expectRevert(RobinAmongThieves.TooManyEntries.selector);
        rat.enter(a4, FIRST, keccak256(abi.encode(a4, FIRST)));
    }

    /// Operator entering for the controller still counts against the controller.
    function test_operatorEntryCountsAgainstController() public {
        toEntries(FIRST);
        wif.mint(ana, 4 * LIC);
        uint256[4] memory ids;
        for (uint256 i; i < 4; ++i) {
            ids[i] = regFunded(ana, 5e6);
            vm.prank(ana);
            rat.setOperator(ids[i], opr);
        }
        for (uint256 i; i < 3; ++i) {
            vm.prank(opr);
            rat.enter(ids[i], FIRST, keccak256(abi.encode(ids[i], FIRST)));
        }
        assertEq(rat.entriesByControllerOf(FIRST, ana), 3);
        vm.prank(opr);
        vm.expectRevert(RobinAmongThieves.TooManyEntries.selector);
        rat.enter(ids[3], FIRST, keccak256(abi.encode(ids[3], FIRST)));
        // Controller itself is also blocked.
        vm.prank(ana);
        vm.expectRevert(RobinAmongThieves.TooManyEntries.selector);
        rat.enter(ids[3], FIRST, keccak256(abi.encode(ids[3], FIRST)));
    }

    /// Sit-out (conflict) refunds and frees the outlaw for a later round. The cap is per round, so the count for
    /// the finished round simply stays (nothing reads it again).
    function test_sitOut_countStaysPerRound() public {
        toEntries(FIRST);
        wif.mint(ana, 3 * LIC);
        uint256 a1 = regFunded(ana, 5e6);
        uint256 a2 = regFunded(ana, 5e6);
        uint256 a3 = regFunded(ana, 5e6);
        enterAs(ana, a1, FIRST);
        enterAs(ana, a2, FIRST);
        enterAs(ana, a3, FIRST);
        assertEq(rat.entriesByControllerOf(FIRST, ana), 3);
        // Pairing will sit them all out (same controller conflict / odd).
        seedPair(FIRST);
        assertEq(rat.entriesByControllerOf(FIRST, ana), 3, "count is per round, not decremented");
        assertEq(openRoundOf(a1), 0);
        assertEq(openRoundOf(a2), 0);
        assertEq(openRoundOf(a3), 0);
        assertEq(bal(a1), 5e6);
        assertEq(bal(a2), 5e6);
        assertEq(bal(a3), 5e6);

        // Next round: can enter 3 again.
        uint256 r = FIRST + 1;
        toEntries(r);
        enterAs(ana, a1, r);
        enterAs(ana, a2, r);
        enterAs(ana, a3, r);
        assertEq(rat.entriesByControllerOf(r, ana), 3);
    }

    /// Cancel refunds every stake; the per-round count is left as is.
    function test_cancel_countStaysPerRound() public {
        toEntries(FIRST);
        wif.mint(ana, 3 * LIC);
        uint256 a1 = regFunded(ana, 5e6);
        uint256 a2 = regFunded(ana, 5e6);
        uint256 a3 = regFunded(ana, 5e6);
        enterAs(ana, a1, FIRST);
        enterAs(ana, a2, FIRST);
        enterAs(ana, a3, FIRST);
        assertEq(rat.entriesByControllerOf(FIRST, ana), 3);
        vm.warp(rat.closeTime(FIRST) + 8 minutes);
        rat.cancelRound(FIRST, 10);
        assertEq(rat.entriesByControllerOf(FIRST, ana), 3);
        assertEq(bal(a1), 5e6);
        assertEq(bal(a2), 5e6);
        assertEq(bal(a3), 5e6);
    }

    /// Settle pays out; the per-round count is left as is.
    function test_settle_countStaysPerRound() public {
        toEntries(FIRST);
        uint256 a = regFunded(ana, 5e6);
        uint256 b = regFunded(bob, 5e6);
        enterAs(ana, a, FIRST);
        enterAs(bob, b, FIRST);
        assertEq(rat.entriesByControllerOf(FIRST, ana), 1);
        assertEq(rat.entriesByControllerOf(FIRST, bob), 1);
        seedPair(FIRST);
        // Still counted until settle (paired, openRound set).
        assertEq(rat.entriesByControllerOf(FIRST, ana), 1);
        settleAll(FIRST);
        assertEq(rat.entriesByControllerOf(FIRST, ana), 1);
        assertEq(rat.entriesByControllerOf(FIRST, bob), 1);
    }

    /// Fuzz: across many controllers, never more than 3 entries each; USDG ledgers stay consistent.
    function testFuzz_entryCapAcrossControllers(uint8 nControllers, uint8 entriesEach) public {
        nControllers = uint8(bound(nControllers, 1, 20));
        entriesEach = uint8(bound(entriesEach, 0, 6));
        toEntries(FIRST);

        uint256 totalEntered;
        for (uint256 c; c < nControllers; ++c) {
            address who = address(uint160(0xB000 + c));
            ratFund(who);
            uint256 want = entriesEach;
            uint256 ok;
            for (uint256 i; i < want; ++i) {
                wif.mint(who, LIC);
                uint256 id = regFunded(who, 5e6);
                if (ok >= 3) {
                    vm.prank(who);
                    vm.expectRevert(RobinAmongThieves.TooManyEntries.selector);
                    rat.enter(id, FIRST, keccak256(abi.encode(id, FIRST)));
                } else {
                    enterAs(who, id, FIRST);
                    ok++;
                    totalEntered++;
                }
            }
            assertEq(rat.entriesByControllerOf(FIRST, who), ok);
            assertLe(ok, 3);
        }
        (,, uint32 entrants,,,,,,,,,,,,,,,) = rat.rounds(FIRST);
        assertEq(entrants, totalEntered);
        assertEq(rat.reservedStakes(), totalEntered * 5e6);
        // I1: held USDG matches ledgers.
        assertEq(
            usdg.balanceOf(address(rat)),
            rat.freeBalances() + rat.reservedStakes() + rat.sharingPot() + rat.rakePending()
        );
    }

    /// After a capped fill, sit-out/cancel returns every stake: no USDG stuck in reservedStakes.
    function test_noUsdgStuckAfterCapAndCancel() public {
        toEntries(FIRST);
        address[5] memory wallets = [ana, bob, cat, dan, eve];
        for (uint256 w; w < wallets.length; ++w) {
            wif.mint(wallets[w], 4 * LIC);
            for (uint256 i; i < 4; ++i) {
                uint256 id = regFunded(wallets[w], 5e6);
                if (i < 3) {
                    enterAs(wallets[w], id, FIRST);
                } else {
                    vm.prank(wallets[w]);
                    vm.expectRevert(RobinAmongThieves.TooManyEntries.selector);
                    rat.enter(id, FIRST, keccak256(abi.encode(id, FIRST)));
                }
            }
        }
        assertEq(rat.reservedStakes(), 5 * 3 * 5e6);
        vm.warp(rat.closeTime(FIRST) + 8 minutes);
        rat.cancelRound(FIRST, 100);
        assertEq(rat.reservedStakes(), 0);
        assertEq(rat.entriesByControllerOf(FIRST, ana), 3);
        assertEq(
            usdg.balanceOf(address(rat)),
            rat.freeBalances() + rat.reservedStakes() + rat.sharingPot() + rat.rakePending()
        );
        ledgersOk();
    }
}
