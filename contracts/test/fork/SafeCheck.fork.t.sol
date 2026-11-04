// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {SafeCheck} from "../../script/Deploy.s.sol";

/// Review M10-b: the deploy's Safe check, against real Safes created on a Robinhood Chain mainnet fork.
contract SafeCheckHarness is SafeCheck {
    function check(address safe, address[] memory owners) external view {
        _checkSafe(safe, owners, "SAFE");
    }

    function pinned(address safe, address pin) external pure {
        _requirePinned(safe, pin, "SAFE");
    }

    function shippedPins() external pure returns (address, address) {
        return (PINNED_MAINNET_SAFE, PINNED_TESTNET_SAFE);
    }
}

interface ISafeFactory {
    function createProxyWithNonce(address singleton, bytes memory initializer, uint256 saltNonce)
        external
        returns (address);
}

interface ISafe {
    function setup(address[] calldata, uint256, address, bytes calldata, address, address, uint256, address) external;
    function getTransactionHash(
        address,
        uint256,
        bytes calldata,
        uint8,
        uint256,
        uint256,
        uint256,
        address,
        address,
        uint256
    ) external view returns (bytes32);
    function approveHash(bytes32) external;
    function execTransaction(
        address,
        uint256,
        bytes calldata,
        uint8,
        uint256,
        uint256,
        uint256,
        address,
        address,
        bytes memory
    ) external payable returns (bool);
    function nonce() external view returns (uint256);
    function enableModule(address) external;
}

/// Pretends to be a Safe: the right singleton in slot 0 and all the right getters, but it isn't a SafeProxy.
contract FakeSafe {
    address internal singleton;
    address[] internal owners_;

    constructor(address s, address[] memory o) {
        singleton = s;
        owners_ = o;
    }

    function getThreshold() external pure returns (uint256) {
        return 2;
    }

    function getOwners() external view returns (address[] memory) {
        return owners_;
    }

    function getModulesPaginated(address, uint256) external pure returns (address[] memory a, address n) {
        a = new address[](0);
        n = address(1);
    }

    function nonce() external pure returns (uint256) {
        return 1;
    }
}

