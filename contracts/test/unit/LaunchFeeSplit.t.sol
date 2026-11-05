// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {FeeSplitter} from "../../src/FeeSplitter.sol";
import {LaunchSplit} from "../../script/LaunchSplit.s.sol";

contract LaunchSplitHarness is LaunchSplit {
    function split() external view returns (FeeSplitter.FeeSplit memory) {
        return _feeSplitFromEnv();
    }

    function legs(address safe, address vault, address deployer) external view returns (FeeSplitter.Recipients memory) {
        return _feeLegs(safe, vault, deployer);
    }
}

/// DS-1 and DS-3 (deploy scripts review): on mainnet the FeeSplitter split is option b and cannot be overridden, the four
/// holding legs are the Safe, and no leg may be the deployer. Env vars are process wide, so every case that sets one
/// lives in a single test and clears what it set.
contract LaunchFeeSplitTest is Test {
    LaunchSplitHarness h = new LaunchSplitHarness();
    address safe = makeAddr("safe");
    address vault = makeAddr("vault");
    address dep = makeAddr("deployer");
    address eoa = makeAddr("eoa");
    string[4] names = ["PURSES", "REBATE", "BURN_BUYER", "OPS"];

    function _clear() internal {
        vm.setEnv("FEE_SPLIT_BPS", "");
        for (uint256 i; i < 4; ++i) {
            vm.setEnv(names[i], "");
        }
    }

    function test_mainnetFeeSplit_envCases() public {
        vm.chainId(4663);
        _clear();
        // option b (the owner, 4 Nov) in leg order purses, vault, rebate, burn, ops
        FeeSplitter.FeeSplit memory s = h.split();
        assertEq(s.pursesBps, 0);
        assertEq(s.vaultBps, 5000);
        assertEq(s.rebateBps, 0);
        assertEq(s.burnBps, 4000);
        assertEq(s.opsBps, 1000);
        // DS-1: any FEE_SPLIT_BPS is refused on mainnet, even option b itself
        vm.setEnv("FEE_SPLIT_BPS", "0,5000,0,4000,1000");
        vm.expectRevert(bytes("FEE_SPLIT_BPS is refused on mainnet, the launch split is fixed in LaunchSplit"));
        h.split();
        vm.setEnv("FEE_SPLIT_BPS", "4000,2500,1500,1000,1000");
        vm.expectRevert(bytes("FEE_SPLIT_BPS is refused on mainnet, the launch split is fixed in LaunchSplit"));
        h.split();
        vm.setEnv("FEE_SPLIT_BPS", "");

        // DS-3: unset legs are the Safe, the vault leg is the vault
        FeeSplitter.Recipients memory r = h.legs(safe, vault, dep);
        assertEq(r.purses, safe);
        assertEq(r.vault, vault);
        assertEq(r.rebate, safe);
        assertEq(r.burnBuyer, safe);
        assertEq(r.ops, safe);

        // a leg set to the Safe is fine, anything else (an EOA, the deployer) is refused
        for (uint256 i; i < 4; ++i) {
            vm.setEnv(names[i], vm.toString(safe));
            h.legs(safe, vault, dep);
            vm.setEnv(names[i], vm.toString(eoa));
            vm.expectRevert(bytes(string.concat(names[i], " must be the Safe on mainnet")));
            h.legs(safe, vault, dep);
            vm.setEnv(names[i], vm.toString(dep));
            vm.expectRevert(bytes(string.concat(names[i], " must be the Safe on mainnet")));
            h.legs(safe, vault, dep);
            vm.setEnv(names[i], "");
        }

        // the deployer is never a leg, not even as the Safe or the vault argument
        vm.expectRevert(bytes("a FeeSplitter leg is the deployer"));
        h.legs(dep, vault, dep);
        vm.expectRevert(bytes("a FeeSplitter leg is the deployer"));
        h.legs(safe, dep, dep);

        // off mainnet the legs come from env and the split may be overridden
        vm.chainId(46630);
        for (uint256 i; i < 4; ++i) {
            vm.setEnv(names[i], vm.toString(eoa));
        }
        r = h.legs(safe, vault, dep);
        assertEq(r.purses, eoa);
        assertEq(r.ops, eoa);
        vm.setEnv("OPS", vm.toString(dep));
        vm.expectRevert(bytes("a FeeSplitter leg is the deployer"));
        h.legs(safe, vault, dep);
        vm.setEnv("FEE_SPLIT_BPS", "4000,2500,1500,1000,1000");
        assertEq(h.split().pursesBps, 4000);
        vm.setEnv("FEE_SPLIT_BPS", "4000,2500,1500,1000,999");
        vm.expectRevert(bytes("FEE_SPLIT_BPS must sum to 10000"));
        h.split();
        _clear();
    }
}
