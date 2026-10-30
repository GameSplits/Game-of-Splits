// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {TestnetBase} from "../../script/Deploy.s.sol";
import {AcceptBase} from "../../script/SafeAccept.s.sol";
import {RakeBuyer} from "../../src/RakeBuyer.sol";

/// Stands in for the multisig Safe: Verify reads its owners and needs it to have code.
contract SafeStubV {
    address[] internal o;

    constructor(address[] memory owners) {
        o = owners;
    }

    function getOwners() external view returns (address[] memory) {
        return o;
    }
}

/// The real DeployTestnet body (the same internal function `run()` broadcasts) followed by the real
/// SafeAcceptVerify checks, with the event scan counted over in-process recorded logs instead of eth_getLogs.
/// The eth_getLogs path itself runs end to end in script/e2e/testnet_rehearsal.sh on an anvil fork.
contract TestnetFlowHarness is TestnetBase, AcceptBase {
    function deploy(address safe, uint64 start, uint64 end) external returns (Out memory o) {
        vm.startPrank(msg.sender);
        o = _deployTestnet(msg.sender, safe, start, end, 1 days);
        vm.stopPrank();
        _checkTestnet(o, msg.sender, safe);
    }

    function verify(Out memory o, address deployer, address safe, uint256 seed, VmSafe.Log[] memory logs) external {
        D memory d = _asD(o, deployer);
        _verifyState(d, safe, seed, SafeStubV(safe).getOwners());
        _expectAllLogs(_verifyWants(d), logs);
    }

    function checkEligible(Out memory o, bytes32[] memory ids) external view {
        _requireEligible(o.alms, ids);
    }

    function _asD(Out memory o, address deployer) internal pure returns (D memory d) {
        d.config = o.config;
        d.core = o.core;
        d.pass = o.pass;
        d.alms = o.alms;
        d.vault = o.vault;
        d.usdg = o.usdg;
        d.wif = o.wif;
        d.arrow = address(o.arrow);
        d.seat = address(o.seat);
        d.routeA = o.routeA;
        d.routeB = o.routeB;
        d.rat = o.rat;
        d.rakeBuyer = o.rakeBuyer;
        d.rakeRouteA = o.rakeRouteA;
        d.rakeRouteB = o.rakeRouteB;
        d.deployer = deployer;
        d.lens = o.lens;
        d.tokenB = o.tokenB;
    }
}

