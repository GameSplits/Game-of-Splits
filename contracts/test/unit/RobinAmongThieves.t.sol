// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {RatBase, RatHarness} from "../RatBase.t.sol";
import {RobinAmongThieves} from "../../src/RobinAmongThieves.sol";
import {GameConfig} from "../../src/GameConfig.sol";
import {IFairCore, IFairPass, IGameConfig, Tokens} from "../../src/interfaces/IFair.sol";
import {IIdentityRegistry, IReputationRegistry} from "../../src/interfaces/I8004.sol";
import {MockToken, FeeToken, MockArbSys} from "../mocks/Mocks.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract RatLifecycleTest is RatBase {
    RobinAmongThieves.Choice constant SHARE = RobinAmongThieves.Choice.Share;
    RobinAmongThieves.Choice constant STEAL = RobinAmongThieves.Choice.Steal;
    RobinAmongThieves.Choice constant NONE = RobinAmongThieves.Choice.None;

    // ---------------------------------------------------------------- construction

    function test_constructor_usdgMustBe6Decimals() public {
        MockToken usdg18 = new MockToken("USDG18", "USDG18", 18);
        GameConfig c18 =
            new GameConfig(owner, address(usdg18), 0, Tokens(address(wif), PASS_LOCK, address(wif)), launchSplit());
        RobinAmongThieves.Params memory p = _params();
        p.usdg = usdg18;
        p.config = IGameConfig(address(c18));
        vm.expectRevert(RobinAmongThieves.BadDecimals.selector);
        new RobinAmongThieves(p);
    }

    function test_constructor_checks() public {
        RobinAmongThieves.Params memory p = _params();
        p.rakeSink = address(0);
        vm.expectRevert(RobinAmongThieves.ZeroAddress.selector);
        new RobinAmongThieves(p);
        p = _params();
        p.identity = IIdentityRegistry(address(0));
        vm.expectRevert(RobinAmongThieves.ZeroAddress.selector);
        new RobinAmongThieves(p);
        p = _params();
        p.core = IFairCore(address(0));
        vm.expectRevert(RobinAmongThieves.ZeroAddress.selector);
        new RobinAmongThieves(p);
        p = _params();
        p.genesis = T0 + 1;
        vm.expectRevert(RobinAmongThieves.BadGenesis.selector);
        new RobinAmongThieves(p);
        // a config for another USDG
        MockToken other = new MockToken("USDG", "USDG", 6);
        GameConfig c2 =
            new GameConfig(owner, address(other), 0, Tokens(address(wif), PASS_LOCK, address(wif)), launchSplit());
        p = _params();
        p.config = IGameConfig(address(c2));
        vm.expectRevert(RobinAmongThieves.ConfigMismatch.selector);
        new RobinAmongThieves(p);
    }

    function test_constructor_mainnetDelays() public {
        vm.chainId(4663);
        RobinAmongThieves.Params memory p = _params();
        p.timelockDelay = 48 hours - 1;
        vm.expectRevert(abi.encodeWithSelector(RobinAmongThieves.TooEarly.selector, 48 hours));
        new RobinAmongThieves(p);
        p = _params();
        p.bondDelay = 7 days - 1;
        vm.expectRevert(abi.encodeWithSelector(RobinAmongThieves.TooEarly.selector, 7 days));
        new RobinAmongThieves(p);
        p = _params();
        RobinAmongThieves r = new RobinAmongThieves(p);
        assertEq(r.timelockDelay(), 48 hours);
        assertEq(r.bondDelay(), 7 days);
        assertFalse(r.bondsEnabled());
        assertEq(r.licenceAmount(), 1000e18);
        assertEq(r.drawBps(), 2500);
    }

    // ---------------------------------------------------------------- registration and licence

    function test_registerOutlawNew_userOwnsIt_ratNotApproved() public {
        uint256 id = reg(ana);
        assertEq(idr.ownerOf(id), ana);
        assertFalse(idr.isAuthorizedOrOwner(address(rat), id), "I8");
        assertEq(idr.getAgentWallet(id), address(0), "the registry clears the wallet on transfer");
        (address ctl, uint64 at,,, address lt,,,,,, uint128 lic,,,,) = rat.outlaws(id);
        assertEq(ctl, ana);
        assertEq(at, T0);
        assertEq(lt, address(wif));
        assertEq(lic, LIC);
        assertEq(rat.lockedOf(address(wif)), LIC);
        assertEq(wif.balanceOf(address(rat)), LIC);
    }

    function test_registerOutlaw_existingIdentity_ownerOrWallet() public {
        vm.prank(bob);
        uint256 id = idr.register("x"); // bob owns it, and is its wallet
        vm.prank(ana);
        vm.expectRevert(RobinAmongThieves.NotAgentOwner.selector);
        rat.registerOutlaw(id, address(0), address(wif), LIC);
        vm.prank(bob);
        idr.setAgentWallet(id, cat);
        vm.prank(cat);
        rat.registerOutlaw(id, address(0), address(wif), LIC); // the agent wallet may register it
        (address ctl,,,,,,,,,,,,,,) = rat.outlaws(id);
        assertEq(ctl, cat);
        vm.prank(bob);
        vm.expectRevert(RobinAmongThieves.AlreadyRegistered.selector);
        rat.registerOutlaw(id, address(0), address(wif), LIC);
    }

    function test_register_tokenChanged() public {
        vm.startPrank(ana);
        vm.expectRevert(RobinAmongThieves.TokenChanged.selector);
        rat.registerOutlawNew("x", address(0), address(tokenB), LIC);
        vm.expectRevert(RobinAmongThieves.TokenChanged.selector);
        rat.registerOutlawNew("x", address(0), address(wif), LIC - 1);
        vm.stopPrank();
    }

    function test_register_feeToken_transferMismatch() public {
        FeeToken fee = new FeeToken();
        applyTokens(address(fee), PASS_LOCK, address(wif));
        fee.mint(ana, 10_000e18);
        vm.startPrank(ana);
        fee.approve(address(rat), type(uint256).max);
        vm.stopPrank();
        // The wif pass no longer counts, so the gate refuses before the pull.
        vm.prank(ana);
        vm.expectRevert(RobinAmongThieves.NoPass.selector);
        rat.registerOutlawNew("x", address(0), address(fee), LIC);
        // A pass that still counts cannot paper over a fee-on-transfer licence.
        vm.mockCall(address(pass), abi.encodeWithSelector(IFairPass.hasPass.selector, ana), abi.encode(true));
        vm.prank(ana);
        vm.expectRevert(RobinAmongThieves.TransferMismatch.selector);
        rat.registerOutlawNew("x", address(0), address(fee), LIC);
        vm.clearMockedCalls();
    }

    function test_onERC721Received_refusesUnsolicitedIdentity() public {
        vm.prank(ana);
        uint256 id = idr.register("x");
        vm.prank(ana);
        vm.expectRevert(RobinAmongThieves.NotMinting.selector);
        idr.safeTransferFrom(ana, address(rat), id);
    }

    /// The licence comes back in the token and amount it was locked in, whatever GameConfig says now.
    function test_licence_returnedInSnapshot_afterConfigUpdate() public {
        uint256 id = reg(ana);
        applyTokens(address(tokenB), PASS_LOCK, address(tokenB));
        vm.prank(owner);
        rat.queue(RobinAmongThieves.Op.SetLicenceAmount, 5e18, address(0));
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        vm.prank(owner);
        rat.execute(RobinAmongThieves.Op.SetLicenceAmount, 5e18, address(0));
        uint256 before = wif.balanceOf(ana);
        vm.prank(ana);
        rat.retire(id);
        assertEq(wif.balanceOf(ana), before + LIC);
        assertEq(rat.lockedOf(address(wif)), 0);
        // a new registration now locks the new token and amount, and needs a pass in that token
        vm.prank(bob);
        pass.unlock();
        lockPass(bob);
        vm.prank(bob);
        uint256 id2 = rat.registerOutlawNew("x", address(0), address(tokenB), 5e18);
        (,,,, address lt,,,,,, uint128 lic,,,,) = rat.outlaws(id2);
        assertEq(lt, address(tokenB));
        assertEq(lic, 5e18);
    }

    function test_retire_rules() public {
        uint256 id = regFunded(ana, 20e6);
        vm.prank(ana);
        vm.expectRevert(abi.encodeWithSelector(RobinAmongThieves.LicenceHeld.selector, uint256(T0) + 24 hours));
        rat.retire(id);
        vm.warp(T0 + 24 hours - 1);
        vm.prank(ana);
        vm.expectRevert(abi.encodeWithSelector(RobinAmongThieves.LicenceHeld.selector, uint256(T0) + 24 hours));
        rat.retire(id);
        // an open entry blocks it
        uint256 r = rat.currentRound();
        enterAs(ana, id, r);
        vm.warp(T0 + 24 hours);
        vm.prank(ana);
        vm.expectRevert(RobinAmongThieves.OpenRound.selector);
        rat.retire(id);
        vm.warp(rat.closeTime(r) + 8 minutes);
        rat.cancelRound(r, 10); // nobody revealed a seed: the entry is refunded
        uint256 u = usdg.balanceOf(ana);
        uint256 w = wif.balanceOf(ana);
        vm.prank(bob);
        vm.expectRevert(RobinAmongThieves.NotController.selector);
        rat.retire(id);
        vm.prank(ana);
        rat.retire(id);
        assertEq(usdg.balanceOf(ana), u + 20e6, "budget back");
        assertEq(wif.balanceOf(ana), w + LIC, "licence back");
        assertEq(rat.freeBalances(), 0);
        ledgersOk();
        // the identity can register again
        vm.prank(ana);
        rat.registerOutlaw(id, address(0), address(wif), LIC);
    }

    // ---------------------------------------------------------------- operator, deposit, withdraw

    function test_operator_canPlayOnly() public {
        uint256 id = regFunded(ana, 20e6);
        uint256 b = regFunded(bob, 20e6);
        vm.prank(ana);
        rat.setOperator(id, opr);
        vm.warp(windowStart(FIRST));
        enterAs(opr, id, FIRST);
        enterAs(bob, b, FIRST);
        seedPair(FIRST);
        commitAs(opr, id, FIRST, SHARE);
        vm.startPrank(opr);
        vm.expectRevert(RobinAmongThieves.NotController.selector);
        rat.withdraw(id, 1e6, opr);
        vm.expectRevert(RobinAmongThieves.NotController.selector);
        rat.retire(id);
        vm.expectRevert(RobinAmongThieves.NotController.selector);
        rat.setOperator(id, opr);
        vm.expectRevert(RobinAmongThieves.NotController.selector);
        rat.unbond(id);
        vm.expectRevert(RobinAmongThieves.BondsDisabled.selector);
        rat.bond(id, 1, address(wif));
        vm.stopPrank();
        revealAs(opr, id, FIRST, SHARE);
        // revoke at once: the operator can no longer play
        vm.prank(ana);
        rat.setOperator(id, address(0));
        vm.prank(opr);
        vm.expectRevert(RobinAmongThieves.NotPlayer.selector);
        rat.reveal(FIRST, id, SHARE, salt(id, FIRST));
    }

    function test_deposit_withdraw() public {
        uint256 id = reg(ana);
        vm.prank(cat);
        rat.deposit(id, 7e6); // anyone may fund
        vm.expectRevert(RobinAmongThieves.ZeroAmount.selector);
        rat.deposit(id, 0);
        vm.expectRevert(RobinAmongThieves.NotRegistered.selector);
        rat.deposit(999, 1e6);
        assertEq(bal(id), 7e6);
        vm.prank(ana);
        vm.expectRevert(RobinAmongThieves.InsufficientBalance.selector);
        rat.withdraw(id, 7e6 + 1, ana);
        vm.prank(ana);
        vm.expectRevert(RobinAmongThieves.ZeroAddress.selector);
        rat.withdraw(id, 1, address(0));
        uint256 before = usdg.balanceOf(dan);
        vm.prank(ana);
        rat.withdraw(id, 3e6, dan);
        assertEq(usdg.balanceOf(dan), before + 3e6);
        assertEq(bal(id), 4e6);
        ledgersOk();
    }

    function test_house_withdrawAlwaysToHouseSink() public {
        uint256 h = regHouse(60e6);
        vm.prank(house);
        rat.withdraw(h, 10e6, house); // `to` is ignored
        assertEq(usdg.balanceOf(houseSink), 10e6);
        vm.warp(T0 + 24 hours);
        uint256 w = wif.balanceOf(house);
        vm.prank(house);
        rat.retire(h);
        assertEq(usdg.balanceOf(houseSink), 60e6, "the rest of the float goes to the vault too");
        assertEq(wif.balanceOf(house), w + LIC, "the licence returns to the house wallet");
        (,,,,,, bool isHouse,,,,,,,,) = rat.outlaws(h);
        assertFalse(isHouse, "house status ends with the outlaw");
    }

    function test_setHouse_onlyOwner_registered() public {
        uint256 id = reg(ana);
        vm.prank(ana);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, ana));
        rat.setHouse(id, true);
        vm.prank(owner);
        vm.expectRevert(RobinAmongThieves.NotRegistered.selector);
        rat.setHouse(77, true);
    }

    /// M-1: house status is opt-in. The Safe can't make a player's outlaw a house outlaw (which would send its USDG to
    /// houseSink) unless the controller asked.
    function test_house_optIn_only() public {
        uint256 id = regFunded(ana, 20e6);
        vm.prank(owner);
        vm.expectRevert(RobinAmongThieves.HouseNotRequested.selector);
        rat.setHouse(id, true);
        // the operator can't ask for it
        vm.prank(ana);
        rat.setOperator(id, opr);
        vm.prank(opr);
        vm.expectRevert(RobinAmongThieves.NotController.selector);
        rat.requestHouse(id);
        withdrawTo(id, 1e6, dan, dan); // still a player: withdrawals go where the controller says
        // request, then flag
        vm.expectEmit(true, false, false, false, address(rat));
        emit RobinAmongThieves.HouseRequested(id);
        vm.prank(ana);
        rat.requestHouse(id);
        assertTrue(rat.houseRequested(id));
        vm.prank(owner);
        rat.setHouse(id, true);
        withdrawTo(id, 1e6, dan, houseSink);
        // un-flagging is immediate
        vm.prank(owner);
        rat.setHouse(id, false);
        withdrawTo(id, 1e6, dan, dan);
        // retire clears both flags: the identity registers again as a player
        vm.prank(owner);
        rat.setHouse(id, true);
        vm.warp(T0 + 24 hours);
        vm.prank(ana);
        rat.retire(id);
        assertFalse(rat.houseRequested(id));
        vm.prank(ana);
        rat.registerOutlaw(id, address(0), address(wif), LIC);
        (,,,,,, bool isHouse,,,,,,,,) = rat.outlaws(id);
        assertFalse(isHouse);
        vm.prank(owner);
        vm.expectRevert(RobinAmongThieves.HouseNotRequested.selector);
        rat.setHouse(id, true);
    }

    /// Withdraw 'amt' from ana's outlaw asking for `to`; check where it actually went.
    function withdrawTo(uint256 id, uint256 amt, address to, address expected) internal {
        uint256 before = usdg.balanceOf(expected);
        vm.prank(ana);
        rat.withdraw(id, amt, to);
        assertEq(usdg.balanceOf(expected), before + amt);
    }

    // ---------------------------------------------------------------- entering

    /// One successful enter, so the gas report for `enter` is that call alone.
    function test_enter_gasProbe() public {
        uint256 id = regFunded(ana, 20e6);
        enterAs(ana, id, rat.currentRound());
    }

    /// Fund `who` for the camp without locking a Fair Pass.
    function fundNoPass(address who) internal {
        usdg.mint(who, 1_000_000e6);
        wif.mint(who, 100_000e18);
        vm.startPrank(who);
        usdg.approve(address(rat), type(uint256).max);
        wif.approve(address(rat), type(uint256).max);
        wif.approve(address(pass), type(uint256).max);
        vm.stopPrank();
    }

    function test_fairPass_noPass_revertsRegisterAndEnter() public {
        address newbie = makeAddr("noPass");
        fundNoPass(newbie);
        uint256 w = wif.balanceOf(newbie);
        uint256 ratW = wif.balanceOf(address(rat));
        vm.prank(newbie);
        vm.expectRevert(RobinAmongThieves.NoPass.selector);
        rat.registerOutlawNew("ipfs://nope", address(0), address(wif), LIC);
        assertEq(wif.balanceOf(newbie), w, "a refused register moves no licence");
        assertEq(wif.balanceOf(address(rat)), ratW);
        assertEq(rat.lockedOf(address(wif)), 0);

        uint256 id = regFunded(ana, 20e6); // ana holds a pass
        vm.warp(pass.unlockableAt(ana));
        vm.prank(ana);
        pass.unlock();
        assertFalse(pass.hasPass(ana));
        uint256 r = rat.currentRound();
        vm.prank(ana);
        vm.expectRevert(RobinAmongThieves.NoPass.selector);
        rat.enter(id, r, bytes32("off"));
        assertEq(bal(id), 20e6, "a refused enter reserves nothing");
        assertEq(rat.reservedStakes(), 0);
    }

    function test_fairPass_withPass_registerAndEnter() public {
        assertTrue(pass.hasPass(ana));
        uint256 before = wif.balanceOf(ana);
        uint256 id = regFunded(ana, 20e6);
        assertEq(wif.balanceOf(ana), before - LIC);
        assertEq(wif.balanceOf(address(rat)), LIC);
        assertEq(rat.lockedOf(address(wif)), LIC);
        enterAs(ana, id, rat.currentRound());
        assertEq(bal(id), 15e6);
        assertEq(rat.reservedStakes(), 5e6);
    }

    /// The player is the controller. An operator or the ERC-8004 wallet may send the call; the pass is the controller's.
    function test_fairPass_operatorAndAgentWallet() public {
        address wallet = makeAddr("agentWallet");
        address bare = makeAddr("bareOperator");
        address ownerNoPass = makeAddr("ownerNoPass");
        fundNoPass(wallet);
        fundNoPass(ownerNoPass);
        lockPass(wallet); // locked at T0, so it can be unlocked during an open round
        ratFund(bare); // locks a pass, dropped below so the operator itself holds none

        vm.warp(pass.unlockableAt(bare));
        vm.prank(bare);
        pass.unlock();
        assertFalse(pass.hasPass(bare));
        assertTrue(pass.hasPass(wallet));

        // The NFT owner has no pass. The agent wallet does, and registering makes the wallet the controller.
        vm.prank(ownerNoPass);
        uint256 id = idr.register("owned");
        vm.prank(ownerNoPass);
        idr.setAgentWallet(id, wallet);
        vm.prank(ownerNoPass);
        vm.expectRevert(RobinAmongThieves.NoPass.selector);
        rat.registerOutlaw(id, address(0), address(wif), LIC);
        uint256 wBefore = wif.balanceOf(wallet);
        vm.prank(wallet);
        rat.registerOutlaw(id, bare, address(wif), LIC);
        assertEq(wif.balanceOf(wallet), wBefore - LIC);
        (address ctl,,,,,,,,,,,,,,) = rat.outlaws(id);
        assertEq(ctl, wallet, "the agent wallet that registered is the controller");

        vm.prank(wallet);
        rat.deposit(id, 20e6);
        uint256 r = rat.currentRound();
        uint256 anaId = regFunded(ana, 20e6);
        enterAs(bare, id, r); // operator holds no pass; the controller does
        enterAs(ana, anaId, r);
        assertEq(bal(id), 15e6);

        // A wallet that is neither controller nor operator cannot enter, pass or not.
        vm.prank(ownerNoPass);
        vm.expectRevert(RobinAmongThieves.NotPlayer.selector);
        rat.enter(id, r, bytes32("no"));

        // Pass withdrawn after entry: the open round can still be committed. A later entry cannot.
        vm.prank(wallet);
        pass.unlock();
        assertFalse(pass.hasPass(wallet));
        seedPair(r);
        commitAs(bare, id, r, SHARE);
        settleAll(r);
        assertEq(openRoundOf(id), 0);
        uint256 later = rat.currentRound();
        vm.prank(bare);
        vm.expectRevert(RobinAmongThieves.NoPass.selector);
        rat.enter(id, later, bytes32("later"));
    }

    /// Unlocking the pass after registering blocks enter. Retire still returns the licence, the bond and the budget.
    function test_fairPass_lapsed_blocksEnter_retireReturnsAll() public {
        uint256 id = regFunded(ana, 40e6);
        vm.prank(owner);
        rat.queueBonds(true, 0);
        vm.warp(rat.bondOpEta());
        vm.prank(owner);
        rat.executeBonds();
        vm.prank(ana);
        rat.bond(id, 10e18, address(wif));

        uint256 r = rat.currentRound();
        enterAs(ana, id, r); // pass still held
        vm.warp(rat.closeTime(r) + 8 minutes);
        rat.cancelRound(r, 10);

        vm.prank(ana);
        pass.unlock();
        assertFalse(pass.hasPass(ana));
        uint256 ratW = wif.balanceOf(address(rat));
        uint256 ratU = usdg.balanceOf(address(rat));
        uint256 next = rat.currentRound();
        vm.prank(ana);
        vm.expectRevert(RobinAmongThieves.NoPass.selector);
        rat.enter(id, next, bytes32("lapsed"));
        assertEq(wif.balanceOf(address(rat)), ratW);
        assertEq(usdg.balanceOf(address(rat)), ratU);

        // Free budget can leave while the pass is gone, and before the licence hold is over.
        vm.prank(ana);
        rat.withdraw(id, 15e6, ana);
        assertEq(bal(id), 25e6);

        uint256 until = T0 + 24 hours;
        if (block.timestamp < until) {
            vm.warp(until - 1);
            vm.prank(ana);
            vm.expectRevert(abi.encodeWithSelector(RobinAmongThieves.LicenceHeld.selector, until));
            rat.retire(id);
            vm.warp(until);
        }
        uint256 u = usdg.balanceOf(ana);
        uint256 w = wif.balanceOf(ana);
        vm.prank(ana);
        rat.retire(id);
        assertEq(usdg.balanceOf(ana), u + 25e6, "budget back");
        assertEq(wif.balanceOf(ana), w + LIC + 10e18, "licence and bond back");
        assertEq(rat.lockedOf(address(wif)), 0);
        assertEq(wif.balanceOf(address(rat)), 0);
        assertEq(usdg.balanceOf(address(rat)), 0);
        ledgersOk();
    }

    function test_enter_rules() public {
        uint256 id = regFunded(ana, 9e6);
        uint256 r = rat.currentRound();
        assertEq(r, 1);
        vm.prank(ana);
        vm.expectRevert(RobinAmongThieves.WrongRound.selector);
        rat.enter(id, r + 1, 0);
        vm.prank(bob);
        vm.expectRevert(RobinAmongThieves.NotPlayer.selector);
        rat.enter(id, r, 0);
        enterAs(ana, id, r);
        vm.prank(ana);
        vm.expectRevert(RobinAmongThieves.AlreadyEntered.selector);
        rat.enter(id, r, 0);
        assertEq(bal(id), 4e6);
        assertEq(rat.reservedStakes(), 5e6);
        // after a refund and a withdrawal, 4 USDG is less than a stake
        vm.warp(rat.closeTime(r) + 8 minutes);
        rat.cancelRound(r, 10);
        vm.prank(ana);
        rat.withdraw(id, 5e6, ana);
        uint256 r2 = rat.currentRound();
        vm.prank(ana);
        vm.expectRevert(RobinAmongThieves.InsufficientBalance.selector);
        rat.enter(id, r2, 0);
    }

    function test_enter_entriesCloseAtT() public {
        uint256 id = regFunded(ana, 20e6);
        uint256 r = rat.currentRound();
        vm.warp(rat.closeTime(r) - 1);
        enterAs(ana, id, r); // T-1: still open
        uint256 b = regFunded(bob, 20e6);
        vm.warp(rat.closeTime(r));
        vm.prank(bob);
        vm.expectRevert(RobinAmongThieves.WrongRound.selector);
        rat.enter(b, r, 0); // T: closed, round r+1 takes entries
        enterAs(bob, b, r + 1);
    }

    function test_enter_identitySold_oldControllerCantPlay() public {
        uint256 id = regFunded(ana, 20e6);
        vm.prank(ana);
        idr.transferFrom(ana, cat, id);
        vm.prank(ana);
        vm.expectRevert(RobinAmongThieves.NotAgentOwner.selector);
        rat.enter(id, 1, 0);
        // the money is still the controller's
        vm.prank(ana);
        rat.withdraw(id, 20e6, ana);
    }

    function test_pause_stopsEnterOnly() public {
        uint256 a = regFunded(ana, 20e6);
        uint256 b = regFunded(bob, 20e6);
        vm.warp(windowStart(FIRST));
        enterAs(ana, a, FIRST);
        enterAs(bob, b, FIRST);
        vm.prank(owner);
        rat.pauseEntries(true);
        uint256 c = regFunded(cat, 20e6);
        vm.prank(cat);
        vm.expectRevert(RobinAmongThieves.EntriesArePaused.selector);
        rat.enter(c, FIRST, 0);
        // everything else keeps working
        seedPair(FIRST);
        commitAs(ana, a, FIRST, SHARE);
        commitAs(bob, b, FIRST, SHARE);
        revealAs(ana, a, FIRST, SHARE);
        revealAs(bob, b, FIRST, SHARE);
        settleAll(FIRST);
        rat.flushRake();
        vm.prank(ana);
        rat.withdraw(a, 1e6, ana);
        vm.warp(T0 + 26 hours);
        vm.prank(cat);
        rat.retire(c);
        vm.prank(owner);
        rat.pauseEntries(false);
    }

    function test_house_entryWindow() public {
        uint256 h = regHouse(60e6);
        vm.warp(windowStart(FIRST) + 5 minutes);
        vm.prank(house);
        vm.expectRevert(RobinAmongThieves.HouseWindowClosed.selector);
        rat.enter(h, FIRST, 0);
        vm.warp(windowStart(FIRST) + 5 minutes - 1);
        enterAs(house, h, FIRST);
    }

    function test_roundFull_at256() public {
        vm.warp(windowStart(FIRST));
        for (uint256 i; i < 256; ++i) {
            address w = address(uint160(0x10000 + i));
            ratFund(w);
            uint256 id = regFunded(w, 5e6);
            enterAs(w, id, FIRST);
        }
        address x = address(uint160(0x20000));
        ratFund(x);
        uint256 last = regFunded(x, 5e6);
        vm.prank(x);
        vm.expectRevert(RobinAmongThieves.RoundFull.selector);
        rat.enter(last, FIRST, 0);
        // a full round still pairs in batches
        vm.warp(rat.closeTime(FIRST));
        rat.revealSeed(FIRST, chain[nextLink++]);
        advanceL2();
        for (uint256 i; i < 20 && rat.reservedStakes() != 0; ++i) {
            (,,,,,,,,,, RobinAmongThieves.Status s,,,,,,,) = rat.rounds(FIRST);
            if (s != RobinAmongThieves.Status.Open) break;
            rat.pair(FIRST, 16);
        }
        (,,,,, uint32 shuffled, uint32 m,,,, RobinAmongThieves.Status st,,,,,,,) = rat.rounds(FIRST);
        assertEq(uint8(st), uint8(RobinAmongThieves.Status.Paired));
        assertEq(m, 128, "256 distinct outlaws: everyone paired");
        assertEq(shuffled, 256);
    }

    // ---------------------------------------------------------------- loot table (exact numbers)

    function _two() internal returns (uint256 a, uint256 b) {
        a = regFunded(ana, 50e6);
        b = regFunded(bob, 50e6);
    }

    function _check(uint256 a, uint256 b, uint256 payA, uint256 payB, uint256 toPot) internal view {
        assertEq(bal(a), 45e6 + payA, "A");
        assertEq(bal(b), 45e6 + payB, "B");
        assertEq(rat.sharingPot(), toPot, "pot");
        assertEq(rat.rakePending(), 300_000, "rake");
        assertEq(payA + payB + toPot + 300_000, 10e6, "I2");
        assertEq(rat.reservedStakes(), 0);
        ledgersOk();
    }

    function test_loot_bothShare() public {
        (uint256 a, uint256 b) = _two();
        playMatch(FIRST, ana, a, SHARE, bob, b, SHARE);
        _check(a, b, 4_750_000, 4_750_000, 200_000);
        assertEq(rep.lastValue(a), 100);
        assertEq(rep.lastTag2(a), "share");
    }

    function test_loot_aSteals() public {
        (uint256 a, uint256 b) = _two();
        playMatch(FIRST, ana, a, STEAL, bob, b, SHARE);
        _check(a, b, 9_500_000, 0, 200_000);
        assertEq(rep.lastValue(a), 0);
        assertEq(rep.lastTag2(a), "steal");
        assertEq(rep.lastValue(b), 100);
    }

    function test_loot_bSteals() public {
        (uint256 a, uint256 b) = _two();
        playMatch(FIRST, ana, a, SHARE, bob, b, STEAL);
        _check(a, b, 0, 9_500_000, 200_000);
    }

    function test_loot_bothSteal() public {
        (uint256 a, uint256 b) = _two();
        playMatch(FIRST, ana, a, STEAL, bob, b, STEAL);
        _check(a, b, 0, 0, 9_700_000);
    }

    function test_loot_onlyAReveals() public {
        (uint256 a, uint256 b) = _two();
        playMatch(FIRST, ana, a, SHARE, bob, b, NONE); // bob never commits
        _check(a, b, 9_500_000, 0, 200_000);
        assertEq(rep.lastTag2(b), "noreveal");
        assertEq(rep.lastValue(b), 0);
    }

    function test_loot_committedButNotRevealed() public {
        (uint256 a, uint256 b) = _two();
        toEntries(FIRST);
        enterAs(ana, a, FIRST);
        enterAs(bob, b, FIRST);
        seedPair(FIRST);
        commitAs(ana, a, FIRST, STEAL);
        commitAs(bob, b, FIRST, SHARE);
        revealAs(bob, b, FIRST, SHARE); // ana committed but never reveals
        settleAll(FIRST);
        _check(a, b, 0, 9_500_000, 200_000);
    }

    function test_loot_neitherReveals() public {
        (uint256 a, uint256 b) = _two();
        playMatch(FIRST, ana, a, NONE, bob, b, NONE);
        _check(a, b, 4_750_000, 4_750_000, 200_000);
    }

    /// Fuzz every reveal pattern: the four parts of a match always add up to the 10 USDG pot.
    function testFuzz_loot_sumsToPot(uint8 x, uint8 y) public {
        RobinAmongThieves.Choice ca = RobinAmongThieves.Choice(x % 3);
        RobinAmongThieves.Choice cb = RobinAmongThieves.Choice(y % 3);
        (uint256 a, uint256 b) = _two();
        playMatch(FIRST, ana, a, ca, bob, b, cb);
        RobinAmongThieves.Match memory m;
        (m.a, m.b,,, m.revA, m.revB, m.settled,,) = rat.matches(FIRST, 0);
        assertTrue(m.settled);
        uint256 got = bal(a) + bal(b) - 90e6;
        assertEq(got + rat.sharingPot() + rat.rakePending(), 10e6);
        ledgersOk();
    }

    // ---------------------------------------------------------------- commit and reveal

    function test_commit_reveal_windowEdges() public {
        (uint256 a, uint256 b) = _two();
        toEntries(FIRST);
        enterAs(ana, a, FIRST);
        enterAs(bob, b, FIRST);
        uint256 t = rat.closeTime(FIRST);
        // commit before pairing: wrong status
        vm.warp(t);
        bytes32 h = rat.commitHash(SHARE, salt(a, FIRST), FIRST, a);
        vm.prank(ana);
        vm.expectRevert(RobinAmongThieves.WrongStatus.selector);
        rat.commit(FIRST, a, h);
        seedPair(FIRST);
        vm.warp(t + 13 minutes);
        vm.prank(ana);
        rat.commit(FIRST, a, h); // T+13m: last commit second
        vm.warp(t + 13 minutes + 1);
        bytes32 hb = rat.commitHash(SHARE, salt(b, FIRST), FIRST, b);
        vm.prank(bob);
        vm.expectRevert(RobinAmongThieves.WrongWindow.selector);
        rat.commit(FIRST, b, hb);
        // reveal: (T+13m, T+23m]
        vm.warp(t + 13 minutes);
        vm.prank(ana);
        vm.expectRevert(RobinAmongThieves.WrongWindow.selector);
        rat.reveal(FIRST, a, SHARE, salt(a, FIRST));
        vm.warp(t + 23 minutes);
        vm.prank(ana);
        rat.reveal(FIRST, a, SHARE, salt(a, FIRST)); // T+23m: last reveal second
        vm.warp(t + 23 minutes + 1);
        vm.prank(ana);
        vm.expectRevert(RobinAmongThieves.WrongWindow.selector);
        rat.reveal(FIRST, a, SHARE, salt(a, FIRST));
        // settle opens one second later than the last reveal
        vm.warp(t + 23 minutes);
        vm.expectRevert(RobinAmongThieves.WrongWindow.selector);
        rat.settle(FIRST, 10);
        vm.warp(t + 23 minutes + 1);
        rat.settle(FIRST, 10);
    }

    function test_commit_bindsRoundAgentContractChain() public {
        (uint256 a, uint256 b) = _two();
        toEntries(FIRST);
        enterAs(ana, a, FIRST);
        enterAs(bob, b, FIRST);
        seedPair(FIRST);
        bytes32 s = salt(a, FIRST);
        // bob tries to replay a commit made for ana: it can't reveal as bob
        bytes32 hA = rat.commitHash(STEAL, s, FIRST, a); // computed first: an external call would use up the prank
        vm.prank(bob);
        rat.commit(FIRST, b, hA);
        vm.prank(ana);
        rat.commit(FIRST, a, hA);
        vm.prank(ana);
        vm.expectRevert(RobinAmongThieves.AlreadyCommitted.selector);
        rat.commit(FIRST, a, bytes32(uint256(1)));
        vm.prank(ana);
        vm.expectRevert(RobinAmongThieves.BadReveal.selector);
        rat.commit(FIRST, a, bytes32(0));
        toReveal(FIRST);
        vm.prank(bob);
        vm.expectRevert(RobinAmongThieves.BadReveal.selector);
        rat.reveal(FIRST, b, STEAL, s); // same choice and salt, but bound to ana's id
        vm.prank(ana);
        vm.expectRevert(RobinAmongThieves.BadReveal.selector);
        rat.reveal(FIRST, a, STEAL, keccak256("wrong salt"));
        vm.prank(ana);
        vm.expectRevert(RobinAmongThieves.BadReveal.selector);
        rat.reveal(FIRST, a, SHARE, s); // the other choice
        vm.prank(ana);
        vm.expectRevert(RobinAmongThieves.BadReveal.selector);
        rat.reveal(FIRST, a, NONE, s);
        vm.prank(ana);
        rat.reveal(FIRST, a, STEAL, s);
        vm.prank(ana);
        vm.expectRevert(RobinAmongThieves.AlreadyRevealed.selector);
        rat.reveal(FIRST, a, STEAL, s);
        // another chain id gives another hash
        bytes32 here = rat.commitHash(STEAL, s, FIRST, a);
        vm.chainId(46630);
        assertTrue(rat.commitHash(STEAL, s, FIRST, a) != here);
    }

    function test_commit_notInMatch() public {
        (uint256 a, uint256 b) = _two();
        uint256 c = regFunded(cat, 50e6);
        toEntries(FIRST);
        enterAs(ana, a, FIRST);
        enterAs(bob, b, FIRST);
        seedPair(FIRST);
        vm.prank(cat);
        vm.expectRevert(RobinAmongThieves.NotInMatch.selector);
        rat.commit(FIRST, c, bytes32(uint256(1)));
    }
}

