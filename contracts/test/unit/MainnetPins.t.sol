// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {SafeCheck} from "../../script/Deploy.s.sol";
import {MainnetPins} from "../../script/MainnetPins.sol";

contract RolesHarness is SafeCheck {
    function check(address keeper, address toll, address safe, bytes32[] memory ids) external view {
        _requireMainnetRoles(keeper, toll, safe, ids);
    }
}

/// P1: on chain 4663 the deploy only takes the pinned keeper, the Safe as toll recipient, and the fair0.json allowlist.
contract MainnetPinsTest is Test {
    using stdJson for string;

    address constant SAFE = 0x7c0fc9869f2D41D88CCA675A9A270214d59DA36a;
    address constant TESTNET_KEEPER = 0xf79640C55805A3dc50F4d07AaA8Dfb52bbAa35E1;
    address constant TESTNET_SAFE = 0xDF3d35A99af7A1A3fdE128b8FDFa0D60aE9A1F00;
    RolesHarness h;

    function setUp() public {
        h = new RolesHarness();
        vm.chainId(4663);
    }

    function _pins() internal pure returns (bytes32[] memory) {
        return MainnetPins.fair0Eligible();
    }

    function test_pinsEqualFair0Json() public view {
        string memory json = vm.readFile("eligible/fair0.json");
        bytes32[] memory ids = _pins();
        for (uint256 i; i < 3; ++i) {
            assertEq(json.readBytes32(string.concat(".charities[", vm.toString(i), "].configId")), ids[i]);
        }
        // the ELIGIBLE_IDS line the runbook exports is the same list, same order
        string memory line = json.readString(".ELIGIBLE_IDS");
        string memory want = string.concat(vm.toString(ids[0]), ",", vm.toString(ids[1]), ",", vm.toString(ids[2]));
        assertEq(keccak256(bytes(vm.toLowercase(line))), keccak256(bytes(vm.toLowercase(want))));
    }

    function test_pinnedValuesPass() public view {
        h.check(MainnetPins.KEEPER, SAFE, SAFE, _pins());
    }

    function test_testnetKeeperRefused() public {
        vm.expectRevert(bytes("KEEPER is not the pinned mainnet keeper"));
        h.check(TESTNET_KEEPER, SAFE, SAFE, _pins());
    }

    function test_tollNotSafeRefused() public {
        vm.expectRevert(bytes("TOLL_RECIPIENT must be the owner Safe on mainnet"));
        h.check(MainnetPins.KEEPER, TESTNET_SAFE, SAFE, _pins());
    }

    function test_testnetIdsRefused() public {
        bytes32[] memory ids = new bytes32[](2);
        ids[0] = keccak256("charity-a");
        ids[1] = keccak256("charity-b");
        vm.expectRevert(bytes("ELIGIBLE_IDS must equal eligible/fair0.json"));
        h.check(MainnetPins.KEEPER, SAFE, SAFE, ids);
    }

    function test_subsetOrReorderRefused() public {
        bytes32[] memory p = _pins();
        bytes32[] memory two = new bytes32[](2);
        (two[0], two[1]) = (p[0], p[1]);
        vm.expectRevert(bytes("ELIGIBLE_IDS must equal eligible/fair0.json"));
        h.check(MainnetPins.KEEPER, SAFE, SAFE, two);
        (p[0], p[1]) = (p[1], p[0]);
        vm.expectRevert(bytes("ELIGIBLE_IDS must equal eligible/fair0.json"));
        h.check(MainnetPins.KEEPER, SAFE, SAFE, p);
    }

    function testFuzz_anyOtherKeeperRefused(address k) public {
        vm.assume(k != MainnetPins.KEEPER);
        vm.expectRevert(bytes("KEEPER is not the pinned mainnet keeper"));
        h.check(k, SAFE, SAFE, _pins());
    }

    function test_otherChainsUnaffected() public {
        vm.chainId(46630);
        h.check(TESTNET_KEEPER, TESTNET_SAFE, TESTNET_SAFE, new bytes32[](0));
    }
}
