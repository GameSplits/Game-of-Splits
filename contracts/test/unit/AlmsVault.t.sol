// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Base} from "../Base.t.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {FairCore} from "../../src/FairCore.sol";
import {AlmsVote} from "../../src/AlmsVote.sol";
import {LocksleyVault, ICoreVaultUsdg} from "../../src/LocksleyVault.sol";
import {IFairCore} from "../../src/interfaces/IFair.sol";
import {MockToken} from "../mocks/Mocks.sol";

/// USDG that refuses one recipient, the way a blacklist does.
contract BlacklistingUsdg is ERC20 {
    address public blocked;

    constructor() ERC20("Global Dollar", "USDG") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function setBlocked(address a) external {
        blocked = a;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (to == blocked) revert("blacklisted");
        return super.transfer(to, amount);
    }
}

/// Stands in for FairCore's vault-USDG release. A blacklisted transfer reverts and leaves `pending` as it was.
contract ReleaseCore {
    BlacklistingUsdg public token;
    uint256 public pending;

    constructor(BlacklistingUsdg t) {
        token = t;
    }

    function load(uint256 amt) external {
        token.transferFrom(msg.sender, address(this), amt);
        pending += amt;
    }

    function releaseVaultUsdg(address to) external returns (uint256 amount) {
        amount = pending;
        pending = 0;
        token.transfer(to, amount);
    }
}