contract RatRoundsTest is RatBase {
    RobinAmongThieves.Choice constant SHARE = RobinAmongThieves.Choice.Share;
    RobinAmongThieves.Choice constant STEAL = RobinAmongThieves.Choice.Steal;

    function _status(uint256 r) internal view returns (RobinAmongThieves.Status s) {
        (,,,,,,,,,, s,,,,,,,) = rat.rounds(r);
    }

    function _matches(uint256 r) internal view returns (uint256 m) {
        (,,,,,, uint32 x,,,,,,,,,,,) = rat.rounds(r);
        m = x;
    }

    function _pairOf(uint256 r, uint256 i) internal view returns (uint256 a, uint256 b) {
        (a, b,,,,,,,) = rat.matches(r, i);
    }

    // ---------------------------------------------------------------- seed chain

    function test_commitSeedChain_rules() public {
        uint256 cur = rat.currentRound();
        vm.prank(ana);
        vm.expectRevert(RobinAmongThieves.NotKeeper.selector);
        rat.commitSeedChain(keccak256("x"), uint64(cur + 2));
        vm.startPrank(keeper);
        vm.expectRevert(RobinAmongThieves.FromTooSoon.selector);
        rat.commitSeedChain(keccak256("x"), uint64(cur + 1));
        vm.expectRevert(RobinAmongThieves.BadSeed.selector);
        rat.commitSeedChain(bytes32(0), uint64(cur + 2));
        vm.stopPrank();
    }

    function test_revealSeed_rules() public {
        uint256 a = regFunded(ana, 50e6);
        uint256 b = regFunded(bob, 50e6);
        uint256 t = rat.closeTime(FIRST);
        vm.warp(t - 1);
        vm.expectRevert(RobinAmongThieves.NoEntrants.selector);
        vm.warp(t);
        rat.revealSeed(FIRST, chain[1]);
        vm.warp(windowStart(FIRST));
        enterAs(ana, a, FIRST);
        enterAs(bob, b, FIRST);
        vm.warp(t - 1);
        vm.expectRevert(RobinAmongThieves.WrongWindow.selector);
        rat.revealSeed(FIRST, chain[1]);
        vm.warp(t + 3 minutes);
        vm.expectRevert(RobinAmongThieves.WrongWindow.selector);
        rat.revealSeed(FIRST, chain[1]);
        vm.warp(t + 3 minutes - 1);
        vm.expectRevert(RobinAmongThieves.BadSeed.selector);
        rat.revealSeed(FIRST, chain[2]); // not the next link
        vm.expectRevert(RobinAmongThieves.WrongStatus.selector);
        rat.pair(FIRST, 10); // no seed yet
        rat.revealSeed(FIRST, chain[1]);
        vm.expectRevert(RobinAmongThieves.SeedAlreadyRevealed.selector);
        rat.revealSeed(FIRST, chain[2]);
        assertEq(rat.seedTip(), chain[1]);
        (,,,,,,,,,,,,, uint64 l2,,,,) = rat.rounds(FIRST);
        assertEq(l2, 1_000_000, "the seed reveal records the L2 block (ArbSys)");
        advanceL2();
        rat.pair(FIRST, 10);
        vm.warp(t + 3 minutes);
        vm.expectRevert(RobinAmongThieves.WrongStatus.selector);
        rat.pair(FIRST, 10);
    }

    function test_noSeedChain() public {
        RatHarness r2 = new RatHarness(_params());
        vm.startPrank(ana);
        usdg.approve(address(r2), type(uint256).max);
        wif.approve(address(r2), type(uint256).max);
        uint256 id = r2.registerOutlawNew("x", address(0), address(wif), LIC);
        r2.deposit(id, 5e6);
        r2.enter(id, 1, keccak256(abi.encode(id, uint256(1))));
        vm.stopPrank();
        vm.warp(r2.closeTime(1));
        vm.expectRevert(RobinAmongThieves.NoSeedChain.selector);
        r2.revealSeed(1, keccak256("anything"));
    }

    /// A new chain only takes over from its fromRound; the old one keeps working until then.
    function test_seedChain_rollover() public {
        uint256 a = regFunded(ana, 100e6);
        uint256 b = regFunded(bob, 100e6);
        playMatch(FIRST, ana, a, RobinAmongThieves.Choice.Share, bob, b, RobinAmongThieves.Choice.Share);
        bytes32 s2 = keccak256("second chain link 1");
        uint64 from = uint64(rat.currentRound() + 2);
        vm.prank(keeper);
        rat.commitSeedChain(keccak256(abi.encode(s2)), from);
        // the round before `from`: still the old chain
        uint256 r = from - 1;
        toEntries(r);
        enterAs(ana, a, r);
        enterAs(bob, b, r);
        vm.warp(rat.closeTime(r));
        rat.revealSeed(r, chain[2]);
        advanceL2();
        rat.pair(r, 10);
        settleAll(r);
        // from `from`: the new chain; the old chain's next link no longer works
        toEntries(from);
        enterAs(ana, a, from);
        enterAs(bob, b, from);
        vm.warp(rat.closeTime(from));
        vm.expectRevert(RobinAmongThieves.BadSeed.selector);
        rat.revealSeed(from, chain[3]);
        rat.revealSeed(from, s2);
        assertEq(rat.seedTip(), s2);
    }

    // ---------------------------------------------------------------- pairing

    function test_pair_oddOneSitsOut() public {
        uint256 a = regFunded(ana, 50e6);
        uint256 b = regFunded(bob, 50e6);
        uint256 c = regFunded(cat, 50e6);
        toEntries(FIRST);
        enterAs(ana, a, FIRST);
        enterAs(bob, b, FIRST);
        enterAs(cat, c, FIRST);
        seedPair(FIRST);
        assertEq(_matches(FIRST), 1);
        assertEq(rat.reservedStakes(), 10e6);
        uint256 out = (openRoundOf(a) == 0 ? 1 : 0) + (openRoundOf(b) == 0 ? 1 : 0) + (openRoundOf(c) == 0 ? 1 : 0);
        assertEq(out, 1, "exactly one sat out, refunded");
        assertEq(bal(a) + bal(b) + bal(c), 140e6);
        assertEq(uint8(_status(FIRST)), uint8(RobinAmongThieves.Status.Paired));
        ledgersOk();
    }

    function test_pair_houseOnlyRound_nobodyPaired_noRake() public {
        uint256 h1 = regHouse(60e6);
        vm.prank(house);
        uint256 h2 = rat.registerOutlawNew("x", address(0), address(wif), LIC);
        vm.prank(house);
        rat.requestHouse(h2);
        vm.prank(owner);
        rat.setHouse(h2, true);
        vm.prank(house);
        rat.deposit(h2, 60e6);
        vm.warp(windowStart(FIRST));
        enterAs(house, h1, FIRST);
        enterAs(house, h2, FIRST);
        vm.warp(rat.closeTime(FIRST));
        rat.revealSeed(FIRST, chain[nextLink++]);
        advanceL2();
        vm.expectEmit(true, true, false, true, address(rat));
        emit RobinAmongThieves.SatOut(FIRST, 0, RobinAmongThieves.SatOutReason.HouseOnly);
        rat.pair(FIRST, 10);
        assertEq(_matches(FIRST), 0);
        assertEq(uint8(_status(FIRST)), uint8(RobinAmongThieves.Status.Finalized), "an empty round closes at once");
        assertEq(bal(h1), 60e6);
        assertEq(bal(h2), 60e6);
        assertEq(rat.rakePending(), 0, "no rake without a match");
        assertEq(rat.reservedStakes(), 0);
        ledgersOk();
    }

    /// Three house outlaws with different controllers (the conflict is the house rule itself, not the wallet).
    function _threeHouses() internal returns (uint256[3] memory h) {
        address[3] memory w = [house, eve, fay];
        for (uint256 i; i < 3; ++i) {
            h[i] = regFunded(w[i], 60e6);
            vm.prank(w[i]);
            rat.requestHouse(h[i]);
            vm.prank(owner);
            rat.setHouse(h[i], true);
        }
    }

    function test_pair_onePlayerThreeHouse() public {
        uint256[3] memory h = _threeHouses();
        uint256 p = regFunded(ana, 50e6);
        vm.warp(windowStart(FIRST));
        enterAs(house, h[0], FIRST);
        enterAs(eve, h[1], FIRST);
        enterAs(fay, h[2], FIRST);
        enterAs(ana, p, FIRST);
        seedPair(FIRST);
        assertEq(_matches(FIRST), 1);
        (uint256 x, uint256 y) = _pairOf(FIRST, 0);
        assertTrue(x == p || y == p, "the player plays a house outlaw");
        uint256 sat;
        for (uint256 i; i < 3; ++i) {
            if (openRoundOf(h[i]) == 0) ++sat;
        }
        assertEq(sat, 2, "two house outlaws sit out");
    }

    /// House outlaws never meet each other.
    function testFuzz_pair_houseNeverMeetsHouse(uint8 players) public {
        uint256[3] memory h = _threeHouses();
        uint256 np = bound(players, 0, 3);
        address[3] memory pw = [ana, bob, cat];
        uint256[3] memory p;
        for (uint256 i; i < np; ++i) {
            p[i] = regFunded(pw[i], 50e6);
        }
        vm.warp(windowStart(FIRST));
        enterAs(house, h[0], FIRST);
        enterAs(eve, h[1], FIRST);
        enterAs(fay, h[2], FIRST);
        for (uint256 i; i < np; ++i) {
            vm.prank(pw[i]);
            rat.enter(p[i], FIRST, keccak256(abi.encode(p[i], FIRST)));
        }
        seedPair(FIRST);
        uint256 m = _matches(FIRST);
        assertLe(m, np, "every match has a player in it");
        for (uint256 i; i < m; ++i) {
            (uint256 x, uint256 y) = _pairOf(FIRST, i);
            (,,,,,, bool hx,,,,,,,,) = rat.outlaws(x);
            (,,,,,, bool hy,,,,,,,,) = rat.outlaws(y);
            assertFalse(hx && hy, "house met house");
        }
    }

    function test_pair_sameControllerNeverPaired() public {
        uint256 a1 = regFunded(ana, 50e6);
        uint256 a2 = regFunded(ana, 50e6);
        toEntries(FIRST);
        enterAs(ana, a1, FIRST);
        enterAs(ana, a2, FIRST);
        seedPair(FIRST);
        assertEq(_matches(FIRST), 0);
        assertEq(openRoundOf(a1) + openRoundOf(a2), 0);
    }

    function test_pair_sameIdentityOwnerNeverPaired() public {
        // bob owns both identities; cat controls one of them as its agent wallet
        vm.startPrank(bob);
        uint256 i1 = idr.register("x");
        idr.setAgentWallet(i1, cat);
        uint256 i2 = idr.register("y");
        rat.registerOutlaw(i2, address(0), address(wif), LIC);
        rat.deposit(i2, 50e6);
        vm.stopPrank();
        vm.startPrank(cat);
        rat.registerOutlaw(i1, address(0), address(wif), LIC);
        rat.deposit(i1, 50e6);
        vm.stopPrank();
        toEntries(FIRST);
        enterAs(cat, i1, FIRST);
        enterAs(bob, i2, FIRST);
        seedPair(FIRST);
        assertEq(_matches(FIRST), 0, "same 8004 owner");
    }

    function test_pair_samePairOncePerHour() public {
        uint256 a = regFunded(ana, 100e6);
        uint256 b = regFunded(bob, 100e6);
        playMatch(FIRST, ana, a, SHARE, bob, b, SHARE);
        // the next round is 30 minutes later: they can't meet
        uint256 r = FIRST + 1;
        enterAs(ana, a, r);
        enterAs(bob, b, r);
        seedPair(r);
        assertEq(_matches(r), 0);
        // an hour after their meeting they can
        uint256 r2 = FIRST + 2;
        toEntries(r2);
        enterAs(ana, a, r2);
        enterAs(bob, b, r2);
        seedPair(r2);
        assertEq(_matches(r2), 1);
    }

    /// Pairing in batches of one gives exactly the same matches as one call.
    function test_pair_batchesAreDeterministic() public {
        address[6] memory w = [ana, bob, cat, dan, eve, fay];
        uint256[6] memory ids;
        for (uint256 i; i < 6; ++i) {
            ids[i] = regFunded(w[i], 50e6);
        }
        toEntries(FIRST);
        for (uint256 i; i < 6; ++i) {
            enterAs(w[i], ids[i], FIRST);
        }
        vm.warp(rat.closeTime(FIRST));
        rat.revealSeed(FIRST, chain[nextLink++]);
        advanceL2();
        uint256 snap = vm.snapshotState();
        rat.pair(FIRST, 1000);
        uint256[6] memory one;
        for (uint256 i; i < 3; ++i) {
            (one[2 * i], one[2 * i + 1]) = _pairOf(FIRST, i);
        }
        vm.revertToState(snap);
        for (uint256 i; i < 10 && _status(FIRST) == RobinAmongThieves.Status.Open; ++i) {
            rat.pair(FIRST, 1);
        }
        for (uint256 i; i < 3; ++i) {
            (uint256 x, uint256 y) = _pairOf(FIRST, i);
            assertEq(x, one[2 * i]);
            assertEq(y, one[2 * i + 1]);
        }
    }

    /// Any number of entrants: each is either in exactly one match or sat out and refunded.
    function testFuzz_pair_everyoneOnce(uint8 count) public {
        uint256 n = bound(count, 1, 24);
        uint256[] memory ids = new uint256[](n);
        address[] memory ws = new address[](n);
        for (uint256 i; i < n; ++i) {
            ws[i] = address(uint160(0x50000 + i));
            ratFund(ws[i]);
            ids[i] = regFunded(ws[i], 5e6);
        }
        toEntries(FIRST);
        for (uint256 i; i < n; ++i) {
            vm.prank(ws[i]);
            rat.enter(ids[i], FIRST, keccak256(abi.encode(ids[i], FIRST)));
        }
        seedPair(FIRST);
        uint256 m = _matches(FIRST);
        uint256 inMatch;
        for (uint256 i; i < n; ++i) {
            uint256 mid = rat.matchOf(FIRST, ids[i]);
            if (mid != 0) {
                ++inMatch;
                (uint256 x, uint256 y) = _pairOf(FIRST, mid - 1);
                assertTrue(x == ids[i] || y == ids[i]);
                assertEq(openRoundOf(ids[i]), FIRST);
            } else {
                assertEq(openRoundOf(ids[i]), 0, "sat out");
                assertEq(bal(ids[i]), 5e6, "refunded");
            }
        }
        assertEq(inMatch, 2 * m);
        assertEq(m, n / 2, "distinct strangers: only an odd one sits out");
        assertEq(rat.reservedStakes(), 2 * m * 5e6);
        ledgersOk();
    }

    // ---------------------------------------------------------------- cancel

    function test_cancel_noSeed_refundsAll() public {
        uint256 a = regFunded(ana, 50e6);
        uint256 b = regFunded(bob, 50e6);
        toEntries(FIRST);
        enterAs(ana, a, FIRST);
        enterAs(bob, b, FIRST);
        uint256 t = rat.closeTime(FIRST);
        vm.warp(t + 8 minutes - 1);
        vm.expectRevert(RobinAmongThieves.WrongWindow.selector);
        rat.cancelRound(FIRST, 10);
        vm.warp(t + 8 minutes);
        vm.expectEmit(true, false, false, false, address(rat));
        emit RobinAmongThieves.RoundCancelled(FIRST);
        rat.cancelRound(FIRST, 1); // batch of one
        assertEq(rat.reservedStakes(), 5e6);
        rat.cancelRound(FIRST, 1);
        assertEq(rat.reservedStakes(), 0);
        assertEq(bal(a), 50e6);
        assertEq(bal(b), 50e6);
        assertEq(uint8(_status(FIRST)), uint8(RobinAmongThieves.Status.Cancelled));
        vm.expectRevert(RobinAmongThieves.WrongStatus.selector);
        rat.settle(FIRST, 10);
        ledgersOk();
    }

    function test_cancel_partialPairing() public {
        address[4] memory w = [ana, bob, cat, dan];
        uint256[4] memory ids;
        for (uint256 i; i < 4; ++i) {
            ids[i] = regFunded(w[i], 50e6);
        }
        toEntries(FIRST);
        for (uint256 i; i < 4; ++i) {
            enterAs(w[i], ids[i], FIRST);
        }
        vm.warp(rat.closeTime(FIRST));
        rat.revealSeed(FIRST, chain[nextLink++]);
        advanceL2();
        rat.pair(FIRST, 1); // one match, pairing not finished
        vm.warp(rat.closeTime(FIRST) + 8 minutes);
        rat.cancelRound(FIRST, 10);
        for (uint256 i; i < 4; ++i) {
            assertEq(bal(ids[i]), 50e6);
        }
        assertEq(rat.reservedStakes(), 0);
        // a paired round can't be cancelled
        uint256 r = FIRST + 1;
        enterAs(ana, ids[0], r);
        enterAs(bob, ids[1], r);
        seedPair(r);
        vm.warp(rat.closeTime(r) + 8 minutes);
        vm.expectRevert(RobinAmongThieves.WrongStatus.selector);
        rat.cancelRound(r, 10);
    }

    function test_settle_finalize_batches() public {
        address[4] memory w = [ana, bob, cat, dan];
        uint256[4] memory ids;
        for (uint256 i; i < 4; ++i) {
            ids[i] = regFunded(w[i], 50e6);
        }
        toEntries(FIRST);
        for (uint256 i; i < 4; ++i) {
            enterAs(w[i], ids[i], FIRST);
        }
        seedPair(FIRST);
        toSettle(FIRST);
        vm.expectRevert(RobinAmongThieves.WrongStatus.selector);
        rat.finalize(FIRST, 10);
        rat.settle(FIRST, 1);
        assertEq(uint8(_status(FIRST)), uint8(RobinAmongThieves.Status.Paired));
        rat.settle(FIRST, 1);
        assertEq(uint8(_status(FIRST)), uint8(RobinAmongThieves.Status.Settled));
        vm.expectRevert(RobinAmongThieves.WrongStatus.selector);
        rat.settle(FIRST, 1);
        rat.finalize(FIRST, 1);
        assertEq(uint8(_status(FIRST)), uint8(RobinAmongThieves.Status.Settled));
        rat.finalize(FIRST, 1);
        assertEq(uint8(_status(FIRST)), uint8(RobinAmongThieves.Status.Finalized));
        // nobody committed: every match settles as a double no-reveal
        assertEq(rat.sharingPot(), 400_000);
        assertEq(rat.rakePending(), 600_000);
        ledgersOk();
    }

    // ---------------------------------------------------------------- 8004 writes

    function _failedWrites() internal view returns (uint256 n) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == RobinAmongThieves.ReputationWriteFailed.selector) ++n;
        }
    }

    function test_reputation_writes_and_counts() public {
        uint256 a = regFunded(ana, 50e6);
        uint256 b = regFunded(bob, 50e6);
        playMatch(FIRST, ana, a, SHARE, bob, b, STEAL);
        assertEq(rep.count(a, address(rat)), 1);
        assertEq(rep.count(b, address(rat)), 1);
        assertEq(rep.sum(a, address(rat)), 100);
        assertEq(rep.sum(b, address(rat)), 0);
    }

    function test_reputation_revert_settleStillSucceeds() public {
        uint256 a = regFunded(ana, 50e6);
        uint256 b = regFunded(bob, 50e6);
        rep.setMode(1);
        vm.recordLogs();
        playMatch(FIRST, ana, a, STEAL, bob, b, SHARE);
        assertEq(_failedWrites(), 2);
        assertEq(bal(a), 45e6 + 9_500_000);
        assertEq(rep.writes(), 0);
        ledgersOk();
    }

    function test_reputation_outOfGas_settleStillSucceeds() public {
        uint256 a = regFunded(ana, 50e6);
        uint256 b = regFunded(bob, 50e6);
        rep.setMode(2);
        playMatch(FIRST, ana, a, SHARE, bob, b, SHARE);
        assertEq(bal(a), 45e6 + 4_750_000);
        assertEq(bal(b), 45e6 + 4_750_000);
        ledgersOk();
    }

    /// If a player approves this contract on its identity, the registry refuses our write (self-feedback): caught.
    function test_reputation_selfFeedbackRefused_caught() public {
        uint256 a = regFunded(ana, 50e6);
        uint256 b = regFunded(bob, 50e6);
        vm.prank(ana);
        idr.approve(address(rat), a);
        vm.recordLogs();
        playMatch(FIRST, ana, a, STEAL, bob, b, SHARE);
        assertEq(_failedWrites(), 1);
        assertEq(rep.count(a, address(rat)), 0);
        assertEq(rep.count(b, address(rat)), 1);
    }

    function _readyToSettle() internal returns (uint256 a, uint256 b) {
        a = regFunded(ana, 50e6);
        b = regFunded(bob, 50e6);
        toEntries(FIRST);
        enterAs(ana, a, FIRST);
        enterAs(bob, b, FIRST);
        seedPair(FIRST);
        commitAs(ana, a, FIRST, STEAL);
        commitAs(bob, b, FIRST, SHARE);
        revealAs(ana, a, FIRST, STEAL);
        revealAs(bob, b, FIRST, SHARE);
        toSettle(FIRST);
    }

    /// L-1: settle is permissionless; with too little gas for a full REP_GAS write it reverts instead of quietly
    /// dropping the thief's record.
    function test_reputation_gasGuard_tooLittleGasReverts() public {
        _readyToSettle();
        uint256 need = rat.REP_GAS() * 64 / 63 + 10_000;
        vm.expectRevert(RobinAmongThieves.FeedbackGas.selector);
        rat.settle{gas: need}(FIRST, 1); // the guard is checked after the payout work: this can't cover it
        // binary search for the smallest gas that settles: below it every call reverts, never a silent skip
        uint256 lo = need;
        uint256 hi = 3_000_000;
        while (hi - lo > 1000) {
            uint256 mid = (lo + hi) / 2;
            uint256 snap = vm.snapshotState();
            (bool ok,) = address(rat).call{gas: mid}(abi.encodeCall(RobinAmongThieves.settle, (FIRST, 1)));
            if (ok) {
                // whenever it succeeds, both records were written
                assertEq(rep.count(0, address(rat)) + rep.count(1, address(rat)), 2, "both written");
                hi = mid;
            } else {
                lo = mid;
            }
            vm.revertToState(snap);
        }
        (bool okLow, bytes memory err) =
            address(rat).call{gas: lo}(abi.encodeCall(RobinAmongThieves.settle, (FIRST, 1)));
        assertFalse(okLow);
        assertEq(bytes4(err), RobinAmongThieves.FeedbackGas.selector, "just under the threshold: FeedbackGas");
    }

    /// With enough gas, a reverting registry still only emits ReputationWriteFailed, and the match settles.
    function test_reputation_gasGuard_enoughGas_failureTolerated() public {
        (uint256 a,) = _readyToSettle();
        rep.setMode(1);
        vm.recordLogs();
        rat.settle{gas: 2_000_000}(FIRST, 1);
        assertEq(_failedWrites(), 2);
        assertEq(bal(a), 45e6 + 9_500_000);
    }

    /// A registry with no code counts as a failed write.
    function test_reputation_noCode_isAFailure() public {
        (uint256 a,) = _readyToSettle();
        vm.etch(address(rep), "");
        vm.recordLogs();
        rat.settle(FIRST, 1);
        assertEq(_failedWrites(), 2);
        assertEq(bal(a), 45e6 + 9_500_000);
    }

    // ---------------------------------------------------------------- R4 counter

    function test_r4_counterCountsDistinctOpponents() public {
        uint256 a = regFunded(ana, 200e6);
        uint256 b = regFunded(bob, 200e6);
        uint256 c = regFunded(cat, 200e6);
        playMatch(FIRST, ana, a, SHARE, bob, b, SHARE);
        playMatch(FIRST + 2, ana, a, SHARE, bob, b, SHARE); // same opponent again
        (,,,,, uint16 n,,,,,,,,,) = rat.outlaws(a);
        assertEq(n, 1);
        playMatch(FIRST + 3, ana, a, SHARE, cat, c, SHARE);
        (,,,,, n,,,,,,,,,) = rat.outlaws(a);
        assertEq(n, 2);
        assertTrue(rat.met(a, b) && rat.met(a, c) && rat.met(c, a));
        rat.setOpponents(a, 5);
        address[3] memory w = [dan, eve, fay];
        for (uint256 i; i < 3; ++i) {
            uint256 x = regFunded(w[i], 50e6);
            playMatch(FIRST + 5 + 2 * i, ana, a, SHARE, w[i], x, SHARE);
        }
        (,,,,, n,,,,,,,,,) = rat.outlaws(a);
        assertEq(n, 5, "stops at 5");
    }
}

