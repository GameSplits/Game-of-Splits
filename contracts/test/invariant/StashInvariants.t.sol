// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {Base} from "../Base.t.sol";
import {FairCore} from "../../src/FairCore.sol";
import {LastArrow} from "../../src/LastArrow.sol";
import {SheriffsSeat} from "../../src/SheriffsSeat.sol";
import {Stash} from "../../src/Stash.sol";
import {IFairCore} from "../../src/interfaces/IFair.sol";
import {MockArbSys, MockToken} from "../mocks/Mocks.sol";

contract StashHandler is Test {
    Stash public stash;
    FairCore public core;
    LastArrow public arrow;
    SheriffsSeat public seat;
    MockToken public usdg;
    MockArbSys public arb;
    address public coreOwner;
    address public raiser;
    address public feeWallet;

    address[] public actors;
    uint256[] public accountPks;
    address[] public keys;
    uint256[] public keyPks;

    uint256 public deposited;
    uint256 public paidOut;
    uint256 public feesPaid;
    uint256 public paidToCore;
    uint256 public capSeen;
    uint256 public shots;
    uint256 public takes;
    uint256 public smallBalanceReverts;
    uint256 public flushed;
    uint256 public donated;
    uint256 public heldTried;
    uint256 public flushes;

    bool public badWithdraw;
    bool public capDecreased;
    bool public capLowered;
    bool public keyWithdrew;
    bool public overLimit;
    bool public overMax;
    bool public revertMoved;
    bool public replayWorked;
    bool public revokeFailed;
    bool public expiredWorked;
    bool public directCharged;
    bool public directSpent;
    bool public badFeeSet;
    bool public wrongShotFee;
    bool public flushWrong;
    bool public heldWorked;

    Stash.Shoot internal lastShoot;
    bytes internal lastSig;
    bool public hasLast;

    constructor(
        Stash stash_,
        FairCore core_,
        LastArrow arrow_,
        SheriffsSeat seat_,
        MockToken usdg_,
        MockArbSys arb_,
        address coreOwner_,
        address raiser_,
        address[3] memory actors_,
        uint256[3] memory accountPks_,
        address[3] memory keys_,
        uint256[3] memory keyPks_
    ) {
        stash = stash_;
        core = core_;
        arrow = arrow_;
        seat = seat_;
        usdg = usdg_;
        arb = arb_;
        coreOwner = coreOwner_;
        raiser = raiser_;
        feeWallet = stash.feeWallet();
        capSeen = stash.cap();
        for (uint256 i; i < 3; ++i) {
            actors.push(actors_[i]);
            accountPks.push(accountPks_[i]);
            keys.push(keys_[i]);
            keyPks.push(keyPks_[i]);
        }
    }

    function seed() external {
        for (uint256 i; i < 3; ++i) {
            _deposit(actors[i], 2_000e6);
            vm.prank(actors[i]);
            stash.authorizeKey(keys[i], 200e6, block.timestamp + 3 hours);
        }
    }

    function deposit(uint256 who, uint256 amt) external {
        _deposit(actors[who % 3], bound(amt, 1e6, 40e6));
        _cap();
    }

    function withdraw(uint256 who, uint256 amt) external {
        address a = actors[who % 3];
        uint256 bal = stash.balance(a);
        uint256 fee = stash.withdrawFee();
        amt = _withdrawAmount(amt, bal, fee, 1e6);
        uint256 wallet = usdg.balanceOf(a);
        uint256 fees = _fees();
        vm.prank(a);
        try stash.withdraw(amt) {
            _noteWithdraw(a, amt, bal, fee, wallet, fees);
        } catch {
            _noteWithdrawRevert(a, amt, bal, fee, wallet, fees);
        }
        _cap();
    }

    function withdrawRelay(uint256 who, uint256 amt) external {
        address a = actors[who % 3];
        uint256 bal = stash.balance(a);
        uint256 fee = stash.withdrawFee();
        amt = _withdrawAmount(amt, bal, fee, 1);
        uint256 wallet = usdg.balanceOf(a);
        uint256 fees = _fees();
        Stash.Withdrawal memory order = Stash.Withdrawal(a, amt, stash.nonces(a), block.timestamp + 1 hours);
        try stash.withdraw(order, _sign(accountPks[who % 3], stash.hashWithdraw(order))) {
            _noteWithdraw(a, amt, bal, fee, wallet, fees);
        } catch {
            _noteWithdrawRevert(a, amt, bal, fee, wallet, fees);
        }
        _cap();
    }

    /// Mixes whole withdrawals, withdrawals that leave a balance at or below the fee, and any other amount.
    function _withdrawAmount(uint256 amt, uint256 bal, uint256 fee, uint256 over) internal pure returns (uint256) {
        if (amt % 5 == 0) return bal;
        if (amt % 5 == 1 && bal > fee) return bal - (amt % fee + 1);
        return bound(amt, 0, bal + over);
    }

    function _noteWithdraw(address a, uint256 amt, uint256 bal, uint256 fee, uint256 wallet, uint256 fees) internal {
        if (bal <= fee || amt <= fee || amt > bal) badWithdraw = true;
        paidOut += amt - fee;
        feesPaid += fee;
        if (stash.balance(a) != bal - amt) revertMoved = true;
        if (usdg.balanceOf(a) != wallet + amt - fee) revertMoved = true;
        if (_fees() != fees + fee) revertMoved = true;
    }

    function _noteWithdrawRevert(address a, uint256 amt, uint256 bal, uint256 fee, uint256 wallet, uint256 fees)
        internal
    {
        if (bal > fee && amt > fee && amt <= bal) badWithdraw = true;
        if (bal <= fee) smallBalanceReverts += 1;
        if (stash.balance(a) != bal || usdg.balanceOf(a) != wallet || _fees() != fees) {
            revertMoved = true;
        }
    }

    function authorize(uint256 who, uint256 limit, uint256 life) external {
        address a = actors[who % 3];
        limit = bound(limit, 1e6, 400e6);
        if (limit % 5 == 0) limit = type(uint128).max;
        life = bound(life, 1 hours, 6 hours);
        uint256 exp = life > 5 hours ? block.timestamp + 7 days : block.timestamp + life;
        bytes memory oldSig = lastSig;
        Stash.Shoot memory old = lastShoot;
        bool had = hasLast && lastShoot.owner == a;
        vm.prank(a);
        try stash.authorizeKey(keys[who % 3], limit, exp) {
            if (had) {
                try stash.shoot(old, oldSig) {
                    revokeFailed = true;
                } catch {}
            }
        } catch {}
        _cap();
    }

    function setLimit(uint256 who, uint256 limit) external {
        address a = actors[who % 3];
        (,,,, uint256 spent,) = stash.session(a);
        limit = bound(limit, 1, 500e6);
        vm.prank(a);
        if (limit != type(uint128).max && limit < spent) {
            try stash.setLimit(limit) {
                overLimit = true;
            } catch {}
        } else {
            try stash.setLimit(limit) {} catch {}
        }
        _cap();
    }

    function revoke(uint256 who) external {
        vm.prank(actors[who % 3]);
        try stash.revokeKey() {} catch {}
        _cap();
    }

    function shoot(uint256 who, uint256 extra) external {
        _shoot(who, extra, true);
    }

    function shootDirect(uint256 who, uint256 extra) external {
        _shoot(who, extra, false);
    }

    function take(uint256 who, uint256 extra) external {
        _take(who, extra, true, uint8(who % 4), uint8(who % 8));
    }

    function takeDirect(uint256 who, uint8 color) external {
        _take(who, 0, false, 0, color);
    }

    function replay() external {
        if (!hasLast) return;
        uint256 before = stash.balance(lastShoot.owner);
        try stash.shoot(lastShoot, lastSig) {
            replayWorked = true;
        } catch {
            if (stash.balance(lastShoot.owner) != before) revertMoved = true;
        }
        _cap();
    }

    function revokeThenShoot(uint256 who, uint256 extra) external {
        address a = actors[who % 3];
        (bool ready, Stash.Shoot memory order, bytes memory sig) = _prepared(who, extra, true);
        if (!ready) return;
        uint256 before = stash.balance(a);
        uint256 tokens = usdg.balanceOf(address(stash));
        vm.prank(a);
        try stash.revokeKey() {} catch {
            return;
        }
        try stash.shoot(order, sig) {
            revokeFailed = true;
        } catch {
            if (stash.balance(a) != before || usdg.balanceOf(address(stash)) != tokens) revertMoved = true;
        }
        _cap();
    }

    function keyWithdraw(uint256 who, uint256 amt) external {
        address a = actors[who % 3];
        (address k,,,,,) = stash.session(a);
        uint256 before = stash.balance(a);
        if (k != address(0)) {
            vm.prank(k);
            try stash.withdraw(amt) {} catch {}
            Stash.Withdrawal memory order = Stash.Withdrawal(a, 2e6, stash.nonces(a), block.timestamp + 1 hours);
            try stash.withdraw(order, _sign(keyPks[who % 3], stash.hashWithdraw(order))) {
                keyWithdrew = true;
            } catch {}
        }
        if (stash.balance(a) != before) keyWithdrew = true;
        _cap();
    }

    function warp(uint256 secs) external {
        vm.warp(block.timestamp + bound(secs, 0, 20 minutes));
    }

    function pause(bool on) external {
        vm.prank(coreOwner);
        try core.pauseSales(on) {} catch {}
    }

    function raiseCap(uint256 bump) external {
        if (stash.capRaiser() == address(0)) return;
        uint256 c = stash.cap();
        uint256 next = c + bound(bump, 1, 1_000e6);
        vm.prank(raiser);
        try stash.raiseCap(c) {
            capLowered = true;
        } catch {}
        vm.prank(raiser);
        try stash.raiseCap(next) {} catch {}
        _cap();
    }

    /// A stranger never sets the fee. The raiser sets it up to the max until renounced, then the fee is frozen.
    function setShotFee(uint256 newFee, uint256 who) external {
        uint256 max = stash.MAX_SHOT_FEE();
        newFee = bound(newFee, 0, max + max / 4);
        uint256 before = stash.shotFee();
        bool live = stash.capRaiser() == raiser;
        vm.prank(actors[who % 3]);
        try stash.setShotFee(newFee) {
            badFeeSet = true;
        } catch {}
        vm.prank(raiser);
        try stash.setShotFee(newFee) {} catch {}
        if (stash.shotFee() != (live && newFee <= max ? newFee : before)) badFeeSet = true;
        _cap();
    }

    function renounce(uint256 salt) external {
        if (salt % 17 != 0) return;
        if (stash.capRaiser() != raiser) return;
        vm.prank(raiser);
        stash.renounceCapRaiser();
        _cap();
    }

    function donate(uint256 amt) external {
        amt = bound(amt, 1, 5e6);
        usdg.mint(address(stash), amt);
        donated += amt;
    }

    /// flushFees moves exactly the accrued fees to the fee wallet and nothing else
    function flush() external {
        uint256 acc = stash.feesAccrued();
        uint256 wallet = usdg.balanceOf(feeWallet);
        uint256 tokens = usdg.balanceOf(address(stash));
        uint256 held = stash.totalHeld();
        try stash.flushFees() {
            flushed += acc;
            flushes += 1;
            if (
                acc == 0 || usdg.balanceOf(feeWallet) != wallet + acc || usdg.balanceOf(address(stash)) != tokens - acc
                    || stash.feesAccrued() != 0 || stash.totalHeld() != held
            ) flushWrong = true;
        } catch {
            if (acc != 0) flushWrong = true;
        }
    }

    /// Signs one of every order at the current nonce and holds them. The owner then acts directly (revoke, limit,
    /// authorize or cancelNonce). If that action lands, no held order may land afterwards.
    function heldOrders(uint256 who, uint256 action) external {
        uint256 i = who % 3;
        address a = actors[i];
        uint256 n = stash.nonces(a);
        uint256 dl = block.timestamp + 1 hours;
        Stash.Authorize memory au = Stash.Authorize(a, keys[i], type(uint128).max, block.timestamp + 1 hours, n, dl);
        Stash.LimitChange memory li = Stash.LimitChange(a, type(uint128).max, n, dl);
        Stash.Revoke memory rv = Stash.Revoke(a, n, dl);
        Stash.Withdrawal memory wd = Stash.Withdrawal(a, 2e6, n, dl);
        bytes memory auSig = _sign(accountPks[i], stash.hashAuthorize(au));
        bytes memory liSig = _sign(accountPks[i], stash.hashSetLimit(li));
        bytes memory rvSig = _sign(accountPks[i], stash.hashRevoke(rv));
        bytes memory wdSig = _sign(accountPks[i], stash.hashWithdraw(wd));

        action = action % 4;
        vm.prank(a);
        if (action == 0) {
            try stash.revokeKey() {} catch { return; }
        } else if (action == 1) {
            try stash.setLimit(300e6) {} catch { return; }
        } else if (action == 2) {
            try stash.authorizeKey(keys[i], 200e6, block.timestamp + 2 hours) {} catch { return; }
        } else {
            stash.cancelNonce();
        }
        (,, uint48 epochNow,,,) = stash.session(a);
        Stash.Shoot memory sh = Stash.Shoot(a, type(uint128).max, arrow.nextShotRound(), n, dl, epochNow);
        bytes memory shSig = _sign(keyPks[i], stash.hashShoot(sh));
        heldTried += 1;
        if (stash.nonces(a) != n + 1) heldWorked = true;
        try stash.authorizeKey(au, auSig) { heldWorked = true; } catch {}
        try stash.setLimit(li, liSig) { heldWorked = true; } catch {}
        try stash.revokeKey(rv, rvSig) { heldWorked = true; } catch {}
        try stash.withdraw(wd, wdSig) { heldWorked = true; } catch {}
        arb.set(arb.n() + 1);
        try stash.shoot(sh, shSig) { heldWorked = true; } catch {}
        _cap();
    }

    /// Fees taken so far: flushed to the fee wallet or still accrued in the Stash.
    function _fees() internal view returns (uint256) {
        return usdg.balanceOf(feeWallet) + stash.feesAccrued();
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function _deposit(address a, uint256 amt) internal {
        uint256 before = stash.balance(a);
        uint256 held = stash.totalHeld();
        uint256 tokens = usdg.balanceOf(address(stash));
        vm.prank(a);
        try stash.deposit(amt) {
            deposited += amt;
        } catch {
            if (stash.balance(a) != before || stash.totalHeld() != held || usdg.balanceOf(address(stash)) != tokens) {
                revertMoved = true;
            }
        }
    }

    function _shoot(uint256 who, uint256 extra, bool asKey) internal {
        (bool ready, Stash.Shoot memory order, bytes memory sig) = _prepared(who, extra, asKey);
        if (!ready) return;
        address a = actors[who % 3];
        uint256 spentBefore;
        (,,,, spentBefore,) = stash.session(a);
        bool dead = _dead(a);
        uint256 before = stash.balance(a);
        uint256 fees = _fees();
        uint256 coreBefore = usdg.balanceOf(address(core));
        uint256 stashBefore = usdg.balanceOf(address(stash));
        uint256 wallet = usdg.balanceOf(a);
        if (asKey) {
            try stash.shoot(order, sig) {
                if (dead) expiredWorked = true;
                _notePlay(a, order.maxPrice, before, fees, coreBefore, wallet, true);
                lastShoot = order;
                lastSig = sig;
                hasLast = true;
                shots += 1;
            } catch {
                _noteRevert(a, before, fees, coreBefore, stashBefore, wallet);
            }
        } else {
            vm.prank(a);
            try stash.shoot(order.maxPrice, order.expectedRound) {
                _notePlay(a, order.maxPrice, before, fees, coreBefore, wallet, false);
                (,,,, uint256 spentAfter,) = stash.session(a);
                if (spentAfter != spentBefore) directSpent = true;
                shots += 1;
            } catch {
                _noteRevert(a, before, fees, coreBefore, stashBefore, wallet);
            }
        }
        _cap();
    }

    function _take(uint256 who, uint256 extra, bool asKey, uint8 presetId, uint8 color) internal {
        address a = actors[who % 3];
        uint256 price = seat.price();
        if (price == 0) return;
        extra = bound(extra, 0, 2e6);
        uint256 maxPrice = price + extra;
        (,, uint48 epoch,,,) = stash.session(a);
        bool dead = _dead(a);
        Stash.Take memory order = Stash.Take(a, maxPrice, presetId, color, stash.nonces(a), block.timestamp + 1 hours, epoch);
        bytes memory sig = _sign(keyPks[who % 3], stash.hashTake(order));
        uint256 spentBefore;
        (,,,, spentBefore,) = stash.session(a);
        uint256 before = stash.balance(a);
        uint256 fees = _fees();
        uint256 coreBefore = usdg.balanceOf(address(core));
        uint256 stashBefore = usdg.balanceOf(address(stash));
        uint256 wallet = usdg.balanceOf(a);
        arb.set(arb.n() + 1);
        if (asKey) {
            try stash.take(order, sig) {
                if (dead) expiredWorked = true;
                _notePlay(a, maxPrice, before, fees, coreBefore, wallet, true);
                takes += 1;
            } catch {
                _noteRevert(a, before, fees, coreBefore, stashBefore, wallet);
            }
        } else {
            vm.prank(a);
            try stash.take(maxPrice, presetId, color) {
                _notePlay(a, maxPrice, before, fees, coreBefore, wallet, false);
                (,,,, uint256 spentAfter,) = stash.session(a);
                if (spentAfter != spentBefore) directSpent = true;
                takes += 1;
            } catch {
                _noteRevert(a, before, fees, coreBefore, stashBefore, wallet);
            }
        }
        _cap();
    }

    function _prepared(uint256 who, uint256 extra, bool)
        internal
        returns (bool ready, Stash.Shoot memory order, bytes memory sig)
    {
        address a = actors[who % 3];
        uint256 price = arrow.currentPrice();
        if (price == 0) return (false, order, sig);
        extra = bound(extra, 0, 2e6);
        (,, uint48 epoch,,,) = stash.session(a);
        arb.set(arb.n() + 1);
        order = Stash.Shoot({
            owner: a,
            maxPrice: price + extra,
            expectedRound: arrow.nextShotRound(),
            nonce: stash.nonces(a),
            deadline: block.timestamp + 1 hours,
            epoch: epoch
        });
        sig = _sign(keyPks[who % 3], stash.hashShoot(order));
        ready = true;
    }

    function _notePlay(
        address a,
        uint256 maxPrice,
        uint256 before,
        uint256 fees,
        uint256 coreBefore,
        uint256 wallet,
        bool asKey
    ) internal {
        uint256 drop = before - stash.balance(a);
        uint256 feeDelta = _fees() - fees;
        uint256 coreDelta = usdg.balanceOf(address(core)) - coreBefore;
        if (drop != feeDelta + coreDelta) revertMoved = true;
        if (usdg.balanceOf(a) != wallet) keyWithdrew = true;
        if (coreDelta > maxPrice) overMax = true;
        if (!asKey && feeDelta != 0) directCharged = true;
        feesPaid += feeDelta;
        paidToCore += coreDelta;
        (,,, uint256 limit, uint256 spent, uint256 feeCap) = stash.session(a);
        if (asKey) {
            uint256 fee = stash.shotFee();
            if (feeDelta != (fee < feeCap ? fee : feeCap)) wrongShotFee = true;
        }
        if (limit != type(uint128).max && spent > limit) overLimit = true;
    }

    function _noteRevert(address a, uint256 before, uint256 fees, uint256 coreBefore, uint256 stashBefore, uint256 wallet)
        internal
    {
        if (
            stash.balance(a) != before || _fees() != fees || usdg.balanceOf(address(core)) != coreBefore
                || usdg.balanceOf(address(stash)) != stashBefore || usdg.balanceOf(a) != wallet
        ) revertMoved = true;
    }

    function _dead(address a) internal view returns (bool) {
        (address k, uint48 exp,,,,) = stash.session(a);
        return k == address(0) || block.timestamp >= exp;
    }

    function _cap() internal {
        uint256 c = stash.cap();
        if (c < capSeen) capDecreased = true;
        capSeen = c;
    }

    function _sign(uint256 pk, bytes32 digest) internal returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }
}

