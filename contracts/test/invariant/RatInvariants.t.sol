// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {RobinAmongThieves} from "../../src/RobinAmongThieves.sol";
import {GameConfig} from "../../src/GameConfig.sol";
import {FairPass} from "../../src/FairPass.sol";
import {FairCore} from "../../src/FairCore.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IFairCore, IGameConfig, Tokens, Split} from "../../src/interfaces/IFair.sol";
import {IIdentityRegistry, IReputationRegistry} from "../../src/interfaces/I8004.sol";
import {MockToken, MockIdentity, MockReputation, MockArbSys} from "../mocks/Mocks.sol";

/// Plays Robin Among Thieves round after round: outlaws deposit, enter (as controller or operator), commit, reveal or
/// skip, withdraw, retire and re-register; the keeper reveals seeds (sometimes not), pairs, cancels, settles and
/// finalizes on schedule; the owner pauses. Ghost checks record any rule broken along the way.
contract RatHandler is Test {
    RobinAmongThieves public rat;
    FairPass public pass;
    MockIdentity idr;
    MockToken usdg;
    MockToken wif;
    address owner;
    address keeper;
    address public houseSink;
    address public opr;
    address[] public actors;
    uint256[] public ids;
    bytes32[] chain;
    uint256 link = 1;

    uint256[] public tracked;
    mapping(uint256 => bool) isTracked;
    mapping(uint256 => bool) done;
    mapping(uint256 => mapping(uint256 => RobinAmongThieves.Choice)) chosen; // round => id => committed choice

    // ghosts
    uint256 public deposited;
    uint256 public paidOut; // withdrawals and retirements
    uint256 public flushed;
    uint256 public matchesSettled;
    uint256 public bonusesPaid;
    uint256 public cancels;
    mapping(bytes32 => uint256) ghostMet;
    mapping(bytes32 => uint256) ghostPairBonus;
    mapping(uint256 => mapping(uint256 => uint256)) dayBonus; // id => day => paid

    bool public houseLeak; // I10
    bool public houseMetHouse; // I11
    bool public sameOwnerMet; // R5
    bool public metTooSoon; // I6
    bool public operatorMoved; // I13
    bool public pauseBlocked; // I7
    bool public bondTaken; // I12
    bool public badEligibility; // R3, R4, R6
    bool public bonusOverCap; // R2, BONUS_CAP
    bool public overDraw; // R1, I3
    bool public pairBonusTwice; // R3

    constructor(
        RobinAmongThieves r,
        FairPass p,
        MockIdentity i,
        MockToken u,
        MockToken w,
        address o,
        address k,
        address hs
    ) {
        (rat, pass, idr, usdg, wif, owner, keeper, houseSink) = (r, p, i, u, w, o, k, hs);
        opr = makeAddr("operator");
        chain = new bytes32[](1500);
        chain[1499] = keccak256("handler chain");
        for (uint256 j = 1499; j > 0; --j) chain[j - 1] = keccak256(abi.encode(chain[j]));
    }

    function tip() external view returns (bytes32) {
        return chain[0];
    }

    bool public isSealed;

    /// Setup only: the actors are fixed before the run (sealed), so the fuzzer can't add, say, the operator as one.
    function seal() external {
        isSealed = true;
    }

    /// Called by the test's setUp after the keeper commits the chain.
    function addActor(address a, bool house) external {
        require(!isSealed, "actors are fixed");
        actors.push(a);
        usdg.mint(a, 10_000_000e6);
        wif.mint(a, 1_000_000e18);
        vm.startPrank(a);
        usdg.approve(address(rat), type(uint256).max);
        wif.approve(address(rat), type(uint256).max);
        wif.approve(address(pass), type(uint256).max);
        pass.lock(address(wif), 5_000e18);
        uint256 id = rat.registerOutlawNew("ipfs://h", address(0), address(wif), 1000e18);
        vm.stopPrank();
        ids.push(id);
        if (house) {
            vm.prank(a);
            rat.requestHouse(id);
            vm.prank(owner);
            rat.setHouse(id, true);
        }
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function trackedCount() external view returns (uint256) {
        return tracked.length;
    }

    function _o(uint256 id) internal view returns (address ctl, address op, uint256 open, bool house, uint256 balance) {
        (ctl,, op, open,,, house,,,,, balance,,,) = rat.outlaws(id);
    }

    function _track(uint256 r) internal {
        if (!isTracked[r]) {
            isTracked[r] = true;
            tracked.push(r);
        }
    }

    // ---------------------------------------------------------------- player actions

    function deposit(uint256 i, uint256 amt) external {
        i %= actors.length;
        amt = bound(amt, 1, 60e6);
        (address ctl,,,,) = _o(ids[i]);
        if (ctl == address(0)) return;
        vm.prank(actors[i]);
        rat.deposit(ids[i], amt);
        deposited += amt;
    }

    function setOperator(uint256 i, bool on) external {
        i %= actors.length;
        (address ctl,,,,) = _o(ids[i]);
        if (ctl != actors[i]) return;
        vm.prank(actors[i]);
        rat.setOperator(ids[i], on ? opr : address(0));
    }

    function enter(uint256 i, bool viaOperator) external {
        i %= actors.length;
        uint256 id = ids[i];
        (, address op,,,) = _o(id);
        address who = viaOperator && op == opr ? opr : actors[i];
        uint256 r = rat.currentRound();
        vm.prank(who);
        try rat.enter(id, r, keccak256(abi.encode(id, r))) {
            _track(r);
        } catch {}
    }

    function commit(uint256 i, uint8 c) external {
        i %= actors.length;
        uint256 id = ids[i];
        RobinAmongThieves.Choice ch = c % 2 == 0 ? RobinAmongThieves.Choice.Share : RobinAmongThieves.Choice.Steal;
        for (uint256 k; k < tracked.length; ++k) {
            uint256 r = tracked[k];
            if (done[r] || rat.matchOf(r, id) == 0 || chosen[r][id] != RobinAmongThieves.Choice.None) continue;
            bytes32 h = rat.commitHash(ch, keccak256(abi.encode(r, id)), r, id);
            vm.prank(actors[i]);
            try rat.commit(r, id, h) {
                chosen[r][id] = ch;
            } catch {}
        }
    }

    function reveal(uint256 i, bool skip) external {
        if (skip) return;
        i %= actors.length;
        uint256 id = ids[i];
        for (uint256 k; k < tracked.length; ++k) {
            uint256 r = tracked[k];
            RobinAmongThieves.Choice ch = chosen[r][id];
            if (done[r] || ch == RobinAmongThieves.Choice.None) continue;
            vm.prank(actors[i]);
            try rat.reveal(r, id, ch, keccak256(abi.encode(r, id))) {} catch {}
        }
    }

    function withdraw(uint256 i, uint256 amt, address to) external {
        i %= actors.length;
        uint256 id = ids[i];
        (address ctl,,, bool house, uint256 b) = _o(id);
        if (ctl == address(0) || b == 0) return;
        amt = bound(amt, 1, b);
        if (to == address(0) || to == address(rat)) to = actors[i];
        uint256 hs = usdg.balanceOf(houseSink);
        uint256 tb = usdg.balanceOf(to);
        vm.prank(actors[i]);
        try rat.withdraw(id, amt, to) {
            paidOut += amt;
            if (house) {
                if (usdg.balanceOf(houseSink) != hs + amt) houseLeak = true;
                if (to != houseSink && usdg.balanceOf(to) != tb) houseLeak = true;
            }
        } catch (bytes memory e) {
            if (bytes4(e) == RobinAmongThieves.EntriesArePaused.selector) pauseBlocked = true;
        }
    }

    /// Retire if allowed, then register the same identity again so the actor keeps playing.
    function retire(uint256 i) external {
        i %= actors.length;
        uint256 id = ids[i];
        (address ctl,,, bool house, uint256 b) = _o(id);
        if (ctl == address(0)) return;
        address balTo = house ? houseSink : actors[i];
        uint256 before = usdg.balanceOf(balTo);
        vm.prank(actors[i]);
        try rat.retire(id) {
            paidOut += b;
            if (usdg.balanceOf(balTo) != before + b) houseLeak = true;
            vm.prank(actors[i]);
            rat.registerOutlaw(id, address(0), address(wif), 1000e18);
            if (house) {
                vm.prank(actors[i]);
                rat.requestHouse(id);
                vm.prank(owner);
                rat.setHouse(id, true);
            }
        } catch (bytes memory e) {
            if (bytes4(e) == RobinAmongThieves.EntriesArePaused.selector) pauseBlocked = true;
        }
    }

    /// I13: an operator can never move value.
    function operatorAbuse(uint256 i) external {
        i %= actors.length;
        uint256 id = ids[i];
        vm.startPrank(opr);
        try rat.withdraw(id, 1, opr) {
            operatorMoved = true;
        } catch {}
        try rat.retire(id) {
            operatorMoved = true;
        } catch {}
        try rat.unbond(id) {
            operatorMoved = true;
        } catch {}
        try rat.setOperator(id, opr) {
            operatorMoved = true;
        } catch {}
        vm.stopPrank();
    }

    /// I12: while bonds are disabled, no bond is ever taken.
    function bondAttempt(uint256 i, uint256 amt) external {
        i %= actors.length;
        vm.prank(actors[i]);
        try rat.bond(ids[i], bound(amt, 1, 1e24), address(wif)) {
            bondTaken = true;
        } catch {}
    }

    function pause(bool p) external {
        vm.prank(owner);
        rat.pauseEntries(p);
    }

    function flushRake() external {
        address sink = rat.rakeSink();
        uint256 before = usdg.balanceOf(sink);
        rat.flushRake();
        flushed += usdg.balanceOf(sink) - before;
    }

    // ---------------------------------------------------------------- the clock and the keeper

    /// Jump to the next point where something is due (a round closes, reveals open, settle opens) and do the keeper's
    /// jobs that are due. Now and then the keeper misses a seed, so the round gets cancelled.
    function step(uint8 jitter, uint8 coin) external {
        uint256 now_ = block.timestamp;
        uint256 next = rat.closeTime(rat.currentRound());
        for (uint256 k; k < tracked.length; ++k) {
            uint256 r = tracked[k];
            if (done[r]) continue;
            uint256 t = rat.closeTime(r);
            uint256[3] memory pts = [t, t + 13 minutes + 1, t + 23 minutes + 1];
            for (uint256 j; j < 3; ++j) if (pts[j] > now_ && pts[j] < next) next = pts[j];
        }
        vm.warp(next + bound(jitter, 0, 100));
        for (uint256 k; k < tracked.length; ++k) _duty(tracked[k], coin);
    }

    function _status(uint256 r) internal view returns (RobinAmongThieves.Status s) {
        (,,,,,,,,,, s,,,,,,,) = rat.rounds(r);
    }

    function _duty(uint256 r, uint8 coin) internal {
        if (done[r]) return;
        uint256 t = rat.closeTime(r);
        RobinAmongThieves.Status s = _status(r);
        if (s == RobinAmongThieves.Status.Open) {
            if (block.timestamp >= t + 8 minutes) {
                rat.cancelRound(r, 1000);
                ++cancels;
                done[r] = true;
            } else if (block.timestamp >= t && r >= 3 && coin % 8 != 0 && link < chain.length) {
                // the chain covers rounds from 3; earlier rounds are cancelled
                rat.revealSeed(r, chain[link++]);
                MockArbSys(address(0x64)).set(MockArbSys(address(0x64)).n() + 1);
                rat.pair(r, 1000);
                _checkPairs(r, t);
                if (_status(r) == RobinAmongThieves.Status.Finalized) done[r] = true;
            }
        } else if (s == RobinAmongThieves.Status.Paired && block.timestamp > t + 23 minutes) {
            _settle(r);
            _finalize(r);
            done[r] = true;
        } else if (s == RobinAmongThieves.Status.Settled) {
            _finalize(r);
            done[r] = true;
        } else if (s != RobinAmongThieves.Status.Paired) {
            done[r] = true;
        }
    }

    function _checkPairs(uint256 r, uint256 t) internal {
        (,,,,,, uint32 m,,,,,,,,,,,) = rat.rounds(r);
        for (uint256 i; i < m; ++i) {
            (uint256 a, uint256 b,,,,,,,) = rat.matches(r, i);
            (address ca,,, bool ha,) = _o(a);
            (address cb,,, bool hb,) = _o(b);
            if (ha && hb) houseMetHouse = true;
            if (ca == cb || idr.ownerOf(a) == idr.ownerOf(b)) sameOwnerMet = true;
            bytes32 key = rat.pairKey(a, b);
            if (ghostMet[key] != 0 && t < ghostMet[key] + 1 hours) metTooSoon = true;
            ghostMet[key] = t;
        }
    }

    function _settle(uint256 r) internal {
        uint256 n = actors.length;
        uint16[] memory before = new uint16[](n);
        for (uint256 i; i < n; ++i) (,,,,, before[i],,,,,,,,,) = rat.outlaws(ids[i]);
        vm.recordLogs();
        rat.settle(r, 1000);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 j; j < logs.length; ++j) {
            if (logs[j].topics[0] != RobinAmongThieves.MatchSettled.selector) continue;
            ++matchesSettled;
            (uint256 a, uint256 b,,, uint256 pa, uint256 pb, uint256 toPot, uint256 rake, bool ea, bool eb) = abi.decode(
                logs[j].data,
                (uint256, uint256, RobinAmongThieves.Choice, RobinAmongThieves.Choice, uint256, uint256, uint256, uint256, bool, bool)
            );
            if (pa + pb + toPot + rake != 10e6) overDraw = true; // I2
            bytes32 key = rat.pairKey(a, b);
            if (ea && !_wasEligible(a, before, key)) badEligibility = true;
            if (eb && !_wasEligible(b, before, key)) badEligibility = true;
        }
    }

    function _idx(uint256 id) internal view returns (uint256) {
        for (uint256 i; i < ids.length; ++i) if (ids[i] == id) return i;
        revert("unknown id");
    }

    function _wasEligible(uint256 id, uint16[] memory before, bytes32 key) internal view returns (bool) {
        (, uint64 at,,,,, bool house,,,,,,,,) = rat.outlaws(id);
        if (house) return false; // R6
        if (block.timestamp < uint256(at) + 24 hours) return false; // R4 age
        if (before[_idx(id)] < 5) return false; // R4 opponents
        uint256 lb = ghostPairBonus[key];
        return lb == 0 || block.timestamp >= lb + 24 hours; // R3
    }

    function _finalize(uint256 r) internal {
        uint256 potBefore = rat.sharingPot();
        uint256 draw = rat.drawBps();
        vm.recordLogs();
        rat.finalize(r, 1000);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 paid;
        uint256 day = block.timestamp / 1 days;
        uint256 lastId = type(uint256).max;
        for (uint256 j; j < logs.length; ++j) {
            if (logs[j].topics[0] != RobinAmongThieves.BonusPaid.selector) continue;
            uint256 id = uint256(logs[j].topics[2]);
            uint256 amt = abi.decode(logs[j].data, (uint256));
            ++bonusesPaid;
            paid += amt;
            if (amt > 2e6) bonusOverCap = true;
            dayBonus[id][day] += amt;
            if (dayBonus[id][day] > 6e6) bonusOverCap = true; // R2
            (,,,,,, bool house,,,,,,,,) = rat.outlaws(id);
            if (house) badEligibility = true; // R6
            // I9/R3 per pair: any bonus to either side of a match is that pair's bonus; at most one per 24h
            uint256 mid = rat.matchOf(r, id);
            if (lastId == type(uint256).max || rat.matchOf(r, lastId) != mid) {
                (uint256 a, uint256 b,,,,,,,) = rat.matches(r, mid - 1);
                bytes32 key = rat.pairKey(a, b);
                if (ghostPairBonus[key] != 0 && block.timestamp < ghostPairBonus[key] + 24 hours) pairBonusTwice = true;
                ghostPairBonus[key] = block.timestamp;
            }
            lastId = id;
        }
        if (paid > potBefore * draw / 10_000) overDraw = true; // R1, I3
    }
}