contract RatBonusTest is RatBase {
    RobinAmongThieves.Choice constant SHARE = RobinAmongThieves.Choice.Share;
    RobinAmongThieves.Choice constant STEAL = RobinAmongThieves.Choice.Steal;

    uint256 a;
    uint256 b;

    function setUp() public override {
        super.setUp();
        a = regFunded(ana, 500e6);
        b = regFunded(bob, 500e6);
        rat.setOpponents(a, 5);
        rat.setOpponents(b, 5);
    }

    /// The first round whose entry window starts after `t`.
    function _roundAfter(uint256 t) internal pure returns (uint256) {
        return (t - T0) / 30 minutes + 2;
    }

    /// Eligibility of `a` (ana) and of her opponent in round r's only match.
    function _elig(uint256 r) internal view returns (bool ea, bool eb) {
        (uint256 x,,,,,,, bool e1, bool e2) = rat.matches(r, 0);
        (ea, eb) = x == a ? (e1, e2) : (e2, e1);
    }

    function test_bonus_paidAtFullCap() public {
        vm.prank(owner);
        rat.fundPot(100e6);
        uint256 r = _roundAfter(T0 + 24 hours);
        playMatch(r, ana, a, SHARE, bob, b, SHARE);
        (bool ea, bool eb) = _elig(r);
        assertTrue(ea && eb);
        assertEq(bal(a), 495e6 + 4_750_000 + 2e6, "4.75 + capped bonus 2");
        assertEq(rat.sharingPot(), 100e6 + 200_000 - 4e6);
        assertEq(rat.lastPairBonus(rat.pairKey(a, b)), vm.getBlockTimestamp());
        ledgersOk();
    }

    /// R1: at most drawBps (25%) of the pot per round, split pro rata.
    function test_r1_drawAtMost25pct() public {
        vm.prank(owner);
        rat.fundPot(4e6);
        uint256 r = _roundAfter(T0 + 24 hours);
        playMatch(r, ana, a, SHARE, bob, b, SHARE);
        // pot at finalize = 4.2: avail = 1.05, two eligible players: 0.525 each
        assertEq(bal(a), 495e6 + 4_750_000 + 525_000);
        assertEq(bal(b), 495e6 + 4_750_000 + 525_000);
        assertEq(rat.sharingPot(), 4_200_000 - 1_050_000);
        (,,,,,,,,,,,,,,, uint128 bpp, uint128 paid,) = rat.rounds(r);
        assertEq(bpp, 525_000);
        assertEq(paid, 1_050_000);
    }

    /// R4: 24h of age, and 5 distinct opponents before the match.
    function test_r4_ageAndOpponentsGate() public {
        vm.prank(owner);
        rat.fundPot(100e6);
        // 4 opponents: no bonus
        rat.setOpponents(a, 4);
        uint256 r = _roundAfter(T0 + 24 hours);
        playMatch(r, ana, a, SHARE, bob, b, SHARE);
        (bool ea, bool eb) = _elig(r);
        assertFalse(ea, "4 opponents");
        assertTrue(eb);
        // age: an outlaw registered less than 24h ago
        uint256 c = regFunded(cat, 100e6);
        rat.setOpponents(c, 5);
        uint256 r2 = r + 2;
        playMatch(r2, cat, c, SHARE, ana, a, SHARE);
        (bool ea2, bool ec) = _elig(r2);
        assertFalse(ec, "younger than 24h");
        assertTrue(ea2, "ana reached 5 distinct opponents by meeting bob");
    }

    /// R3: a pair is bonused at most once per 24 hours.
    function test_r3_pairBonusOncePer24h() public {
        vm.prank(owner);
        rat.fundPot(100e6);
        uint256 r = _roundAfter(T0 + 24 hours);
        playMatch(r, ana, a, SHARE, bob, b, SHARE);
        uint256 paidAt = vm.getBlockTimestamp();
        playMatch(r + 2, ana, a, SHARE, bob, b, SHARE);
        (bool ea, bool eb) = _elig(r + 2);
        assertFalse(ea || eb, "same pair within 24h");
        uint256 r3 = _roundAfter(paidAt + 24 hours);
        playMatch(r3, ana, a, SHARE, bob, b, SHARE);
        (ea, eb) = _elig(r3);
        assertTrue(ea && eb, "after 24h again");
    }

    /// L-2: a bonus to only one side still counts for the pair (R3).
    function test_r3_oneSidedBonus_countsForThePair() public {
        vm.prank(owner);
        rat.fundPot(100e6);
        rat.setOpponents(b, 4); // bob not eligible this time
        uint256 r = _roundAfter(T0 + 24 hours);
        playMatch(r, ana, a, SHARE, bob, b, SHARE);
        (bool ea, bool eb) = _elig(r);
        assertTrue(ea && !eb);
        assertEq(rat.lastPairBonus(rat.pairKey(a, b)), vm.getBlockTimestamp(), "set by one side's bonus");
        // bob now has 5 opponents, but the pair was bonused less than 24h ago
        uint256 before = bal(a) + bal(b);
        playMatch(r + 2, ana, a, SHARE, bob, b, SHARE);
        (ea, eb) = _elig(r + 2);
        assertFalse(ea || eb);
        assertEq(bal(a) + bal(b), before - 10e6 + 9_500_000, "no bonus");
    }

    /// L-2: two rounds of one pair settled before either finalizes: the pair is bonused at most once.
    function test_r3_twoSettledRounds_payOnce() public {
        vm.prank(owner);
        rat.fundPot(100e6);
        uint256 r = _roundAfter(T0 + 24 hours);
        uint256[2] memory rs = [r, r + 2];
        for (uint256 k; k < 2; ++k) {
            uint256 x = rs[k];
            toEntries(x);
            enterAs(ana, a, x);
            enterAs(bob, b, x);
            seedPair(x);
            commitAs(ana, a, x, SHARE);
            commitAs(bob, b, x, SHARE);
            revealAs(ana, a, x, SHARE);
            revealAs(bob, b, x, SHARE);
            toSettle(x);
            rat.settle(x, 10); // not finalized yet
        }
        (bool e1, bool e2) = _elig(r + 2);
        assertTrue(e1 && e2, "both eligible at settle: nothing paid yet");
        rat.finalize(r, 10);
        rat.finalize(r + 2, 10);
        (,,,,,,,,,,,,,,,, uint128 paid1,) = rat.rounds(r);
        (,,,,,,,,,,,,,,,, uint128 paid2,) = rat.rounds(r + 2);
        assertEq(paid1, 4e6);
        assertEq(paid2, 0, "the second round of the same pair pays nothing");
    }

    /// R2: at most 6 USDG of bonus per outlaw per UTC day; the ledger resets with the day.
    function test_r2_dailyCap_andRollover() public {
        vm.prank(owner);
        rat.fundPot(1000e6);
        address[4] memory w = [cat, dan, eve, fay];
        uint256[4] memory opp;
        for (uint256 i; i < 4; ++i) {
            opp[i] = regFunded(w[i], 100e6);
            rat.setOpponents(opp[i], 5);
        }
        uint256 r = _roundAfter(T0 + 24 hours);
        uint256 start = bal(a);
        for (uint256 i; i < 4; ++i) {
            playMatch(r + 2 * i, ana, a, SHARE, w[i], opp[i], SHARE);
        }
        assertEq(bal(a) + 4 * 5e6, start + 4 * 4_750_000 + 6e6, "bonus 2 + 2 + 2 + 0");
        (,,,,,,,, uint32 day,,,,,, uint128 today) = rat.outlaws(a);
        assertEq(today, 6e6);
        // the next UTC day pays again
        uint256 nextDay = (vm.getBlockTimestamp() / 1 days + 1) * 1 days;
        uint256 r2 = _roundAfter(nextDay);
        uint256 before = bal(a);
        playMatch(r2, ana, a, SHARE, bob, b, SHARE); // a pair not bonused in the last 24h (R3)
        assertEq(bal(a) - before + 5e6, 4_750_000 + 2e6);
        (,,,,,,,, uint32 day2,,,,,, uint128 today2) = rat.outlaws(a);
        assertEq(day2, day + 1);
        assertEq(today2, 2e6);
    }

    /// R6: house outlaws are never bonused.
    function test_r6_houseNeverBonused() public {
        vm.prank(owner);
        rat.fundPot(100e6);
        uint256 h = regHouse(100e6);
        rat.setOpponents(h, 5);
        vm.warp(T0 + 24 hours);
        uint256 r = _roundAfter(T0 + 24 hours);
        vm.warp(windowStart(r));
        enterAs(house, h, r);
        enterAs(ana, a, r);
        seedPair(r);
        commitAs(house, h, r, SHARE);
        commitAs(ana, a, r, SHARE);
        revealAs(house, h, r, SHARE);
        revealAs(ana, a, r, SHARE);
        settleAll(r);
        (, bool eh) = _elig(r);
        assertFalse(eh, "house not eligible");
        assertEq(bal(h), 95e6 + 4_750_000, "no bonus");
    }

    /// The pot can't pay more than it holds, even with several rounds finalizing over the same pot.
    function test_bonus_neverExceedsPot() public {
        vm.prank(owner);
        rat.fundPot(1e6);
        uint256 r = _roundAfter(T0 + 24 hours);
        playMatch(r, ana, a, SHARE, bob, b, SHARE);
        assertGe(rat.sharingPot(), 0);
        ledgersOk();
    }

    /// Steals and both-steals feed the pot that later pays cooperators.
    function test_bothStealFeedsPot_thenPays() public {
        uint256 r = _roundAfter(T0 + 24 hours);
        uint256 c = regFunded(cat, 100e6);
        uint256 d = regFunded(dan, 100e6);
        playMatch(r, cat, c, STEAL, dan, d, STEAL);
        assertEq(rat.sharingPot(), 9_700_000);
        playMatch(r + 1, ana, a, SHARE, bob, b, SHARE);
        // pot 9.9 at finalize: avail 2.475, 1.2375 each
        assertEq(bal(a), 495e6 + 4_750_000 + 1_237_500);
        assertEq(rat.sharingPot(), 9_900_000 - 2_475_000);
    }
}

