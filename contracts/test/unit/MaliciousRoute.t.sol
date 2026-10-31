// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {RatBase} from "../RatBase.t.sol";
import {FairCore} from "../../src/FairCore.sol";
import {RakeBuyer} from "../../src/RakeBuyer.sol";
import {FeeSplitter} from "../../src/FeeSplitter.sol";
import {RobinAmongThieves} from "../../src/RobinAmongThieves.sol";
import {IBuyRoute, IGameConfig} from "../../src/interfaces/IFair.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {MockToken} from "../mocks/Mocks.sol";

/// @dev A Safe-installed route that turned malicious: keeps the USDG, delivers `deliver` buy tokens itself, and runs
///      one call mid-swap (a permissionless flow that moves buy tokens to the vault or to DEAD).
contract EvilRoute is IBuyRoute {
    MockToken public immutable token;
    IERC20 public immutable usdg;
    address public hookTarget;
    bytes public hookData;
    uint256 public deliver;
    address public pullFrom;

    constructor(MockToken t, IERC20 u) {
        token = t;
        usdg = u;
    }

    function tokenOut() external view returns (address) {
        return address(token);
    }

    function arm(address target, bytes calldata data, uint256 deliver_) external {
        (hookTarget, hookData, deliver) = (target, data, deliver_);
    }

    function armPull(address from) external {
        pullFrom = from;
    }

    function swapToToken(uint256, uint256, address recipient) external returns (uint256) {
        if (pullFrom != address(0)) usdg.transferFrom(pullFrom, address(this), 1); // no allowance: must revert
        if (hookTarget != address(0)) {
            (bool ok, bytes memory ret) = hookTarget.call(hookData);
            if (!ok) {
                assembly {
                    revert(add(ret, 0x20), mload(ret))
                }
            }
        }
        if (deliver != 0) token.mint(recipient, deliver);
        return deliver;
    }
}

/// @dev Mints `amt` of the buy token to `to` when a route calls it mid-swap. That is an inflow outside FairCore's delta.
contract SideInflow {
    MockToken immutable token;

    constructor(MockToken t) {
        token = t;
    }

    function mintTo(address to, uint256 amt) external {
        if (amt != 0) token.mint(to, amt);
    }
}

