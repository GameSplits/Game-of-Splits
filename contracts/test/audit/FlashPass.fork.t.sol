// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FairPass} from "../../src/FairPass.sol";
import {FairCore} from "../../src/FairCore.sol";
import {LastArrow} from "../../src/LastArrow.sol";
import {IFairCore, IGameConfig, Tokens, Split} from "../../src/interfaces/IFair.sol";
import {GameConfig} from "../../src/GameConfig.sol";
import {IPoolManager, IUnlockCallback} from "../../src/interfaces/IV4Minimal.sol";
import {MockArbSys} from "../mocks/Mocks.sol";

/// Tries to borrow 5,000 $wif from the v4 PoolManager for free inside one unlock, lock a Fair Pass, shoot, unlock
/// and repay, all in one transaction. On v3.5 this worked (audit M-1). From v3.6 the 24h hold blocks the unlock.
contract FlashPlayer is IUnlockCallback {
    IPoolManager immutable pm;
    IERC20 immutable wif;
    IERC20 immutable usdg;
    FairPass immutable pass;
    LastArrow immutable arrow;
    FairCore immutable core;

    constructor(IPoolManager pm_, IERC20 wif_, IERC20 usdg_, FairPass pass_, LastArrow arrow_, FairCore core_) {
        (pm, wif, usdg, pass, arrow, core) = (pm_, wif_, usdg_, pass_, arrow_, core_);
    }

    function go() external {
        pm.unlock("");
    }

    function unlockCallback(bytes calldata) external returns (bytes memory) {
        require(msg.sender == address(pm));
        (, uint256 lockAmt,) = pass.config().tokens();
        pm.take(address(wif), address(this), lockAmt); // flash: owe the PoolManager 5,000 $wif
        wif.approve(address(pass), lockAmt);
        pass.lock(address(wif), lockAmt);
        usdg.approve(address(core), type(uint256).max);
        arrow.shoot(type(uint256).max, address(0), arrow.nextShotRound()); // credited to this contract, which "holds a pass"
        pass.unlock();
        pm.sync(address(wif));
        wif.transfer(address(pm), lockAmt); // repay
        pm.settle();
        return "";
    }

    function claim() external {
        core.claim();
    }
}

contract FlashPassForkPoC is Test {
    address constant PM = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant WIF = 0x5173b8eA6923c2d40267890D45C46a3480954773;

    function test_F1_flashLoanedFairPass_isBlockedByTheHold() public {
        vm.createSelectFork("robinhood");
        assertGt(IERC20(WIF).balanceOf(PM), 5_000e18, "PoolManager holds enough $wif to lend");
        vm.etch(address(0x64), address(new MockArbSys()).code);
        MockArbSys(address(0x64)).set(1_000_000);

        address owner = makeAddr("owner");
        GameConfig config = new GameConfig(
            owner, USDG, 7 days, Tokens(WIF, 5_000e18, WIF), Split(6000, 2000, 1750, 1750, 2500, 2500, 2500)
        );
        FairPass pass = new FairPass(IGameConfig(address(config)), owner);
        FairCore core = new FairCore(IERC20(USDG), IGameConfig(address(config)), pass, owner, 48 hours);
        LastArrow arrow = new LastArrow(IFairCore(address(core)));
        uint64 t = uint64(vm.getBlockTimestamp());
        vm.startPrank(owner);
        core.setupSet(FairCore.Op.AddBooth, 0, address(arrow));
        core.finishSetup();
        core.setFair(0, t + 1, t + 30 days);
        vm.stopPrank();
        vm.warp(t + 1);

        FlashPlayer bot = new FlashPlayer(IPoolManager(PM), IERC20(WIF), IERC20(USDG), pass, arrow, core);
        deal(USDG, address(bot), 10e6);

        vm.expectRevert(abi.encodeWithSelector(FairPass.HoldNotOver.selector, uint256(t + 1) + 24 hours));
        bot.go();

        assertEq(arrow.currentRound(), 0, "no shot landed");
        assertFalse(core.playedIn(0, address(bot)));
    }
}