contract RatAdminTest is RatBase {
    RobinAmongThieves.Choice constant SHARE = RobinAmongThieves.Choice.Share;
    RobinAmongThieves.Choice constant STEAL = RobinAmongThieves.Choice.Steal;

    function test_ops_48hTimelock_eachParam() public {
        RobinAmongThieves.Op[5] memory ops = [
            RobinAmongThieves.Op.SetKeeper,
            RobinAmongThieves.Op.SetRakeSink,
            RobinAmongThieves.Op.SetHouseSink,
            RobinAmongThieves.Op.SetLicenceAmount,
            RobinAmongThieves.Op.SetDrawBps
        ];
        uint256[5] memory vals = [uint256(0), 0, 0, 2000e18, 1000];
        address[5] memory addrs = [makeAddr("k2"), makeAddr("sink2"), makeAddr("house2"), address(0), address(0)];
        for (uint256 i; i < 5; ++i) {
            vm.prank(owner);
            bytes32 id = rat.queue(ops[i], vals[i], addrs[i]);
            uint256 eta = rat.queuedAt(id);
            assertEq(eta, vm.getBlockTimestamp() + 48 hours);
            vm.warp(eta - 1);
            vm.prank(owner);
            vm.expectRevert(abi.encodeWithSelector(RobinAmongThieves.TooEarly.selector, eta));
            rat.execute(ops[i], vals[i], addrs[i]);
            vm.warp(eta);
            vm.prank(owner);
            rat.execute(ops[i], vals[i], addrs[i]);
            assertEq(rat.queuedAt(id), 0);
        }
        assertEq(rat.keeper(), makeAddr("k2"));
        assertEq(rat.rakeSink(), makeAddr("sink2"));
        assertEq(rat.houseSink(), makeAddr("house2"));
        assertEq(rat.licenceAmount(), 2000e18);
        assertEq(rat.drawBps(), 1000);
    }

    function test_ops_validationCancelAccess() public {
        vm.startPrank(owner);
        vm.expectRevert(RobinAmongThieves.BadValue.selector);
        rat.queue(RobinAmongThieves.Op.SetDrawBps, 2501, address(0));
        vm.expectRevert(RobinAmongThieves.BadValue.selector);
        rat.queue(RobinAmongThieves.Op.SetLicenceAmount, 0, address(0));
        vm.expectRevert(RobinAmongThieves.BadValue.selector);
        rat.queue(RobinAmongThieves.Op.SetLicenceAmount, uint256(type(uint128).max) + 1, address(0));
        vm.expectRevert(RobinAmongThieves.ZeroAddress.selector);
        rat.queue(RobinAmongThieves.Op.SetRakeSink, 0, address(0));
        vm.expectRevert(RobinAmongThieves.ZeroAddress.selector);
        rat.queue(RobinAmongThieves.Op.SetHouseSink, 0, address(0));
        bytes32 id = rat.queue(RobinAmongThieves.Op.SetDrawBps, 0, address(0));
        rat.cancel(id);
        vm.expectRevert(RobinAmongThieves.NotQueued.selector);
        rat.cancel(id);
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        vm.expectRevert(RobinAmongThieves.NotQueued.selector);
        rat.execute(RobinAmongThieves.Op.SetDrawBps, 0, address(0));
        vm.expectRevert(RobinAmongThieves.RenounceDisabled.selector);
        rat.renounceOwnership();
        vm.stopPrank();
        bytes memory unauth = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, ana);
        vm.startPrank(ana);
        vm.expectRevert(unauth);
        rat.queue(RobinAmongThieves.Op.SetKeeper, 0, ana);
        vm.expectRevert(unauth);
        rat.revokeKeeper();
        vm.expectRevert(unauth);
        rat.pauseEntries(true);
        vm.expectRevert(unauth);
        rat.queueBonds(true, 1);
        vm.expectRevert(unauth);
        rat.sweepExcess(address(usdg), ana);
        vm.stopPrank();
    }

    function test_revokeKeeper_immediate() public {
        vm.prank(owner);
        rat.revokeKeeper();
        assertEq(rat.keeper(), address(0));
        assertEq(rat.seedTip(), bytes32(0));
        assertEq(rat.nextSeedTip(), bytes32(0));
        uint64 from = uint64(rat.currentRound() + 2);
        vm.prank(keeper);
        vm.expectRevert(RobinAmongThieves.NotKeeper.selector);
        rat.commitSeedChain(keccak256("x"), from);
    }

    /// Operator and agent-wallet entries must use the one-click nonce. A keeper-chosen value is rejected.
    function test_RAT01_oneClickEntropy_operatorAndAgent() public {
        uint256 id = regFunded(ana, 50e6);
        vm.prank(ana);
        rat.setOperator(id, opr);
        toEntries(FIRST);
        bytes32 grind = keccak256("grind");
        vm.prank(opr);
        vm.expectRevert(RobinAmongThieves.BadEntropy.selector);
        rat.enter(id, FIRST, grind);
        enterAs(opr, id, FIRST);
        assertEq(openRoundOf(id), FIRST);

        address wallet = makeAddr("agentWallet");
        ratFund(wallet);
        vm.prank(ana);
        uint256 agentId = idr.register("agent");
        vm.prank(ana);
        idr.setAgentWallet(agentId, wallet);
        vm.prank(wallet);
        rat.registerOutlaw(agentId, address(0), address(wif), LIC);
        vm.prank(wallet);
        rat.deposit(agentId, 20e6);
        uint256 r2 = FIRST + 1;
        toEntries(r2);
        vm.prank(wallet);
        vm.expectRevert(RobinAmongThieves.BadEntropy.selector);
        rat.enter(agentId, r2, grind);
        vm.prank(wallet);
        rat.enter(agentId, r2, keccak256(abi.encode(agentId, r2)));
        assertEq(openRoundOf(agentId), r2);
    }

    /// The keeper chooses who enters and knows the seed, but cannot know the shuffle until the reveal
    /// block's hash exists. Two hashes do not give the same pairing.
    function test_RAT01_keeperCannotPredictPairingBeforeRevealBlock() public {
        uint256 n = 4;
        uint256[] memory ids = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            address w = address(uint160(0x71000 + i));
            ratFund(w);
            ids[i] = regFunded(w, 20e6);
        }
        address colluder = address(0x7BAD);
        ratFund(colluder);
        uint256 x = regFunded(colluder, 20e6);
        toEntries(FIRST);
        for (uint256 i; i < n; ++i) {
            enterAs(address(uint160(0x71000 + i)), ids[i], FIRST);
        }
        enterAs(colluder, x, FIRST); // last, an order the keeper chose

        vm.warp(rat.closeTime(FIRST));
        rat.revealSeed(FIRST, chain[1]);
        vm.expectRevert(RobinAmongThieves.SeedHashUnavailable.selector);
        rat.pair(FIRST, 1000);

        uint256 revealed = MockArbSys(address(0x64)).n();
        uint256 snap = vm.snapshotState();
        uint256 seen;
        uint256 distinct;
        for (uint256 h; h < 12; ++h) {
            vm.revertToState(snap);
            snap = vm.snapshotState();
            MockArbSys arb = MockArbSys(address(0x64));
            arb.setHash(revealed, bytes32(uint256(h + 1)));
            arb.set(revealed + 1);
            rat.pair(FIRST, 1000);
            uint256 opp = rat.matchOf(FIRST, x);
            if (seen == 0) seen = opp + 1;
            else if (opp + 1 != seen) ++distinct;
        }
        assertGt(distinct, 0, "different reveal-block hashes change the pairing");
    }

    /// A reveal block older than 256 L2 blocks cannot be mixed, so the round stays open to be cancelled.
    function test_RAT01_staleRevealBlock_pairReverts_thenCancel() public {
        uint256 a = regFunded(ana, 20e6);
        uint256 b = regFunded(bob, 20e6);
        toEntries(FIRST);
        enterAs(ana, a, FIRST);
        enterAs(bob, b, FIRST);
        vm.warp(rat.closeTime(FIRST));
        rat.revealSeed(FIRST, chain[1]);
        MockArbSys arb = MockArbSys(address(0x64));
        arb.set(arb.n() + 257);
        vm.expectRevert(RobinAmongThieves.SeedHashUnavailable.selector);
        rat.pair(FIRST, 10);
        vm.warp(rat.closeTime(FIRST) + 8 minutes);
        rat.cancelRound(FIRST, 10);
        assertEq(bal(a), 20e6);
        assertEq(bal(b), 20e6);
    }

    /// Revoking the keeper drops the hash chain. The old preimage no longer reveals, so a stolen chain cannot
    /// keep steering rounds.
    function test_RAT01_revokeKeeper_clearsSeedChain() public {
        assertTrue(rat.nextSeedTip() != bytes32(0));
        uint256 a = regFunded(ana, 50e6);
        uint256 b = regFunded(bob, 50e6);
        toEntries(FIRST);
        enterAs(ana, a, FIRST);
        enterAs(bob, b, FIRST);
        vm.warp(rat.closeTime(FIRST));
        rat.revealSeed(FIRST, chain[1]);
        assertEq(rat.seedTip(), chain[1]);
        vm.prank(owner);
        rat.revokeKeeper();
        assertEq(rat.keeper(), address(0));
        assertEq(rat.seedTip(), bytes32(0));
        assertEq(rat.nextSeedTip(), bytes32(0));
        // ana and bob are still in the revealed round. Two other outlaws enter the next one.
        uint256 c = regFunded(cat, 50e6);
        uint256 d = regFunded(dan, 50e6);
        uint256 r2 = FIRST + 1;
        toEntries(r2);
        enterAs(cat, c, r2);
        enterAs(dan, d, r2);
        vm.warp(rat.closeTime(r2));
        vm.expectRevert(RobinAmongThieves.NoSeedChain.selector);
        rat.revealSeed(r2, chain[2]);
    }

    /// Retiring between settle and finalize used to credit the bonus to an outlaw with no controller.
    /// The bonus stays in the Sharing Pot, and nothing is left where withdraw cannot reach it.
    function test_RAT02_retireBeforeFinalize_bonusStaysInPot() public {
        uint256 a = regFunded(ana, 500e6);
        uint256 b = regFunded(bob, 500e6);
        rat.setOpponents(a, 5);
        rat.setOpponents(b, 5);
        vm.prank(owner);
        rat.fundPot(100e6);
        uint256 r = (T0 + 24 hours - T0) / 30 minutes + 2;
        toEntries(r);
        enterAs(ana, a, r);
        enterAs(bob, b, r);
        seedPair(r);
        commitAs(ana, a, r, SHARE);
        commitAs(bob, b, r, SHARE);
        revealAs(ana, a, r, SHARE);
        revealAs(bob, b, r, SHARE);
        toSettle(r);
        rat.settle(r, 1000);
        assertEq(openRoundOf(a), 0);
        uint256 bobBefore = bal(b);
        uint256 potBefore = rat.sharingPot();

        vm.prank(ana);
        rat.retire(a);
        assertEq(bal(a), 0);

        rat.finalize(r, 1000);
        assertEq(bal(a), 0, "retired outlaw is not credited");
        assertEq(bal(b), bobBefore + 2e6, "the other outlaw still receives the bonus");
        assertEq(rat.sharingPot(), potBefore - 2e6, "the retired outlaw's bonus stays in the pot");
        ledgersOk();

        uint256 owed = rat.freeBalances() + rat.reservedStakes() + rat.sharingPot() + rat.rakePending();
        assertEq(usdg.balanceOf(address(rat)), owed);
        vm.prank(owner);
        rat.sweepExcess(address(usdg), owner);
        assertEq(usdg.balanceOf(address(rat)), owed, "sweep cannot take the pot");
        vm.prank(bob);
        rat.withdraw(b, 2e6, bob);
        ledgersOk();
    }

    function test_drawBpsZero_noBonus() public {
        vm.prank(owner);
        rat.queue(RobinAmongThieves.Op.SetDrawBps, 0, address(0));
        vm.warp(T0 + 48 hours);
        vm.prank(owner);
        rat.execute(RobinAmongThieves.Op.SetDrawBps, 0, address(0));
        uint256 a = regFunded(ana, 100e6);
        uint256 b = regFunded(bob, 100e6);
        rat.setOpponents(a, 5);
        rat.setOpponents(b, 5);
        vm.prank(owner);
        rat.fundPot(100e6);
        vm.warp(T0 + 72 hours);
        uint256 r = rat.currentRound();
        playMatch(r, ana, a, SHARE, bob, b, SHARE);
        assertEq(bal(a), 95e6 + 4_750_000);
    }

    function test_flushRake_toRakeSink() public {
        uint256 a = regFunded(ana, 50e6);
        uint256 b = regFunded(bob, 50e6);
        rat.flushRake(); // nothing yet: no-op
        playMatch(FIRST, ana, a, SHARE, bob, b, STEAL);
        rat.flushRake();
        assertEq(usdg.balanceOf(address(buyer)), 300_000);
        assertEq(rat.rakePending(), 0);
        ledgersOk();
    }

    function test_sweepExcess_onlyAboveLedgers() public {
        uint256 a = regFunded(ana, 50e6);
        reg(bob);
        usdg.mint(address(rat), 7e6);
        wif.mint(address(rat), 3e18);
        address to = makeAddr("sweepTo");
        vm.startPrank(owner);
        rat.sweepExcess(address(usdg), to);
        rat.sweepExcess(address(wif), to);
        rat.sweepExcess(address(usdg), to); // nothing more
        vm.expectRevert(RobinAmongThieves.ZeroAddress.selector);
        rat.sweepExcess(address(usdg), address(0));
        vm.stopPrank();
        assertEq(usdg.balanceOf(to), 7e6);
        assertEq(wif.balanceOf(to), 3e18);
        assertEq(wif.balanceOf(address(rat)), 2 * LIC);
        assertEq(bal(a), 50e6);
        ledgersOk();
    }
}