contract RatInvariants is Test {
    MockToken usdg;
    MockToken wif;
    GameConfig config;
    MockIdentity idr;
    MockReputation rep;
    RobinAmongThieves rat;
    RatHandler h;
    address owner = makeAddr("ownerSafe");
    address keeper = makeAddr("keeper");
    address houseSink = makeAddr("houseSink");
    address rakeSink = makeAddr("rakeSink");

    function setUp() public {
        uint256 t0 = 1_800_000_000;
        vm.warp(t0);
        vm.etch(address(0x64), address(new MockArbSys()).code);
        MockArbSys(address(0x64)).set(1);
        usdg = new MockToken("USDG", "USDG", 6);
        wif = new MockToken("WIF", "WIF", 18);
        config = new GameConfig(
            owner, address(usdg), 0, Tokens(address(wif), 5_000e18, address(wif)), Split(6000, 2000, 1750, 1750, 2500, 2500, 2500)
        );
        FairPass pass_ = new FairPass(IGameConfig(address(config)), owner);
        FairCore core_ = new FairCore(IERC20(address(usdg)), IGameConfig(address(config)), pass_, owner, 0);
        idr = new MockIdentity();
        rep = new MockReputation(idr);
        rat = new RobinAmongThieves(
            RobinAmongThieves.Params({
                usdg: usdg,
                config: IGameConfig(address(config)),
                core: IFairCore(address(core_)),
                identity: IIdentityRegistry(address(idr)),
                reputation: IReputationRegistry(address(rep)),
                owner: owner,
                timelockDelay: 0,
                bondDelay: 0,
                genesis: t0,
                keeper: keeper,
                rakeSink: rakeSink,
                houseSink: houseSink
            })
        );
        h = new RatHandler(rat, pass_, idr, usdg, wif, owner, keeper, houseSink);
        bytes32 tip = h.tip();
        vm.prank(keeper);
        rat.commitSeedChain(tip, 3);
        for (uint256 i; i < 8; ++i) h.addActor(address(uint160(0xA000 + i)), i >= 6); // two house outlaws
        h.seal();
        bytes4[] memory sel = new bytes4[](12);
        sel[0] = RatHandler.deposit.selector;
        sel[1] = RatHandler.setOperator.selector;
        sel[2] = RatHandler.enter.selector;
        sel[3] = RatHandler.commit.selector;
        sel[4] = RatHandler.reveal.selector;
        sel[5] = RatHandler.withdraw.selector;
        sel[6] = RatHandler.retire.selector;
        sel[7] = RatHandler.operatorAbuse.selector;
        sel[8] = RatHandler.bondAttempt.selector;
        sel[9] = RatHandler.pause.selector;
        sel[10] = RatHandler.flushRake.selector;
        sel[11] = RatHandler.step.selector;
        targetSelector(FuzzSelector({addr: address(h), selectors: sel}));
        targetContract(address(h));
    }

    /// Guards against a vacuous run: rounds really get paired, settled, finalized, cancelled, and bonuses get paid.
    function test_handlerCovers() public {
        for (uint256 i; i < 8; ++i) h.deposit(i, 60e6);
        // Start 23h in, so the outlaws pass the 24h bonus age during play; then ~20 hours of rounds. Sized to stay
        // under forge's default 2^30 test gas limit on every version (forge 1.8.x counts cheatcode gas).
        vm.warp(block.timestamp + 23 hours);
        for (uint256 k; k < 120; ++k) {
            for (uint256 i; i < 8; ++i) {
                h.enter(i, false);
                h.commit(i, uint8(i + k));
                h.reveal(i, (i + k) % 11 == 0);
            }
            h.step(uint8(k), uint8(k));
            if (k % 30 == 0) for (uint256 i; i < 8; ++i) h.deposit(i, 60e6);
        }
        assertGt(h.matchesSettled(), 40, "matches settled");
        assertGt(h.cancels(), 0, "some rounds cancelled");
        assertGt(h.bonusesPaid(), 0, "bonuses paid");
        invariant_I1_usdgConservation();
        invariant_ledgersMatchOutlaws();
        invariant_flags();
    }

    /// I1, and Σ deposits = Σ paid out + rake flushed + what RAT holds.
    function invariant_I1_usdgConservation() public view {
        uint256 held = usdg.balanceOf(address(rat));
        assertEq(held, rat.freeBalances() + rat.reservedStakes() + rat.sharingPot() + rat.rakePending(), "I1");
        assertEq(h.deposited(), h.paidOut() + h.flushed() + held, "deposits = withdrawn + rake + held");
    }

    /// Free balances and reserved stakes match the outlaws one by one (I4: no stranded stake); licences match locks (I5).
    function invariant_ledgersMatchOutlaws() public view {
        uint256 free;
        uint256 reserved;
        uint256 locked;
        uint256 bonds;
        for (uint256 i; i < h.actorCount(); ++i) {
            (address ctl,,, uint64 open,,,,,,, uint128 lic, uint128 b,, uint128 bond,) = rat.outlaws(h.ids(i));
            free += b;
            if (open != 0) reserved += 5e6;
            if (ctl != address(0)) locked += lic;
            bonds += bond;
        }
        assertEq(free, rat.freeBalances(), "free balances");
        assertEq(reserved, rat.reservedStakes(), "I4: reserved stakes");
        assertEq(locked, rat.lockedOf(address(wif)), "I5: licences");
        assertGe(wif.balanceOf(address(rat)), rat.lockedOf(address(wif)) + rat.claimableOf(address(wif)), "I5");
        assertEq(bonds, 0, "I12: no bond while disabled");
        assertFalse(rat.bondsEnabled());
    }

    /// I8: this contract never owns or is approved for any identity.
    function invariant_I8_neverOwnsIdentity() public view {
        for (uint256 i; i < h.actorCount(); ++i) {
            uint256 id = h.ids(i);
            assertTrue(idr.ownerOf(id) != address(rat));
            assertFalse(idr.isAuthorizedOrOwner(address(rat), id));
        }
    }

    /// I2, I3, I6, I7, I9, I10, I11, I12, I13, R1-R6, as recorded by the handler.
    function invariant_flags() public view {
        assertFalse(h.overDraw(), "I2/I3/R1");
        assertFalse(h.metTooSoon(), "I6: pair met twice within 1h");
        assertFalse(h.pauseBlocked(), "I7");
        assertFalse(h.bonusOverCap(), "I9/R2");
        assertFalse(h.badEligibility(), "I9/R3/R4/R6");
        assertFalse(h.pairBonusTwice(), "R3");
        assertFalse(h.houseLeak(), "I10");
        assertFalse(h.houseMetHouse(), "I11");
        assertFalse(h.sameOwnerMet(), "R5");
        assertFalse(h.bondTaken(), "I12");
        assertFalse(h.operatorMoved(), "I13");
    }
}
