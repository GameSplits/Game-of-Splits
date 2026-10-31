// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Base} from "../Base.t.sol";
import {GameConfig} from "../../src/GameConfig.sol";
import {Tokens, Split} from "../../src/interfaces/IFair.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {MockToken} from "../mocks/Mocks.sol";

contract NoDecimalsToken {}

contract GameConfigTest is Base {
    // ---------------------------------------------------------------- access

    function test_onlyOwner_everyWrite() public {
        bytes memory unauth = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, ana);
        vm.startPrank(ana);
        vm.expectRevert(unauth);
        config.queueTokens(Tokens(address(tokenB), PASS_LOCK, address(tokenB)));
        vm.expectRevert(unauth);
        config.cancelTokens();
        vm.expectRevert(unauth);
        config.executeTokens();
        vm.expectRevert(unauth);
        config.queueSplit(launchSplit());
        vm.expectRevert(unauth);
        config.cancelSplit();
        vm.expectRevert(unauth);
        config.executeSplit();
        vm.expectRevert(unauth);
        config.bindCore(address(core));
        vm.stopPrank();
    }

    function test_renounceDisabled() public {
        vm.prank(owner);
        vm.expectRevert(GameConfig.RenounceDisabled.selector);
        config.renounceOwnership();
        assertEq(config.owner(), owner);
    }

    function test_bindCore_once() public {
        assertEq(config.core(), address(core));
        vm.prank(owner);
        vm.expectRevert(GameConfig.AlreadyBound.selector);
        config.bindCore(makeAddr("other"));

        GameConfig c = _fresh(0);
        vm.startPrank(owner);
        vm.expectRevert(GameConfig.ZeroAddress.selector);
        c.bindCore(address(0));
        c.queueTokens(Tokens(address(tokenB), PASS_LOCK, address(tokenB)));
        vm.expectRevert(GameConfig.CoreNotBound.selector);
        c.executeTokens(); // no core to ask whether a Fair is running: refuse
        c.queueSplit(launchSplit());
        vm.expectRevert(GameConfig.CoreNotBound.selector);
        c.executeSplit();
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- timelock

    function test_timelock_etaExact() public {
        Tokens memory t = Tokens(address(tokenB), 5_000e18, address(tokenB));
        vm.prank(owner);
        vm.expectEmit(address(config));
        emit GameConfig.TokensQueued(1, t.playToken, t.passLock, t.buyToken, T0 + CONFIG_DELAY);
        config.queueTokens(t);
        uint256 eta = config.tokensEta();
        assertEq(eta, T0 + CONFIG_DELAY);
        (address pp, uint256 pa, address pb) = config.pendingTokens();
        assertEq(pp, address(tokenB));
        assertEq(pa, 5_000e18);
        assertEq(pb, address(tokenB));

        vm.warp(eta - 1);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(GameConfig.TooEarly.selector, eta));
        config.executeTokens();
        (address p0,,) = config.tokens();
        assertEq(p0, address(wif), "nothing changed before the ETA");
        assertEq(config.epoch(), 0);

        vm.warp(eta);
        vm.prank(owner);
        vm.expectEmit(address(config));
        emit GameConfig.TokensExecuted(1, t.playToken, t.passLock, t.buyToken);
        config.executeTokens();
        (address p1, uint256 a1, address b1) = config.tokens();
        assertEq(p1, address(tokenB));
        assertEq(a1, 5_000e18);
        assertEq(b1, address(tokenB));
        assertEq(config.epoch(), 1);
        assertEq(config.tokensEta(), 0);
        (pp,,) = config.pendingTokens();
        assertEq(pp, address(0), "pending cleared");
    }

    function test_onePendingAtATime_cancelResetsEta() public {
        vm.startPrank(owner);
        config.queueTokens(Tokens(address(tokenB), PASS_LOCK, address(tokenB)));
        vm.expectRevert(GameConfig.AlreadyPending.selector);
        config.queueTokens(Tokens(address(wif), 1, address(wif)));
        vm.warp(T0 + 3 days);
        config.cancelTokens();
        assertEq(config.tokensEta(), 0);
        vm.expectRevert(GameConfig.NothingPending.selector);
        config.executeTokens();
        vm.expectRevert(GameConfig.NothingPending.selector);
        config.cancelTokens();
        config.queueTokens(Tokens(address(tokenB), PASS_LOCK, address(tokenB)));
        assertEq(config.tokensEta(), T0 + 3 days + CONFIG_DELAY, "a fresh delay from the new queue");
        vm.warp(T0 + CONFIG_DELAY); // the old ETA
        vm.expectPartialRevert(GameConfig.TooEarly.selector);
        config.executeTokens();
        vm.stopPrank();
    }

    function test_split_onePendingAtATime() public {
        Split memory s = launchSplit();
        s.purseBps = 7000;
        vm.startPrank(owner);
        vm.expectRevert(GameConfig.NothingPending.selector);
        config.executeSplit();
        vm.expectRevert(GameConfig.NothingPending.selector);
        config.cancelSplit();
        config.queueSplit(s);
        vm.expectRevert(GameConfig.AlreadyPending.selector);
        config.queueSplit(s);
        uint256 eta = config.splitEta();
        assertEq(eta, T0 + CONFIG_DELAY);
        assertEq(config.pendingSplit().purseBps, 7000);
        vm.warp(eta - 1);
        vm.expectRevert(abi.encodeWithSelector(GameConfig.TooEarly.selector, eta));
        config.executeSplit();
        vm.warp(eta);
        config.executeSplit();
        vm.stopPrank();
        assertEq(config.split().purseBps, 7000);
        assertEq(config.splitEta(), 0);
        assertEq(config.epoch(), 0, "a split update doesn't move the epoch");
    }

    function test_executeTokens_refusedWhileAFairRuns() public {
        vm.startPrank(owner);
        core.setFair(1, T0 + 6 days, T0 + 10 days); // covers the ETA
        config.queueTokens(Tokens(address(tokenB), PASS_LOCK, address(tokenB)));
        vm.warp(config.tokensEta());
        vm.expectRevert(abi.encodeWithSelector(GameConfig.FairActive.selector, 1));
        config.executeTokens();
        vm.warp(T0 + 10 days); // Fair 1 over
        config.executeTokens();
        vm.stopPrank();
        assertEq(config.epoch(), 1);
    }

    function test_executeSplit_refusedWhileAFairRuns() public {
        Split memory s = launchSplit();
        s.tollBps = 1500;
        s.bonfireBps = 2000;
        vm.startPrank(owner);
        core.setFair(1, T0 + 6 days, T0 + 10 days); // covers the ETA
        config.queueSplit(s);
        vm.warp(config.splitEta());
        vm.expectRevert(abi.encodeWithSelector(GameConfig.FairActive.selector, 1));
        config.executeSplit();
        assertEq(config.split().tollBps, 1750, "unchanged while Fair 1 runs");
        vm.warp(T0 + 10 days); // Fair 1 over
        vm.expectEmit(address(config));
        emit GameConfig.SplitExecuted(s);
        config.executeSplit();
        vm.stopPrank();
        assertEq(config.split().tollBps, 1500);
        assertEq(config.split().bonfireBps, 2000);
    }

    function test_mainnetDelayAtLeast7Days() public {
        vm.chainId(4663);
        vm.expectRevert(GameConfig.DelayTooShort.selector);
        _fresh(7 days - 1);
        assertEq(_fresh(7 days).delay(), 7 days);
        vm.chainId(46630);
        assertEq(_fresh(0).delay(), 0, "testnet may run with no delay");
    }

    // ---------------------------------------------------------------- validation

    function test_tokens_validation() public {
        address eoa = makeAddr("eoa");
        vm.startPrank(owner);
        vm.expectRevert(GameConfig.ZeroAddress.selector);
        config.queueTokens(Tokens(address(0), PASS_LOCK, address(wif)));
        vm.expectRevert(GameConfig.ZeroAddress.selector);
        config.queueTokens(Tokens(address(wif), PASS_LOCK, address(0)));
        vm.expectRevert(abi.encodeWithSelector(GameConfig.NotAContract.selector, eoa));
        config.queueTokens(Tokens(eoa, PASS_LOCK, address(wif)));
        vm.expectRevert(abi.encodeWithSelector(GameConfig.NotAContract.selector, eoa));
        config.queueTokens(Tokens(address(wif), PASS_LOCK, eoa));
        vm.expectRevert(GameConfig.TokenIsUsdg.selector);
        config.queueTokens(Tokens(address(usdg), PASS_LOCK, address(wif)));
        vm.expectRevert(GameConfig.TokenIsUsdg.selector);
        config.queueTokens(Tokens(address(wif), PASS_LOCK, address(usdg)));
        vm.expectRevert(GameConfig.BadPassLock.selector);
        config.queueTokens(Tokens(address(wif), 0, address(wif)));
        vm.expectRevert(GameConfig.BadPassLock.selector);
        config.queueTokens(Tokens(address(wif), uint256(type(uint128).max) + 1, address(wif)));
        vm.stopPrank();
        assertEq(config.tokensEta(), 0, "nothing queued");
    }

    function test_GC01_tokensMustHave18Decimals() public {
        MockToken eight = new MockToken("Eight", "EIGHT", 8);
        NoDecimalsToken bare = new NoDecimalsToken();
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(GameConfig.BadDecimals.selector, address(eight)));
        config.queueTokens(Tokens(address(eight), PASS_LOCK, address(wif)));
        vm.expectRevert(abi.encodeWithSelector(GameConfig.BadDecimals.selector, address(eight)));
        config.queueTokens(Tokens(address(wif), PASS_LOCK, address(eight)));
        vm.expectRevert(abi.encodeWithSelector(GameConfig.BadDecimals.selector, address(bare)));
        config.queueTokens(Tokens(address(bare), PASS_LOCK, address(wif)));
        vm.stopPrank();
        vm.expectRevert(abi.encodeWithSelector(GameConfig.BadDecimals.selector, address(eight)));
        new GameConfig(owner, address(usdg), 0, Tokens(address(eight), PASS_LOCK, address(wif)), launchSplit());
        vm.expectRevert(abi.encodeWithSelector(GameConfig.BadDecimals.selector, address(bare)));
        new GameConfig(owner, address(usdg), 0, Tokens(address(bare), PASS_LOCK, address(wif)), launchSplit());
        assertEq(config.tokensEta(), 0);
    }

    function test_constructor_validates() public {
        vm.expectRevert(GameConfig.ZeroAddress.selector);
        new GameConfig(owner, address(0), 0, Tokens(address(wif), PASS_LOCK, address(wif)), launchSplit());
        vm.expectRevert(GameConfig.TokenIsUsdg.selector);
        new GameConfig(owner, address(usdg), 0, Tokens(address(usdg), PASS_LOCK, address(wif)), launchSplit());
        Split memory s = launchSplit();
        s.purseBps = 9000;
        vm.expectRevert(GameConfig.BadSplit.selector);
        new GameConfig(owner, address(usdg), 0, Tokens(address(wif), PASS_LOCK, address(wif)), s);
    }

    function test_split_capsAndSums() public {
        // purse range
        _badSplit(Split(4999, 2000, 1750, 1750, 2500, 2500, 2500));
        _badSplit(Split(8001, 2000, 1750, 1750, 2500, 2500, 2500));
        // Greenwood: alms floor and cap, part caps, sum over 10000, remainder (Vault) cap
        _badSplit(Split(6000, 999, 1750, 1750, 2500, 2500, 2500));
        _badSplit(Split(6000, 5001, 1750, 1750, 2500, 2500, 2500));
        _badSplit(Split(6000, 2000, 5001, 1750, 2500, 2500, 2500));
        _badSplit(Split(6000, 2000, 1750, 5001, 2500, 2500, 2500));
        _badSplit(Split(6000, 5000, 5000, 1000, 2500, 2500, 2500)); // 11000
        _badSplit(Split(6000, 1000, 1000, 1000, 2500, 2500, 2500)); // Vault share 70%
        // Vault: part caps, sum over 10000, remainder cap
        _badSplit(Split(6000, 2000, 1750, 1750, 5001, 2500, 2500));
        _badSplit(Split(6000, 2000, 1750, 1750, 2500, 5001, 2500));
        _badSplit(Split(6000, 2000, 1750, 1750, 2500, 2500, 5001));
        _badSplit(Split(6000, 2000, 1750, 1750, 5000, 5000, 1000)); // 11000
        _badSplit(Split(6000, 2000, 1750, 1750, 1000, 1000, 1000)); // remainder 70%
        // edges that pass
        vm.startPrank(owner);
        config.queueSplit(Split(8000, 5000, 0, 0, 5000, 0, 0)); // both remainders exactly 50%
        config.cancelSplit();
        config.queueSplit(Split(5000, 1000, 5000, 4000, 5000, 5000, 0)); // remainders 0
        vm.stopPrank();
    }

    function _badSplit(Split memory s) internal {
        vm.prank(owner);
        vm.expectRevert(GameConfig.BadSplit.selector);
        config.queueSplit(s);
    }

    function _fresh(uint256 delay) internal returns (GameConfig) {
        return new GameConfig(owner, address(usdg), delay, Tokens(address(wif), PASS_LOCK, address(wif)), launchSplit());
    }
}