contract RatBondTest is RatBase {
    RobinAmongThieves.Choice constant SHARE = RobinAmongThieves.Choice.Share;
    RobinAmongThieves.Choice constant STEAL = RobinAmongThieves.Choice.Steal;

    uint256 a;
    uint256 b;

    function setUp() public override {
        super.setUp();
        a = regFunded(ana, 100e6);
        b = regFunded(bob, 100e6);
    }

    function _enable(uint128 minB) internal {
        vm.prank(owner);
        rat.queueBonds(true, minB);
        vm.warp(rat.bondOpEta());
        vm.prank(owner);
        rat.executeBonds();
    }

    function test_disabled_everyPath() public {
        assertFalse(rat.bondsEnabled());
        assertEq(rat.minBond(), 0);
        vm.prank(ana);
        vm.expectRevert(RobinAmongThieves.BondsDisabled.selector);
        rat.bond(a, 1000e18, address(wif));
        vm.prank(ana);
        rat.unbond(a); // no bond: no-op
        vm.prank(bob);
        rat.claimBond(address(wif)); // nothing: no-op
        rat.flushBondBurn(address(wif)); // nothing: no-op
        playMatch(FIRST, ana, a, STEAL, bob, b, SHARE);
        assertEq(rat.burnPending(address(wif)), 0, "no slash while disabled");
        assertEq(rat.bondClaimable(bob, address(wif)), 0);
        assertEq(rat.lockedOf(address(wif)), 2 * LIC);
    }

    function test_enableOp_7days_cancel_pending() public {
        vm.startPrank(owner);
        rat.queueBonds(true, 1000e18);
        uint256 eta = rat.bondOpEta();
        assertEq(eta, vm.getBlockTimestamp() + 7 days);
        vm.expectRevert(RobinAmongThieves.AlreadyPending.selector);
        rat.queueBonds(true, 1);
        vm.warp(eta - 1);
        vm.expectRevert(abi.encodeWithSelector(RobinAmongThieves.TooEarly.selector, eta));
        rat.executeBonds();
        rat.cancelBonds();
        vm.expectRevert(RobinAmongThieves.NotQueued.selector);
        rat.cancelBonds();
        vm.warp(eta);
        vm.expectRevert(RobinAmongThieves.NotQueued.selector);
        rat.executeBonds();
        assertFalse(rat.bondsEnabled());
        vm.stopPrank();
        vm.prank(ana);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, ana));
        rat.executeBonds();
    }

    function test_enabled_bond_steal_exactSlash_thenDisable_unbond() public {
        _enable(1000e18);
        assertTrue(rat.bondsEnabled());
        assertEq(rat.minBond(), 1000e18);
        vm.startPrank(ana);
        vm.expectRevert(RobinAmongThieves.BondTooSmall.selector);
        rat.bond(a, 999e18, address(wif));
        vm.expectRevert(RobinAmongThieves.TokenChanged.selector);
        rat.bond(a, 1000e18, address(tokenB));
        rat.bond(a, 1000e18, address(wif));
        vm.stopPrank();
        vm.prank(bob);
        vm.expectRevert(RobinAmongThieves.NotController.selector);
        rat.bond(a, 1, address(wif));
        assertEq(rat.lockedOf(address(wif)), 3000e18);

        uint256 r = rat.currentRound();
        playMatch(r, ana, a, STEAL, bob, b, SHARE);
        // 10% of 1000: 50 burned (pending), 50 to bob's controller
        (,,,,,,,,,,,, address bt, uint128 left,) = rat.outlaws(a);
        assertEq(bt, address(wif));
        assertEq(left, 900e18);
        assertEq(rat.burnPending(address(wif)), 50e18);
        assertEq(rat.bondClaimable(bob, address(wif)), 50e18);
        assertEq(rat.lockedOf(address(wif)), 2900e18);
        assertEq(wif.balanceOf(address(rat)), 3000e18, "I5: everything still covered");
        rat.flushBondBurn(address(wif));
        assertEq(wif.balanceOf(rat.DEAD()), 50e18);
        uint256 w = wif.balanceOf(bob);
        vm.prank(bob);
        rat.claimBond(address(wif));
        assertEq(wif.balanceOf(bob), w + 50e18);

        // a bonded no-reveal isn't slashed
        uint256 r2 = r + 2;
        playMatch(r2, ana, a, RobinAmongThieves.Choice.None, bob, b, SHARE);
        (,,,,,,,,,,,,, left,) = rat.outlaws(a);
        assertEq(left, 900e18);

        // top-ups stay in the snapshotted token, even after a GameConfig token update
        applyTokens(address(tokenB), PASS_LOCK, address(tokenB));
        vm.prank(ana);
        vm.expectRevert(RobinAmongThieves.TokenChanged.selector);
        rat.bond(a, 100e18, address(tokenB));
        vm.prank(ana);
        rat.bond(a, 100e18, address(wif));

        // disable again: no new bonds, existing ones come back
        vm.prank(owner);
        rat.queueBonds(false, 0);
        vm.warp(rat.bondOpEta());
        vm.prank(owner);
        rat.executeBonds();
        vm.prank(ana);
        vm.expectRevert(RobinAmongThieves.BondsDisabled.selector);
        rat.bond(a, 100e18, address(wif));
        uint256 before = wif.balanceOf(ana);
        vm.prank(ana);
        rat.unbond(a);
        assertEq(wif.balanceOf(ana), before + 1000e18);
        assertEq(rat.lockedOf(address(wif)), 2 * LIC);
    }

    function test_unbond_blockedWithOpenRound_retireReturnsBond() public {
        _enable(0);
        vm.prank(ana);
        rat.bond(a, 10e18, address(wif));
        uint256 r = rat.currentRound();
        enterAs(ana, a, r);
        vm.prank(ana);
        vm.expectRevert(RobinAmongThieves.OpenRound.selector);
        rat.unbond(a);
        vm.warp(rat.closeTime(r) + 8 minutes);
        rat.cancelRound(r, 10);
        vm.warp(T0 + 30 days);
        uint256 before = wif.balanceOf(ana);
        vm.prank(ana);
        rat.retire(a);
        assertEq(wif.balanceOf(ana), before + LIC + 10e18);
        assertEq(rat.lockedOf(address(wif)), LIC);
    }
}

