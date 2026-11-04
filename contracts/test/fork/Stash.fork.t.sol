// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FairCore} from "../../src/FairCore.sol";
import {FairPass} from "../../src/FairPass.sol";
import {LastArrow} from "../../src/LastArrow.sol";
import {SheriffsSeat} from "../../src/SheriffsSeat.sol";
import {Stash} from "../../src/Stash.sol";
import {DeployStash} from "../../script/DeployStash.s.sol";

/// Fork of chain 46630 against the 7555 deployment file. Fair 1 is live on that FairCore.
/// Deploys Stash in the fork only. Nothing is broadcast.
contract StashForkTest is Test {
    using stdJson for string;

    bool internal forked;

    function setUp() public {
        try vm.createSelectFork(vm.rpcUrl("robinhood_testnet")) {
            forked = true;
        } catch {
            forked = false;
        }
    }

    function test_wiresLiveBooths_andDirectWithdrawPaysFee() public {
        if (!forked) vm.skip(true, "testnet fork unavailable");
        (FairCore core, LastArrow arrow, SheriffsSeat seat, IERC20 usdg, Stash stash, address feeTo) = _deploy();
        _assert7555(core, arrow, seat, usdg);
        assertEq(address(stash.core()), address(core));
        assertEq(address(stash.arrow()), address(arrow));
        assertEq(address(stash.seat()), address(seat));
        assertEq(address(stash.usdg()), address(usdg));
        assertEq(stash.shotFee(), 0.05e6);
        assertEq(stash.withdrawFee(), 1e6);
        assertEq(stash.cap(), 50_000e6);

        address player = makeAddr("forkPlayer");
        deal(address(usdg), player, 100e6);
        vm.startPrank(player);
        usdg.approve(address(stash), type(uint256).max);
        stash.deposit(25e6);
        uint256 wallet = usdg.balanceOf(player);
        stash.withdraw(10e6);
        vm.stopPrank();
        assertEq(stash.balance(player), 15e6);
        assertEq(usdg.balanceOf(player), wallet + 9e6);
        assertEq(usdg.balanceOf(feeTo), 1e6);

        vm.startPrank(player);
        stash.withdraw(14e6);
        assertEq(stash.balance(player), 1e6);
        vm.expectRevert(Stash.BalanceAtOrBelowFee.selector);
        stash.withdraw(1e6);
        vm.stopPrank();
        assertEq(stash.balance(player), 1e6);
        assertEq(usdg.balanceOf(feeTo), 2e6);
    }

    function test_claimBatch_onFork() public {
        if (!forked) vm.skip(true, "testnet fork unavailable");
        (FairCore core, LastArrow arrow, SheriffsSeat seat, IERC20 usdg, Stash stash,) = _deploy();
        _assert7555(core, arrow, seat, usdg);
        if (core.salesPaused()) {
            vm.prank(core.owner());
            core.pauseSales(false);
        }
        (bool active, uint256 fairId) = core.activeFair();
        assertTrue(active, "no fair is live on the 7555 FairCore");
        assertEq(fairId, 1, "expected Fair 1");

        (address playToken, uint256 lock,) = core.config().tokens();
        address player = makeAddr("forkShooter");
        _pass(core, playToken, lock, player);
        deal(address(usdg), player, 20_000e6);
        vm.startPrank(player);
        usdg.approve(address(stash), type(uint256).max);
        stash.deposit(10_000e6);
        vm.stopPrank();

        vm.etch(address(0x64), address(new ForkArb()).code);
        uint256 roundId = arrow.nextShotRound();
        uint256 price = arrow.currentPrice();
        vm.prank(player);
        stash.shoot(price + 1e6, roundId);
        assertEq(arrow.roundState(arrow.currentRound()).lastShooter, player);

        uint256 seatPrice = seat.price();
        vm.prank(player);
        stash.take(seatPrice + 1e6, 0, 3);
        (address holder,,) = seat.holderOf(seat.today());
        assertEq(holder, player);

        uint256 stashBal = stash.balance(player);
        vm.warp(block.timestamp + 2 hours);
        uint256 settledRound = arrow.currentRound();
        arrow.settle(settledRound);
        assertGt(core.claimable(player), 0, "claimable lands on the owner");
        assertEq(stash.balance(player), stashBal, "winnings are not a stash balance");

        uint256 claimable = core.claimable(player);
        uint256 wallet = usdg.balanceOf(player);
        vm.prank(player);
        core.claim();
        vm.prank(player);
        usdg.approve(address(stash), claimable);
        vm.prank(player);
        stash.deposit(claimable);
        assertEq(stash.balance(player), stashBal + claimable);

        uint256 fees = usdg.balanceOf(stash.feeWallet());
        uint256 all = stash.balance(player);
        vm.prank(player);
        stash.withdraw(all);
        assertEq(stash.balance(player), 0);
        assertEq(usdg.balanceOf(player), wallet + stashBal + claimable - 1e6);
        assertEq(usdg.balanceOf(stash.feeWallet()), fees + 1e6, "direct withdraw pays the fee");
    }

    function _deploy()
        internal
        returns (FairCore core, LastArrow arrow, SheriffsSeat seat, IERC20 usdg, Stash stash, address feeTo)
    {
        string memory json = vm.readFile("deployments/46630.json");
        core = FairCore(json.readAddress(".fairCore"));
        arrow = LastArrow(json.readAddress(".lastArrow"));
        seat = SheriffsSeat(json.readAddress(".sheriffsSeat"));
        usdg = IERC20(json.readAddress(".usdg"));
        feeTo = makeAddr("forkFees");
        string[] memory lines = new string[](1);
        lines[0] = "Hold fast";
        stash = new Stash(address(core), address(arrow), address(seat), address(usdg), feeTo, core.owner(), 0.05e6, 1e6, lines);
    }

    function _assert7555(FairCore core, LastArrow arrow, SheriffsSeat seat, IERC20 usdg) internal {
        DeployStash pins = new DeployStash();
        assertEq(address(core), pins.FAIR_CORE(), "fork FairCore");
        assertEq(address(arrow), pins.LAST_ARROW(), "fork LastArrow");
        assertEq(address(seat), pins.SHERIFFS_SEAT(), "fork SheriffsSeat");
        assertEq(address(usdg), pins.USDG(), "fork USDG");
    }

    function _pass(FairCore core, address playToken, uint256 lock, address who) internal {
        deal(playToken, who, lock);
        vm.startPrank(who);
        IERC20(playToken).approve(address(core.fairPass()), lock);
        FairPass(address(core.fairPass())).lock(playToken, lock);
        vm.stopPrank();
    }

}

/// Minimal ArbSys so a fork shot is not stuck on the real precompile block.
contract ForkArb {
    function arbBlockNumber() external view returns (uint256) {
        return 5_000_000 + block.timestamp;
    }

    function arbBlockHash(uint256) external pure returns (bytes32) {
        return bytes32(uint256(1));
    }
}