contract StashInvariantTest is Base {
    LastArrow internal la;
    SheriffsSeat internal seat;
    Stash internal stash;
    MockArbSys internal arb;
    StashHandler internal h;
    uint256 internal day0;
    address internal raiser = makeAddr("stashRaiser");
    address internal feeTo = makeAddr("stashFees");

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
        vm.warp(day0);

        address[3] memory actors;
        uint256[3] memory accountPks;
        address[3] memory keys;
        uint256[3] memory keyPks;
        for (uint256 i; i < 3; ++i) {
            (actors[i], accountPks[i]) = makeAddrAndKey(string.concat("stashActor", vm.toString(i)));
            (keys[i], keyPks[i]) = makeAddrAndKey(string.concat("stashKey", vm.toString(i)));
            usdg.mint(actors[i], 200_000e6);
            wif.mint(actors[i], 20_000e18);
            vm.startPrank(actors[i]);
            wif.approve(address(pass), type(uint256).max);
            pass.lock(address(wif), PASS_LOCK);
            vm.stopPrank();
        }

        stash = new Stash(address(core), address(la), address(seat), address(usdg), feeTo, raiser, 0.05e6, 1e6, _lines());
        for (uint256 i; i < 3; ++i) {
            vm.prank(actors[i]);
            usdg.approve(address(stash), type(uint256).max);
        }
        h = new StashHandler(stash, core, la, seat, usdg, arb, owner, raiser, actors, accountPks, keys, keyPks);
        h.seed();

        bytes4[] memory sels = new bytes4[](21);
        sels[0] = h.deposit.selector;
        sels[1] = h.withdraw.selector;
        sels[2] = h.withdrawRelay.selector;
        sels[3] = h.authorize.selector;
        sels[4] = h.setLimit.selector;
        sels[5] = h.revoke.selector;
        sels[6] = h.shoot.selector;
        sels[7] = h.shootDirect.selector;
        sels[8] = h.take.selector;
        sels[9] = h.takeDirect.selector;
        sels[10] = h.replay.selector;
        sels[11] = h.revokeThenShoot.selector;
        sels[12] = h.keyWithdraw.selector;
        sels[13] = h.warp.selector;
        sels[14] = h.pause.selector;
        sels[15] = h.raiseCap.selector;
        sels[16] = h.renounce.selector;
        sels[17] = h.donate.selector;
        sels[18] = h.setShotFee.selector;
        sels[19] = h.flush.selector;
        sels[20] = h.heldOrders.selector;
        targetContract(address(h));
        targetSelector(FuzzSelector({addr: address(h), selectors: sels}));
    }

    function test_handlerPlays() public {
        h.shoot(0, 0);
        h.shoot(1, 1);
        h.take(2, 0);
        h.take(0, 1);
        assertGt(h.shots(), 0, "shots land");
        assertGt(h.takes(), 0, "takes land");
        invariant_balancesPlusFees();
        invariant_feesAccounting();
        h.flush();
        h.heldOrders(0, 0);
        h.heldOrders(1, 1);
        h.heldOrders(2, 2);
        h.heldOrders(0, 3);
        assertGt(h.flushes(), 0, "flush lands");
        assertEq(h.heldTried(), 4, "every direct action landed");
        assertFalse(h.heldWorked(), "held order landed after a direct action");
        assertFalse(h.flushWrong(), "flush moved the wrong amount");
        invariant_feesAccounting();
        h.replay();
        h.revokeThenShoot(0, 0);
        h.keyWithdraw(1, 1e6);
        assertFalse(h.replayWorked());
        assertFalse(h.revokeFailed());
        assertFalse(h.keyWithdrew());
        assertFalse(h.revertMoved());
        assertFalse(h.overMax());
        assertFalse(h.overLimit());
    }

    function test_handlerShotFee() public {
        uint256 max = stash.MAX_SHOT_FEE();
        h.setShotFee(max, 0);
        assertEq(stash.shotFee(), max);
        h.shoot(0, 0);
        h.setShotFee(max + 1, 1);
        assertEq(stash.shotFee(), max);
        h.authorize(1, 100e6, 2 hours);
        h.take(1, 0);
        h.setShotFee(0.01e6, 2);
        assertEq(stash.shotFee(), 0.01e6);
        h.shoot(2, 0);
        h.renounce(0);
        h.setShotFee(0.02e6, 0);
        assertEq(stash.shotFee(), 0.01e6, "renounce freezes the fee");
        assertGt(h.shots(), 0);
        assertGt(h.takes(), 0);
        invariant_balancesPlusFees();
    }

    function test_handlerWithdraws() public {
        // An amount divisible by 5 picks the whole balance. Empty it, then top up to exactly the fee.
        h.withdraw(0, 0);
        assertEq(stash.balance(h.actors(0)), 0);
        h.withdraw(0, 5);
        h.withdrawRelay(0, 5);
        h.deposit(0, 1e6);
        assertEq(stash.balance(h.actors(0)), 1e6);
        h.withdraw(0, 5);
        h.withdrawRelay(0, 5);
        assertEq(h.smallBalanceReverts(), 4, "balance at or below the fee reverts");
        assertEq(stash.balance(h.actors(0)), 1e6);
        assertFalse(h.badWithdraw());
        invariant_balancesPlusFees();
    }

    /// sum(balance) == totalHeld <= USDG held. Deposits equal balances plus payouts, fees and game pulls.
    function invariant_balancesPlusFees() public view {
        uint256 sum;
        for (uint256 i; i < h.actorCount(); ++i) {
            sum += stash.balance(h.actors(i));
        }
        assertEq(sum, stash.totalHeld(), "sum of balances");
        assertLe(stash.totalHeld(), usdg.balanceOf(address(stash)), "held covers balances");
        assertEq(h.deposited(), sum + h.paidOut() + h.feesPaid() + h.paidToCore(), "balances plus fees");
        assertFalse(h.badWithdraw(), "withdraw broke the fee rules");
        assertFalse(h.capDecreased(), "cap fell");
        assertFalse(h.capLowered(), "lower cap was accepted");
        assertFalse(h.keyWithdrew(), "key moved funds");
        assertFalse(h.overLimit(), "spent above limit");
        assertFalse(h.overMax(), "paid above maxPrice");
        assertFalse(h.revertMoved(), "revert moved funds");
        assertFalse(h.replayWorked(), "replay succeeded");
        assertFalse(h.revokeFailed(), "revoked key still played");
        assertFalse(h.expiredWorked(), "expired key played");
        assertFalse(h.directCharged(), "direct call paid a fee");
        assertFalse(h.directSpent(), "direct call spent the limit");
        assertFalse(h.badFeeSet(), "setShotFee broke its rules");
        assertFalse(h.wrongShotFee(), "relayed play paid other than min(shotFee, feeCap)");
        assertLe(stash.shotFee(), stash.MAX_SHOT_FEE(), "shot fee above max");
        for (uint256 i; i < h.actorCount(); ++i) {
            (,,, uint256 limit, uint256 spent, uint256 feeCap) = stash.session(h.actors(i));
            if (limit != type(uint128).max) assertLe(spent, limit);
            assertLe(feeCap, stash.MAX_SHOT_FEE(), "fee cap above max");
        }
    }

    /// Fees stay apart from balances. The Stash holds exactly balances plus accrued fees plus donations, the fee
    /// wallet holds exactly what was flushed, and every fee taken is either accrued or flushed.
    function invariant_feesAccounting() public view {
        uint256 tokens = usdg.balanceOf(address(stash));
        assertGe(tokens, stash.totalHeld() + stash.feesAccrued(), "Stash covers balances and fees");
        assertEq(tokens, stash.totalHeld() + stash.feesAccrued() + h.donated(), "Stash conservation");
        assertEq(stash.sweepable(), h.donated(), "only donations are sweepable");
        assertEq(usdg.balanceOf(feeTo), h.flushed(), "fee wallet holds only flushed fees");
        assertEq(stash.feesAccrued() + h.flushed(), h.feesPaid(), "fees accrued or flushed");
        assertFalse(h.flushWrong(), "flush moved the wrong amount");
        assertFalse(h.heldWorked(), "held order landed after a direct action");
    }

    function _lines() internal pure returns (string[] memory lines) {
        lines = new string[](4);
        lines[0] = "Hold fast";
        lines[1] = "Make way";
        lines[2] = "Still here";
        lines[3] = "Your move";
    }
}
