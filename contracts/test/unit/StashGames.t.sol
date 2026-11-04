// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {console2} from "forge-std/console2.sol";
import {Base} from "../Base.t.sol";
import {FairCore} from "../../src/FairCore.sol";
import {LastArrow} from "../../src/LastArrow.sol";
import {SheriffsSeat} from "../../src/SheriffsSeat.sol";
import {Nonces} from "@openzeppelin/contracts/utils/Nonces.sol";
import {Stash} from "../../src/Stash.sol";
import {IFairCore} from "../../src/interfaces/IFair.sol";
import {MockArbSys} from "../mocks/Mocks.sol";

/// Real Last Arrow and Sheriff's Seat. Stash is the payer and the owner is the player.
contract StashGamesTest is Base {
    LastArrow internal la;
    SheriffsSeat internal seat;
    Stash internal stash;
    MockArbSys internal arb;
    uint256 internal day0;

    address internal p1;
    address internal p2;
    address internal p1Key;
    address internal p2Key;
    uint256 internal p1Pk;
    uint256 internal p2Pk;
    uint256 internal p1KeyPk;
    uint256 internal p2KeyPk;
    address internal feeTo = makeAddr("stashFees");
    address internal raiser = makeAddr("stashRaiser");

    function wireBooths() internal override {
        la = new LastArrow(IFairCore(address(core)));
        day0 = (uint256(T0) / 1 days + 1) * 1 days;
        uint256 back = vm.getBlockTimestamp();
        vm.warp(day0);
        seat = new SheriffsSeat(IFairCore(address(core)), day0, 1 days);
        vm.warp(back);
        core.setupSet(FairCore.Op.AddBooth, 0, address(la));
        core.setupSet(FairCore.Op.AddBooth, 0, address(seat));
    }

    function setUp() public override {
        super.setUp();
        vm.etch(address(0x64), address(new MockArbSys()).code);
        arb = MockArbSys(address(0x64));
        arb.set(1_000_000);
        (p1, p1Pk) = makeAddrAndKey("stashP1");
        (p2, p2Pk) = makeAddrAndKey("stashP2");
        (p1Key, p1KeyPk) = makeAddrAndKey("stashP1Key");
        (p2Key, p2KeyPk) = makeAddrAndKey("stashP2Key");
        _fund(p1);
        _fund(p2);
        vm.warp(day0);
        stash = new Stash(
            address(core),
            address(la),
            address(seat),
            address(usdg),
            feeTo,
            raiser,
            0.05e6,
            1e6,
            _lines()
        );
        _enter(p1, p1Key);
        _enter(p2, p2Key);
    }

    function test_relayedShoot_creditsOwner_andRefunds() public {
        uint256 price = la.currentPrice();
        uint256 before = stash.balance(p1);
        uint256 maxPrice = price + 10e6;
        _relayShoot(p1, p1KeyPk, maxPrice);
        assertEq(stash.balance(p1), before - price - stash.shotFee());
        assertEq(tokenFee(), stash.shotFee());
        assertEq(usdg.allowance(address(stash), address(core)), 0);
        assertEq(la.roundState(1).lastShooter, p1);
        assertEq(la.countOf(1, p1), 1);
        assertEq(la.countOf(1, address(stash)), 0);
        (,,,, uint256 spent) = stash.session(p1);
        assertEq(spent, price + stash.shotFee());
    }

    function test_directShoot_hasNoFee() public {
        _bump();
        uint256 price = la.currentPrice();
        uint256 before = stash.balance(p1);
        uint256 roundId = la.nextShotRound();
        vm.prank(p1);
        stash.shoot(price + 1e6, roundId);
        assertEq(stash.balance(p1), before - price);
        assertEq(tokenFee(), 0);
        (,,,, uint256 spent) = stash.session(p1);
        assertEq(spent, 0);
        assertEq(usdg.allowance(address(stash), address(core)), 0);
    }

    function test_gas_relayedShootAndTake() public {
        _bump();
        uint256 shootGas = _meterShoot(p1, p1KeyPk);
        _bump();
        uint256 steadyGas = _meterShoot(p2, p2KeyPk);
        _bump();
        uint256 takeGas = _meterTake(p1, p1KeyPk);
        console2.log("relayed shoot open", shootGas);
        console2.log("relayed shoot steady", steadyGas);
        console2.log("relayed take", takeGas);
        assertLt(shootGas, 2_000_000);
        assertLt(steadyGas, 2_000_000);
        assertLt(takeGas, 2_000_000);
        assertGt(shootGas, 50_000);
        assertGt(takeGas, 50_000);
    }

    function test_relayedTake_usesPreset_andCreditsOwner() public {
        _bump();
        uint256 price = seat.price();
        vm.expectEmit(true, true, true, true, address(seat));
        emit SheriffsSeat.SeatTaken(seat.today(), p1, address(0), address(stash), price, "Hold fast", 4);
        _relayTake(p1, p1KeyPk, 0, 4, price + 5e6);
        (address holder,,) = seat.holderOf(seat.today());
        assertEq(holder, p1);
        assertEq(usdg.allowance(address(stash), address(core)), 0);
        assertEq(tokenFee(), stash.shotFee());
    }

    function test_reverts_moveNothing() public {
        uint256 live = la.currentPrice();
        Stash.Shoot memory high = _shoot(p1, live - 1);
        bytes memory highSig = _sig(p1KeyPk, stash.hashShoot(high));
        vm.expectRevert(abi.encodeWithSelector(Stash.PriceAboveMax.selector, live, live - 1));
        stash.shoot(high, highSig);

        uint256 want = la.nextShotRound();
        Stash.Shoot memory wrong = _shoot(p1, type(uint256).max);
        wrong.expectedRound = 9;
        bytes memory wrongSig = _sig(p1KeyPk, stash.hashShoot(wrong));
        vm.expectRevert(abi.encodeWithSelector(LastArrow.WrongRound.selector, 9, want));
        stash.shoot(wrong, wrongSig);

        address bare = makeAddr("bare");
        usdg.mint(bare, 100e6);
        vm.startPrank(bare);
        usdg.approve(address(stash), type(uint256).max);
        stash.deposit(50e6);
        stash.authorizeKey(p1Key, type(uint128).max, block.timestamp + 1 days);
        vm.stopPrank();
        Stash.Shoot memory noPass = _shoot(bare, 5e6);
        (,, uint48 epoch,,) = stash.session(bare);
        noPass.epoch = epoch;
        noPass.nonce = 0;
        bytes memory noPassSig = _sig(p1KeyPk, stash.hashShoot(noPass));
        vm.expectRevert(LastArrow.NoPass.selector);
        stash.shoot(noPass, noPassSig);

        _bump();
        _relayShoot(p1, p1KeyPk, 5e6);
        Stash.Shoot memory back = _shoot(p1, 5e6);
        bytes memory backSig = _sig(p1KeyPk, stash.hashShoot(back));
        vm.expectRevert(LastArrow.BackToBack.selector);
        stash.shoot(back, backSig);

        _bump();
        _relayShoot(p2, p2KeyPk, 5e6);
        Stash.Shoot memory same = _shoot(p1, 5e6);
        bytes memory sameSig = _sig(p1KeyPk, stash.hashShoot(same));
        vm.expectRevert(LastArrow.SameBlock.selector);
        stash.shoot(same, sameSig);

        Stash.Take memory badPreset = _take(p1, 9, 1, 5e6);
        bytes memory badPresetSig = _sig(p1KeyPk, stash.hashTake(badPreset));
        vm.expectRevert(Stash.BadPreset.selector);
        stash.take(badPreset, badPresetSig);

        Stash.Take memory badColor = _take(p2, 0, 9, 5e6);
        bytes memory badColorSig = _sig(p2KeyPk, stash.hashTake(badColor));
        vm.expectRevert(SheriffsSeat.BadColor.selector);
        stash.take(badColor, badColorSig);

        vm.prank(owner);
        core.pauseSales(true);
        _bump();
        Stash.Shoot memory paused = _shoot(p1, 5e6);
        bytes memory pausedSig = _sig(p1KeyPk, stash.hashShoot(paused));
        vm.expectRevert(FairCore.Paused.selector);
        stash.shoot(paused, pausedSig);
        uint256 pausedBal = stash.balance(p1);
        vm.prank(p1);
        stash.withdraw(2e6);
        assertEq(stash.balance(p1), pausedBal - 2e6);
        assertEq(stash.balance(p1), 1_000e6 - 1e6 - stash.shotFee() - 2e6);
        assertEq(stash.balance(p2), 1_000e6 - 1_005_000 - stash.shotFee());
        assertEq(stash.balance(bare), 50e6);
        assertEq(tokenFee(), stash.shotFee() * 2 + stash.withdrawFee());
        assertEq(usdg.allowance(address(stash), address(core)), 0);
    }

    function test_noFair_withdrawStillWorks() public {
        vm.warp(T0 + 6 days + 1);
        Stash.Shoot memory order = _shoot(p1, 5e6);
        bytes memory sig = _sig(p1KeyPk, stash.hashShoot(order));
        vm.expectRevert(FairCore.NoActiveFair.selector);
        stash.shoot(order, sig);
        uint256 bal = stash.balance(p1);
        vm.prank(p1);
        stash.withdraw(bal);
        assertEq(stash.balance(p1), 0);
        assertEq(tokenFee(), stash.withdrawFee());
    }

    function test_claimThenWithdraw_andClaimThenDeposit() public {
        _bump();
        _directShoot(p1);
        _bump();
        _directShoot(p2);
        uint256 stash1 = stash.balance(p1);
        uint256 stash2 = stash.balance(p2);
        vm.warp(block.timestamp + 1 hours + 1);
        la.settle(1);
        assertEq(stash.balance(p1), stash1, "winnings are not a stash balance");
        assertEq(stash.balance(p2), stash2);
        assertGt(core.claimable(p1), 0);
        assertGt(core.claimable(p2), 0);

        uint256 claim2 = core.claimable(p2);
        uint256 wallet2 = usdg.balanceOf(p2);
        uint256 fees = tokenFee();
        vm.prank(p2);
        core.claim();
        vm.prank(p2);
        stash.withdraw(stash2);
        assertEq(usdg.balanceOf(p2), wallet2 + claim2 + stash2 - stash.withdrawFee());
        assertEq(tokenFee(), fees + stash.withdrawFee(), "the claim is free, the withdraw pays the fee");
        assertEq(stash.balance(p2), 0);

        uint256 claim1 = core.claimable(p1);
        vm.prank(p1);
        core.claim();
        vm.prank(p1);
        usdg.approve(address(stash), claim1);
        vm.prank(p1);
        stash.deposit(claim1);
        assertEq(stash.balance(p1), stash1 + claim1);
        assertEq(tokenFee(), fees + stash.withdrawFee(), "only p2's withdraw paid a fee");
    }

    function test_keyCannotWithdraw_replayFails_revokeIsInstant() public {
        uint256 bal = stash.balance(p1);
        vm.prank(p1Key);
        vm.expectRevert(Stash.BalanceAtOrBelowFee.selector);
        stash.withdraw(2e6);
        Stash.Withdrawal memory w = Stash.Withdrawal(p1, 2e6, stash.nonces(p1), block.timestamp + 1 hours);
        bytes memory wsig = _sig(p1KeyPk, stash.hashWithdraw(w));
        vm.expectRevert(Stash.BadSignature.selector);
        stash.withdraw(w, wsig);
        assertEq(stash.balance(p1), bal);

        Stash.Shoot memory pending = _shoot(p1, 5e6);
        bytes memory sig = _sig(p1KeyPk, stash.hashShoot(pending));
        vm.prank(p1);
        stash.revokeKey();
        vm.expectRevert(Stash.KeyMissing.selector);
        stash.shoot(pending, sig);
        assertEq(stash.balance(p1), bal);

        vm.prank(p1);
        stash.authorizeKey(p1Key, type(uint128).max, block.timestamp + 1 days);
        _bump();
        _relayShoot(p1, p1KeyPk, 5e6);
        uint256 expectedNonce = stash.nonces(p1);
        Stash.Shoot memory replay = _shoot(p1, 5e6);
        replay.nonce = expectedNonce - 1;
        bytes memory replaySig = _sig(p1KeyPk, stash.hashShoot(replay));
        vm.expectRevert(abi.encodeWithSelector(Nonces.InvalidAccountNonce.selector, p1, expectedNonce));
        stash.shoot(replay, replaySig);
    }

    function testFuzz_relayedShootRefundsExtra(uint256 extra) public {
        extra = bound(extra, 0, 20e6);
        _bump();
        uint256 price = la.currentPrice();
        uint256 before = stash.balance(p2);
        _relayShoot(p2, p2KeyPk, price + extra);
        assertEq(stash.balance(p2), before - price - stash.shotFee());
        assertEq(usdg.allowance(address(stash), address(core)), 0);
        assertEq(la.roundState(la.currentRound()).lastShooter, p2);
    }

    function _fund(address who) internal {
        usdg.mint(who, 1_000_000e6);
        wif.mint(who, 100_000e18);
        vm.startPrank(who);
        wif.approve(address(pass), type(uint256).max);
        pass.lock(address(wif), PASS_LOCK);
        vm.stopPrank();
    }

    function _enter(address who, address sessionKey) internal {
        vm.startPrank(who);
        usdg.approve(address(stash), type(uint256).max);
        stash.deposit(1_000e6);
        stash.authorizeKey(sessionKey, type(uint128).max, block.timestamp + 7 days);
        vm.stopPrank();
    }

    function _lines() internal pure returns (string[] memory lines) {
        lines = new string[](4);
        lines[0] = "Hold fast";
        lines[1] = "Make way";
        lines[2] = "Still here";
        lines[3] = "Your move";
    }

    function _bump() internal {
        arb.set(arb.n() + 1);
    }

    function _sig(uint256 pk, bytes32 digest) internal returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _shoot(address who, uint256 maxPrice) internal view returns (Stash.Shoot memory order) {
        (,, uint48 epoch,,) = stash.session(who);
        order = Stash.Shoot({
            owner: who,
            maxPrice: maxPrice,
            expectedRound: la.nextShotRound(),
            nonce: stash.nonces(who),
            deadline: block.timestamp + 1 hours,
            epoch: epoch
        });
    }

    function _take(address who, uint8 presetId, uint8 color, uint256 maxPrice) internal view returns (Stash.Take memory order) {
        (,, uint48 epoch,,) = stash.session(who);
        order = Stash.Take({
            owner: who,
            maxPrice: maxPrice,
            presetId: presetId,
            color: color,
            nonce: stash.nonces(who),
            deadline: block.timestamp + 1 hours,
            epoch: epoch
        });
    }

    function _relayShoot(address who, uint256 keyPk, uint256 maxPrice) internal {
        Stash.Shoot memory order = _shoot(who, maxPrice);
        stash.shoot(order, _sig(keyPk, stash.hashShoot(order)));
    }

    function _relayTake(address who, uint256 keyPk, uint8 presetId, uint8 color, uint256 maxPrice) internal {
        Stash.Take memory order = _take(who, presetId, color, maxPrice);
        stash.take(order, _sig(keyPk, stash.hashTake(order)));
    }

    function _directShoot(address who) internal {
        _bump();
        uint256 price = la.currentPrice();
        uint256 roundId = la.nextShotRound();
        vm.prank(who);
        stash.shoot(price + 1e6, roundId);
    }

    function _meterShoot(address who, uint256 keyPk) internal returns (uint256 used) {
        Stash.Shoot memory order = _shoot(who, la.currentPrice() + 1e6);
        bytes memory sig = _sig(keyPk, stash.hashShoot(order));
        uint256 before = gasleft();
        stash.shoot(order, sig);
        used = before - gasleft();
    }

    function _meterTake(address who, uint256 keyPk) internal returns (uint256 used) {
        Stash.Take memory order = _take(who, 0, 1, seat.price() + 1e6);
        bytes memory sig = _sig(keyPk, stash.hashTake(order));
        uint256 before = gasleft();
        stash.take(order, sig);
        used = before - gasleft();
    }

    function tokenFee() internal view returns (uint256) {
        return usdg.balanceOf(feeTo);
    }
}
