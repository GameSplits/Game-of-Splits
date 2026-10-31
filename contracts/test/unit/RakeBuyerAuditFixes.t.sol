// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Base} from "../Base.t.sol";
import {RakeBuyer} from "../../src/RakeBuyer.sol";
import {IGameConfig} from "../../src/interfaces/IFair.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// Audit fixes for RakeBuyer: the anchor follows the keeper's quote, a USDG shortfall does not revert the flows,
/// and the owner can write the ledgers down to the balance.
contract RakeBuyerAuditFixesTest is Base {
    RakeBuyer rb;
    address vaultTo = makeAddr("locksleyVault");
    uint256 constant RATE = 781_250e12;

    function setUp() public override {
        super.setUp();
        rb = new RakeBuyer(usdg, IGameConfig(address(config)), vaultTo, owner, 48 hours, address(core));
        vm.startPrank(owner);
        rb.setupSet(RakeBuyer.Op.SetKeeper, 0, keeper);
        rb.setupSet(RakeBuyer.Op.SetRoute, 0, address(route));
        rb.setupSet(RakeBuyer.Op.SetRoute, 1, address(routeB));
        rb.resetRatchet(RATE * 1e18);
        rb.finishSetup();
        vm.stopPrank();
    }

    function _buy(uint256 usdgIn) internal returns (uint256) {
        vm.prank(keeper);
        return rb.buy(0, usdgIn, usdgIn * RATE);
    }

    function _one(address token) internal pure returns (address[] memory t) {
        t = new address[](1);
        t[0] = token;
    }

    /// A fill above the keeper's quote used to lift the anchor. After max decay the floor still sat above the
    /// market, and every later buy reverted RatchetTripped. The anchor now follows minOut.
    function test_windfallFill_doesNotFreezeBuys() public {
        usdg.mint(address(rb), 1_000e6);
        route.setRate(RATE * 16 / 10);
        vm.prank(keeper);
        uint256 out = rb.buy(0, 50e6, 50e6 * RATE);
        assertEq(out, 50e6 * RATE * 16 / 10, "the route still pays the windfall");
        assertEq(rb.anchorRate(), RATE * 1e18, "anchor stays on the keeper's quote");

        route.setRate(RATE);
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        assertLt(rb.ratchetFloorRate(), RATE * 1e18, "floor is under the market after max decay");
        vm.prank(keeper);
        rb.buy(0, 50e6, 50e6 * RATE);
    }

    /// One unit under the ledgers used to underflow in sync, so forward, forwardToken and sweepExcess all reverted.
    /// The shortfall sits in the unspent budget here, and each of those calls goes through.
    function test_usdgDrop_doesNotBrickForwardForwardTokenSweep() public {
        usdg.mint(address(rb), 200e6);
        uint256 out1 = _buy(50e6);
        deal(address(usdg), address(rb), usdg.balanceOf(address(rb)) - 1);

        rb.sync();
        assertEq(rb.buyPending(), 50e6, "no new split");
        assertEq(rb.legPending(), 100e6);

        rb.forward();
        assertEq(wif.balanceOf(vaultTo), out1);
        assertEq(usdg.balanceOf(vaultTo), 50e6);

        vm.warp(vm.getBlockTimestamp() + 50 minutes);
        uint256 out2 = _buy(40e6);
        rb.forwardToken(address(wif));
        assertEq(wif.balanceOf(vaultTo), out1 + out2);
        assertEq(usdg.balanceOf(vaultTo), 90e6);

        wif.mint(address(rb), 3e18);
        address to = makeAddr("sweepTo");
        vm.startPrank(owner);
        rb.sweepExcess(address(wif), to);
        rb.sweepExcess(address(usdg), to);
        vm.stopPrank();
        assertEq(wif.balanceOf(to), 3e18);
        assertEq(usdg.balanceOf(to), 0, "a shortfall is not excess");
        assertEq(usdg.balanceOf(address(rb)), 20e6 - 1);
    }

    /// The matched leg itself is short: forward reverts on the transfer until the owner writes the leg and spentOf
    /// down, and then the bought tokens move.
    function test_usdgDrop_intoLeg_reconcileThenForward() public {
        usdg.mint(address(rb), 100e6);
        uint256 out = _buy(50e6);
        deal(address(usdg), address(rb), 40e6);
        rb.sync();
        // K-C01: the legs go independently. The bought token still forwards; the short USDG leg fails, stays
        // ledgered and is reported (it used to revert the whole forward).
        vm.expectEmit(address(rb));
        emit RakeBuyer.ForwardFailed(address(wif), address(usdg), vaultTo, 50e6);
        rb.forward();
        assertEq(wif.balanceOf(vaultTo), out);
        assertEq(rb.spentOf(address(wif)), 50e6);

        vm.prank(owner);
        rb.reconcile(_one(address(wif)));
        assertEq(rb.buyPending(), 0);
        assertEq(rb.legPending(), 40e6);
        assertEq(rb.spentOf(address(wif)), 40e6);
        assertEq(usdg.balanceOf(address(rb)), 40e6, "reconcile moves no USDG");

        rb.forwardToken(address(wif));
        assertEq(usdg.balanceOf(vaultTo), 40e6);
        assertEq(usdg.balanceOf(address(rb)), 0);
    }

    /// A partial wipe used to revert buy inside sync. reconcile cuts buyPending first, buys of that budget work,
    /// and the call is onlyOwner and moves nothing.
    function test_reconcile_restoresBuy_onlyOwner_movesNothing() public {
        usdg.mint(address(rb), 100e6);
        rb.sync();
        deal(address(usdg), address(rb), 60e6);
        address[] memory tokens = _one(address(wif));

        vm.prank(ana);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, ana));
        rb.reconcile(tokens);

        uint256 usdgBefore = usdg.balanceOf(address(rb));
        uint256 wifBefore = wif.balanceOf(address(rb));
        uint256 legBefore = rb.legPending();
        vm.expectEmit(address(rb));
        emit RakeBuyer.Reconciled(60e6, 10e6, 50e6);
        vm.prank(owner);
        rb.reconcile(tokens);

        assertEq(usdg.balanceOf(address(rb)), usdgBefore);
        assertEq(wif.balanceOf(address(rb)), wifBefore);
        assertEq(rb.buyPending(), 10e6);
        assertEq(rb.legPending(), legBefore, "the leg is left whole while buyPending can absorb the loss");
        assertLt(rb.buyPending(), 50e6);
        assertEq(rb.buyPending() + rb.legPending(), usdgBefore);

        uint256 budget = rb.buyPending();
        vm.prank(keeper);
        assertEq(rb.buy(0, budget, budget * RATE), 10e6 * RATE);
        assertEq(usdg.balanceOf(address(rb)), rb.legPending(), "the leg is still funded");

        vm.warp(vm.getBlockTimestamp() + 50 minutes);
        vm.prank(keeper);
        vm.expectRevert(RakeBuyer.OverLedger.selector);
        rb.buy(0, 50e6, 50e6 * RATE);
    }

    /// buyPending, then the unmatched leg, then spentOf. Two open tokens: the first in the list takes the haircut.
    function test_reconcile_buyPendingThenUnmatchedLegThenSpent() public {
        usdg.mint(address(rb), 200e6);
        _buy(40e6);
        applyTokens(address(tokenB), 5_000e18, address(tokenB));
        reseedRb(rb, 100e12 * 1e18);
        vm.prank(keeper);
        rb.buy(1, 20e6, 20e6 * 100e12);

        assertEq(rb.buyPending(), 40e6);
        assertEq(rb.legPending(), 100e6);
        assertEq(rb.spentOf(address(wif)), 40e6);
        assertEq(rb.spentOf(address(tokenB)), 20e6);
        assertEq(usdg.balanceOf(address(rb)), 140e6);

        deal(address(usdg), address(rb), 50e6);
        address[] memory tokens = new address[](2);
        tokens[0] = address(wif);
        tokens[1] = address(tokenB);
        uint256 wifBefore = wif.balanceOf(address(rb));
        uint256 bBefore = tokenB.balanceOf(address(rb));
        vm.prank(owner);
        rb.reconcile(tokens);

        assertEq(usdg.balanceOf(address(rb)), 50e6);
        assertEq(wif.balanceOf(address(rb)), wifBefore);
        assertEq(tokenB.balanceOf(address(rb)), bBefore);
        assertEq(rb.buyPending(), 0, "buy budget is cut first");
        assertEq(rb.legPending(), 50e6);
        assertEq(rb.spentOf(address(wif)), 30e6, "unmatched leg absorbs what it can, then this token");
        assertEq(rb.spentOf(address(tokenB)), 20e6, "later tokens keep their match");
        assertEq(rb.spentOf(address(wif)) + rb.spentOf(address(tokenB)), rb.legPending());

        rb.forwardToken(address(wif));
        rb.forwardToken(address(tokenB));
        assertEq(usdg.balanceOf(vaultTo), 50e6);
        assertEq(usdg.balanceOf(address(rb)), 0);
    }

    function test_reconcile_rejectsDuplicateTokens() public {
        usdg.mint(address(rb), 100e6);
        _buy(10e6);
        deal(address(usdg), address(rb), usdg.balanceOf(address(rb)) - 1);
        address[] memory tokens = new address[](2);
        tokens[0] = address(wif);
        tokens[1] = address(wif);
        uint256 buyBefore = rb.buyPending();
        vm.prank(owner);
        vm.expectRevert(RakeBuyer.BadTokens.selector);
        rb.reconcile(tokens);
        assertEq(rb.buyPending(), buyBefore, "a revert leaves the ledgers");
    }

    /// The odd unit of a sync still sits in the leg. reconcile does not clear it, and it still cannot be forwarded
    /// or swept.
    function test_oddUnitDust_unchanged() public {
        usdg.mint(address(rb), 1);
        rb.sync();
        assertEq(rb.buyPending(), 0);
        assertEq(rb.legPending(), 1);
        vm.prank(owner);
        rb.reconcile(_one(address(wif)));
        assertEq(rb.buyPending(), 0);
        assertEq(rb.legPending(), 1);
        vm.expectRevert(RakeBuyer.NothingToForward.selector);
        rb.forward();
        address to = makeAddr("to");
        vm.prank(owner);
        rb.sweepExcess(address(usdg), to);
        assertEq(usdg.balanceOf(to), 0);
        assertEq(usdg.balanceOf(address(rb)), 1);
    }

    /// Any shortfall: sync does not revert, and after reconcile the ledgers are the balance and no higher.
    function testFuzz_balanceDrop_syncAndReconcile(uint96 rakeRaw, uint96 fillRaw, uint96 dropRaw) public {
        uint256 rake = bound(rakeRaw, 2, 10_000e6);
        usdg.mint(address(rb), rake);
        rb.sync();
        uint256 cap = rb.buyPending() > 50e6 ? 50e6 : rb.buyPending();
        uint256 usdgIn = bound(fillRaw, 0, cap);
        if (usdgIn != 0) {
            vm.prank(keeper);
            rb.buy(0, usdgIn, usdgIn * RATE);
        }
        uint256 bal = usdg.balanceOf(address(rb));
        uint256 drop = bound(dropRaw, 0, bal);
        if (drop != 0) deal(address(usdg), address(rb), bal - drop);

        rb.sync();
        uint256 buyBefore = rb.buyPending();
        uint256 legBefore = rb.legPending();
        uint256 spentBefore = rb.spentOf(address(wif));
        uint256 balNow = usdg.balanceOf(address(rb));
        vm.prank(owner);
        rb.reconcile(_one(address(wif)));

        assertEq(usdg.balanceOf(address(rb)), balNow, "reconcile moves no funds");
        assertLe(rb.buyPending(), buyBefore);
        assertLe(rb.legPending(), legBefore);
        assertLe(rb.spentOf(address(wif)), spentBefore);
        assertEq(rb.buyPending() + rb.legPending(), balNow, "ledgers are written down to the balance");
        assertLe(rb.spentOf(address(wif)), rb.legPending());
        if (drop == 0) assertGe(rb.legPending(), rb.spentOf(address(wif)) + (rake % 2), "odd unit stays in the leg");
    }
}
