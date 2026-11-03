// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Nonces} from "@openzeppelin/contracts/utils/Nonces.sol";
import {Stash} from "../../src/Stash.sol";
import {DeployStash} from "../../script/DeployStash.s.sol";
import {MockToken, FeeToken} from "../mocks/Mocks.sol";

contract Puller {
    IERC20 public immutable token;

    constructor(IERC20 t) {
        token = t;
    }

    function pull(address from, uint256 amount) external {
        require(token.transferFrom(from, address(this), amount), "pull");
    }
}

contract MockArrow {
    Puller public immutable puller;
    IERC20 public immutable token;
    uint256 public quote = 1e6;
    uint256 public pullAmount = 1e6;
    uint256 public returned = 1e6;
    bool public doRevert;
    address public seenPlayer;
    uint256 public seenAllowance;

    constructor(Puller p, IERC20 t) {
        puller = p;
        token = t;
    }

    function setQuote(uint256 p) external {
        quote = p;
        pullAmount = p;
        returned = p;
    }

    function setReturned(uint256 v) external {
        returned = v;
    }

    function setRevert(bool v) external {
        doRevert = v;
    }

    function currentPrice() external view returns (uint256) {
        return quote;
    }

    function shoot(uint256 maxPrice, address player, uint256) external returns (uint256) {
        maxPrice;
        if (doRevert) revert("game");
        seenPlayer = player;
        seenAllowance = token.allowance(msg.sender, address(puller));
        if (pullAmount != 0) puller.pull(msg.sender, pullAmount);
        return returned;
    }
}

contract MockSeat {
    Puller public immutable puller;
    IERC20 public immutable token;
    uint256 public quote = 1e6;
    uint256 public pullAmount = 1e6;
    uint256 public returned = 1e6;
    bool public doRevert;
    address public seenPlayer;
    string public seenMessage;
    uint8 public seenColor;

    constructor(Puller p, IERC20 t) {
        puller = p;
        token = t;
    }

    function setQuote(uint256 p) external {
        quote = p;
        pullAmount = p;
        returned = p;
    }

    function price() external view returns (uint256) {
        return quote;
    }

    function take(uint256, address player, string calldata message, uint8 color) external returns (uint256) {
        if (doRevert) revert("game");
        seenPlayer = player;
        seenMessage = message;
        seenColor = color;
        if (pullAmount != 0) puller.pull(msg.sender, pullAmount);
        return returned;
    }
}

/// @dev Accepts any ERC-1271 signature while `ok` is true.
contract SigWallet {
    bytes4 internal constant MAGIC = 0x1626ba7e;
    bool public ok = true;

    function setOk(bool v) external {
        ok = v;
    }

    function isValidSignature(bytes32, bytes calldata) external view returns (bytes4) {
        return ok ? MAGIC : bytes4(0);
    }
}

/// @dev On the next transfer, tries to reenter Stash.withdraw and swallows the revert.
contract ReenterToken is ERC20 {
    address public stash;
    bool public armed;
    bool public reentered;

    constructor() ERC20("Reenter", "RE") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setStash(address s) external {
        stash = s;
    }

    function arm() external {
        armed = true;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (armed && stash != address(0)) {
            armed = false;
            (bool ok,) = stash.call(abi.encodeWithSignature("withdraw(uint256)", 1));
            reentered = ok;
        }
    }
}