contract SafeCheckForkTest is Test {
    address constant F141 = 0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67;
    address constant S141 = 0x29fcB43b46531BcA003ddC8FCB67FFE91900C762;
    address constant F150 = 0x14F2982D601c9458F93bd70B218933A6f8165e7b;
    address constant S150 = 0xEdd160fEBBD92E350D4D398fb636302fccd67C7e;
    SafeCheckHarness h;
    address[] safeOwners;
    address[] attacker;
    uint256 salt = 1000;

    function setUp() public {
        vm.createSelectFork("robinhood");
        h = new SafeCheckHarness();
        safeOwners = [makeAddr("ownerA"), makeAddr("ownerB"), makeAddr("ownerC")];
        attacker = [makeAddr("x"), makeAddr("y"), makeAddr("z")];
    }

    function _make(address factory, address singleton, address[] memory owners, uint256 threshold)
        internal
        returns (address)
    {
        bytes memory init = abi.encodeCall(
            ISafe.setup, (owners, threshold, address(0), "", address(0), address(0), 0, address(0))
        );
        return ISafeFactory(factory).createProxyWithNonce(singleton, init, salt++);
    }

    /// One Safe tx approved on-chain by owners[0] and owners[1] (pre-validated signatures, v = 1).
    function _exec(address safe, address[] memory owners, bytes memory data) internal {
        bytes32 txh =
            ISafe(safe).getTransactionHash(safe, 0, data, 0, 0, 0, 0, address(0), address(0), ISafe(safe).nonce());
        (address a, address b) = owners[0] < owners[1] ? (owners[0], owners[1]) : (owners[1], owners[0]);
        vm.prank(a);
        ISafe(safe).approveHash(txh);
        vm.prank(b);
        ISafe(safe).approveHash(txh);
        bytes memory sigs = abi.encodePacked(
            bytes32(uint256(uint160(a))), bytes32(0), uint8(1), bytes32(uint256(uint160(b))), bytes32(0), uint8(1)
        );
        vm.prank(a);
        ISafe(safe).execTransaction(safe, 0, data, 0, 0, 0, 0, address(0), address(0), sigs);
    }

    function _used(address factory, address singleton, address[] memory owners) internal returns (address safe) {
        safe = _make(factory, singleton, owners, 2);
        _exec(safe, owners, "");
    }

    function test_genuine_141_and_150_pass() public {
        h.check(_used(F141, S141, safeOwners), safeOwners);
        h.check(_used(F150, S150, safeOwners), safeOwners);
        address[] memory shuffled = new address[](3);
        (shuffled[0], shuffled[1], shuffled[2]) = (safeOwners[2], safeOwners[0], safeOwners[1]);
        h.check(_used(F141, S141, safeOwners), shuffled); // any order
    }

    function test_attackerOwnedReal2of3_refused() public {
        address safe = _used(F141, S141, attacker);
        vm.expectRevert(bytes("SAFE: owners are not the expected 3"));
        h.check(safe, safeOwners);
    }

    function test_listsRealOwnersButNeverUsed_refused() public {
        address safe = _make(F141, S141, safeOwners, 2); // anyone can create this: setup needs no signatures
        vm.expectRevert(bytes("SAFE: never used: the signers must execute one tx on it first"));
        h.check(safe, safeOwners);
    }

    function test_fakeSafeWithRightSlotAndGetters_refused() public {
        FakeSafe fake = new FakeSafe(S141, safeOwners);
        assertEq(address(uint160(uint256(vm.load(address(fake), bytes32(0))))), S141);
        vm.expectRevert(bytes("SAFE: not a genuine SafeL2 1.4.1/1.5.0 proxy"));
        h.check(address(fake), safeOwners);
    }

    function test_oneOfThree_refused() public {
        address safe = _make(F141, S141, safeOwners, 1);
        vm.expectRevert(bytes("SAFE: threshold must be 2"));
        h.check(safe, safeOwners);
    }

    function test_moduleEnabled_refused() public {
        address safe = _used(F141, S141, safeOwners);
        _exec(safe, safeOwners, abi.encodeCall(ISafe.enableModule, (makeAddr("module"))));
        vm.expectRevert(bytes("SAFE: must have no modules"));
        h.check(safe, safeOwners);
    }

    function test_wrongSingletonVersionMix_refused() public {
        // a 1.4.1 proxy pointed at the 1.5.0 singleton isn't one of the two genuine pairs
        address safe = _make(F141, S150, safeOwners, 2);
        vm.expectRevert(bytes("SAFE: not a genuine SafeL2 1.4.1/1.5.0 proxy"));
        h.check(safe, safeOwners);
    }

    function test_addressPin() public {
        address ours = _used(F141, S141, safeOwners);
        address twin = _used(F141, S141, safeOwners); // same owners, threshold 2, nonce 1: passes _checkSafe...
        h.check(twin, safeOwners);
        h.pinned(ours, ours);
        vm.expectRevert(bytes("SAFE: not the pinned Safe address")); // ...but not the pin
        h.pinned(twin, ours);
        vm.expectRevert(bytes("SAFE: no Safe pinned in script/Deploy.s.sol yet"));
        h.pinned(ours, address(0));
    }

    /// Mainnet is the confirmed Safe on 4 Nov 2026, testnet (46630) the confirmed Safe on 29 Oct 2026.
    function test_shippedPins() public view {
        (address m, address t) = h.shippedPins();
        assertEq(m, 0x7c0fc9869f2D41D88CCA675A9A270214d59DA36a);
        assertEq(t, 0xDF3d35A99af7A1A3fdE128b8FDFa0D60aE9A1F00);
    }

    /// The pinned mainnet Safe passes the same pin and Safe checks DeployMainnet runs.
    function test_pinnedMainnetSafePasses() public view {
        if (block.chainid != 4663) return;
        (address m,) = h.shippedPins();
        address[] memory owners = new address[](3);
        owners[0] = 0xCA652b365Fa1052d43297907B1eAe5676182Eb5c;
        owners[1] = 0x8AAb7f969f7e6AE1098e4158EA4547F07A3204e2;
        owners[2] = 0x36E54F5366b7d01529BA1abF233314184B876D89;
        h.pinned(m, m);
        h.check(m, owners);
    }
}
