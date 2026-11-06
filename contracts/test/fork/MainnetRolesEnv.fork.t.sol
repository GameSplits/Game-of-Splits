// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {DeployMainnet} from "../../script/Deploy.s.sol";
import {MainnetPins} from "../../script/MainnetPins.sol";

/// P1 failing-env test: DeployMainnet on a 4663 fork, with the testnet values a stale shell would carry
/// (deploy_tools/testnet_env.sh), refuses before broadcasting. With the pinned values it gets past the guard and stops
/// at the next check (the deployer nonce, which a pranked test call always bumps), so nothing is deployed. One test, run alone (env is process-wide).
contract MainnetRolesEnvForkTest is Test {
    address constant SAFE = 0x7c0fc9869f2D41D88CCA675A9A270214d59DA36a;
    string constant OWNERS =
        "0xCA652b365Fa1052d43297907B1eAe5676182Eb5c,0x8AAb7f969f7e6AE1098e4158EA4547F07A3204e2,0x36E54F5366b7d01529BA1abF233314184B876D89";
    string constant FAIR0 =
        "0xb02173170bada3eb8162396b27744f9c5ac99bed3a632b1c4d2bc9b1b366b0e8,0xc1f8523fd8f90bb29f8c20ef2dd5bce2d8a94d172083b59840e312f32a44a02b,0x48058626e8f67696c865eb4bacf23f3716d0f28968a65c29410dfc31d59fd93f";
    bool forked;

    function setUp() public {
        try vm.createSelectFork(vm.rpcUrl("robinhood")) {
            forked = true;
        } catch {}
    }

    function _env(string memory keeper, string memory toll, string memory ids) internal {
        vm.setEnv("OWNER_SAFE", vm.toString(SAFE)); // the alias only: GOS_SAFE or ALMS_SAFE would leak into other suites
        vm.setEnv("SAFE_OWNERS", OWNERS);
        vm.setEnv("KEEPER", keeper);
        vm.setEnv("TOLL_RECIPIENT", toll);
        vm.setEnv("ELIGIBLE_IDS", ids);
        vm.setEnv("ANCHOR_SEED", "1");
    }

    function _run(DeployMainnet s, address dep, bytes memory err) internal {
        vm.expectRevert(err);
        vm.prank(dep);
        s.run();
    }

    function test_staleTestnetEnvRefused_pinnedEnvPasses() public {
        // env is process-wide and other suites (TestnetDeployVerify) set the same keys in parallel, so this runs alone:
        //   ROLES_ENV_TEST=1 forge test --match-contract MainnetRolesEnvForkTest
        if (!vm.envOr("ROLES_ENV_TEST", false)) vm.skip(true, "set ROLES_ENV_TEST=1 and run this suite alone");
        if (!forked) vm.skip(true, "mainnet fork unavailable");
        if (block.timestamp > 1794351600) vm.skip(true, "past DEPLOY_BY");
        DeployMainnet s = new DeployMainnet();
        address dep = makeAddr("freshDeployer");
        string memory k = vm.toString(MainnetPins.KEEPER);
        string memory safe = vm.toString(SAFE);
        string memory testIds = string.concat(vm.toString(keccak256("charity-a")), ",", vm.toString(keccak256("charity-b")));

        _env("0xf79640C55805A3dc50F4d07AaA8Dfb52bbAa35E1", "0xDF3d35A99af7A1A3fdE128b8FDFa0D60aE9A1F00", testIds);
        _run(s, dep, bytes("KEEPER is not the pinned mainnet keeper"));
        _env(k, "0xDF3d35A99af7A1A3fdE128b8FDFa0D60aE9A1F00", FAIR0);
        _run(s, dep, bytes("TOLL_RECIPIENT must be the owner Safe on mainnet"));
        _env(k, safe, testIds);
        _run(s, dep, bytes("ELIGIBLE_IDS must equal eligible/fair0.json"));
        _env(k, safe, FAIR0);
        _run(s, dep, bytes("deployer nonce isn't 0")); // past the P1 guard (a pranked test call bumps the nonce)
    }
}
