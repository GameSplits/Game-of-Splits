// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FairPass} from "../../src/FairPass.sol";
import {FairCore} from "../../src/FairCore.sol";
import {LastArrow} from "../../src/LastArrow.sol";
import {SheriffsSeat} from "../../src/SheriffsSeat.sol";
import {IFairCore, IGameConfig, Tokens, Split} from "../../src/interfaces/IFair.sol";
import {GameConfig} from "../../src/GameConfig.sol";
import {MockToken, MockRoute, MockArbSys} from "../mocks/Mocks.sol";

contract Handler is Test {
    FairCore core;
    FairPass pass;
    LastArrow arrow;
    SheriffsSeat seat;
    MockToken usdg;
    MockArbSys arb;
    address owner;
    address keeper;
    address[] public actors;

    // keys a pot may sit under, so the invariant can sum every Purse
    uint256[] public arrowKeys;
    mapping(uint256 => bool) seenArrow;
    uint256[] public seatKeys;
    mapping(uint256 => bool) seenSeat;

    bool public claimFailedWhilePaused;
    bool public unlockFailed;
    uint256 public unlocksAfterHold; // coverage: the post-24h branch really runs
    uint256 public unlocksRefusedInHold;

    // Last Arrow clock model: when the last shot of a round landed, and pausedSeconds() just after it.
    mapping(uint256 => uint64) public lastShotAt;
    mapping(uint256 => uint64) public pausedAtShot;

    constructor(
        FairCore c,
        FairPass p,
        LastArrow a,
        SheriffsSeat s,
        MockToken u,
        MockArbSys arb_,
        address o,
        address k
    ) {
        (core, pass, arrow, seat, usdg, arb, owner, keeper) = (c, p, a, s, u, arb_, o, k);
        for (uint256 i; i < 4; ++i) {
            actors.push(address(uint160(0xA11CE + i)));
        }
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _nextBlock() internal {
        arb.set(arb.n() + 1);
    }

    function shoot(uint256 who, uint256 payerSeed) public {
        address player = _actor(who);
        address payer = _actor(payerSeed);
        _nextBlock();
        uint256 r12 = arrow.nextShotRound();
        vm.prank(payer);
        try arrow.shoot(type(uint256).max, player, r12) {
            uint256 id = arrow.currentRound();
            if (!seenArrow[id]) {
                seenArrow[id] = true;
                arrowKeys.push(id);
            }
            lastShotAt[id] = uint64(block.timestamp);
            pausedAtShot[id] = uint64(core.pausedSeconds());
        } catch {}
    }

    function take(uint256 who, uint8 color) public {
        _nextBlock();
        vm.prank(_actor(who));
        try seat.take(type(uint256).max, address(0), "taunt", color % 8) {
            uint256 d = seat.today();
            if (!seenSeat[d]) {
                seenSeat[d] = true;
                seatKeys.push(d);
            }
        } catch {}
    }

    function warp(uint32 secs) public {
        vm.warp(vm.getBlockTimestamp() + bound(secs, 1, 6 hours));
    }

    /// A full day in one step, so the post-hold unlock branch is reached often.
    function warpDay() public {
        vm.warp(vm.getBlockTimestamp() + 24 hours);
    }

    function settleArrow(uint256 i) public {
        if (arrowKeys.length == 0) return;
        try arrow.settle(arrowKeys[i % arrowKeys.length]) {} catch {}
    }

    function settleSeat(uint256 i) public {
        if (seatKeys.length == 0) return;
        try seat.settle(seatKeys[i % seatKeys.length]) {} catch {}
    }

    function claim(uint256 who) public {
        address a = _actor(who);
        if (core.claimable(a) == 0) return;
        bool paused = core.salesPaused();
        vm.prank(a);
        try core.claim() {}
        catch {
            if (paused) claimFailedWhilePaused = true;
        }
    }

    function burn(uint256 amt, bool fromVault) public {
        uint256 pending = fromVault ? core.vaultBurnPending() : core.bonfirePending();
        if (pending == 0) return;
        amt = bound(amt, 1, pending < 250e6 ? pending : 250e6);
        uint256 last = core.anchorRate();
        uint256 minOut = last == 0 ? 1 : amt * last / 1e18;
        if (minOut == 0) minOut = 1;
        vm.prank(keeper);
        try core.burnBuyToken(fromVault ? FairCore.BurnSource.Vault : FairCore.BurnSource.Bonfire, 0, amt, minOut) {}
            catch {}
    }

    function buyVault(uint256 amt) public {
        uint256 pending = core.vaultBuyPending();
        if (pending == 0) return;
        amt = bound(amt, 1, pending < 250e6 ? pending : 250e6);
        uint256 last = core.anchorRate();
        uint256 minOut = last == 0 ? 1 : amt * last / 1e18;
        if (minOut == 0) minOut = 1;
        vm.prank(keeper);
        try core.buyForVault(0, amt, minOut) {} catch {}
    }

    function togglePause(bool p) public {
        vm.prank(owner);
        core.pauseSales(p);
    }

    function relock(uint256 who) public {
        address a = _actor(who);
        vm.startPrank(a);
        if (pass.hasPass(a)) {
            // v3.6: unlock opens 24h after locking. Before that it must revert; after it, it must never fail.
            if (block.timestamp < pass.unlockableAt(a)) {
                try pass.unlock() {
                    unlockFailed = true; // an unlock inside the hold would break the rule
                } catch (bytes memory e) {
                    if (bytes4(e) != FairPass.HoldNotOver.selector) unlockFailed = true; // only the hold may refuse
                    else ++unlocksRefusedInHold;
                }
            } else {
                try pass.unlock() {
                    ++unlocksAfterHold;
                } catch {
                    unlockFailed = true; // after 24h nothing may block it, not even a pause
                }
            }
        } else {
            (address t, uint256 amt,) = pass.config().tokens();
            try pass.lock(t, amt) {} catch {}
        }
        vm.stopPrank();
    }

    /// Sweep excess of the play token, or of USDG (never a pass token). Locks must survive either.
    function sweep(uint256 tokenIdx) public {
        address token;
        if (tokenIdx % 2 == 0) {
            (token,,) = pass.config().tokens();
        } else {
            token = address(usdg);
        }
        vm.prank(owner);
        pass.sweepExcess(IERC20(token), owner);
    }

    function arrowKeyCount() external view returns (uint256) {
        return arrowKeys.length;
    }

    function seatKey(uint256 i) external view returns (uint256) {
        return seatKeys[i];
    }

    function seatKeyCount() external view returns (uint256) {
        return seatKeys.length;
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }
}

contract FairInvariants is Test {
    MockToken usdg;
    MockToken wif;
    FairPass pass;
    FairCore core;
    LastArrow arrow;
    SheriffsSeat seat;
    MockRoute route;
    MockArbSys arb;
    Handler h;
    address owner = makeAddr("owner");
    address keeper = makeAddr("keeper");

    function setUp() public {
        uint256 t0 = 1_800_000_000;
        vm.warp(t0);
        vm.etch(address(0x64), address(new MockArbSys()).code);
        arb = MockArbSys(address(0x64));
        arb.set(1);
        usdg = new MockToken("USDG", "USDG", 6);
        wif = new MockToken("WIF", "WIF", 18);
        GameConfig config = new GameConfig(
            owner,
            address(usdg),
            0,
            Tokens(address(wif), 5_000e18, address(wif)),
            Split(6000, 2000, 1750, 1750, 2500, 2500, 2500)
        );
        pass = new FairPass(IGameConfig(address(config)), owner);
        core = new FairCore(usdg, IGameConfig(address(config)), pass, owner, 0);
        vm.prank(owner);
        config.bindCore(address(core));
        arrow = new LastArrow(IFairCore(address(core)));
        seat = new SheriffsSeat(IFairCore(address(core)), (t0 / 1 days) * 1 days, 1 days);
        route = new MockRoute(wif, usdg);
        vm.startPrank(owner);
        core.setupSet(FairCore.Op.AddBooth, 0, address(arrow));
        core.setupSet(FairCore.Op.AddBooth, 0, address(seat));
        core.setupSet(FairCore.Op.SetKeeper, 0, keeper);
        core.setupSet(FairCore.Op.SetRoute, 0, address(route));
        core.setupSet(FairCore.Op.SetVault, 0, makeAddr("vault"));
        core.resetRatchet(route.rate() * 1e18); // v3.6: buybacks need a seeded anchor
        core.finishSetup();
        core.setFair(0, uint64(t0 + 1), uint64(t0 + 35 days)); // the longest Fair FairCore allows
        vm.stopPrank();
        vm.warp(t0 + 1);

        h = new Handler(core, pass, arrow, seat, usdg, arb, owner, keeper);
        for (uint256 i; i < h.actorCount(); ++i) {
            address a = h.actors(i);
            usdg.mint(a, 10_000_000e6);
            wif.mint(a, 20_000e18);
            vm.startPrank(a);
            usdg.approve(address(core), type(uint256).max);
            wif.approve(address(pass), type(uint256).max);
            pass.lock(address(wif), 5_000e18);
            vm.stopPrank();
        }
        targetContract(address(h));
    }

    /// Guards against a vacuous pass: the handler really shoots, takes, settles, claims and burns.
    function test_handlerActuallyPlays() public {
        h.shoot(0, 0);
        h.shoot(1, 2);
        h.take(2, 1);
        h.take(3, 4);
        assertGt(h.arrowKeyCount(), 0, "shots land");
        assertGt(h.seatKeyCount(), 0, "takes land");
        assertGt(core.accounted(), 0);
        vm.warp(vm.getBlockTimestamp() + 2 days);
        h.settleArrow(0);
        h.settleSeat(0);
        uint256 before = core.accounted();
        h.claim(1);
        h.burn(1e6, false);
        assertLt(core.accounted(), before, "claims and burns move money out");
        h.sweep(0);
        h.sweep(1);
        invariant_I1_solventAndAccountedExact();
        invariant_passBalanceEqualsLocks();
    }

    /// I1: everything owed is covered, and `accounted` equals the sum of every bucket.
    function invariant_I1_solventAndAccountedExact() public view {
        assertGe(usdg.balanceOf(address(core)), core.accounted(), "insolvent");
        uint256 pots;
        for (uint256 i; i < h.arrowKeyCount(); ++i) {
            pots += core.pot(address(arrow), h.arrowKeys(i));
        }
        for (uint256 i; i < h.seatKeyCount(); ++i) {
            pots += core.pot(address(seat), h.seatKeys(i));
        }
        uint256 claims;
        for (uint256 i; i < h.actorCount(); ++i) {
            claims += core.claimable(h.actors(i));
        }
        uint256 sum = pots + core.rollover(address(arrow)) + core.rollover(address(seat)) + claims + core.almsByFair(0) + core.almsEscrow()
            + core.bonfirePending() + core.tollPending() + core.vaultLiqUsdg() + core.vaultBuyPending()
            + core.vaultBurnPending() + core.vaultFairsBurnUsdg();
        assertEq(sum, core.accounted(), "every USDG is in exactly one bucket");
    }

    /// I5: booths never hold tokens.
    function invariant_I5_boothsHoldNothing() public view {
        assertEq(usdg.balanceOf(address(arrow)), 0);
        assertEq(usdg.balanceOf(address(seat)), 0);
    }

    /// v3.6 I1 (Seat): after any take on day d, every earlier day that had takes is settled.
    function invariant_seat_everyEarlierTakeDaySettled() public view {
        uint256 ld = seat.lastTakeDayPlus1();
        if (ld == 0) return;
        for (uint256 i; i < h.seatKeyCount(); ++i) {
            uint256 k = h.seatKey(i);
            if (k < ld - 1) assertTrue(seat.isSettled(k), "an earlier take day was left unsettled");
        }
    }

    /// v3.6: the 24h hold is exercised both ways, and an unlock after it always succeeds.
    function test_holdCoverage() public {
        h.relock(0); // inside the hold: refused with HoldNotOver
        assertEq(h.unlocksRefusedInHold(), 1);
        h.warpDay();
        h.togglePause(true);
        h.relock(0); // after the hold, while paused: succeeds
        assertEq(h.unlocksAfterHold(), 1);
        assertFalse(h.unlockFailed());
    }

    /// I6 and pause scope: claims and unlocks never fail because of a pause.
    function invariant_I6_pauseNeverBlocksClaimOrUnlock() public view {
        assertFalse(h.claimFailedWhilePaused(), "claim blocked while paused");
        assertFalse(h.unlockFailed(), "unlock failed");
    }

    /// FairPass: the contract holds exactly 5,000 $wif per open pass.
    function invariant_passBalanceEqualsLocks() public view {
        uint256 passes;
        for (uint256 i; i < h.actorCount(); ++i) {
            if (pass.hasPass(h.actors(i))) ++passes;
        }
        assertEq(pass.totalLocked(address(wif)), passes * 5_000e18);
        assertEq(wif.balanceOf(address(pass)), pass.totalLocked(address(wif)));
    }

    /// Last Arrow: stored deadline is at most 1h after the last shot, plus paused seconds since that shot.
    /// A settle folds those seconds into the deadline; a live round has not yet. hardEnd stays 0 (no hard end).
    function invariant_arrowClock() public view {
        uint256 n = h.arrowKeyCount();
        for (uint256 i; i < n; ++i) {
            uint256 id = h.arrowKeys(i);
            LastArrow.Round memory R = arrow.roundState(id);
            uint64 last = h.lastShotAt(id);
            if (last == 0) continue;
            uint256 pausedSince = core.pausedSeconds() - h.pausedAtShot(id);
            assertLe(R.deadline, uint256(last) + 1 hours + pausedSince);
            assertEq(R.hardEnd, 0);
        }
    }

    /// Seat: seconds credited in any day never exceed the day.
    function invariant_seatSecondsBounded() public view {
        for (uint256 i; i < h.seatKeyCount(); ++i) {
            uint256 d = h.seatKeys(i);
            uint256 total;
            for (uint256 j; j < h.actorCount(); ++j) {
                total += seat.secsOf(d, h.actors(j));
            }
            assertLe(total, 1 days);
        }
    }
}
