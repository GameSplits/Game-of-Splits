// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Nonces} from "@openzeppelin/contracts/utils/Nonces.sol";
import {Stash} from "../../src/Stash.sol";
import {Puller, MockArrow, MockSeat} from "./Stash.t.sol";

/// USDG-like token with an issuer blocklist (Paxos USDG can freeze addresses).
contract BlockUSDG is ERC20 {
    mapping(address => bool) public blocked;

    constructor() ERC20("Global Dollar", "USDG") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 a) external {
        _mint(to, a);
    }

    function setBlocked(address a, bool b) external {
        blocked[a] = b;
    }

    function _update(address from, address to, uint256 v) internal override {
        require(!blocked[from] && !blocked[to], "blocked");
        super._update(from, to, v);
    }
}

/// Fees accrue in the Stash so a frozen fee wallet cannot lock balances or plays, and direct owner actions use the
/// nonce so a held signed order cannot outlive a direct revoke.
contract StashFeesAndNoncesTest is Test {
    uint256 internal constant ALICE_PK = 0xA11CE;
    uint256 internal constant KEY_PK = 0xBEEF;

    BlockUSDG internal usdg;
    Puller internal puller;
    MockArrow internal arrow;
    MockSeat internal seat;
    Stash internal stash;
    address internal feeTo = makeAddr("stashFees");
    address internal raiser = makeAddr("raiser");
    address internal alice;
    address internal key;

    event FeesFlushed(address indexed feeWallet, uint256 amount);
    event NonceCancelled(address indexed owner, uint256 nonce);

    function setUp() public {
        alice = vm.addr(ALICE_PK);
        key = vm.addr(KEY_PK);
        usdg = new BlockUSDG();
        puller = new Puller(usdg);
        arrow = new MockArrow(puller, usdg);
        seat = new MockSeat(puller, usdg);
        string[] memory lines = new string[](1);
        lines[0] = "Hold fast";
        stash = new Stash(
            address(puller), address(arrow), address(seat), address(usdg), feeTo, raiser, 0.05e6, 1e6, lines
        );
        usdg.mint(alice, 1_000e6);
        vm.startPrank(alice);
        usdg.approve(address(stash), type(uint256).max);
        stash.deposit(100e6);
        vm.stopPrank();
    }

    // ================================================================ fees

    function test_fees_withdrawAccruesFee_flushPays() public {
        vm.prank(alice);
        stash.withdraw(100e6);
        assertEq(usdg.balanceOf(alice), 900e6 + 99e6);
        assertEq(usdg.balanceOf(feeTo), 0, "nothing pushed to the fee wallet");
        assertEq(stash.feesAccrued(), 1e6);
        assertEq(usdg.balanceOf(address(stash)), 1e6);
        vm.expectEmit(true, false, false, true, address(stash));
        emit FeesFlushed(feeTo, 1e6);
        vm.prank(makeAddr("anyone"));
        stash.flushFees();
        assertEq(usdg.balanceOf(feeTo), 1e6);
        assertEq(stash.feesAccrued(), 0);
        assertEq(usdg.balanceOf(address(stash)), 0);
    }

    /// Regression: the issuer freezes the fee wallet and every player path still works
    function test_fees_feeWalletFreeze_doesNotLockBalances() public {
        usdg.setBlocked(feeTo, true);

        vm.prank(alice);
        stash.withdraw(40e6);
        assertEq(stash.balance(alice), 60e6);
        assertEq(usdg.balanceOf(alice), 900e6 + 39e6);

        Stash.Withdrawal memory w = Stash.Withdrawal(alice, 10e6, stash.nonces(alice), block.timestamp + 1 hours);
        stash.withdraw(w, _sig(ALICE_PK, stash.hashWithdraw(w)));
        assertEq(stash.balance(alice), 50e6);

        vm.prank(alice);
        stash.authorizeKey(key, type(uint128).max, block.timestamp + 1 days);
        Stash.Shoot memory s = _shoot(5e6);
        stash.shoot(s, _sig(KEY_PK, stash.hashShoot(s)));
        Stash.Take memory t = Stash.Take(alice, 5e6, 0, 1, stash.nonces(alice), block.timestamp + 1 hours, _epoch());
        stash.take(t, _sig(KEY_PK, stash.hashTake(t)));
        assertEq(stash.balance(alice), 50e6 - 2 * (1e6 + 0.05e6));

        uint256 fees = 2e6 + 2 * 0.05e6;
        assertEq(stash.feesAccrued(), fees);
        assertEq(usdg.balanceOf(address(stash)), stash.totalHeld() + fees);

        // the frozen wallet only blocks the flush, and the fees stay accrued
        vm.expectRevert(bytes("blocked"));
        stash.flushFees();
        assertEq(stash.feesAccrued(), fees);

        // the whole balance still leaves
        uint256 bal = stash.balance(alice);
        vm.prank(alice);
        stash.withdraw(bal);
        assertEq(stash.balance(alice), 0);
        assertEq(stash.totalHeld(), 0);

        usdg.setBlocked(feeTo, false);
        stash.flushFees();
        assertEq(usdg.balanceOf(feeTo), fees + 1e6);
        assertEq(usdg.balanceOf(address(stash)), 0);
    }

    /// Relayed plays under a frozen fee wallet, after the cap raiser moves the shot fee. Each play accrues the
    /// session fee, min(shotFee, feeCap), and nothing is pushed to the fee wallet.
    function test_fees_frozenFeeWallet_relayedPlaysAccrueSessionFee() public {
        vm.prank(alice);
        stash.authorizeKey(key, type(uint128).max, block.timestamp + 1 days);
        usdg.setBlocked(feeTo, true);

        // fee raised after the key was authorized: this session still pays its 0.05 snapshot
        vm.prank(raiser);
        stash.setShotFee(0.2e6);
        Stash.Shoot memory s1 = _shoot(5e6);
        stash.shoot(s1, _sig(KEY_PK, stash.hashShoot(s1)));
        assertEq(stash.feesAccrued(), 0.05e6);

        // fee lowered below the snapshot: the lower fee applies at once
        vm.prank(raiser);
        stash.setShotFee(0.01e6);
        Stash.Take memory t = Stash.Take(alice, 5e6, 0, 1, stash.nonces(alice), block.timestamp + 1 hours, _epoch());
        stash.take(t, _sig(KEY_PK, stash.hashTake(t)));
        assertEq(stash.feesAccrued(), 0.05e6 + 0.01e6);

        // a new session snapshots the raised fee
        vm.prank(raiser);
        stash.setShotFee(0.2e6);
        vm.prank(alice);
        stash.authorizeKey(key, type(uint128).max, block.timestamp + 1 days);
        Stash.Shoot memory s2 = _shoot(5e6);
        stash.shoot(s2, _sig(KEY_PK, stash.hashShoot(s2)));
        uint256 fees = 0.05e6 + 0.01e6 + 0.2e6;
        assertEq(stash.feesAccrued(), fees);
        assertEq(usdg.balanceOf(feeTo), 0);
        assertEq(stash.balance(alice), 100e6 - 3e6 - fees);
        assertEq(usdg.balanceOf(address(stash)), stash.totalHeld() + fees);

        vm.expectRevert(bytes("blocked"));
        stash.flushFees();
        usdg.setBlocked(feeTo, false);
        stash.flushFees();
        assertEq(usdg.balanceOf(feeTo), fees);
        assertEq(stash.feesAccrued(), 0);
    }

    /// The approved withdraw minimum is unchanged: a balance at or below 1 USDG cannot leave and is not swept,
    /// and every withdrawal above it accrues exactly 1 USDG.
    function test_fees_withdrawMinimumUnchanged() public {
        vm.prank(alice);
        stash.withdraw(99e6);
        assertEq(stash.balance(alice), 1e6);
        assertEq(stash.feesAccrued(), 1e6);
        vm.prank(alice);
        vm.expectRevert(Stash.BalanceAtOrBelowFee.selector);
        stash.withdraw(1e6);
        Stash.Withdrawal memory w = Stash.Withdrawal(alice, 1e6, stash.nonces(alice), block.timestamp + 1 hours);
        bytes memory sig = _sig(ALICE_PK, stash.hashWithdraw(w));
        vm.expectRevert(Stash.BalanceAtOrBelowFee.selector);
        stash.withdraw(w, sig);
        assertEq(stash.balance(alice), 1e6, "stays, no sweep");
        assertEq(stash.feesAccrued(), 1e6);
        vm.prank(alice);
        stash.deposit(1);
        vm.prank(alice);
        vm.expectRevert(Stash.AmountNotAboveFee.selector);
        stash.withdraw(1e6);
        vm.prank(alice);
        stash.withdraw(1e6 + 1);
        assertEq(stash.balance(alice), 0);
        assertEq(stash.feesAccrued(), 2e6);
        assertEq(usdg.balanceOf(alice), 900e6 - 1 + 99e6 - 1e6 + 1);
    }

    function test_fees_flushWithNothing_reverts() public {
        vm.expectRevert(Stash.ZeroAmount.selector);
        stash.flushFees();
        vm.prank(alice);
        stash.withdraw(10e6);
        stash.flushFees();
        vm.expectRevert(Stash.ZeroAmount.selector);
        stash.flushFees();
    }

    function test_fees_directShoot_accruesNothing() public {
        vm.prank(alice);
        stash.shoot(5e6, 1);
        assertEq(stash.feesAccrued(), 0);
        assertEq(stash.balance(alice), 99e6);
    }

    function test_fees_sweepableExcludesFees() public {
        vm.prank(alice);
        stash.withdraw(10e6);
        assertEq(stash.sweepable(), 0);
        usdg.mint(address(stash), 3e6);
        assertEq(stash.sweepable(), 3e6);
    }

    /// conservation: player + fee wallet + Stash never changes, and flushFees moves exactly the accrued fees
    function testFuzz_fees_conservation(uint256 a1, uint256 a2, bool flushMid, bool frozen) public {
        if (frozen) usdg.setBlocked(feeTo, true);
        uint256 total = usdg.balanceOf(alice) + usdg.balanceOf(feeTo) + usdg.balanceOf(address(stash));
        a1 = bound(a1, 0, 120e6);
        vm.prank(alice);
        try stash.withdraw(a1) {} catch {}
        _checkCover();
        if (flushMid) _flushChecked(frozen);
        a2 = bound(a2, 0, stash.balance(alice) + 2e6);
        Stash.Withdrawal memory w = Stash.Withdrawal(alice, a2, stash.nonces(alice), block.timestamp + 1 hours);
        bytes memory sig = _sig(ALICE_PK, stash.hashWithdraw(w));
        try stash.withdraw(w, sig) {} catch {}
        _checkCover();
        _flushChecked(frozen);
        assertEq(usdg.balanceOf(alice) + usdg.balanceOf(feeTo) + usdg.balanceOf(address(stash)), total);
        _checkCover();
    }

    function _flushChecked(bool frozen) internal {
        uint256 acc = stash.feesAccrued();
        uint256 wallet = usdg.balanceOf(feeTo);
        uint256 tokens = usdg.balanceOf(address(stash));
        uint256 held = stash.totalHeld();
        if (acc == 0) {
            vm.expectRevert(Stash.ZeroAmount.selector);
            stash.flushFees();
        } else if (frozen) {
            vm.expectRevert(bytes("blocked"));
            stash.flushFees();
            assertEq(stash.feesAccrued(), acc);
        } else {
            stash.flushFees();
            assertEq(usdg.balanceOf(feeTo), wallet + acc);
            assertEq(usdg.balanceOf(address(stash)), tokens - acc);
            assertEq(stash.feesAccrued(), 0);
        }
        assertEq(stash.totalHeld(), held);
    }

    function _checkCover() internal view {
        assertGe(usdg.balanceOf(address(stash)), stash.totalHeld() + stash.feesAccrued());
        assertEq(stash.balance(alice), stash.totalHeld());
    }

    // ================================================================ nonces

    /// Regression: a held AuthorizeKey dies with the emergency direct revoke
    function test_nonce_heldAuthorize_diesOnDirectRevoke() public {
        Stash.Authorize memory order = _authorize(stash.nonces(alice));
        bytes memory sig = _sig(ALICE_PK, stash.hashAuthorize(order));

        vm.startPrank(alice);
        stash.authorizeKey(key, 50e6, block.timestamp + 1 days);
        stash.revokeKey();
        vm.stopPrank();
        (address k,,,,,) = stash.session(alice);
        assertEq(k, address(0));
        assertEq(stash.nonces(alice), order.nonce + 2, "each direct action used a nonce");

        vm.prank(makeAddr("anyone"));
        vm.expectRevert(abi.encodeWithSelector(Nonces.InvalidAccountNonce.selector, alice, order.nonce + 2));
        stash.authorizeKey(order, sig);
        (address k2,,,,,) = stash.session(alice);
        assertEq(k2, address(0), "revoked key stays revoked");

        // the key the attacker holds can do nothing: no shot, no take, no withdraw, no limit change
        uint256 n = stash.nonces(alice);
        Stash.Shoot memory s = Stash.Shoot(alice, 5e6, 1, n, block.timestamp + 1 hours, _epoch());
        bytes memory sSig = _sig(KEY_PK, stash.hashShoot(s));
        vm.expectRevert(Stash.KeyMissing.selector);
        stash.shoot(s, sSig);
        Stash.Take memory t = Stash.Take(alice, 5e6, 0, 1, n, block.timestamp + 1 hours, _epoch());
        bytes memory tSig = _sig(KEY_PK, stash.hashTake(t));
        vm.expectRevert(Stash.KeyMissing.selector);
        stash.take(t, tSig);
        Stash.Withdrawal memory w = Stash.Withdrawal(alice, 50e6, n, block.timestamp + 1 hours);
        bytes memory wSig = _sig(KEY_PK, stash.hashWithdraw(w));
        vm.expectRevert(Stash.BadSignature.selector);
        stash.withdraw(w, wSig);
        Stash.LimitChange memory l = Stash.LimitChange(alice, type(uint128).max, n, block.timestamp + 1 hours);
        bytes memory lSig = _sig(KEY_PK, stash.hashSetLimit(l));
        vm.expectRevert(Stash.BadSignature.selector);
        stash.setLimit(l, lSig);
        vm.prank(key);
        vm.expectRevert(Stash.KeyMissing.selector);
        stash.revokeKey();
        assertEq(stash.balance(alice), 100e6, "balance untouched");
        assertEq(stash.feesAccrued(), 0);
    }

    /// a held order signed after the direct authorize also dies with the direct revoke
    function test_nonce_heldAuthorizeAtCurrentNonce_diesOnDirectRevoke() public {
        vm.prank(alice);
        stash.authorizeKey(key, 50e6, block.timestamp + 1 days);
        Stash.Authorize memory order = _authorize(stash.nonces(alice));
        bytes memory sig = _sig(ALICE_PK, stash.hashAuthorize(order));
        vm.prank(alice);
        stash.revokeKey();
        vm.expectRevert(abi.encodeWithSelector(Nonces.InvalidAccountNonce.selector, alice, order.nonce + 1));
        stash.authorizeKey(order, sig);
    }

    function test_nonce_heldSetLimit_diesOnDirectSetLimit() public {
        vm.prank(alice);
        stash.authorizeKey(key, 50e6, block.timestamp + 1 days);
        Stash.LimitChange memory order =
            Stash.LimitChange(alice, type(uint128).max, stash.nonces(alice), block.timestamp + 1 hours);
        bytes memory sig = _sig(ALICE_PK, stash.hashSetLimit(order));
        vm.prank(alice);
        stash.setLimit(10e6);
        vm.expectRevert(abi.encodeWithSelector(Nonces.InvalidAccountNonce.selector, alice, order.nonce + 1));
        stash.setLimit(order, sig);
        (,,, uint256 limit,,) = stash.session(alice);
        assertEq(limit, 10e6);
    }

    function test_nonce_cancelNonce_voidsHeldOrders_only() public {
        vm.prank(alice);
        stash.authorizeKey(key, 50e6, block.timestamp + 1 days);
        uint256 n = stash.nonces(alice);
        Stash.Withdrawal memory w = Stash.Withdrawal(alice, 10e6, n, block.timestamp + 1 hours);
        bytes memory wSig = _sig(ALICE_PK, stash.hashWithdraw(w));
        Stash.Shoot memory s = _shoot(5e6);
        bytes memory sSig = _sig(KEY_PK, stash.hashShoot(s));
        (address k0, uint48 e0, uint48 ep0, uint256 l0, uint256 sp0, uint256 fc0) = stash.session(alice);

        vm.expectEmit(true, false, false, true, address(stash));
        emit NonceCancelled(alice, n);
        vm.prank(alice);
        stash.cancelNonce();
        assertEq(stash.nonces(alice), n + 1);

        vm.expectRevert(abi.encodeWithSelector(Nonces.InvalidAccountNonce.selector, alice, n + 1));
        stash.withdraw(w, wSig);
        vm.expectRevert(abi.encodeWithSelector(Nonces.InvalidAccountNonce.selector, alice, n + 1));
        stash.shoot(s, sSig);

        (address k1, uint48 e1, uint48 ep1, uint256 l1, uint256 sp1, uint256 fc1) = stash.session(alice);
        assertEq(k1, k0);
        assertEq(e1, e0);
        assertEq(ep1, ep0);
        assertEq(l1, l0);
        assertEq(sp1, sp0);
        assertEq(fc1, fc0);
        assertEq(stash.balance(alice), 100e6);

        // the next order at the new nonce works
        Stash.Shoot memory fresh = _shoot(5e6);
        stash.shoot(fresh, _sig(KEY_PK, stash.hashShoot(fresh)));
        assertEq(stash.balance(alice), 100e6 - 1e6 - 0.05e6);
    }

    /// a failed direct action uses no nonce, so it cannot be mistaken for a cancel
    function test_nonce_failedDirectAction_keepsNonce() public {
        uint256 n = stash.nonces(alice);
        vm.prank(alice);
        vm.expectRevert(Stash.KeyMissing.selector);
        stash.revokeKey();
        assertEq(stash.nonces(alice), n);
    }

    /// whichever direct action the owner takes, every order held at the old nonce dies
    function testFuzz_nonce_directActionKillsEveryHeldOrder(uint8 action, uint256 limit) public {
        vm.prank(alice);
        stash.authorizeKey(key, 50e6, block.timestamp + 1 days);
        uint256 n = stash.nonces(alice);
        uint256 dl = block.timestamp + 1 hours;
        Stash.Authorize memory au = _authorize(n);
        Stash.LimitChange memory li = Stash.LimitChange(alice, type(uint128).max, n, dl);
        Stash.Revoke memory rv = Stash.Revoke(alice, n, dl);
        Stash.Withdrawal memory wd = Stash.Withdrawal(alice, 10e6, n, dl);
        bytes memory auSig = _sig(ALICE_PK, stash.hashAuthorize(au));
        bytes memory liSig = _sig(ALICE_PK, stash.hashSetLimit(li));
        bytes memory rvSig = _sig(ALICE_PK, stash.hashRevoke(rv));
        bytes memory wdSig = _sig(ALICE_PK, stash.hashWithdraw(wd));

        action = action % 4;
        vm.prank(alice);
        if (action == 0) stash.revokeKey();
        else if (action == 1) stash.setLimit(bound(limit, 1, 1_000e6));
        else if (action == 2) stash.authorizeKey(key, bound(limit, 1, 1_000e6), block.timestamp + 2 hours);
        else stash.cancelNonce();
        assertEq(stash.nonces(alice), n + 1);

        Stash.Shoot memory sh = Stash.Shoot(alice, 5e6, 1, n, dl, _epoch());
        bytes memory shSig = _sig(KEY_PK, stash.hashShoot(sh));
        bytes memory bad = abi.encodeWithSelector(Nonces.InvalidAccountNonce.selector, alice, n + 1);
        vm.expectRevert(bad);
        stash.authorizeKey(au, auSig);
        vm.expectRevert(bad);
        stash.setLimit(li, liSig);
        vm.expectRevert(bad);
        stash.revokeKey(rv, rvSig);
        vm.expectRevert(bad);
        stash.withdraw(wd, wdSig);
        if (action != 0) {
            vm.expectRevert(bad);
            stash.shoot(sh, shSig);
        }
        assertEq(stash.balance(alice), 100e6);
    }

    // ================================================================ helpers

    function _authorize(uint256 nonce) internal view returns (Stash.Authorize memory) {
        return Stash.Authorize({
            owner: alice,
            key: key,
            limit: type(uint128).max,
            expiry: block.timestamp + 7 days,
            nonce: nonce,
            deadline: block.timestamp + 7 days
        });
    }

    /// direct withdraw and shoot do not use the nonce (unchanged from before the fix), so a held
    /// order at the current nonce stays valid after them; cancelNonce is what voids it.
    function test_nonce_directWithdrawAndShoot_leaveNonce_cancelNonceVoids() public {
        vm.prank(alice);
        stash.authorizeKey(key, type(uint128).max, block.timestamp + 1 days);
        uint256 n = stash.nonces(alice);
        Stash.Withdrawal memory w = Stash.Withdrawal(alice, 10e6, n, block.timestamp + 1 hours);
        bytes memory wSig = _sig(ALICE_PK, stash.hashWithdraw(w));
        Stash.Shoot memory s = _shoot(5e6);
        bytes memory sSig = _sig(KEY_PK, stash.hashShoot(s));
        vm.startPrank(alice);
        stash.withdraw(10e6);
        stash.shoot(5e6, 1);
        vm.stopPrank();
        assertEq(stash.nonces(alice), n, "direct withdraw and shoot leave the nonce");
        uint256 snap = vm.snapshotState();
        stash.withdraw(w, wSig); // the held order still lands, paying the owner as signed
        vm.revertToState(snap);
        vm.prank(alice);
        stash.cancelNonce();
        vm.expectRevert(abi.encodeWithSelector(Nonces.InvalidAccountNonce.selector, alice, n + 1));
        stash.withdraw(w, wSig);
        vm.expectRevert(abi.encodeWithSelector(Nonces.InvalidAccountNonce.selector, alice, n + 1));
        stash.shoot(s, sSig);
    }

    function _shoot(uint256 maxPrice) internal view returns (Stash.Shoot memory) {
        return Stash.Shoot(alice, maxPrice, 1, stash.nonces(alice), block.timestamp + 1 hours, _epoch());
    }

    function _epoch() internal view returns (uint256 e) {
        (,, uint48 ep,,,) = stash.session(alice);
        e = ep;
    }

    function _sig(uint256 pk, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }
}