contract TestnetDeployVerifyTest is Test {
    uint256 constant T0 = 1_800_000_000; // same clock and Fair env as HiddenBooth.t.sol (env is process-wide)
    bytes32 constant ID_A = keccak256("charity-a");
    bytes32 constant ID_B = keccak256("charity-b");
    TestnetFlowHarness h;
    SafeStubV safe;
    address deployer = makeAddr("gosTestnetDeployer");
    address keeper = makeAddr("theKeeper");
    address toll = makeAddr("toll");

    function setUp() public {
        vm.chainId(46630);
        vm.warp(T0);
        vm.setEnv("FAIR_START", vm.toString(T0 + 1 hours));
        vm.setEnv("FAIR_END", vm.toString(T0 + 7 days));
        // every test in this file deploys and verifies with the same two charity ids (env is process-wide)
        vm.setEnv("ELIGIBLE_IDS", string.concat(vm.toString(ID_A), ",", vm.toString(ID_B)));
        address[] memory owners = new address[](3);
        owners[0] = makeAddr("signer1");
        owners[1] = makeAddr("signer2");
        owners[2] = makeAddr("signer3");
        safe = new SafeStubV(owners);
        h = new TestnetFlowHarness();
        vm.allowCheatcodes(address(h));
        vm.setEnv("KEEPER", vm.toString(keeper));
        vm.setEnv("TOLL_RECIPIENT", vm.toString(toll));
        vm.setEnv("OWNER_SAFE", vm.toString(address(safe)));
        vm.setEnv("DEPLOYER", vm.toString(deployer));
    }

    function _deploy() internal returns (TestnetFlowHarness.Out memory o, VmSafe.Log[] memory logs) {
        vm.recordLogs();
        vm.startPrank(deployer);
        o = h.deploy(address(safe), uint64(T0 + 1 hours), uint64(T0 + 7 days));
        vm.stopPrank();
        logs = vm.getRecordedLogs();
    }

    function _seed(TestnetFlowHarness.Out memory o) internal view returns (uint256) {
        return o.core.anchorRate();
    }

    /// M-1 (KF-E-01, G-1): a correct testnet deploy (which pauses Robin entries, K-B05) passes Verify.
    function test_testnetDeploy_thenVerify_passes() public {
        (TestnetFlowHarness.Out memory o, VmSafe.Log[] memory logs) = _deploy();
        assertTrue(o.rat.entriesPaused());
        assertEq(o.rat.owner(), address(safe));
        h.verify(o, deployer, address(safe), _seed(o), logs);
    }

    /// A Safe un-pause before Verify ran is not the planned deploy: refused by the state check.
    function test_unpausedBeforeVerify_refused() public {
        (TestnetFlowHarness.Out memory o, VmSafe.Log[] memory logs) = _deploy();
        uint256 seed = _seed(o);
        vm.prank(address(safe));
        o.rat.pauseEntries(false);
        vm.expectRevert(bytes("robin entries must start paused (K-B05)"));
        h.verify(o, deployer, address(safe), seed, logs);
    }

    /// An extra pause/unpause pair (state back to paused) still leaves a wrong EntriesPaused count.
    function test_extraPauseToggle_failsScan() public {
        vm.recordLogs();
        vm.startPrank(deployer);
        TestnetFlowHarness.Out memory o = h.deploy(address(safe), uint64(T0 + 1 hours), uint64(T0 + 7 days));
        vm.stopPrank();
        vm.startPrank(address(safe));
        o.rat.pauseEntries(false);
        o.rat.pauseEntries(true);
        vm.stopPrank();
        VmSafe.Log[] memory logs = vm.getRecordedLogs();
        uint256 seed = _seed(o);
        vm.expectRevert(bytes("an owner action happened that nobody planned: investigate before going on"));
        h.verify(o, deployer, address(safe), seed, logs);
    }

    /// M-3 (G-5): a forward target set on RakeBuyer is refused by state, even if the scan were blind to it.
    function test_forwardToSet_refused() public {
        (TestnetFlowHarness.Out memory o, VmSafe.Log[] memory logs) = _deploy();
        uint256 seed = _seed(o);
        address thief = makeAddr("thief");
        vm.startPrank(address(safe));
        o.rakeBuyer.queue(RakeBuyer.Op.SetForwardTo, 0, thief);
        o.rakeBuyer.execute(RakeBuyer.Op.SetForwardTo, 0, thief);
        vm.stopPrank();
        assertEq(o.rakeBuyer.forwardTo(), thief);
        vm.expectRevert(bytes("rakeBuyer forwardTo must be unset (forwards go to the vault)"));
        h.verify(o, deployer, address(safe), seed, logs);
    }

    /// M-3: the scan counts ForwardToSet, so a set-then-cleared target (state back to zero) still fails.
    function test_forwardToSetThenCleared_failsScan() public {
        vm.recordLogs();
        vm.startPrank(deployer);
        TestnetFlowHarness.Out memory o = h.deploy(address(safe), uint64(T0 + 1 hours), uint64(T0 + 7 days));
        vm.stopPrank();
        uint256 seed = _seed(o);
        // only a ForwardToSet, no OpQueued/OpExecuted: what a setupSet before finishSetup would leave behind
        VmSafe.Log[] memory logs = _withForwardToSet(vm.getRecordedLogs(), address(o.rakeBuyer));
        vm.expectRevert(bytes("an owner action happened that nobody planned: investigate before going on"));
        h.verify(o, deployer, address(safe), seed, logs);
    }

    function _withForwardToSet(VmSafe.Log[] memory logs, address rb) internal pure returns (VmSafe.Log[] memory out) {
        out = new VmSafe.Log[](logs.length + 1);
        for (uint256 i; i < logs.length; ++i) {
            out[i] = logs[i];
        }
        bytes32[] memory t = new bytes32[](1);
        t[0] = keccak256("ForwardToSet(address)");
        out[logs.length] = VmSafe.Log(t, abi.encode(address(0)), rb);
    }

    /// L-7: Verify checks the ids themselves, not just how many EligibleSet events there were.
    function test_eligibleIdsChecked() public {
        (TestnetFlowHarness.Out memory o,) = _deploy();
        assertTrue(o.alms.eligibleAt(ID_A) != 0 && o.alms.eligibleAt(ID_B) != 0);
        bytes32[] memory ids = new bytes32[](2);
        ids[0] = ID_A;
        ids[1] = ID_B;
        h.checkEligible(o, ids);
        ids[1] = keccak256("a charity nobody approved");
        vm.expectRevert(bytes("a charity id from ELIGIBLE_IDS is not eligible on chain"));
        h.checkEligible(o, ids);
    }
}
