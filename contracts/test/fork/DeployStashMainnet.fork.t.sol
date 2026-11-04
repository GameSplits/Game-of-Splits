// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FairCore} from "../../src/FairCore.sol";
import {Stash} from "../../src/Stash.sol";
import {DeployBase, ISafeView} from "../../script/Deploy.s.sol";
import {MainnetAddrs} from "../../script/Mainnet.s.sol";
import {DeployStashMainnet} from "../../script/DeployStashMainnet.s.sol";

/// Deploys the real game contracts the way DeployMainnet does, with this contract as the owner, and adds the booths.
contract MainnetBooths is DeployBase, MainnetAddrs {
    function deploy() external returns (address core, address arrow, address seat) {
        Out memory o = _deployGame(USDG, WIF, address(this), 48 hours, CONFIG_DELAY_MAINNET, 1 days);
        o.core.setupSet(FairCore.Op.AddBooth, 0, address(o.arrow));
        o.core.setupSet(FairCore.Op.AddBooth, 0, address(o.seat));
        return (address(o.core), address(o.arrow), address(o.seat));
    }
}

/// Fork of chain 4663. Needs no key. Nothing is broadcast. Keep the env changes in this one test, since tests in a
/// contract run in parallel and env is shared.
contract DeployStashMainnetForkTest is Test {
    address internal constant SAFE = 0x7c0fc9869f2D41D88CCA675A9A270214d59DA36a;
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;

    bool internal forked;

    function setUp() public {
        try vm.createSelectFork(vm.rpcUrl("robinhood")) {
            forked = true;
        } catch {
            forked = false;
        }
    }

    function test_simulateMainnetDeploy() public {
        if (!forked) vm.skip(true, "mainnet fork unavailable");
        assertEq(block.chainid, 4663);
        DeployStashMainnet script = new DeployStashMainnet();

        if (!vm.isFile("deployments/4663.json")) {
            _refusesBadBooths(script);
            (address c, address a, address s) = new MainnetBooths().deploy();
            vm.setEnv("FAIR_CORE", vm.toString(c));
            vm.setEnv("LAST_ARROW", vm.toString(a));
            vm.setEnv("SHERIFFS_SEAT", vm.toString(s));
        }
        (address core, address arrow, address seat) = script.booths();

        assertGe(ISafeView(SAFE).nonce(), 1, "Safe has never executed a tx");

        Stash stash = script.run();

        assertEq(stash.core(), core);
        assertEq(address(stash.arrow()), arrow);
        assertEq(address(stash.seat()), seat);
        assertEq(address(stash.usdg()), USDG);
        assertEq(stash.feeWallet(), SAFE);
        assertEq(stash.capRaiser(), SAFE);
        assertEq(stash.shotFee(), 0.05e6);
        assertEq(stash.withdrawFee(), 1e6);
        assertEq(stash.cap(), 50_000e6);
        assertEq(stash.totalHeld(), 0);
        _assertPresets(stash);
        _withdrawRules(stash);

        console2.log("Stash", address(stash));
        console2.log("code bytes", address(stash).code.length);
        console2.log("FairCore", core);
        console2.log("LastArrow", arrow);
        console2.log("SheriffsSeat", seat);
        console2.log("feeWallet", stash.feeWallet());
        console2.log("capRaiser", stash.capRaiser());
        console2.log("shotFee", stash.shotFee());
        console2.log("withdrawFee", stash.withdrawFee());
        console2.log("presets", stash.presetCount());
        for (uint256 i; i < stash.presetCount(); ++i) {
            console2.log(i, stash.preset(i));
        }
    }

    function _refusesBadBooths(DeployStashMainnet script) internal {
        vm.setEnv("FAIR_CORE", vm.toString(address(0)));
        vm.setEnv("LAST_ARROW", vm.toString(address(0)));
        vm.setEnv("SHERIFFS_SEAT", vm.toString(address(0)));
        vm.expectRevert(bytes("FAIR_CORE missing"));
        script.booths();
        vm.setEnv("FAIR_CORE", vm.toString(makeAddr("noCode")));
        vm.expectRevert(bytes("FAIR_CORE has no code"));
        script.booths();
    }

    function _assertPresets(Stash stash) internal view {
        string[16] memory expected = [
            "Off my seat",
            "Skill issue",
            "Diamond hands",
            "Cope harder",
            "Comfy up here",
            "Not your seat",
            "Touch grass",
            "Wen dethrone",
            "Few understand",
            "Gm from the throne",
            "Bow down",
            "Still sitting",
            "Zoom out",
            "Ngmi",
            "Catch me if you can",
            "Wagmi from up here"
        ];
        assertEq(stash.presetCount(), 16);
        for (uint256 i; i < 16; ++i) {
            assertEq(stash.preset(i), expected[i]);
        }
    }

    function _withdrawRules(Stash stash) internal {
        IERC20 token = IERC20(USDG);
        address player = makeAddr("mainnetForkPlayer");
        deal(USDG, player, 10e6);
        uint256 fees = token.balanceOf(SAFE);
        vm.startPrank(player);
        token.approve(address(stash), 10e6);
        stash.deposit(10e6);
        stash.withdraw(9e6);
        assertEq(token.balanceOf(player), 8e6);
        assertEq(token.balanceOf(SAFE), fees + 1e6);
        assertEq(stash.balance(player), 1e6);
        vm.expectRevert(Stash.BalanceAtOrBelowFee.selector);
        stash.withdraw(1e6);
        vm.stopPrank();
        assertEq(stash.balance(player), 1e6);
        assertEq(token.balanceOf(SAFE), fees + 1e6);
    }
}