/// @notice FairCore._swap must count only what the route delivered. Permissionless flows that pay the vault or DEAD
///         mid-swap (RakeBuyer.forward, FeeSplitter.distribute, RobinAmongThieves.flushBondBurn) must not satisfy
///         ShortFill, and `out` in the return value and events must be the route's own fill.
contract MaliciousRouteTest is RatBase {
    uint256 constant RATE = 781_250e12; // wif wei per USDG unit (MockRoute default)
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 constant EVIL = 2; // FairCore route index of the malicious route

    enum Src {
        RakeForward,
        SplitterDistribute,
        BondBurn
    }

    FeeSplitter fs;
    EvilRoute evil;
    EvilRoute evilRb;
    uint256 ra; // outlaw ids for the bond slash
    uint256 rb_;

    function setUp() public override {
        super.setUp();
        // Fund FairCore's ledgers during Fair 0: 5,000 USDG of shots.
        openFair();
        shot(ana, 1, 5_000e6);

        // RatBase's RakeBuyer forwards to the same vault as FairCore, as Deploy.s.sol wires it.
        evilRb = new EvilRoute(wif, usdg);
        vm.startPrank(owner);
        buyer.setupSet(RakeBuyer.Op.SetKeeper, 0, keeper);
        buyer.setupSet(RakeBuyer.Op.SetRoute, 0, address(route));
        buyer.setupSet(RakeBuyer.Op.SetRoute, 1, address(evilRb));
        buyer.resetRatchet(RATE * 1e18);
        buyer.finishSetup();
        vm.stopPrank();

        // FeeSplitter: vault leg = the vault, $wif burn leg = DEAD.
        fs = new FeeSplitter(
            address(wif),
            owner,
            FeeSplitter.Recipients({
                purses: makeAddr("purses"),
                vault: vaultAddr,
                rebate: makeAddr("rebate"),
                burnBuyer: makeAddr("burnBuyer"),
                ops: makeAddr("ops")
            }),
            FeeSplitter.FeeSplit({pursesBps: 4000, vaultBps: 2500, rebateBps: 1500, burnBps: 1000, opsBps: 1000}),
            address(core),
            address(buyer)
        );

        // A malicious route reaches FairCore only through the Safe's timelock.
        evil = new EvilRoute(wif, usdg);
        vm.startPrank(owner);
        core.queue(FairCore.Op.SetRoute, EVIL, address(evil));
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        core.execute(FairCore.Op.SetRoute, EVIL, address(evil));
        vm.stopPrank();

        ra = regFunded(ana, 100e6);
        rb_ = regFunded(bob, 100e6);
        reseed(RATE * 1e18);
    }

    // ---------------------------------------------------------------- helpers

    /// RakeBuyer buys `usdgIn` honestly, so it holds bought tokens waiting for a permissionless forward() to the vault.
    function _rakeHolds(uint256 usdgIn) internal {
        usdg.mint(address(buyer), usdgIn * 2); // rake: half of it buys
        vm.prank(keeper);
        buyer.buy(0, usdgIn, usdgIn * RATE);
    }

    /// A slashed bond leaves 50 $wif in RobinAmongThieves' burnPending, flushable to DEAD by anyone.
    function _bondBurnPending() internal returns (uint256 pending) {
        vm.prank(owner);
        rat.queueBonds(true, 1000e18);
        vm.warp(rat.bondOpEta());
        vm.prank(owner);
        rat.executeBonds();
        vm.prank(ana);
        rat.bond(ra, 1000e18, address(wif));
        playMatch(
            rat.currentRound(), ana, ra, RobinAmongThieves.Choice.Steal, bob, rb_, RobinAmongThieves.Choice.Share
        );
        pending = rat.burnPending(address(wif));
        assertEq(pending, 50e18);
        reseed(RATE * 1e18); // the anchor decayed during the bond delay
    }

    /// Arms `src` so that, called mid-swap, it delivers at least `minOut` to the vault (or DEAD) on its own.
    function _armSource(EvilRoute r, Src src, uint256 minOut, uint256 deliver) internal {
        if (src == Src.RakeForward) {
            _rakeHolds(minOut / RATE);
            r.arm(address(buyer), abi.encodeCall(RakeBuyer.forward, ()), deliver);
        } else if (src == Src.SplitterDistribute) {
            wif.mint(address(fs), minOut * 10); // vault leg 25%, burn leg 10% = minOut
            r.arm(address(fs), abi.encodeCall(FeeSplitter.distribute, (address(wif))), deliver);
        } else {
            r.arm(address(rat), abi.encodeCall(RobinAmongThieves.flushBondBurn, (address(wif))), deliver);
        }
    }

    function _usdgIn(Src src) internal pure returns (uint256) {
        // 64 * RATE = 50e18, the same size as the 50 $wif bond burn. 64_000 would ask for 50,000 $wif.
        return src == Src.BondBurn ? 64 : 50e6;
    }

    function _anchors() internal view returns (uint256, uint256, uint256, uint64, uint64) {
        return (core.anchorRate(), core.anchorBase(), core.raiseBase(), core.anchorAt(), core.raiseWindowStart());
    }

    function _expectShortFillBoth(Src src) internal {
        if (src == Src.BondBurn) _bondBurnPending();
        uint256 usdgIn = _usdgIn(src);
        uint256 minOut = usdgIn * RATE;
        _armSource(evil, src, minOut, 0);

        uint256 vaultW = wif.balanceOf(vaultAddr);
        uint256 deadW = wif.balanceOf(DEAD);
        uint256 coreU = usdg.balanceOf(address(core));
        uint256 acc = core.accounted();
        uint256 vb = core.vaultBuyPending();
        uint256 bf = core.bonfirePending();
        (uint256 a0, uint256 b0, uint256 r0, uint64 t0, uint64 w0) = _anchors();

        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(FairCore.ShortFill.selector, 0, minOut));
        core.buyForVault(EVIL, usdgIn, minOut);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(FairCore.ShortFill.selector, 0, minOut));
        core.burnBuyToken(FairCore.BurnSource.Bonfire, EVIL, usdgIn, minOut);

        // Both calls rolled back completely, the mid-swap inflow included.
        assertEq(wif.balanceOf(vaultAddr), vaultW);
        assertEq(wif.balanceOf(DEAD), deadW);
        assertEq(usdg.balanceOf(address(evil)), 0, "route kept nothing");
        assertEq(usdg.balanceOf(address(core)), coreU);
        assertEq(core.accounted(), acc);
        assertEq(core.vaultBuyPending(), vb);
        assertEq(core.bonfirePending(), bf);
        (uint256 a1, uint256 b1, uint256 r1, uint64 t1, uint64 w1) = _anchors();
        assertEq(a1, a0);
        assertEq(b1, b0);
        assertEq(r1, r0);
        assertEq(t1, t0);
        assertEq(w1, w0);
        assertEq(wif.balanceOf(address(core)), 0);
    }

    // ---------------------------------------------------------------- a route that delivers nothing

    function test_evilRoute_rakeForward_shortFills() public {
        _expectShortFillBoth(Src.RakeForward);
    }

    function test_evilRoute_feeSplitterDistribute_shortFills() public {
        _expectShortFillBoth(Src.SplitterDistribute);
    }

    /// usdgIn 64 makes minOut equal the 50 $wif bond. On the old balance-of-DEAD check this inflow would fill the
    /// swap. FairCore's own balance does not move, so it reverts ShortFill.
    function test_evilRoute_flushBondBurn_shortFills() public {
        uint256 pending = _bondBurnPending(); // 50e18
        uint256 usdgIn = 64; // 64 * RATE = 50e18 = pending
        uint256 minOut = usdgIn * RATE;
        assertEq(minOut, pending);
        evil.arm(address(rat), abi.encodeCall(RobinAmongThieves.flushBondBurn, (address(wif))), 0);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(FairCore.ShortFill.selector, 0, minOut));
        core.burnBuyToken(FairCore.BurnSource.Bonfire, EVIL, usdgIn, minOut);
    }

    /// One wei short of minOut from the route itself still fails, with or without an inflow.
    function test_evilRoute_oneWeiShort_plusInflow_shortFills() public {
        uint256 usdgIn = 50e6;
        uint256 minOut = usdgIn * RATE;
        _armSource(evil, Src.SplitterDistribute, minOut, minOut - 1);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(FairCore.ShortFill.selector, minOut - 1, minOut));
        core.buyForVault(EVIL, usdgIn, minOut);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(FairCore.ShortFill.selector, minOut - 1, minOut));
        core.burnBuyToken(FairCore.BurnSource.Bonfire, EVIL, usdgIn, minOut);
    }

    // ---------------------------------------------------------------- honest fill plus an inflow: exact out

    function test_honestFill_plusRakeForward_vault_exactOut() public {
        uint256 usdgIn = 50e6;
        uint256 minOut = usdgIn * RATE;
        _armSource(evil, Src.RakeForward, minOut, minOut);
        uint256 v0 = wif.balanceOf(vaultAddr);
        vm.expectEmit(true, false, false, true, address(core));
        emit FairCore.BoughtForVault(address(wif), EVIL, usdgIn, minOut, minOut);
        vm.prank(keeper);
        uint256 out = core.buyForVault(EVIL, usdgIn, minOut);
        assertEq(out, minOut, "out = the route's own fill");
        assertEq(wif.balanceOf(vaultAddr) - v0, 2 * minOut, "the forward and the fill both land");
        assertEq(wif.balanceOf(address(core)), 0, "nothing left in FairCore");
        assertSolvent();
    }

    function test_honestFill_plusDistribute_dead_exactOut() public {
        uint256 usdgIn = 100e6;
        uint256 minOut = usdgIn * RATE;
        _armSource(evil, Src.SplitterDistribute, minOut, minOut);
        uint256 d0 = wif.balanceOf(DEAD);
        vm.expectEmit(true, false, false, true, address(core));
        emit FairCore.Burned(address(wif), uint8(FairCore.BurnSource.Bonfire), EVIL, usdgIn, minOut, minOut);
        vm.prank(keeper);
        uint256 out = core.burnBuyToken(FairCore.BurnSource.Bonfire, EVIL, usdgIn, minOut);
        assertEq(out, minOut);
        assertEq(wif.balanceOf(DEAD) - d0, 2 * minOut, "FeeSplitter's burn leg and the fill both land");
        assertEq(wif.balanceOf(address(core)), 0);
    }

    function test_honestFill_plusFlushBondBurn_dead_exactOut() public {
        uint256 pending = _bondBurnPending();
        uint256 usdgIn = 64_000;
        uint256 minOut = usdgIn * RATE;
        _armSource(evil, Src.BondBurn, minOut, minOut);
        uint256 d0 = wif.balanceOf(DEAD);
        vm.prank(keeper);
        uint256 out = core.burnBuyToken(FairCore.BurnSource.Bonfire, EVIL, usdgIn, minOut);
        assertEq(out, minOut);
        assertEq(wif.balanceOf(DEAD) - d0, pending + minOut);
        assertEq(wif.balanceOf(address(core)), 0);
    }

    /// An over-delivering route: everything it paid is counted and passed on.
    function test_overFill_allForwarded() public {
        uint256 usdgIn = 50e6;
        uint256 minOut = usdgIn * RATE;
        evil.arm(address(0), "", minOut * 3);
        uint256 v0 = wif.balanceOf(vaultAddr);
        vm.prank(keeper);
        uint256 out = core.buyForVault(EVIL, usdgIn, minOut);
        assertEq(out, minOut * 3);
        assertEq(wif.balanceOf(vaultAddr) - v0, minOut * 3);
        assertEq(wif.balanceOf(address(core)), 0);
    }

    // ---------------------------------------------------------------- anchor

    /// The anchor reads the keeper's quote, never `out`: an honest route and a route that fills exactly the quote while
    /// a third-party inflow lands at the vault leave identical anchor state.
    function test_anchor_identical_honest_vs_inflow() public {
        uint256 usdgIn = 100e6;
        uint256 minOut = usdgIn * RATE * 101 / 100; // a quote 1% above the anchor: the anchor rises, capped at 2%
        uint256 curBefore = core.decayedAnchor();
        uint256 snap = vm.snapshotState();

        route.setRate(RATE * 101 / 100);
        vm.prank(keeper);
        uint256 outHonest = core.buyForVault(0, usdgIn, minOut);
        (uint256 a1, uint256 b1, uint256 r1, uint64 t1, uint64 w1) = _anchors();

        vm.revertToState(snap);
        _armSource(evil, Src.SplitterDistribute, minOut, minOut);
        vm.prank(keeper);
        uint256 outEvil = core.buyForVault(EVIL, usdgIn, minOut);
        (uint256 a2, uint256 b2, uint256 r2, uint64 t2, uint64 w2) = _anchors();

        assertEq(outHonest, outEvil, "both report the route's own fill");
        assertEq(a1, a2);
        assertEq(b1, b2);
        assertEq(r1, r2);
        assertEq(t1, t2);
        assertEq(w1, w2);
        assertGt(a2, curBefore, "the quote lifted the anchor");
        assertEq(a2, minOut * 1e18 / usdgIn, "anchor = the keeper's quote (under the 2% raise cap), not the fill");
    }

    // ---------------------------------------------------------------- input side

    function test_noAllowance_routeCannotPullMore() public {
        assertEq(usdg.allowance(address(core), address(evil)), 0);
        evil.armPull(address(core));
        evil.arm(address(0), "", 100e6 * RATE);
        vm.prank(keeper);
        vm.expectRevert(); // ERC20InsufficientAllowance
        core.buyForVault(EVIL, 100e6, 100e6 * RATE);
        assertEq(usdg.allowance(address(core), address(evil)), 0);
    }

    function test_exactInputDebited_andNoBuyTokenLeft() public {
        uint256 usdgIn = 100e6;
        uint256 coreU = usdg.balanceOf(address(core));
        uint256 acc = core.accounted();
        vm.prank(keeper);
        core.buyForVault(0, usdgIn, usdgIn * RATE);
        assertEq(coreU - usdg.balanceOf(address(core)), usdgIn);
        assertEq(acc - core.accounted(), usdgIn);
        assertEq(usdg.allowance(address(core), address(route)), 0);
        assertEq(wif.balanceOf(address(core)), 0);

        vm.prank(keeper);
        core.burnBuyToken(FairCore.BurnSource.Bonfire, 0, usdgIn, usdgIn * RATE);
        assertEq(coreU - usdg.balanceOf(address(core)), 2 * usdgIn);
        assertEq(acc - core.accounted(), 2 * usdgIn);
        assertEq(wif.balanceOf(address(core)), 0);
        assertSolvent();
    }

    /// Buy token already sitting in FairCore (sent by mistake) is not counted as fill, is not passed on, and stays
    /// sweepable by the Safe.
    function test_strayBuyTokenInCore_notCounted_stillSweepable() public {
        uint256 stray = 7e18;
        wif.mint(address(core), stray);
        uint256 usdgIn = 50e6;
        uint256 minOut = usdgIn * RATE;
        evil.arm(address(0), "", 0);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(FairCore.ShortFill.selector, 0, minOut));
        core.buyForVault(EVIL, usdgIn, minOut);

        uint256 v0 = wif.balanceOf(vaultAddr);
        vm.prank(keeper);
        uint256 out = core.buyForVault(0, usdgIn, minOut);
        assertEq(out, minOut);
        assertEq(wif.balanceOf(vaultAddr) - v0, minOut);
        assertEq(wif.balanceOf(address(core)), stray);

        address to = makeAddr("sweepTo");
        vm.prank(owner);
        core.sweepExcess(IERC20(address(wif)), to);
        assertEq(wif.balanceOf(to), stray);
        assertEq(wif.balanceOf(address(core)), 0);
    }

    // ---------------------------------------------------------------- RakeBuyer (unchanged)

    /// RakeBuyer.buy and forward() share one lock, so a RakeBuyer route can't re-enter forward() mid-buy.
    function test_rakeBuyer_routeReenterForward_blocked() public {
        _rakeHolds(10e6);
        vm.warp(vm.getBlockTimestamp() + 50 minutes);
        usdg.mint(address(buyer), 100e6);
        evilRb.arm(address(buyer), abi.encodeCall(RakeBuyer.forward, ()), 0);
        vm.prank(keeper);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        buyer.buy(1, 10e6, 10e6 * RATE);
    }

    // ---------------------------------------------------------------- L_VAULT_BURN

    /// BurnSource.Vault is ledger L_VAULT_BURN. A mid-swap payment to DEAD does not count, and an honest fill is
    /// forwarded to DEAD as exactly the route's own amount.
    function test_vaultBurn_inflowIgnored_honestFillExact() public {
        uint256 usdgIn = 50e6;
        uint256 minOut = usdgIn * RATE;
        assertGe(core.vaultBurnPending(), usdgIn);

        _armSource(evil, Src.SplitterDistribute, minOut, 0);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(FairCore.ShortFill.selector, 0, minOut));
        core.burnBuyToken(FairCore.BurnSource.Vault, EVIL, usdgIn, minOut);

        // The short fill rolled back. The splitter still holds the amount armed above; only the route's fill changes.
        evil.arm(address(fs), abi.encodeCall(FeeSplitter.distribute, (address(wif))), minOut);
        uint256 d0 = wif.balanceOf(DEAD);
        vm.expectEmit(true, false, false, true, address(core));
        emit FairCore.Burned(address(wif), uint8(FairCore.BurnSource.Vault), EVIL, usdgIn, minOut, minOut);
        vm.prank(keeper);
        uint256 out = core.burnBuyToken(FairCore.BurnSource.Vault, EVIL, usdgIn, minOut);
        assertEq(out, minOut, "out is the route's own fill");
        assertEq(wif.balanceOf(DEAD) - d0, 2 * minOut, "FeeSplitter's burn leg and the fill both land on DEAD");
        assertEq(wif.balanceOf(address(core)), 0);
    }

    // ---------------------------------------------------------------- stray plus a short fill

    /// Buy token already in FairCore is not part of the delta. A route that lands one wei under minOut still reverts,
    /// and the stray stays put.
    function test_strayPlusOneWeiShort_revertsShortFill() public {
        uint256 stray = 7e18;
        wif.mint(address(core), stray);
        uint256 usdgIn = 50e6;
        uint256 minOut = usdgIn * RATE;
        evil.arm(address(0), "", minOut - 1);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(FairCore.ShortFill.selector, minOut - 1, minOut));
        core.buyForVault(EVIL, usdgIn, minOut);
        assertEq(wif.balanceOf(address(core)), stray, "the short fill rolled back; the stray did not move");
        assertEq(wif.balanceOf(vaultAddr), 0);
    }

    // ---------------------------------------------------------------- callback into FairCore

    /// The route calls back into FairCore before it delivers. The swap holds the reentrancy lock, so the callback reverts.
    function test_routeCallbackIntoFairCore_reverts() public {
        uint256 usdgIn = 50e6;
        uint256 minOut = usdgIn * RATE;
        evil.arm(address(core), abi.encodeCall(FairCore.flushAlms, ()), minOut);
        uint256 coreU = usdg.balanceOf(address(core));
        vm.prank(keeper);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        core.buyForVault(EVIL, usdgIn, minOut);
        assertEq(usdg.balanceOf(address(core)), coreU);
        assertEq(wif.balanceOf(address(core)), 0);
        assertGe(core.vaultBuyPending(), usdgIn);
    }

    // ---------------------------------------------------------------- FairCore as a recipient

    /// FeeSplitter will not pay FairCore or RakeBuyer, and RakeBuyer will not forward to FairCore.
    function test_fairCoreAsRecipient_rejected() public {
        FeeSplitter.FeeSplit memory split =
            FeeSplitter.FeeSplit({pursesBps: 4000, vaultBps: 2500, rebateBps: 1500, burnBps: 1000, opsBps: 1000});
        FeeSplitter.Recipients memory toCore = FeeSplitter.Recipients({
            purses: address(core),
            vault: vaultAddr,
            rebate: makeAddr("rebate2"),
            burnBuyer: makeAddr("burn2"),
            ops: makeAddr("ops2")
        });
        vm.expectRevert(FeeSplitter.BadRecipient.selector);
        new FeeSplitter(address(wif), owner, toCore, split, address(core), address(buyer));

        FeeSplitter.Recipients memory toBuyer = FeeSplitter.Recipients({
            purses: makeAddr("purses2"),
            vault: vaultAddr,
            rebate: makeAddr("rebate3"),
            burnBuyer: address(buyer),
            ops: makeAddr("ops3")
        });
        vm.expectRevert(FeeSplitter.BadRecipient.selector);
        new FeeSplitter(address(wif), owner, toBuyer, split, address(core), address(buyer));

        vm.expectRevert(FeeSplitter.ZeroAddress.selector);
        new FeeSplitter(address(wif), owner, toBuyer, split, address(0), address(buyer));

        vm.startPrank(owner);
        vm.expectRevert(FeeSplitter.BadRecipient.selector);
        fs.queue(FeeSplitter.Op.SetVault, 0, address(core));
        vm.expectRevert(FeeSplitter.BadRecipient.selector);
        fs.queue(FeeSplitter.Op.SetBurnBuyer, 0, address(buyer));
        vm.expectRevert(FeeSplitter.BadRecipient.selector);
        fs.queue(FeeSplitter.Op.SetOps, 0, address(fs));
        vm.stopPrank();

        RakeBuyer fresh = new RakeBuyer(usdg, IGameConfig(address(config)), vaultAddr, owner, 0, address(core));
        vm.prank(owner);
        vm.expectRevert(RakeBuyer.BadOpValue.selector);
        fresh.setupSet(RakeBuyer.Op.SetForwardTo, 0, address(core));
        vm.prank(owner);
        fresh.setupSet(RakeBuyer.Op.SetForwardTo, 0, address(0));
        assertEq(fresh.forwardTo(), address(0), "address(0) still means the vault");

        vm.expectRevert(RakeBuyer.ZeroAddress.selector);
        new RakeBuyer(usdg, IGameConfig(address(config)), vaultAddr, owner, 0, address(0));

        vm.prank(owner);
        vm.expectRevert(RakeBuyer.BadOpValue.selector);
        buyer.queue(RakeBuyer.Op.SetForwardTo, 0, address(core));
        assertEq(buyer.queuedAt(buyer.opId(RakeBuyer.Op.SetForwardTo, 0, address(core))), 0);
        assertEq(buyer.forwardTo(), address(0));
        assertEq(buyer.fairCore(), address(core));
        assertEq(fs.fairCore(), address(core));
        assertEq(fs.rakeBuyer(), address(buyer));
    }

    /// FeeSplitter must refuse FairCore as a leg and as a rescue target.
    function test_feeSplitter_rejectsFairCoreAndRakeBuyer() public {
        FeeSplitter.FeeSplit memory split =
            FeeSplitter.FeeSplit({pursesBps: 4000, vaultBps: 2500, rebateBps: 1500, burnBps: 1000, opsBps: 1000});
        vm.expectRevert(FeeSplitter.BadRecipient.selector);
        new FeeSplitter(
            address(wif),
            owner,
            FeeSplitter.Recipients({
                purses: makeAddr("pursesPoc"),
                vault: address(core),
                rebate: makeAddr("rebatePoc"),
                burnBuyer: makeAddr("bbPoc"),
                ops: makeAddr("opsPoc")
            }),
            split,
            address(core),
            address(buyer)
        );
        vm.startPrank(owner);
        vm.expectRevert(FeeSplitter.BadRecipient.selector);
        fs.queue(FeeSplitter.Op.SetVault, 0, address(core));
        vm.expectRevert(FeeSplitter.BadRecipient.selector);
        fs.queue(FeeSplitter.Op.SetPurses, 0, address(buyer));
        vm.expectRevert(FeeSplitter.BadRecipient.selector);
        fs.queueRescue(address(wif), address(buyer), address(core), 1);
        vm.expectRevert(FeeSplitter.BadRecipient.selector);
        fs.queueRescue(address(wif), address(core), address(buyer), 1);
        vm.stopPrank();
    }

    /// RakeBuyer must refuse forwardTo = FairCore at queue time, so the op is never stored.
    function test_rakeBuyer_queueForwardToFairCore_reverts() public {
        bytes32 id = buyer.opId(RakeBuyer.Op.SetForwardTo, 0, address(core));
        vm.prank(owner);
        vm.expectRevert(RakeBuyer.BadOpValue.selector);
        buyer.queue(RakeBuyer.Op.SetForwardTo, 0, address(core));
        assertEq(buyer.queuedAt(id), 0);
        assertEq(buyer.forwardTo(), address(0));
    }

    /// `out` is the amount the route paid FairCore. An inflow to the vault and a stray balance already in FairCore
    /// are not part of it. A delivery under minOut reverts ShortFill and moves nothing.
    function testFuzz_deliveryInflowAndStray(uint256 deliver, uint256 inflow, uint256 stray) public {
        uint256 usdgIn = 50e6;
        uint256 minOut = usdgIn * RATE;
        deliver = bound(deliver, 0, minOut * 2);
        inflow = bound(inflow, 0, minOut);
        stray = bound(stray, 0, 1_000e18);
        if (stray != 0) wif.mint(address(core), stray);
        SideInflow side = new SideInflow(wif);
        evil.arm(address(side), abi.encodeCall(SideInflow.mintTo, (vaultAddr, inflow)), deliver);
        uint256 v0 = wif.balanceOf(vaultAddr);
        if (deliver < minOut) {
            vm.prank(keeper);
            vm.expectRevert(abi.encodeWithSelector(FairCore.ShortFill.selector, deliver, minOut));
            core.buyForVault(EVIL, usdgIn, minOut);
            assertEq(wif.balanceOf(address(core)), stray);
            assertEq(wif.balanceOf(vaultAddr), v0);
            assertEq(usdg.balanceOf(address(evil)), 0);
        } else {
            vm.prank(keeper);
            uint256 out = core.buyForVault(EVIL, usdgIn, minOut);
            assertEq(out, deliver);
            assertEq(wif.balanceOf(vaultAddr) - v0, deliver + inflow);
            assertEq(wif.balanceOf(address(core)), stray);
            assertEq(usdg.balanceOf(address(evil)), usdgIn);
        }
    }

    /// Three fills, one per ledger, in one timestamp. The anchor follows each quote, capped at +2% from the window
    /// base, and ignores how much the route actually delivered.
    function testFuzz_multiFill_anchorFollowsQuoteNotFill(uint16 up1, uint16 up2, uint16 up3, uint16 extraBps) public {
        up1 = uint16(bound(up1, 0, 200));
        up2 = uint16(bound(up2, 0, 500));
        up3 = uint16(bound(up3, 0, 500));
        extraBps = uint16(bound(extraBps, 0, 10_000));
        uint256 usdgIn = 50e6;
        uint256 anchor0 = RATE * 1e18;
        uint256 cap = anchor0 * 10_200 / 10_000;
        assertEq(core.anchorRate(), anchor0);

        uint256 anchor = anchor0;
        anchor = _fillAndAnchor(0, usdgIn, up1, extraBps, anchor0, cap, anchor);
        anchor = _fillAndAnchor(1, usdgIn, up2, extraBps, anchor0, cap, anchor);
        anchor = _fillAndAnchor(2, usdgIn, up3, extraBps, anchor0, cap, anchor);
        assertEq(core.anchorRate(), anchor);
        assertEq(wif.balanceOf(address(core)), 0);
    }

    function _fillAndAnchor(
        uint8 which,
        uint256 usdgIn,
        uint16 upBps,
        uint16 extraBps,
        uint256 anchor0,
        uint256 cap,
        uint256 anchor
    ) internal returns (uint256) {
        uint256 minOut = usdgIn * RATE * (10_000 + upBps) / 10_000;
        uint256 deliver = minOut * (10_000 + extraBps) / 10_000;
        evil.arm(address(0), "", deliver);
        vm.prank(keeper);
        uint256 out;
        if (which == 0) out = core.buyForVault(EVIL, usdgIn, minOut);
        else if (which == 1) out = core.burnBuyToken(FairCore.BurnSource.Bonfire, EVIL, usdgIn, minOut);
        else out = core.burnBuyToken(FairCore.BurnSource.Vault, EVIL, usdgIn, minOut);
        assertEq(out, deliver, "anchor input is the quote, the return value is the fill");
        uint256 px = anchor0 * (10_000 + upBps) / 10_000;
        if (px > cap) px = cap;
        if (px > anchor) anchor = px;
        assertEq(core.anchorRate(), anchor);
        return anchor;
    }

    /// Inflow to DEAD during a burn is not part of `out`. The burn ledger forwards only what the route paid FairCore.
    function testFuzz_burnLedgerInflow(uint256 deliver, uint256 inflow) public {
        uint256 usdgIn = 50e6;
        uint256 minOut = usdgIn * RATE;
        deliver = bound(deliver, 0, minOut * 2);
        inflow = bound(inflow, 0, minOut);
        SideInflow side = new SideInflow(wif);
        evil.arm(address(side), abi.encodeCall(SideInflow.mintTo, (DEAD, inflow)), deliver);
        uint256 d0 = wif.balanceOf(DEAD);
        if (deliver < minOut) {
            vm.prank(keeper);
            vm.expectRevert(abi.encodeWithSelector(FairCore.ShortFill.selector, deliver, minOut));
            core.burnBuyToken(FairCore.BurnSource.Bonfire, EVIL, usdgIn, minOut);
            assertEq(wif.balanceOf(DEAD), d0);
            assertEq(wif.balanceOf(address(core)), 0);
        } else {
            vm.prank(keeper);
            uint256 out = core.burnBuyToken(FairCore.BurnSource.Bonfire, EVIL, usdgIn, minOut);
            assertEq(out, deliver);
            assertEq(wif.balanceOf(DEAD) - d0, deliver + inflow);
            assertEq(wif.balanceOf(address(core)), 0);
        }
    }

    /// Tokens minted to FairCore during the swap are part of the delta. A balance that was already there is not.
    function testFuzz_directInflowToFairCore(uint256 deliver, uint256 direct, uint256 stray) public {
        uint256 usdgIn = 50e6;
        uint256 minOut = usdgIn * RATE;
        deliver = bound(deliver, 0, minOut);
        direct = bound(direct, 0, minOut);
        stray = bound(stray, 0, 1_000e18);
        if (stray != 0) wif.mint(address(core), stray);
        SideInflow side = new SideInflow(wif);
        evil.arm(address(side), abi.encodeCall(SideInflow.mintTo, (address(core), direct)), deliver);
        uint256 counted = deliver + direct;
        if (counted < minOut) {
            vm.prank(keeper);
            vm.expectRevert(abi.encodeWithSelector(FairCore.ShortFill.selector, counted, minOut));
            core.buyForVault(EVIL, usdgIn, minOut);
            assertEq(wif.balanceOf(address(core)), stray);
            assertEq(wif.balanceOf(vaultAddr), 0);
        } else {
            vm.prank(keeper);
            uint256 out = core.buyForVault(EVIL, usdgIn, minOut);
            assertEq(out, counted);
            assertEq(wif.balanceOf(vaultAddr), counted);
            assertEq(wif.balanceOf(address(core)), stray);
        }
    }

    /// After time passes the anchor is the quote, capped, measured from the decayed anchor. The stored rate does not
    /// change when the quote is at or below that decayed value.
    function testFuzz_anchor_afterWarp(uint256 dt, uint256 upBps) public {
        dt = bound(dt, 50 minutes, 40 hours);
        upBps = bound(upBps, 0, 500);
        vm.warp(block.timestamp + dt);
        uint256 usdgIn = 50e6;
        uint256 cur = core.decayedAnchor();
        uint256 floorMin = usdgIn * core.ratchetFloorRate() / 1e18;
        uint256 minOut = floorMin + usdgIn * cur / 1e18 * upBps / 10_000;
        evil.arm(address(0), "", minOut);
        uint256 anchorBefore = core.anchorRate();
        uint256 baseBefore = core.anchorBase();
        uint256 raiseBase = core.raiseBase();
        uint64 window = core.raiseWindowStart();
        vm.prank(keeper);
        uint256 out = core.burnBuyToken(FairCore.BurnSource.Bonfire, EVIL, usdgIn, minOut);
        assertEq(out, minOut);
        uint256 px = minOut * 1e18 / usdgIn;
        if (block.timestamp >= uint256(window) + 4 hours) raiseBase = cur;
        uint256 cap = raiseBase * 10_200 / 10_000;
        if (px > cap) px = cap;
        assertEq(core.anchorRate(), px > cur ? px : anchorBefore);
        assertEq(core.anchorBase(), px > baseBefore ? px : baseBefore);
    }
}
