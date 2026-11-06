// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {FeeSplitter} from "../../src/FeeSplitter.sol";
import {LaunchSplit} from "../../script/LaunchSplit.s.sol";

/// @notice BLK-5 on a Robinhood Chain fork: FeeSplitter as DeployFeeSplitter builds it for the launch. The owner is the
///         real pinned mainnet Safe (impersonated), the split is `_launchFeeSplit`, the tokens are the real $wif and
///         USDG. Skips when the robinhood RPC in foundry.toml is unreachable. Nothing is sent to the real chain.
contract FeeSplitterLaunchForkTest is Test, LaunchSplit {
    address constant PINNED_MAINNET_SAFE = 0x7c0fc9869f2D41D88CCA675A9A270214d59DA36a; // SafeCheck pin
    address constant WIF = 0x5173b8eA6923c2d40267890D45C46a3480954773;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;

    FeeSplitter fs;
    bool forked;
    address safe;
    address purses = makeAddr("purses");
    address vault = makeAddr("vault");
    address rebate = makeAddr("rebate");
    address burnBuyer = makeAddr("burnBuyer");
    address ops = makeAddr("ops");
    address deployer = makeAddr("deployer");

    function setUp() public {
        try vm.createSelectFork("robinhood") returns (uint256) {
            forked = true;
        } catch {
            return;
        }
        safe = PINNED_MAINNET_SAFE;
        vm.prank(deployer);
        fs = new FeeSplitter(
            WIF,
            safe,
            FeeSplitter.Recipients(purses, vault, rebate, burnBuyer, ops),
            _launchFeeSplit(),
            makeAddr("fairCore"),
            makeAddr("rakeBuyer")
        );
    }

    modifier onFork() {
        if (!forked) {
            vm.skip(true, "robinhood RPC unavailable");
            return;
        }
        _;
    }

    function test_fork_launch_ownerIsPinnedSafe_splitIsLaunch() public onFork {
        assertGt(safe.code.length, 0, "pinned Safe has code on the fork");
        assertEq(fs.owner(), safe);
        assertEq(fs.pendingOwner(), address(0));
        assertEq(fs.TIMELOCK(), 7 days);
        // option b (4 Nov): 0 purses, 50% vault, 0 rebate, 40% buy and burn, 10% ops
        assertEq(fs.pursesBps(), 0);
        assertEq(fs.vaultBps(), 5000);
        assertEq(fs.rebateBps(), 0);
        assertEq(fs.burnBps(), 4000);
        assertEq(fs.opsBps(), 1000);
        vm.prank(safe);
        vm.expectRevert(FeeSplitter.RenounceDisabled.selector);
        fs.renounceOwnership();
    }

    function test_fork_launch_wifBurnToDead_usdgBurnToBuyer() public onFork {
        uint256 amt = 1_000e18;
        deal(WIF, address(fs), amt);
        if (IERC20(WIF).balanceOf(address(fs)) != amt) {
            vm.skip(true, "deal() did not credit real $wif");
            return;
        }
        uint256 dead0 = IERC20(WIF).balanceOf(fs.DEAD());
        fs.distribute(WIF);
        assertEq(IERC20(WIF).balanceOf(fs.DEAD()) - dead0, amt * 4 / 10, "$wif burn share to dead");
        assertEq(IERC20(WIF).balanceOf(burnBuyer), 0);
        assertEq(IERC20(WIF).balanceOf(purses), 0);
        assertEq(IERC20(WIF).balanceOf(rebate), 0);
        assertEq(IERC20(WIF).balanceOf(vault), amt / 2);
        assertEq(IERC20(WIF).balanceOf(ops), amt / 10);

        uint256 u = 1_000e6;
        deal(USDG, address(fs), u);
        if (IERC20(USDG).balanceOf(address(fs)) != u) {
            vm.skip(true, "deal() did not credit real USDG");
            return;
        }
        fs.distribute(USDG);
        assertEq(IERC20(USDG).balanceOf(burnBuyer), u * 4 / 10, "other tokens: burn leg to the burn buyer");
        assertEq(IERC20(USDG).balanceOf(rebate), 0);
        assertEq(IERC20(USDG).balanceOf(vault), u / 2);
        assertEq(IERC20(USDG).balanceOf(ops), u / 10);
        assertEq(IERC20(USDG).balanceOf(address(fs)), 0);
    }

    function test_fork_launch_changesNeedTheSafeAndSevenDays() public onFork {
        address next = makeAddr("nextOps");
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, deployer));
        fs.queue(FeeSplitter.Op.SetOps, 0, next);

        vm.prank(safe);
        fs.queue(FeeSplitter.Op.SetOps, 0, next);
        uint256 eta = block.timestamp + 7 days;
        vm.warp(eta - 1);
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(FeeSplitter.TooEarly.selector, eta));
        fs.execute(FeeSplitter.Op.SetOps, 0, next);
        vm.warp(eta);
        vm.prank(safe);
        fs.execute(FeeSplitter.Op.SetOps, 0, next);
        assertEq(fs.ops(), next);
    }
}