contract RatFuzzTest is RatBase {
    RobinAmongThieves.Choice constant SHARE = RobinAmongThieves.Choice.Share;
    RobinAmongThieves.Choice constant STEAL = RobinAmongThieves.Choice.Steal;

    function testFuzz_deposit_withdraw(uint256 dep, uint256 out, address to) public {
        vm.assume(to != address(0) && to != address(rat));
        dep = bound(dep, 1, 900_000e6);
        out = bound(out, 1, dep);
        uint256 id = reg(ana);
        vm.prank(ana);
        rat.deposit(id, dep);
        uint256 before = usdg.balanceOf(to);
        vm.prank(ana);
        rat.withdraw(id, out, to);
        assertEq(usdg.balanceOf(to), before + out);
        assertEq(bal(id), dep - out);
        assertEq(rat.freeBalances(), dep - out);
        ledgersOk();
    }

    function testFuzz_enter_reservesExactlyOneStake(uint256 dep) public {
        dep = bound(dep, 5e6, 900_000e6);
        uint256 id = regFunded(ana, dep);
        enterAs(ana, id, rat.currentRound());
        assertEq(bal(id), dep - 5e6);
        assertEq(rat.reservedStakes(), 5e6);
        ledgersOk();
    }

    /// I3: whatever the pot, a round's bonuses are at most drawBps of it, at most 2 each, and the pot never goes negative.
    function testFuzz_finalize_boundedByPot(uint256 pot) public {
        pot = bound(pot, 0, 500_000e6);
        uint256 a = regFunded(ana, 100e6);
        uint256 b = regFunded(bob, 100e6);
        rat.setOpponents(a, 5);
        rat.setOpponents(b, 5);
        if (pot != 0) {
            vm.prank(owner);
            rat.fundPot(pot);
        }
        vm.warp(T0 + 25 hours);
        uint256 r = rat.currentRound();
        uint256 potAtFinalize = pot + 200_000;
        playMatch(r, ana, a, SHARE, bob, b, SHARE);
        (,,,,,,,,,,,,,,, uint128 bpp, uint128 paid,) = rat.rounds(r);
        assertLe(paid, potAtFinalize * 2500 / 10_000, "R1");
        assertLe(bpp, 2e6);
        assertEq(rat.sharingPot(), potAtFinalize - paid);
        assertEq(bal(a) + bal(b), 190e6 + 9_500_000 + paid);
        ledgersOk();
    }

    function testFuzz_flushRake_matchesRakeTaken(uint8 rounds_) public {
        uint256 n = bound(rounds_, 1, 6);
        uint256 a = regFunded(ana, 100e6);
        uint256 b = regFunded(bob, 100e6);
        for (uint256 i; i < n; ++i) {
            playMatch(FIRST + 2 * i, ana, a, STEAL, bob, b, SHARE);
        }
        rat.flushRake();
        assertEq(usdg.balanceOf(address(buyer)), n * 300_000);
        ledgersOk();
    }

    /// Licence lock and return stay exact whether the controller keeps the pass or unlocks it before retiring.
    function testFuzz_licence_lockAndReturn_passOnAndOff(uint256 dep, uint256 bondAmt, bool dropPass) public {
        dep = bound(dep, 0, 500_000e6);
        bondAmt = bound(bondAmt, 0, 20_000e18);

        uint256 w0 = wif.balanceOf(ana);
        uint256 id = reg(ana);
        assertEq(wif.balanceOf(ana), w0 - LIC, "register locks exactly the licence");
        assertEq(wif.balanceOf(address(rat)), LIC);
        assertEq(rat.lockedOf(address(wif)), LIC);

        if (bondAmt != 0) {
            vm.prank(owner);
            rat.queueBonds(true, 0);
            vm.warp(rat.bondOpEta());
            vm.prank(owner);
            rat.executeBonds();
            vm.prank(ana);
            rat.bond(id, bondAmt, address(wif));
            assertEq(wif.balanceOf(address(rat)), LIC + bondAmt, "bond lock is exact");
            assertEq(rat.lockedOf(address(wif)), LIC + bondAmt);
        }
        if (dep != 0) {
            vm.prank(ana);
            rat.deposit(id, dep);
        }
        if (dep < 5e6) {
            vm.prank(ana);
            rat.deposit(id, 5e6);
            dep += 5e6;
        }

        uint256 r = rat.currentRound();
        uint256 ratW = wif.balanceOf(address(rat));
        enterAs(ana, id, r);
        assertEq(wif.balanceOf(address(rat)), ratW, "enter does not move the licence");
        assertEq(bal(id), dep - 5e6);
        assertEq(rat.reservedStakes(), 5e6);
        vm.warp(rat.closeTime(r) + 8 minutes);
        rat.cancelRound(r, 10);
        assertEq(bal(id), dep, "the reserved stake comes back");
        assertEq(rat.reservedStakes(), 0);

        if (dropPass) {
            uint256 unlockAt = pass.unlockableAt(ana);
            if (block.timestamp < unlockAt) vm.warp(unlockAt);
            uint256 held = wif.balanceOf(ana);
            vm.prank(ana);
            pass.unlock();
            assertEq(wif.balanceOf(ana), held + PASS_LOCK, "unlock returns the pass, not the licence");
            assertFalse(pass.hasPass(ana));
            uint256 ratW2 = wif.balanceOf(address(rat));
            uint256 ratU2 = usdg.balanceOf(address(rat));
            uint256 wHeld = wif.balanceOf(ana);
            uint256 blocked = rat.currentRound();
            vm.prank(ana);
            vm.expectRevert(RobinAmongThieves.NoPass.selector);
            rat.enter(id, blocked, bytes32("off"));
            vm.prank(ana);
            vm.expectRevert(RobinAmongThieves.NoPass.selector);
            rat.registerOutlawNew("x", address(0), address(wif), LIC);
            assertEq(wif.balanceOf(address(rat)), ratW2, "a refused entry keeps the licence");
            assertEq(usdg.balanceOf(address(rat)), ratU2, "a refused entry keeps the budget");
            assertEq(wif.balanceOf(ana), wHeld);
        } else {
            uint256 r2 = rat.currentRound();
            enterAs(ana, id, r2);
            vm.warp(rat.closeTime(r2) + 8 minutes);
            rat.cancelRound(r2, 10);
        }

        if (block.timestamp < uint256(T0) + 24 hours) vm.warp(uint256(T0) + 24 hours);
        uint256 u = usdg.balanceOf(ana);
        uint256 w = wif.balanceOf(ana);
        vm.prank(ana);
        rat.retire(id);
        assertEq(usdg.balanceOf(ana), u + dep, "budget back in full");
        assertEq(wif.balanceOf(ana), w + LIC + bondAmt, "licence and bond back in full");
        assertEq(rat.lockedOf(address(wif)), 0);
        assertEq(wif.balanceOf(address(rat)), 0);
        assertEq(usdg.balanceOf(address(rat)), 0);
        ledgersOk();
    }

    function testFuzz_retire_returnsEverything(uint256 dep, uint256 waitS) public {
        dep = bound(dep, 0, 900_000e6);
        waitS = bound(waitS, 24 hours, 400 days);
        uint256 id = reg(ana);
        if (dep != 0) {
            vm.prank(ana);
            rat.deposit(id, dep);
        }
        vm.warp(T0 + waitS);
        uint256 u = usdg.balanceOf(ana);
        uint256 w = wif.balanceOf(ana);
        vm.prank(ana);
        rat.retire(id);
        assertEq(usdg.balanceOf(ana), u + dep);
        assertEq(wif.balanceOf(ana), w + LIC);
        assertEq(usdg.balanceOf(address(rat)), 0);
        assertEq(wif.balanceOf(address(rat)), 0);
    }

    /// With bonds enabled: the slash is exactly 10% (half burned, half to the victim), and every unit stays covered.
    function testFuzz_bond_slash_claim_unbond(uint256 amt) public {
        amt = bound(amt, 1, 50_000e18);
        vm.prank(owner);
        rat.queueBonds(true, 0);
        vm.warp(rat.bondOpEta());
        vm.prank(owner);
        rat.executeBonds();
        uint256 a = regFunded(ana, 100e6);
        uint256 b = regFunded(bob, 100e6);
        vm.prank(ana);
        rat.bond(a, amt, address(wif));
        playMatch(rat.currentRound(), ana, a, STEAL, bob, b, SHARE);
        uint256 slash = amt / 10;
        assertEq(rat.burnPending(address(wif)) + rat.bondClaimable(bob, address(wif)), slash);
        assertGe(
            wif.balanceOf(address(rat)),
            rat.lockedOf(address(wif)) + rat.claimableOf(address(wif)) + rat.burnPending(address(wif)),
            "I5"
        );
        vm.prank(bob);
        rat.claimBond(address(wif));
        rat.flushBondBurn(address(wif));
        uint256 w = wif.balanceOf(ana);
        vm.prank(ana);
        rat.unbond(a);
        assertEq(wif.balanceOf(ana), w + amt - slash);
        assertEq(wif.balanceOf(address(rat)), 2 * LIC);
    }
}
