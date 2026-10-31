// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Base} from "../Base.t.sol";

/// L-2: the watcher's fill check zeroes FairCore's per-ledger guards by raw slot in an eth_call stateOverride.
/// These numbers must equal FAIRCORE_SLOTS in watcher/lib/abi.mjs (watcher/test/detectors.test.mjs pins the same
/// values there); `script/check_slots.sh` compares both against `forge inspect` directly.
contract WatcherSlotsTest is Base {
    uint256 constant LAST_SWAP_AT = 41;
    uint256 constant SWAPPED_ON_DAY = 42;

    function test_watcherSlots_lastSwapAt() public {
        for (uint8 ledger; ledger < 4; ledger++) {
            bytes32 slot = keccak256(abi.encode(uint256(ledger), LAST_SWAP_AT));
            vm.store(address(core), slot, bytes32(uint256(1234 + ledger)));
            assertEq(core.lastSwapAt(ledger), 1234 + ledger);
        }
    }

    function test_watcherSlots_swappedOnDay() public {
        uint256 day = block.timestamp / 1 days;
        for (uint8 ledger; ledger < 4; ledger++) {
            bytes32 inner = keccak256(abi.encode(uint256(ledger), SWAPPED_ON_DAY));
            bytes32 slot = keccak256(abi.encode(day, inner));
            vm.store(address(core), slot, bytes32(uint256(777 + ledger)));
            assertEq(core.swappedOnDay(ledger, day), 777 + ledger);
        }
    }
}