contract StashTest is Test {
    uint256 internal constant PLAYER_PK = 0xA11CE;
    uint256 internal constant KEY_PK = 0xBEEF;
    uint256 internal constant OTHER_PK = 0xC0FFEE;

    MockToken internal token;
    Puller internal puller;
    MockArrow internal arrow;
    MockSeat internal seat;
    Stash internal stash;
    address internal player;
    address internal key;
    address internal other;
    address internal feeTo;
    address internal raiser;

    function setUp() public {
        player = vm.addr(PLAYER_PK);
        key = vm.addr(KEY_PK);
        other = vm.addr(OTHER_PK);
        feeTo = makeAddr("fees");
        raiser = makeAddr("raiser");
        token = new MockToken("Global Dollar", "USDG", 6);
        puller = new Puller(token);
        arrow = new MockArrow(puller, token);
        seat = new MockSeat(puller, token);
        stash = new Stash(
            address(puller), address(arrow), address(seat), address(token), feeTo, raiser, 0.05e6, 1e6, _lines()
        );
        token.mint(player, 1_000_000e6);
        vm.startPrank(player);
        token.approve(address(stash), type(uint256).max);
        stash.deposit(10_000e6);
        stash.authorizeKey(key, type(uint128).max, block.timestamp + 1 days);
        vm.stopPrank();
    }

    function test_domain_andTypehashes() public view {
        (, string memory name, string memory version, uint256 chainId, address verifying,,) = stash.eip712Domain();
        assertEq(name, "Stash");
        assertEq(version, "1");
        assertEq(chainId, block.chainid);
        assertEq(verifying, address(stash));
        assertEq(stash.SHOOT_TYPEHASH(), keccak256("Shoot(address owner,uint256 maxPrice,uint256 expectedRound,uint256 nonce,uint256 deadline,uint256 epoch)"));
        assertEq(stash.TAKE_TYPEHASH(), keccak256("Take(address owner,uint256 maxPrice,uint8 presetId,uint8 color,uint256 nonce,uint256 deadline,uint256 epoch)"));
        assertEq(stash.WITHDRAW_TYPEHASH(), keccak256("Withdraw(address owner,uint256 amount,uint256 nonce,uint256 deadline)"));
        assertEq(stash.SHOOT_TYPEHASH(), 0x801186bd6009f0b16ebf43fffa8c3c173af2178b7c8457dbf9f9413499652cff);
        assertEq(stash.TAKE_TYPEHASH(), 0x0d04c6d024e9e0c841385c23ea018007a89b83781233965c4f2503c204df279d);
        assertEq(stash.shotFee(), 0.05e6);
        assertEq(stash.withdrawFee(), 1e6);
        assertEq(stash.cap(), 50_000e6);
        assertEq(stash.preset(0), "Hold fast");
        assertEq(stash.presetCount(), 2);
    }

    function test_deposit_delta_andCap() public {
        uint256 before = stash.balance(player);
        uint256 room = 50_000e6 - stash.totalHeld();
        vm.prank(player);
        stash.deposit(room);
        assertEq(stash.totalHeld(), 50_000e6);
        assertEq(stash.balance(player), before + (50_000e6 - before));
        vm.prank(player);
        vm.expectRevert(Stash.OverCap.selector);
        stash.deposit(1);
        vm.prank(player);
        vm.expectRevert(Stash.ZeroAmount.selector);
        stash.deposit(0);
    }

    function test_raiseCap_onlyUp_thenUnlimited() public {
        uint256 c = stash.cap();
        vm.prank(player);
        vm.expectRevert(Stash.NotCapRaiser.selector);
        stash.raiseCap(c + 1);
        vm.prank(raiser);
        vm.expectRevert(Stash.CapNotRaised.selector);
        stash.raiseCap(c);
        vm.prank(raiser);
        vm.expectRevert(Stash.CapNotRaised.selector);
        stash.raiseCap(c - 1);
        vm.prank(raiser);
        stash.raiseCap(type(uint256).max);
        assertEq(stash.cap(), type(uint256).max);
        vm.prank(player);
        stash.deposit(1_000_000e6 - 10_000e6);
        assertEq(stash.totalHeld(), 1_000_000e6);
        vm.prank(raiser);
        stash.renounceCapRaiser();
        assertEq(stash.capRaiser(), address(0));
        vm.prank(raiser);
        vm.expectRevert(Stash.NotCapRaiser.selector);
        stash.raiseCap(type(uint256).max);
    }

    function test_directAndRelayWithdraw_bothChargeOne() public {
        uint256 fees = token.balanceOf(feeTo);
        uint256 wallet = token.balanceOf(player);
        vm.prank(player);
        stash.withdraw(100e6);
        assertEq(token.balanceOf(player), wallet + 100e6 - 1e6);
        assertEq(token.balanceOf(feeTo), fees + 1e6);
        assertEq(stash.balance(player), 10_000e6 - 100e6);

        uint256 bal = stash.balance(player);
        _relayWithdraw(bal);
        assertEq(stash.balance(player), 0);
        assertEq(token.balanceOf(feeTo), fees + 2e6);
        assertEq(token.balanceOf(player), wallet + 100e6 - 1e6 + (bal - 1e6));
    }

    function test_directWithdraw_revertsAtOrBelowFee() public {
        uint256 fee = stash.withdrawFee();
        uint256 bal = stash.balance(player);
        vm.prank(player);
        vm.expectRevert(Stash.AmountNotAboveFee.selector);
        stash.withdraw(fee);
        vm.prank(player);
        vm.expectRevert(Stash.AmountNotAboveFee.selector);
        stash.withdraw(1);
        assertEq(stash.balance(player), bal);
    }

    function test_relayWithdraw_revertsAtOrBelowFee() public {
        Stash.Withdrawal memory order = _withdrawOrder(1e6);
        bytes memory sig = _sig(PLAYER_PK, stash.hashWithdraw(order));
        vm.expectRevert(Stash.AmountNotAboveFee.selector);
        stash.withdraw(order, sig);
        vm.prank(player);
        vm.expectRevert(Stash.ZeroAmount.selector);
        stash.withdraw(0);
        uint256 bal = stash.balance(player);
        vm.prank(player);
        vm.expectRevert(Stash.InsufficientBalance.selector);
        stash.withdraw(bal + 1);
    }

    function test_keyCannotWithdrawOrRetarget() public {
        uint256 bal = stash.balance(player);
        vm.prank(key);
        vm.expectRevert(Stash.InsufficientBalance.selector);
        stash.withdraw(2e6);
        assertEq(stash.balance(player), bal);

        Stash.Withdrawal memory w = _withdrawOrder(2e6);
        bytes memory wsig = _sig(KEY_PK, stash.hashWithdraw(w));
        vm.expectRevert(Stash.BadSignature.selector);
        stash.withdraw(w, wsig);

        Stash.LimitChange memory lim = Stash.LimitChange(player, 1e6, stash.nonces(player), block.timestamp + 1 hours);
        bytes memory lsig = _sig(KEY_PK, stash.hashSetLimit(lim));
        vm.expectRevert(Stash.BadSignature.selector);
        stash.setLimit(lim, lsig);

        Stash.Authorize memory auth = Stash.Authorize(player, other, 1e6, block.timestamp + 1 days, stash.nonces(player), block.timestamp + 1 hours);
        bytes memory asig = _sig(KEY_PK, stash.hashAuthorize(auth));
        vm.expectRevert(Stash.BadSignature.selector);
        stash.authorizeKey(auth, asig);

        (address still,,,,) = stash.session(player);
        assertEq(still, key);
        assertEq(stash.balance(player), bal);
    }

    function test_relayedShoot_refundsUnusedMax_andClearsApproval() public {
        uint256 before = stash.balance(player);
        uint256 fees = token.balanceOf(feeTo);
        _relayShoot(5e6);
        assertEq(stash.balance(player), before - 1e6 - stash.shotFee());
        assertEq(token.balanceOf(feeTo), fees + stash.shotFee());
        assertEq(token.balanceOf(address(puller)), 1e6);
        assertEq(token.allowance(address(stash), address(puller)), 0);
        assertEq(arrow.seenPlayer(), player);
        assertEq(arrow.seenAllowance(), 5e6);
        (,,,, uint256 spent) = stash.session(player);
        assertEq(spent, 1e6 + stash.shotFee());
    }

    function test_directShoot_hasNoFee_andDoesNotSpendLimit() public {
        vm.prank(player);
        stash.shoot(5e6, 1);
        assertEq(stash.balance(player), 10_000e6 - 1e6);
        assertEq(token.balanceOf(feeTo), 0);
        (,,,, uint256 spent) = stash.session(player);
        assertEq(spent, 0);
        assertEq(token.allowance(address(stash), address(puller)), 0);
    }

    function test_degen_maxPriceCanEqualBalanceWhenFeeFits() public {
        arrow.setQuote(1e6);
        uint256 cost = 1e6 + stash.shotFee();
        uint256 bal = stash.balance(player);
        vm.prank(player);
        stash.withdraw(bal - cost);
        assertEq(stash.balance(player), cost);
        _relayShoot(cost);
        assertEq(stash.balance(player), 0);
        assertEq(token.balanceOf(feeTo), stash.withdrawFee() + stash.shotFee());
    }

    function test_limit_countsPricePlusFee_notUnusedHeadroom() public {
        uint256 tight = 1e6 + stash.shotFee();
        vm.prank(player);
        stash.setLimit(tight);
        _relayShoot(50e6);
        (,,, uint256 limit, uint256 spent) = stash.session(player);
        assertEq(spent, limit);
        uint256 bal = stash.balance(player);
        Stash.Shoot memory again = _shootOrder(50e6);
        bytes memory againSig = _sig(KEY_PK, stash.hashShoot(again));
        vm.expectRevert(Stash.OverLimit.selector);
        stash.shoot(again, againSig);
        assertEq(stash.balance(player), bal);
        assertEq(token.balanceOf(feeTo), stash.shotFee());
    }

    function test_priceAboveMax_movesNothing() public {
        uint256 bal = stash.balance(player);
        arrow.setQuote(2e6);
        Stash.Shoot memory order = _shootOrder(2e6 - 1);
        bytes memory sig = _sig(KEY_PK, stash.hashShoot(order));
        vm.expectRevert(abi.encodeWithSelector(Stash.PriceAboveMax.selector, 2e6, 2e6 - 1));
        stash.shoot(order, sig);
        assertEq(stash.balance(player), bal);
        assertEq(token.balanceOf(feeTo), 0);
        assertEq(token.allowance(address(stash), address(puller)), 0);
        assertEq(stash.nonces(player), 0);
    }

    function test_revertingGame_movesNothing() public {
        arrow.setRevert(true);
        uint256 bal = stash.balance(player);
        uint256 tokens = token.balanceOf(address(stash));
        Stash.Shoot memory order = _shootOrder(5e6);
        bytes memory sig = _sig(KEY_PK, stash.hashShoot(order));
        vm.expectRevert(bytes("game"));
        stash.shoot(order, sig);
        assertEq(stash.balance(player), bal);
        assertEq(token.balanceOf(address(stash)), tokens);
        assertEq(token.balanceOf(feeTo), 0);
        assertEq(token.allowance(address(stash), address(puller)), 0);
        (,,,, uint256 spent) = stash.session(player);
        assertEq(spent, 0);
    }

    function test_lyingGame_reverts() public {
        arrow.setReturned(2e6);
        uint256 bal = stash.balance(player);
        Stash.Shoot memory order = _shootOrder(5e6);
        bytes memory sig = _sig(KEY_PK, stash.hashShoot(order));
        vm.expectRevert(Stash.TransferMismatch.selector);
        stash.shoot(order, sig);
        assertEq(stash.balance(player), bal);
        assertEq(token.allowance(address(stash), address(puller)), 0);
    }

    function test_take_usesPreset_andRejectsFreeText() public {
        _relayTake(0, 3, 5e6);
        assertEq(seat.seenMessage(), "Hold fast");
        assertEq(seat.seenColor(), 3);
        assertEq(seat.seenPlayer(), player);
        Stash.Take memory bad = _takeOrder(9, 1, 5e6);
        bytes memory badSig = _sig(KEY_PK, stash.hashTake(bad));
        vm.expectRevert(Stash.BadPreset.selector);
        stash.take(bad, badSig);
        vm.prank(player);
        stash.take(4e6, 1, 2);
        assertEq(seat.seenMessage(), "Make way");
        assertEq(token.balanceOf(feeTo), stash.shotFee());
    }

    function test_replay_expired_andWrongNonce() public {
        _relayShoot(5e6);
        Stash.Shoot memory again = _shootOrder(5e6);
        again.nonce = 0;
        bytes memory againSig = _sig(KEY_PK, stash.hashShoot(again));
        vm.expectRevert(abi.encodeWithSelector(Nonces.InvalidAccountNonce.selector, player, 1));
        stash.shoot(again, againSig);

        Stash.Shoot memory skipped = _shootOrder(5e6);
        skipped.nonce = 5;
        bytes memory skippedSig = _sig(KEY_PK, stash.hashShoot(skipped));
        vm.expectRevert(abi.encodeWithSelector(Nonces.InvalidAccountNonce.selector, player, 1));
        stash.shoot(skipped, skippedSig);

        Stash.Shoot memory late = _shootOrder(5e6);
        late.deadline = block.timestamp - 1;
        bytes memory lateSig = _sig(KEY_PK, stash.hashShoot(late));
        vm.warp(block.timestamp + 2);
        vm.expectRevert(Stash.DeadlineExpired.selector);
        stash.shoot(late, lateSig);
    }

    function test_revoke_andNewKey_voidOldSignatures() public {
        Stash.Shoot memory pending = _shootOrder(5e6);
        bytes memory sig = _sig(KEY_PK, stash.hashShoot(pending));
        vm.prank(player);
        stash.revokeKey();
        vm.expectRevert(Stash.KeyMissing.selector);
        stash.shoot(pending, sig);
        assertEq(stash.balance(player), 10_000e6);

        vm.prank(player);
        stash.authorizeKey(key, type(uint128).max, block.timestamp + 1 days);
        vm.expectRevert(Stash.StaleEpoch.selector);
        stash.shoot(pending, sig);

        Stash.Shoot memory fresh = _shootOrder(5e6);
        bytes memory freshSig = _sig(KEY_PK, stash.hashShoot(fresh));
        vm.prank(player);
        stash.authorizeKey(other, type(uint128).max, block.timestamp + 1 days);
        vm.expectRevert(Stash.StaleEpoch.selector);
        stash.shoot(fresh, freshSig);
        (address nowKey,,,,) = stash.session(player);
        assertEq(nowKey, other);
    }

    function test_expiry_bounds_andInstantStop() public {
        uint256 t = block.timestamp;
        vm.prank(player);
        vm.expectRevert(Stash.ExpiryTooFar.selector);
        stash.authorizeKey(key, 1e6, t + 7 days + 1);
        vm.prank(player);
        vm.expectRevert(Stash.ExpiryNotFuture.selector);
        stash.authorizeKey(key, 1e6, t);
        vm.prank(player);
        stash.authorizeKey(key, 1e6, t + 7 days);
        (, uint48 expiry,,,) = stash.session(player);
        assertEq(expiry, t + 7 days);

        vm.warp(t + 7 days);
        Stash.Shoot memory order = _shootOrder(5e6);
        bytes memory sig = _sig(KEY_PK, stash.hashShoot(order));
        vm.expectRevert(Stash.KeyExpired.selector);
        stash.shoot(order, sig);
        vm.prank(player);
        stash.shoot(5e6, 1);
        assertEq(arrow.seenPlayer(), player);
    }

    function test_setLimit_cannotDropBelowSpent() public {
        _relayShoot(5e6);
        (,,,, uint256 spent) = stash.session(player);
        vm.prank(player);
        vm.expectRevert(Stash.LimitBelowSpent.selector);
        stash.setLimit(spent - 1);
        vm.prank(player);
        stash.setLimit(spent);
        vm.prank(player);
        stash.setLimit(type(uint128).max);
        (,,, uint256 limit,) = stash.session(player);
        assertEq(limit, type(uint128).max);
    }

    function test_depositAndWithdraw_doNotResetKey() public {
        (address beforeKey, uint48 beforeExpiry, uint48 beforeEpoch,,) = stash.session(player);
        vm.prank(player);
        stash.deposit(2e6);
        vm.prank(player);
        stash.withdraw(2e6);
        (address afterKey, uint48 afterExpiry, uint48 afterEpoch,,) = stash.session(player);
        assertEq(afterKey, beforeKey);
        assertEq(afterExpiry, beforeExpiry);
        assertEq(afterEpoch, beforeEpoch);
    }

    function test_crossChain_andSecondDeployment_reject() public {
        Stash.Shoot memory order = _shootOrder(5e6);
        bytes memory sig = _sig(KEY_PK, stash.hashShoot(order));
        Stash otherStash = new Stash(
            address(puller), address(arrow), address(seat), address(token), feeTo, raiser, 0.05e6, 1e6, _lines()
        );
        vm.startPrank(player);
        token.approve(address(otherStash), type(uint256).max);
        otherStash.deposit(10e6);
        otherStash.authorizeKey(key, type(uint128).max, block.timestamp + 1 days);
        vm.stopPrank();
        vm.expectRevert(Stash.BadSignature.selector);
        otherStash.shoot(order, sig);

        vm.chainId(4663);
        vm.expectRevert(Stash.BadSignature.selector);
        stash.shoot(order, sig);
    }

    function test_signedOwnerFlows() public {
        Stash.Authorize memory auth = Stash.Authorize(player, other, 50e6, block.timestamp + 2 days, stash.nonces(player), block.timestamp + 1 hours);
        stash.authorizeKey(auth, _sig(PLAYER_PK, stash.hashAuthorize(auth)));
        (address nowKey,, uint48 epoch, uint256 limit, uint256 spent) = stash.session(player);
        assertEq(nowKey, other);
        assertEq(limit, 50e6);
        assertEq(spent, 0);
        assertEq(epoch, 2);

        Stash.LimitChange memory lim = Stash.LimitChange(player, 40e6, stash.nonces(player), block.timestamp + 1 hours);
        stash.setLimit(lim, _sig(PLAYER_PK, stash.hashSetLimit(lim)));
        (,,, limit,) = stash.session(player);
        assertEq(limit, 40e6);

        Stash.Revoke memory rev = Stash.Revoke(player, stash.nonces(player), block.timestamp + 1 hours);
        stash.revokeKey(rev, _sig(PLAYER_PK, stash.hashRevoke(rev)));
        (nowKey,,,,) = stash.session(player);
        assertEq(nowKey, address(0));
    }

    function test_erc1271Owner() public {
        SigWallet wallet = new SigWallet();
        token.mint(address(wallet), 100e6);
        vm.startPrank(address(wallet));
        token.approve(address(stash), type(uint256).max);
        stash.deposit(20e6);
        vm.stopPrank();
        Stash.Authorize memory auth = Stash.Authorize(address(wallet), key, 10e6, block.timestamp + 1 days, 0, block.timestamp + 1 hours);
        stash.authorizeKey(auth, hex"11");
        (address nowKey,,,,) = stash.session(address(wallet));
        assertEq(nowKey, key);
        wallet.setOk(false);
        Stash.Revoke memory rev = Stash.Revoke(address(wallet), 1, block.timestamp + 1 hours);
        vm.expectRevert(Stash.BadSignature.selector);
        stash.revokeKey(rev, hex"11");
    }

    function test_strandedTransfer_isSweepableOnly() public {
        token.mint(address(stash), 5e6);
        assertEq(stash.sweepable(), 5e6);
        assertEq(stash.totalHeld(), 10_000e6);
        vm.prank(player);
        vm.expectRevert(Stash.InsufficientBalance.selector);
        stash.withdraw(10_000e6 + 1);
        (bool ok,) = address(stash).call(abi.encodeWithSignature("sweep(address)", player));
        assertFalse(ok);
    }

    function test_ethTransfer_reverts() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(stash).call{value: 1 ether}("");
        assertFalse(ok);
    }

    function test_feeOnTransferDeposit_reverts() public {
        FeeToken fee = new FeeToken();
        Stash s = new Stash(address(puller), address(arrow), address(seat), address(fee), feeTo, raiser, 0, 0, _lines());
        fee.mint(player, 100e6);
        vm.startPrank(player);
        fee.approve(address(s), type(uint256).max);
        vm.expectRevert(Stash.TransferMismatch.selector);
        s.deposit(10e6);
        vm.stopPrank();
    }

    function test_reenterOnTransfer_cannotWithdraw() public {
        ReenterToken bad = new ReenterToken();
        Puller p = new Puller(bad);
        MockArrow a = new MockArrow(p, bad);
        MockSeat seat2 = new MockSeat(p, bad);
        Stash s = new Stash(address(p), address(a), address(seat2), address(bad), feeTo, raiser, 0.05e6, 1e6, _lines());
        bad.setStash(address(s));
        bad.mint(player, 100e6);
        vm.startPrank(player);
        bad.approve(address(s), type(uint256).max);
        s.deposit(20e6);
        s.authorizeKey(key, type(uint128).max, block.timestamp + 1 days);
        vm.stopPrank();
        bad.arm();
        Stash.Shoot memory order = Stash.Shoot(player, 5e6, 1, 0, block.timestamp + 1 hours, 1);
        s.shoot(order, _sig(KEY_PK, s.hashShoot(order)));
        assertFalse(bad.reentered());
        assertEq(s.balance(player), 20e6 - 1e6 - s.shotFee());
    }

    function test_constructor_rejectsBadFeesPresetsAndWallets() public {
        vm.expectRevert(Stash.FeeAboveMax.selector);
        new Stash(address(puller), address(arrow), address(seat), address(token), feeTo, raiser, 0.25e6 + 1, 1e6, _lines());
        vm.expectRevert(Stash.FeeAboveMax.selector);
        new Stash(address(puller), address(arrow), address(seat), address(token), feeTo, raiser, 0.05e6, 2e6 + 1, _lines());
        new Stash(address(puller), address(arrow), address(seat), address(token), feeTo, raiser, 0.25e6, 2e6, _lines());

        string[] memory empty;
        vm.expectRevert(Stash.BadPresets.selector);
        new Stash(address(puller), address(arrow), address(seat), address(token), feeTo, raiser, 0, 0, empty);

        string[] memory many = new string[](17);
        for (uint256 i; i < 17; ++i) many[i] = "Ok";
        vm.expectRevert(Stash.BadPresets.selector);
        new Stash(address(puller), address(arrow), address(seat), address(token), feeTo, raiser, 0, 0, many);

        string[] memory bad = new string[](1);
        bad[0] = "Hold: fast";
        vm.expectRevert(Stash.BadPresets.selector);
        new Stash(address(puller), address(arrow), address(seat), address(token), feeTo, raiser, 0, 0, bad);
        bad[0] = "Hold; fast";
        vm.expectRevert(Stash.BadPresets.selector);
        new Stash(address(puller), address(arrow), address(seat), address(token), feeTo, raiser, 0, 0, bad);
        bad[0] = unicode"Hold \u2014 fast";
        vm.expectRevert(Stash.BadPresets.selector);
        new Stash(address(puller), address(arrow), address(seat), address(token), feeTo, raiser, 0, 0, bad);

        vm.expectRevert(Stash.BadFeeWallet.selector);
        new Stash(address(puller), address(arrow), address(seat), address(token), address(puller), raiser, 0, 0, _lines());
        vm.expectRevert(Stash.ZeroAddress.selector);
        new Stash(address(0), address(arrow), address(seat), address(token), feeTo, raiser, 0, 0, _lines());
    }

    function test_deployScript_feesAndPresets() public {
        DeployStash deploy = new DeployStash();
        assertEq(deploy.SHOT_FEE(), 0.05e6);
        assertEq(deploy.WITHDRAW_FEE(), 1e6);
        string memory json = vm.readFile("deployments/46630.json");
        assertEq(deploy.FAIR_CORE(), vm.parseJsonAddress(json, ".fairCore"));
        assertEq(deploy.LAST_ARROW(), vm.parseJsonAddress(json, ".lastArrow"));
        assertEq(deploy.SHERIFFS_SEAT(), vm.parseJsonAddress(json, ".sheriffsSeat"));
        assertEq(deploy.USDG(), vm.parseJsonAddress(json, ".usdg"));
        assertEq(deploy.FAIR_CORE(), 0xc76d5ED46786e67Fb5925928af18C08da7078Cf0);
        assertLe(deploy.SHOT_FEE(), 0.25e6);
        assertLe(deploy.WITHDRAW_FEE(), 2e6);
        string[] memory lines = deploy.presetLines();
        assertEq(lines.length, 16);
        Stash s = new Stash(
            address(puller), address(arrow), address(seat), address(token), feeTo, raiser, deploy.SHOT_FEE(), deploy.WITHDRAW_FEE(), lines
        );
        assertEq(s.presetCount(), 16);
        assertEq(s.preset(3), "Make way");
        vm.chainId(4663);
        vm.expectRevert(bytes("Stash deploys on chain 46630 only"));
        deploy.run();
    }

    function testFuzz_chargeIsQuotePlusFee(uint256 quote, uint256 extra) public {
        quote = bound(quote, 1, 100e6);
        extra = bound(extra, 0, 50e6);
        arrow.setQuote(quote);
        uint256 before = stash.balance(player);
        vm.assume(before >= quote + stash.shotFee());
        _relayShoot(quote + extra);
        assertEq(stash.balance(player), before - quote - stash.shotFee());
        assertEq(token.allowance(address(stash), address(puller)), 0);
        assertEq(arrow.seenAllowance(), quote + extra);
        assertEq(arrow.seenPlayer(), player);
    }

    function testFuzz_directWithdraw(uint256 amt) public {
        uint256 bal = stash.balance(player);
        uint256 wallet = token.balanceOf(player);
        amt = bound(amt, 0, bal + 10e6);
        uint256 fee = stash.withdrawFee();
        vm.prank(player);
        if (amt <= fee || amt > bal) {
            vm.expectRevert();
            stash.withdraw(amt);
        } else {
            stash.withdraw(amt);
            assertEq(stash.balance(player), bal - amt);
            assertEq(token.balanceOf(player), wallet + amt - fee);
            assertEq(token.balanceOf(feeTo), fee);
        }
    }

    function testFuzz_relayWithdraw(uint256 amt) public {
        uint256 bal = stash.balance(player);
        uint256 wallet = token.balanceOf(player);
        uint256 fee = stash.withdrawFee();
        amt = bound(amt, 0, bal + 1);
        Stash.Withdrawal memory order = _withdrawOrder(amt);
        bytes memory sig = _sig(PLAYER_PK, stash.hashWithdraw(order));
        if (amt <= fee || amt > bal) {
            vm.expectRevert();
            stash.withdraw(order, sig);
        } else {
            stash.withdraw(order, sig);
            assertEq(stash.balance(player), bal - amt);
            assertEq(token.balanceOf(player), wallet + amt - fee);
            assertEq(token.balanceOf(feeTo), fee);
        }
    }

    function testFuzz_expiry(uint256 exp) public {
        exp = bound(exp, 0, block.timestamp + 14 days);
        vm.prank(player);
        if (exp <= block.timestamp || exp > block.timestamp + 7 days) {
            vm.expectRevert();
            stash.authorizeKey(key, 1e6, exp);
        } else {
            stash.authorizeKey(key, 1e6, exp);
            (, uint48 expiry,,,) = stash.session(player);
            assertEq(uint256(expiry), exp);
        }
    }

    function testFuzz_wrongSigner(uint256 pk) public {
        pk = bound(pk, 1, type(uint128).max);
        vm.assume(pk != KEY_PK);
        Stash.Shoot memory order = _shootOrder(5e6);
        bytes memory sig = _sig(pk, stash.hashShoot(order));
        vm.expectRevert(Stash.BadSignature.selector);
        stash.shoot(order, sig);
    }

    function testFuzz_depositRoom(uint256 amt) public {
        uint256 room = stash.cap() - stash.totalHeld();
        amt = bound(amt, 1, room + 1000e6);
        uint256 before = stash.totalHeld();
        vm.prank(player);
        if (amt > room) {
            vm.expectRevert(Stash.OverCap.selector);
            stash.deposit(amt);
        } else {
            stash.deposit(amt);
            assertEq(stash.totalHeld(), before + amt);
        }
    }

    function _lines() internal pure returns (string[] memory lines) {
        lines = new string[](2);
        lines[0] = "Hold fast";
        lines[1] = "Make way";
    }

    function _sig(uint256 pk, bytes32 digest) internal returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _epoch() internal view returns (uint256 epoch) {
        (,, uint48 e,,) = stash.session(player);
        epoch = e;
    }

    function _shootOrder(uint256 maxPrice) internal view returns (Stash.Shoot memory) {
        return Stash.Shoot({
            owner: player,
            maxPrice: maxPrice,
            expectedRound: 1,
            nonce: stash.nonces(player),
            deadline: block.timestamp + 1 hours,
            epoch: _epoch()
        });
    }

    function _takeOrder(uint8 presetId, uint8 color, uint256 maxPrice) internal view returns (Stash.Take memory) {
        return Stash.Take({
            owner: player,
            maxPrice: maxPrice,
            presetId: presetId,
            color: color,
            nonce: stash.nonces(player),
            deadline: block.timestamp + 1 hours,
            epoch: _epoch()
        });
    }

    function _withdrawOrder(uint256 amount) internal view returns (Stash.Withdrawal memory) {
        return Stash.Withdrawal({
            owner: player, amount: amount, nonce: stash.nonces(player), deadline: block.timestamp + 1 hours
        });
    }

    function _relayShoot(uint256 maxPrice) internal {
        Stash.Shoot memory order = _shootOrder(maxPrice);
        stash.shoot(order, _sig(KEY_PK, stash.hashShoot(order)));
    }

    function _relayTake(uint8 presetId, uint8 color, uint256 maxPrice) internal {
        Stash.Take memory order = _takeOrder(presetId, color, maxPrice);
        stash.take(order, _sig(KEY_PK, stash.hashTake(order)));
    }

    function _relayWithdraw(uint256 amount) internal {
        Stash.Withdrawal memory order = _withdrawOrder(amount);
        stash.withdraw(order, _sig(PLAYER_PK, stash.hashWithdraw(order)));
    }
}
