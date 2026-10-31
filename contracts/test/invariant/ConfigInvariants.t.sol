// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {FairPass} from "../../src/FairPass.sol";
import {FairCore} from "../../src/FairCore.sol";
import {GameConfig} from "../../src/GameConfig.sol";
import {IFairCore, IGameConfig, Tokens, Split} from "../../src/interfaces/IFair.sol";
import {MockToken, MockRoute, StubBooth} from "../mocks/Mocks.sol";

/// Plays Fairs back to back while the owner queues, cancels and executes GameConfig updates between them, and players
/// lock and unlock in whatever token is current.
contract ConfigHandler is Test {
    GameConfig public config;
    FairPass pass;
    FairCore core;
    StubBooth booth;
    MockToken usdg;
    MockToken[3] toks;
    address owner;
    address keeper;
    address[] public actors;

    // ghost: what GameConfig's tokens must be, moved only by a successful executeTokens
    address public gPlay;
    uint256 public gLock;
    address public gBuy;
    bool public executedEarly;
    bool public executedDuringFair;
    bool public unlockFailed;
    uint256 public executes;
    uint256 public splitExecutes;
    uint256 public unlocksAfterHold;
    uint256 public reseeds;
    bool public resetOutOfBounds;
    uint256 public buybacks;

    constructor(
        GameConfig c,
        FairPass p,
        FairCore co,
        StubBooth b,
        MockToken u,
        MockToken[3] memory t,
        address o,
        address k,
        address[] memory a
    ) {
        (config, pass, core, booth, usdg, toks, owner, keeper, actors) = (c, p, co, b, u, t, o, k, a);
        (gPlay, gLock, gBuy) = c.tokens();
    }

    function _routeIndex(address t) internal view returns (uint256) {
        for (uint256 i; i < 3; ++i) if (address(toks[i]) == t) return i;
        revert("unknown token");
    }

    function warp(uint32 secs) public {
        vm.warp(vm.getBlockTimestamp() + bound(secs, 1, 2 days));
    }

    /// Schedule the next one-day Fair, starting now, once the last one is over.
    function nextFair() public {
        uint256 n = core.fairCount();
        (, uint64 lastEnd) = n == 0 ? (uint64(0), uint64(0)) : core.fairs(n - 1);
        if (block.timestamp < lastEnd) return;
        vm.prank(owner);
        core.setFair(n, uint64(block.timestamp + 1), uint64(block.timestamp + 1 days));
        vm.warp(block.timestamp + 1);
    }

    function shoot(uint256 who, uint256 amt) public {
        (bool active, uint256 fairId) = core.activeFair();
        if (!active) return;
        address a = actors[who % actors.length];
        vm.prank(a);
        booth.shot(a, fairId, bound(amt, 1, 5_000e6));
    }

    function burn(uint256 amt, bool fromVault) public {
        uint256 pending = fromVault ? core.vaultBurnPending() : core.bonfirePending();
        if (pending == 0) return;
        amt = bound(amt, 1, pending < 250e6 ? pending : 250e6);
        uint256 floorRate = core.ratchetFloorRate();
        uint256 minOut = amt * floorRate / 1e18 + 1;
        uint256 r = _routeIndex(core.buyToken());
        vm.prank(keeper);
        try core.burnBuyToken(fromVault ? FairCore.BurnSource.Vault : FairCore.BurnSource.Bonfire, r, amt, minOut) {
            ++buybacks;
        } catch {}
    }

    function reseed() public {
        MockRoute r = MockRoute(address(core.routes(_routeIndex(core.buyToken()))));
        uint256 seed = r.rate() * 1e18;
        vm.startPrank(owner); // A1-12: through the timelock (0 here)
        core.queue(FairCore.Op.ResetRatchet, seed, address(0));
        core.execute(FairCore.Op.ResetRatchet, seed, address(0));
        vm.stopPrank();
        ++reseeds;
    }

    /// A1-12: the Safe tries any value. While an anchor is live in this epoch, a reset outside MAX_RESET_BPS of the
    /// stored anchor must never land; with no live anchor any value may.
    function reseedAny(uint256 x) public {
        x = bound(x, 1, type(uint128).max);
        bool live = core.anchorRate() != 0 && core.anchorEpoch() == config.epoch();
        // M-2: a reset is bounded around the high-water mark (anchorBase), not the decayed or walked-down anchorRate
        uint256 a = core.anchorBase();
        vm.startPrank(owner);
        core.queue(FairCore.Op.ResetRatchet, x, address(0));
        try core.execute(FairCore.Op.ResetRatchet, x, address(0)) {
            ++reseeds;
            if (live && (x < a * 7000 / 10_000 || x > a * 13_000 / 10_000)) resetOutOfBounds = true;
        } catch {}
        vm.stopPrank();
    }

    function queueTokens(uint8 play, uint8 buy, uint8 amt) public {
        uint256[3] memory amts = [uint256(5_000e18), 10_000e18, 20_000e18];
        vm.prank(owner);
        try config.queueTokens(Tokens(address(toks[play % 3]), amts[amt % 3], address(toks[buy % 3]))) {} catch {}
    }

    function cancelTokens() public {
        vm.prank(owner);
        try config.cancelTokens() {} catch {}
    }

    function executeTokens(bool waitForIt) public {
        uint256 eta = config.tokensEta();
        if (waitForIt && eta > block.timestamp) vm.warp(eta);
        (address pp, uint256 pa, address pb) = config.pendingTokens();
        (bool active,) = core.activeFair();
        vm.prank(owner);
        try config.executeTokens() {
            if (block.timestamp < eta || eta == 0) executedEarly = true;
            if (active) executedDuringFair = true;
            (gPlay, gLock, gBuy) = (pp, pa, pb);
            ++executes;
        } catch {}
    }

    function queueSplit(uint16[6] memory r) public {
        Split memory s;
        s.purseBps = uint16(5000 + r[0] % 3001);
        s.almsBps = uint16(1000 + r[1] % 4001);
        s.bonfireBps = uint16(r[2] % 5001);
        s.tollBps = uint16(r[3] % 5001);
        s.vBuyBps = uint16(r[4] % 5001);
        s.vLiqBps = uint16(r[5] % 5001);
        s.vBurnBps = uint16((uint256(r[0]) + r[5]) % 5001);
        vm.prank(owner);
        try config.queueSplit(s) {} catch {} // invalid ones are refused, which is part of the point
    }

    function executeSplit(bool waitForIt) public {
        uint256 eta = config.splitEta();
        if (waitForIt && eta > block.timestamp) vm.warp(eta);
        (bool active,) = core.activeFair();
        vm.prank(owner);
        try config.executeSplit() {
            if (block.timestamp < eta || eta == 0) executedEarly = true;
            if (active) executedDuringFair = true;
            ++splitExecutes;
        } catch {}
    }

    /// Unlock if holding (any token; must never fail after 24h), otherwise lock the current play token.
    function relock(uint256 who) public {
        address a = actors[who % actors.length];
        vm.startPrank(a);
        if (pass.heldSince(a) != 0) {
            if (block.timestamp >= pass.unlockableAt(a)) {
                try pass.unlock() {
                    ++unlocksAfterHold;
                } catch {
                    unlockFailed = true;
                }
            }
        } else {
            (address t, uint256 amt,) = config.tokens();
            pass.lock(t, amt); // every actor holds and has approved every token
        }
        vm.stopPrank();
    }

    /// Sweep excess of one token the handler can lock. The per-token invariant checks locks are untouched.
    function sweep(uint256 tokenIdx) public {
        vm.prank(owner);
        pass.sweepExcess(toks[tokenIdx % 3], owner);
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function tok(uint256 i) external view returns (MockToken) {
        return toks[i];
    }
}

contract ConfigInvariants is Test {
    MockToken usdg;
    MockToken[3] toks;
    GameConfig config;
    FairPass pass;
    FairCore core;
    StubBooth booth;
    ConfigHandler h;
    address owner = makeAddr("owner");
    address keeper = makeAddr("keeper");

    function setUp() public {
        vm.warp(1_800_000_000);
        usdg = new MockToken("USDG", "USDG", 6);
        toks = [new MockToken("Token A", "TKA", 18), new MockToken("Token B", "TKB", 18), new MockToken("Token C", "TKC", 18)];
        config = new GameConfig(
            owner,
            address(usdg),
            2 days,
            Tokens(address(toks[0]), 5_000e18, address(toks[0])),
            Split(6000, 2000, 1750, 1750, 2500, 2500, 2500)
        );
        pass = new FairPass(IGameConfig(address(config)), owner);
        core = new FairCore(usdg, IGameConfig(address(config)), pass, owner, 0);
        booth = new StubBooth(IFairCore(address(core)));
        vm.startPrank(owner);
        config.bindCore(address(core));
        core.setupSet(FairCore.Op.AddBooth, 0, address(booth));
        core.setupSet(FairCore.Op.SetKeeper, 0, keeper);
        core.setupSet(FairCore.Op.SetVault, 0, makeAddr("vault"));
        for (uint256 i; i < 3; ++i) {
            MockRoute r = new MockRoute(toks[i], usdg);
            r.setRate(100e12 * (i + 1));
            core.setupSet(FairCore.Op.SetRoute, i, address(r));
        }
        core.resetRatchet(MockRoute(address(core.routes(0))).rate() * 1e18);
        core.finishSetup();
        vm.stopPrank();

        address[] memory actors = new address[](4);
        for (uint256 i; i < 4; ++i) {
            address a = address(uint160(0xB0B0 + i));
            actors[i] = a;
            usdg.mint(a, 1_000_000_000e6);
            vm.startPrank(a);
            usdg.approve(address(core), type(uint256).max);
            for (uint256 j; j < 3; ++j) {
                toks[j].mint(a, 1_000_000e18);
                toks[j].approve(address(pass), type(uint256).max);
            }
            vm.stopPrank();
        }
        h = new ConfigHandler(config, pass, core, booth, usdg, toks, owner, keeper, actors);
        targetContract(address(h));
    }

    /// Guards against a vacuous pass: the handler really updates tokens, re-seeds, buys back and unlocks across epochs.
    function test_handlerCoversUpdates() public {
        h.relock(0);
        h.nextFair();
        h.shoot(1, 1_000e6);
        h.burn(100e6, false);
        h.warp(2 days);
        h.queueTokens(1, 1, 0);
        h.executeTokens(true);
        assertEq(h.executes(), 1);
        assertEq(config.epoch(), 1);
        h.burn(100e6, false); // refused: not seeded in the new epoch
        assertEq(h.buybacks(), 1);
        h.reseed();
        h.nextFair();
        h.shoot(2, 1_000e6);
        h.burn(100e6, false);
        assertEq(h.buybacks(), 2);
        h.relock(1); // locks token B
        h.relock(0); // unlocks token A after the hold
        assertEq(h.unlocksAfterHold(), 1);
        h.queueSplit([uint16(1000), 1000, 1500, 1500, 2500, 2500]);
        h.executeSplit(true);
        assertEq(h.splitExecutes(), 1);
        h.sweep(0);
        h.sweep(1);
        h.sweep(2);
        invariant_I1_solventAndAccountedExact();
        invariant_perTokenPassBalance();
    }

    /// I1 through every update: solvent, and every USDG in exactly one bucket.
    function invariant_I1_solventAndAccountedExact() public view {
        assertGe(usdg.balanceOf(address(core)), core.accounted(), "insolvent");
        uint256 n = core.fairCount();
        uint256 sum = core.rollover(address(booth)) + core.bonfirePending() + core.tollPending() + core.vaultLiqUsdg()
            + core.vaultBuyPending() + core.vaultBurnPending() + core.vaultFairsBurnUsdg();
        for (uint256 f; f < n; ++f) sum += core.pot(address(booth), f) + core.almsByFair(f);
        sum += core.almsEscrow();
        assertEq(sum, core.accounted(), "every USDG is in exactly one bucket");
    }

    /// For every token ever used: the pass holds exactly what is locked in it, and that equals the sum of the
    /// recorded passes in it.
    function invariant_perTokenPassBalance() public view {
        for (uint256 i; i < 3; ++i) {
            address t = address(toks[i]);
            uint256 snap;
            for (uint256 j; j < h.actorCount(); ++j) {
                (, address pt, uint256 amt,) = pass.passOf(h.actors(j));
                if (pt == t) snap += amt;
            }
            assertEq(pass.totalLocked(t), snap, "sum of passes != totalLocked");
            assertEq(toks[i].balanceOf(address(pass)), pass.totalLocked(t), "balance != totalLocked");
        }
    }

    /// I6: an unlock after the 24h hold never fails, whatever GameConfig did meanwhile.
    function invariant_I6_unlockNeverBlocked() public view {
        assertFalse(h.unlockFailed());
    }

    /// The split in force always meets GameConfig's caps.
    function invariant_splitWithinCaps() public view {
        Split memory s = config.split();
        assertGe(s.purseBps, 5000);
        assertLe(s.purseBps, 8000);
        uint256 gw = uint256(s.almsBps) + s.bonfireBps + s.tollBps;
        assertLe(gw, 10_000);
        assertLe(10_000 - gw, 5000);
        assertGe(s.almsBps, 1000);
        assertLe(s.almsBps, 5000);
        assertLe(s.bonfireBps, 5000);
        assertLe(s.tollBps, 5000);
        uint256 v = uint256(s.vBuyBps) + s.vLiqBps + s.vBurnBps;
        assertLe(v, 10_000);
        assertLe(10_000 - v, 5000);
        assertLe(s.vBuyBps, 5000);
        assertLe(s.vLiqBps, 5000);
        assertLe(s.vBurnBps, 5000);
    }

    /// The timelock is never bypassed: tokens change only through executeTokens at or after the ETA.
    function invariant_tokensOnlyViaTimelock() public view {
        assertFalse(h.executedEarly(), "executed before the ETA");
        (address p, uint256 a, address b) = config.tokens();
        assertEq(p, h.gPlay());
        assertEq(a, h.gLock());
        assertEq(b, h.gBuy());
        assertEq(config.epoch(), h.executes());
    }

    /// No update, tokens or split, ever lands while a Fair is running.
    function invariant_noUpdateDuringAFair() public view {
        assertFalse(h.executedDuringFair(), "executed during a Fair");
    }

    /// A1-12: no reset ever moved a live anchor by more than MAX_RESET_BPS.
    function invariant_resetWithinBounds() public view {
        assertFalse(h.resetOutOfBounds(), "a reset moved a live anchor past MAX_RESET_BPS");
    }

    /// Buybacks only ever run on an anchor seeded in the current epoch.
    function invariant_anchorEpochNeverAhead() public view {
        assertLe(core.anchorEpoch(), config.epoch());
    }
}