contract AlmsVaultTest is Base {
    AlmsVote alms;
    LocksleyVault vault;

    bytes32 constant RED = keccak256("red-cross-campaign");
    bytes32 constant BLUE = keccak256("blue-ocean-fund");
    bytes32 constant GREEN = keccak256("green-forest-trust");
    uint64 S;
    uint64 V;
    uint64 E;

    function wireBooths() internal override {
        alms = new AlmsVote(IFairCore(address(core)), owner, 24 hours, 24 hours);
        vault = new LocksleyVault(ICoreVaultUsdg(address(core)), owner);
        core.setupSet(FairCore.Op.SetAlmsVote, 0, address(alms));
        core.setupSet(FairCore.Op.SetVault, 0, address(vault));
    }

    function setUp() public override {
        super.setUp();
        (S, V, E) = (T0 + 2 days, T0 + 3 days, T0 + 4 days);
        bytes32[] memory ids = new bytes32[](3);
        (ids[0], ids[1], ids[2]) = (RED, BLUE, GREEN);
        vm.startPrank(owner);
        alms.setEligible(ids);
        alms.setAlmsWindows(0, S, V, E);
        vm.stopPrank();
        address[3] memory people = [ana, bob, cat];
        for (uint256 i; i < 3; ++i) {
            vm.prank(people[i]);
            pass.lock(address(wif), PASS_LOCK); // at T0, before suggestions open
        }
        openFair();
        shot(ana, 1, 100e6);
        shot(bob, 1, 100e6);
        shot(cat, 1, 100e6); // Alms for Fair 0: 24 USDG
    }

    function sug(address who, bytes32 id) internal {
        vm.prank(who);
        alms.suggest(0, id);
    }

    function vot(address who, bytes32 id) internal {
        vm.prank(who);
        alms.vote(0, id);
    }

    // ---------------------------------------------------------------- windows

    function test_AV01_rejectsZeroCharityId() public {
        bytes32[] memory z = new bytes32[](1);
        z[0] = bytes32(0);
        vm.prank(owner);
        vm.expectRevert(AlmsVote.ZeroId.selector);
        alms.setEligible(z);

        bytes32 ok = keccak256("ok-charity");
        bytes32[] memory mixed = new bytes32[](2);
        (mixed[0], mixed[1]) = (ok, bytes32(0));
        vm.prank(owner);
        vm.expectRevert(AlmsVote.ZeroId.selector);
        alms.setEligible(mixed);
        assertEq(alms.eligibleAt(ok), 0, "a reverted batch allowlists nothing");

        vm.prank(ana);
        vm.expectRevert(AlmsVote.ZeroId.selector);
        alms.suggest(0, bytes32(0));

        bytes32[] memory one = new bytes32[](1);
        one[0] = ok;
        vm.prank(owner);
        alms.setEligible(one);
        assertGt(alms.eligibleAt(ok), 0);
    }

    function test_windows_enforced() public {
        vm.prank(ana);
        vm.expectRevert(AlmsVote.WrongWindow.selector);
        alms.suggest(0, RED); // before suggestStart
        vm.warp(S);
        sug(ana, RED);
        vm.prank(bob);
        vm.expectRevert(AlmsVote.WrongWindow.selector);
        alms.vote(0, RED); // before voteStart
        vm.warp(V);
        vm.prank(bob);
        vm.expectRevert(AlmsVote.WrongWindow.selector);
        alms.suggest(0, BLUE); // suggestions closed
        vot(bob, RED);
        vm.warp(E);
        vm.prank(cat);
        vm.expectRevert(AlmsVote.WrongWindow.selector);
        alms.vote(0, RED); // vote closed
    }

    /// Audit W1: no one-second windows, no surprise windows, no endless postponement.
    function test_W1_windowRules() public {
        vm.startPrank(owner);
        core.setFair(1, T0 + 6 days, T0 + 36 days);
        uint64 n = uint64(vm.getBlockTimestamp());
        vm.expectRevert(AlmsVote.BadWindows.selector);
        alms.setAlmsWindows(1, T0 + 37 days, T0 + 37 days + 1, T0 + 37 days + 2); // 1-second windows
        vm.expectRevert(AlmsVote.BadWindows.selector);
        alms.setAlmsWindows(1, T0 + 37 days, T0 + 38 days, T0 + 38 days + 1 hours); // vote under a day
        vm.expectRevert(AlmsVote.BadWindows.selector);
        alms.setAlmsWindows(1, T0 + 37 days, T0 + 38 days, T0 + 51 days); // more than 14 days after the Fair
        vm.expectRevert(AlmsVote.BadWindows.selector);
        alms.setAlmsWindows(1, T0 + 5 days, T0 + 38 days, T0 + 39 days); // before Fair 1 starts
        vm.expectRevert(AlmsVote.BadWindows.selector);
        alms.setAlmsWindows(2, T0 + 70 days, T0 + 71 days, T0 + 72 days); // Fair 2 doesn't exist
        vm.warp(T0 + 36 days + 1 hours);
        vm.expectRevert(AlmsVote.BadWindows.selector);
        alms.setAlmsWindows(1, T0 + 36 days + 2 hours, T0 + 38 days, T0 + 39 days); // less than a day's notice
        alms.setAlmsWindows(1, T0 + 37 days + 2 hours, T0 + 38 days + 2 hours, T0 + 39 days + 2 hours); // ok
        vm.stopPrank();
        n;
    }

    /// Audit L-a: once a Fair is finalized (e.g. by the 7-day fallback), no new vote can be opened for it.
    function test_La_noWindowsAfterFinalize() public {
        uint64 f1 = T0 + 6 days;
        vm.prank(owner);
        core.setFair(1, f1, f1 + 30 days);
        vm.warp(f1 + 37 days);
        alms.finalize(1); // fallback: rolled
        vm.prank(owner);
        vm.expectRevert(AlmsVote.AlreadyFinalized.selector);
        alms.setAlmsWindows(1, f1 + 38 days, f1 + 39 days, f1 + 40 days);
    }

    /// Audit L-b: a Fair with vote windows set can't be moved with setFair.
    function test_Lb_cantMoveFairWithWindows() public {
        uint64 f1 = T0 + 6 days;
        vm.startPrank(owner);
        core.setFair(1, f1, f1 + 30 days);
        core.setFair(1, f1, f1 + 31 days); // no windows yet: still editable
        alms.setAlmsWindows(1, f1 + 32 days, f1 + 33 days, f1 + 34 days);
        vm.expectRevert(FairCore.WindowsSet.selector);
        core.setFair(1, f1 + 20 days, f1 + 50 days);
        vm.stopPrank();
    }

    /// Reschedule a Fair whose windows are set (e.g. Fair 0 right after deploy, if the hackathon moves):
    /// clear the windows before it starts, move it, set new windows that pass every rule again.
    function test_clearWindows_thenReschedule() public {
        uint64 f1 = T0 + 6 days;
        vm.startPrank(owner);
        core.setFair(1, f1, f1 + 30 days);
        alms.setAlmsWindows(1, f1 + 2 days, f1 + 3 days, f1 + 4 days);
        vm.expectRevert(FairCore.WindowsSet.selector);
        core.setFair(1, f1 + 7 days, f1 + 37 days);

        alms.clearWindows(1);
        assertFalse(alms.windowsSet(1));
        core.setFair(1, f1 + 7 days, f1 + 37 days); // now it moves
        vm.expectRevert(AlmsVote.BadWindows.selector);
        alms.setAlmsWindows(1, f1 + 2 days, f1 + 3 days, f1 + 4 days); // old windows now start before the Fair
        alms.setAlmsWindows(1, f1 + 9 days, f1 + 10 days, f1 + 11 days);
        vm.stopPrank();
        assertTrue(alms.windowsSet(1));
    }

    function test_clearWindows_rules() public {
        uint64 f1 = T0 + 6 days;
        vm.startPrank(owner);
        core.setFair(1, f1, f1 + 30 days);
        vm.expectRevert(AlmsVote.NoWindows.selector);
        alms.clearWindows(1); // nothing to clear
        alms.setAlmsWindows(1, f1 + 2 days, f1 + 3 days, f1 + 4 days);
        vm.stopPrank();

        vm.prank(ana);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", ana));
        alms.clearWindows(1); // owner only

        vm.warp(f1); // the Fair has started
        vm.prank(owner);
        vm.expectRevert(AlmsVote.WindowsLocked.selector);
        alms.clearWindows(1);

        vm.prank(owner);
        vm.expectRevert(AlmsVote.WindowsLocked.selector);
        alms.clearWindows(0); // Fair 0 is running (and its suggestions may be open): locked for good
    }

    function test_windows_lockedOnceOpen() public {
        vm.warp(S);
        vm.prank(owner);
        vm.expectRevert(AlmsVote.WindowsLocked.selector);
        alms.setAlmsWindows(0, S + 1 days, V + 1 days, E + 1 days);
    }

    // ---------------------------------------------------------------- who may suggest and vote

    function test_passLockedAfterSuggestStart_cantVote() public {
        address dan = makeAddr("dan");
        fund(dan);
        vm.warp(S + 1);
        vm.prank(dan);
        pass.lock(address(wif), PASS_LOCK); // too late
        // dan plays, so only the pass timing is wrong
        vm.prank(dan);
        booth.shot(dan, 1, 1e6);
        vm.prank(dan);
        vm.expectRevert(AlmsVote.NotEligibleVoter.selector);
        alms.suggest(0, RED);
    }

    function test_nonPlayer_cantVote() public {
        address eve = makeAddr("eve");
        fund(eve);
        vm.prank(eve);
        pass.lock(address(wif), PASS_LOCK); // early enough, but never shoots in Fair 0
        vm.warp(S);
        vm.prank(eve);
        vm.expectRevert(AlmsVote.NotPlayed.selector);
        alms.suggest(0, RED);
    }

    function test_unlockThenRelock_losesVote() public {
        vm.warp(S);
        sug(ana, RED);
        vm.startPrank(bob);
        pass.unlock();
        pass.lock(address(wif), PASS_LOCK); // heldSince is now after suggestStart
        vm.stopPrank();
        vm.warp(V);
        vm.prank(bob);
        vm.expectRevert(AlmsVote.NotEligibleVoter.selector);
        alms.vote(0, RED);
    }

    function test_charityMustBeAllowlistedBeforeWindow() public {
        bytes32 late = keccak256("added-too-late");
        vm.warp(S);
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = late;
        vm.prank(owner);
        alms.setEligible(ids);
        vm.prank(ana);
        vm.expectRevert(AlmsVote.NotEligibleCharity.selector);
        alms.suggest(0, late);
        vm.prank(ana);
        vm.expectRevert(AlmsVote.NotEligibleCharity.selector);
        alms.suggest(0, keccak256("never-listed"));
    }

    function test_oneSuggestion_oneVote_perWallet() public {
        vm.warp(S);
        sug(ana, RED);
        vm.prank(ana);
        vm.expectRevert(AlmsVote.AlreadySuggested.selector);
        alms.suggest(0, BLUE);
        vm.prank(bob);
        vm.expectRevert(AlmsVote.AlreadySuggested.selector);
        alms.suggest(0, RED); // already on the list
        vm.warp(V);
        vot(bob, RED);
        vm.prank(bob);
        vm.expectRevert(AlmsVote.AlreadyVoted.selector);
        alms.vote(0, RED);
        vm.prank(cat);
        vm.expectRevert(AlmsVote.NotSuggested.selector);
        alms.vote(0, GREEN);
    }

    // ---------------------------------------------------------------- outcomes

    function test_mostVotesWins() public {
        vm.warp(S);
        sug(ana, RED);
        sug(bob, BLUE);
        vm.warp(V);
        vot(ana, BLUE);
        vot(bob, BLUE);
        vot(cat, RED);
        vm.warp(E);
        alms.finalize(0);
        (,,,, bool fin, bytes32 winner,) = alms.results(0);
        assertTrue(fin);
        assertEq(winner, BLUE);
    }

    function test_tie_earliestSuggestionWins() public {
        vm.warp(S);
        sug(ana, RED);
        sug(bob, BLUE);
        vm.warp(V);
        vot(cat, BLUE); // BLUE leads 1-0
        vot(ana, RED); // 1-1: RED was suggested first
        vm.warp(E);
        alms.finalize(0);
        (,,,,, bytes32 winner,) = alms.results(0);
        assertEq(winner, RED);
    }

    /// Zero votes: nobody chooses. Fair 0's Alms carry into Fair 1 and add to Fair 1's vote.
    function test_zeroVotes_carryToNextFair_thenVoted() public {
        vm.warp(S);
        sug(bob, BLUE); // suggested but nobody votes
        vm.warp(E);
        alms.finalize(0);
        (,,,, bool fin, bytes32 winner,) = alms.results(0);
        assertTrue(fin);
        assertEq(winner, bytes32(0), "no winner");
        assertEq(alms.releaseAlms(0), 24e6, "carried");
        assertEq(core.almsByFair(0), 0);
        assertEq(core.almsByFair(1), 24e6);
        assertEq(core.almsCarriedIn(1), 24e6, "label: includes 24 carried");
        assertEq(usdg.balanceOf(almsSafe), 0, "nothing paid out without a vote");

        // Fair 1: players vote, and the winner gets Fair 1's own Alms plus the carried 24
        uint64 f1 = T0 + 6 days;
        vm.startPrank(owner);
        core.setFair(1, f1, f1 + 30 days);
        alms.setAlmsWindows(1, f1 + 31 days, f1 + 32 days, f1 + 33 days);
        vm.stopPrank();
        vm.warp(f1);
        shot(ana, 1, 100e6); // + 8 for Fair 1
        shot(bob, 1, 100e6); // + 8
        vm.warp(f1 + 31 days);
        vm.prank(ana);
        alms.suggest(1, RED);
        vm.warp(f1 + 32 days);
        vm.prank(bob);
        alms.vote(1, RED);
        vm.warp(f1 + 33 days);
        alms.finalize(1);
        assertEq(alms.releaseAlms(1), 24e6 + 16e6);
        assertEq(usdg.balanceOf(almsSafe), 40e6);
    }

    /// Two silent Fairs in a row: the Alms keep accumulating.
    function test_zeroVotes_accumulateAcrossFairs() public {
        vm.warp(E);
        alms.finalize(0); // no suggestions at all
        alms.releaseAlms(0);
        uint64 f1 = T0 + 6 days;
        vm.startPrank(owner);
        core.setFair(1, f1, f1 + 30 days);
        alms.setAlmsWindows(1, f1 + 31 days, f1 + 32 days, f1 + 33 days);
        vm.stopPrank();
        vm.warp(f1);
        shot(ana, 1, 50e6); // + 4
        vm.warp(f1 + 33 days);
        alms.finalize(1);
        alms.releaseAlms(1);
        assertEq(core.almsByFair(2), 24e6 + 4e6, "both Fairs' Alms now wait for Fair 2's vote");
        assertEq(core.almsCarriedIn(2), 24e6 + 4e6, "all of Fair 2's Alms so far came carried");
    }

    /// Shots after a zero-vote finalize (Fair 0's vote ends mid-Fair) carry too, as later tranches.
    function test_zeroVotes_laterShotsCarryAsTranches() public {
        vm.warp(E);
        alms.finalize(0);
        alms.releaseAlms(0);
        shot(ana, 1, 100e6); // Fair 0 still running
        assertEq(alms.releaseAlms(0), 8e6);
        assertEq(core.almsByFair(1), 32e6);
    }

    /// Audit R1 item 5: a Fair whose windows were never set rolls its Alms 7 days after it ends.
    function test_windowsNeverSet_rollsAfter7Days() public {
        uint64 f1 = T0 + 6 days;
        vm.prank(owner);
        core.setFair(1, f1, f1 + 30 days);
        vm.warp(f1);
        shot(ana, 1, 100e6); // Fair 1 Alms: 8
        vm.warp(f1 + 30 days + 7 days - 1);
        vm.expectRevert(AlmsVote.WrongWindow.selector);
        alms.finalize(1);
        vm.warp(f1 + 37 days);
        alms.finalize(1);
        alms.releaseAlms(1);
        assertEq(core.almsByFair(2), 8e6, "rolled into Fair 2 with nobody's say-so");
    }

    /// No owner path names a winner or moves the Alms: the owner can't carry, release, or reach FairCore's Alms.
    function test_ownerHasNoPathToAlms() public {
        vm.startPrank(owner);
        vm.expectRevert(FairCore.NotAlmsVote.selector);
        core.releaseAlms(0);
        vm.expectRevert(FairCore.NotAlmsVote.selector);
        core.carryAlms(0);
        // K16-A05: the Alms Safe can move, but only in public view through the 48h timelock
        core.queue(FairCore.Op.SetAlmsSafe, 0, owner);
        vm.expectPartialRevert(FairCore.TooEarly.selector);
        core.execute(FairCore.Op.SetAlmsSafe, 0, owner);
        vm.expectRevert(FairCore.SetupOnly.selector);
        core.queue(FairCore.Op.SetAlmsVote, 0, owner);
        vm.stopPrank();
        assertEq(core.almsByFair(0), 24e6);
    }

    function test_carryAlms_onlyAlmsVote() public {
        vm.prank(owner);
        vm.expectRevert(FairCore.NotAlmsVote.selector);
        core.carryAlms(0);
    }

    function test_release_tranches_sameWinner_sumMatches() public {
        vm.warp(S);
        sug(ana, RED);
        vm.warp(V);
        vot(bob, RED);
        vm.warp(E);
        vm.expectRevert(AlmsVote.NotFinalized.selector);
        alms.releaseAlms(0);
        alms.finalize(0);
        vm.expectRevert(AlmsVote.AlreadyFinalized.selector);
        alms.finalize(0);

        uint256 first = alms.releaseAlms(0); // early tranche
        assertEq(first, 24e6);
        shot(ana, 1, 50e6); // shots after the vote keep feeding Fair 0's Alms
        uint256 second = alms.releaseAlms(0); // remainder
        assertEq(second, 4e6);
        assertEq(usdg.balanceOf(almsSafe), first + second, "everything went to the Alms Safe");
        (,,,,, bytes32 winner, uint32 tranches) = alms.results(0);
        assertEq(winner, RED);
        assertEq(tranches, 2);
        assertEq(alms.releaseAlms(0), 0, "nothing left");
    }

    function test_releaseWorksWhilePaused() public {
        vm.warp(S);
        sug(ana, RED);
        vm.warp(V);
        vot(bob, RED);
        vm.warp(E);
        alms.finalize(0);
        vm.prank(owner);
        core.pauseSales(true);
        assertEq(alms.releaseAlms(0), 24e6);
    }

    // ---------------------------------------------------------------- Locksley Vault

    function _toks() internal view returns (IERC20[] memory t) {
        t = new IERC20[](1);
        t[0] = IERC20(address(wif));
    }

    function _fillVault() internal {
        uint256 full = 10e6 * route.rate();
        vm.prank(keeper);
        core.buyForVault(0, 10e6, full);
    }

    function test_vault_holdsWif_andNothingMovesIt() public {
        _fillVault();
        uint256 held = wif.balanceOf(address(vault));
        assertGt(held, 0);
        vm.prank(owner);
        vm.expectRevert(LocksleyVault.NotLauncher.selector);
        vault.pull(_toks()); // owner can't pull
        vm.prank(owner);
        vm.expectRevert(FairCore.NotVault.selector);
        core.releaseVaultUsdg(owner);
        assertEq(wif.balanceOf(address(vault)), held);
        assertEq(core.vaultUsdg(), 13.5e6 * 2, "two USDG quarters of 300 USDG of shots");
    }

    function test_launcher_7dayTimelock_oneTime() public {
        _fillVault();
        address l = makeAddr("launcher");
        vm.startPrank(owner);
        vm.expectRevert(LocksleyVault.NotQueued.selector);
        vault.attachLauncher();
        vault.queueLauncher(l);
        vm.warp(vm.getBlockTimestamp() + 7 days - 1);
        vm.expectPartialRevert(LocksleyVault.TooEarly.selector);
        vault.attachLauncher();
        vm.warp(vm.getBlockTimestamp() + 1);
        vault.attachLauncher();
        vm.expectRevert(LocksleyVault.AlreadyAttached.selector);
        vault.queueLauncher(makeAddr("second"));
        vm.stopPrank();

        uint256 held = wif.balanceOf(address(vault));
        uint256 owedUsdg = core.vaultUsdg();
        vm.prank(l);
        (uint256[] memory w, uint256 u) = vault.pull(_toks());
        assertEq(w[0], held);
        assertEq(u, owedUsdg);
        assertEq(wif.balanceOf(l), held);
        assertEq(usdg.balanceOf(l), owedUsdg);
        assertSolvent();
    }

    function test_launcher_cancel() public {
        vm.startPrank(owner);
        vault.queueLauncher(makeAddr("l"));
        vault.cancelLauncher();
        vm.warp(vm.getBlockTimestamp() + 8 days);
        vm.expectRevert(LocksleyVault.NotQueued.selector);
        vault.attachLauncher();
        vm.stopPrank();
    }

    /// The Vault keeps what it bought in every epoch, and the launcher pulls each listed token in one call.
    function test_vault_pullsEveryListedToken() public {
        _fillVault(); // wif, epoch 0
        applyTokens(address(tokenB), 5_000e18, address(tokenB));
        reseed(routeB.rate() * 1e18);
        uint256 fullB = 3e6 * routeB.rate();
        vm.prank(keeper);
        core.buyForVault(1, 3e6, fullB);
        uint256 heldA = wif.balanceOf(address(vault));
        uint256 heldB = tokenB.balanceOf(address(vault));
        assertGt(heldA, 0);
        assertEq(heldB, fullB);
        assertEq(vault.heldOf(IERC20(address(tokenB))), fullB);

        IERC20[] memory t = new IERC20[](2);
        (t[0], t[1]) = (IERC20(address(wif)), IERC20(address(tokenB)));
        address l = makeAddr("launcher");
        vm.startPrank(owner);
        vault.queueLauncher(l);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        vault.attachLauncher();
        vm.stopPrank();

        vm.prank(ana);
        vm.expectRevert(LocksleyVault.NotLauncher.selector);
        vault.pull(t);
        vm.prank(owner);
        vm.expectRevert(LocksleyVault.NotLauncher.selector);
        vault.pull(t);

        vm.prank(l);
        (uint256[] memory got,) = vault.pull(t);
        assertEq(got[0], heldA);
        assertEq(got[1], heldB);
        assertEq(wif.balanceOf(l), heldA);
        assertEq(tokenB.balanceOf(l), heldB);
        assertEq(wif.balanceOf(address(vault)) + tokenB.balanceOf(address(vault)), 0);
        assertSolvent();
    }

    /// GameConfig has no path to Vault funds: executing any update leaves the Vault's balances alone.
    function test_configUpdate_neverTouchesVault() public {
        _fillVault();
        uint256 held = wif.balanceOf(address(vault));
        uint256 owed = core.vaultUsdg();
        applyTokens(address(tokenB), 5_000e18, address(tokenB));
        assertEq(wif.balanceOf(address(vault)), held);
        assertEq(core.vaultUsdg(), owed);
        assertEq(vault.launcher(), address(0));
        vm.prank(address(config));
        vm.expectRevert(LocksleyVault.NotLauncher.selector);
        vault.pull(_toks());
    }

    /// A USDG blacklist on the launcher reverts the release. The bought tokens still move, and the USDG
    /// stays pending until the launcher names a recipient the token will accept.
    function test_LV01_revertingUsdgDoesNotFreezeTokenPull() public {
        BlacklistingUsdg usd = new BlacklistingUsdg();
        ReleaseCore rc = new ReleaseCore(usd);
        LocksleyVault v = new LocksleyVault(ICoreVaultUsdg(address(rc)), owner);
        address launcher = makeAddr("launcher");
        address other = makeAddr("other");
        vm.startPrank(owner);
        v.queueLauncher(launcher);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        v.attachLauncher();
        vm.stopPrank();

        MockToken tok = new MockToken("Bought", "BOUGHT", 18);
        tok.mint(address(v), 1000e18);
        usd.mint(address(this), 25e6);
        usd.approve(address(rc), 25e6);
        rc.load(25e6);
        usd.setBlocked(launcher);

        IERC20[] memory tokens = _toksOf(tok);
        vm.prank(launcher);
        vm.expectRevert(LocksleyVault.ZeroAddress.selector);
        v.pull(tokens, address(0));

        vm.prank(launcher);
        (uint256[] memory amounts, uint256 usdgAmount) = v.pull(tokens);
        assertEq(amounts[0], 1000e18);
        assertEq(tok.balanceOf(launcher), 1000e18, "token pull is not frozen");
        assertEq(usdgAmount, 0);
        assertEq(rc.pending(), 25e6, "USDG stays pending in FairCore");
        assertEq(usd.balanceOf(address(rc)), 25e6);

        vm.prank(launcher);
        (amounts, usdgAmount) = v.pull(tokens, other);
        assertEq(amounts[0], 0, "the tokens were already pulled");
        assertEq(usdgAmount, 25e6);
        assertEq(usd.balanceOf(other), 25e6, "USDG is claimable to another recipient");
        assertEq(rc.pending(), 0);
        assertEq(tok.balanceOf(address(v)), 0);
    }

    function _toksOf(IERC20 t) internal pure returns (IERC20[] memory tokens) {
        tokens = new IERC20[](1);
        tokens[0] = t;
    }
}
