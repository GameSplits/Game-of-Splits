// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {FairCore} from "./FairCore.sol";
import {FairPass} from "./FairPass.sol";
import {LastArrow} from "./LastArrow.sol";
import {SheriffsSeat} from "./SheriffsSeat.sol";
import {GameConfig} from "./GameConfig.sol";
import {Split} from "./interfaces/IFair.sol";

interface IVaultView {
    function heldOf(address token) external view returns (uint256);
    function launcher() external view returns (address);
}

/// @title FairLens
/// @notice Read-only, batched views for the site, share cards and keeper. Holds nothing, has no owner, changes nothing.
///         Every number comes from the other contracts' public getters; if anything here disagrees, they are the truth.
contract FairLens {
    FairCore public immutable core;
    FairPass public immutable pass;
    LastArrow public immutable arrow;
    SheriffsSeat public immutable seat;
    IVaultView public immutable vault;
    GameConfig public immutable config;

    /// @notice GameConfig's current values and any queued update (the site shows a banner while one is queued).
    struct Config {
        address playToken;
        uint256 passLock;
        address buyToken;
        uint64 epoch;
        Split split;
        address pendingPlayToken;
        uint256 pendingPassLock;
        address pendingBuyToken;
        uint256 tokensEta; // 0 = nothing queued
        Split pendingSplit;
        uint256 splitEta; // 0 = nothing queued
        uint64 anchorEpoch;
        bool anchorStale;
    }

    struct Greenwood {
        bool fairActive;
        uint256 fairId;
        bool salesPaused;
        uint256 accounted;
        uint256 usdgBalance;
        bool solvent;
        uint256 almsThisFair;
        uint256 almsCarriedIn; // part of almsThisFair that rolled in from earlier zero-vote Fairs
        uint256 bonfirePending;
        uint256 tollPending;
        uint256 vaultBuyPending;
        uint256 vaultBurnPending;
        uint256 vaultLiqUsdg;
        uint256 vaultFairsBurnUsdg;
        uint256 vaultBuyTokenHeld;
        uint256 vaultPlayTokenHeld;
        address vaultLauncher;
        uint256 anchorRate;
        address keeper;
    }

    struct ArrowView {
        uint256 roundId;
        LastArrow.Round round; // round.hardEnd is always 0 (no hard end). Do not display it. Use timeLeft.
        uint256 currentPrice;
        uint256 timeLeft;
        uint256 purse;
        uint256 rollover;
        LastArrow.Entry[] lastShots;
        /// L-6: pass this to `shoot` as expectedRound. It is roundId + 1 once roundId has ended (or before the first).
        uint256 expectedRound;
        bool live; // roundId is still taking shots
    }

    struct SeatView {
        uint256 dayId;
        uint256 dayEnd;
        address holder;
        uint64 since;
        uint128 lastPaid;
        uint256 price;
        uint256 purse;
        uint256 rollover;
        SheriffsSeat.Rank[3] top;
    }

    struct PlayerView {
        bool hasPass; // a pass in the current play token
        address passToken; // the token the pass was locked in (unlock returns this)
        uint256 passAmount;
        uint64 passSince;
        uint256 passUnlockableAt; // v3.6: 24h after the lock; the /pass page's countdown. 0 = no pass
        uint256 claimable;
        bool playedThisFair;
        uint32 arrowShotsThisRound;
        uint64 seatSecsToday;
    }

    /// @notice K-D01: the seat's day0 is in the future, so its day views would revert.
    error SeatNotStarted();

    constructor(FairCore core_, LastArrow arrow_, SheriffsSeat seat_, IVaultView vault_) {
        if (seat_.day0() > block.timestamp) revert SeatNotStarted();
        core = core_;
        pass = FairPass(address(core_.fairPass()));
        arrow = arrow_;
        seat = seat_;
        vault = vault_;
        config = GameConfig(address(core_.config()));
    }

    function configNow() public view returns (Config memory c) {
        (c.playToken, c.passLock, c.buyToken) = config.tokens();
        c.epoch = config.epoch();
        c.split = config.split();
        (c.pendingPlayToken, c.pendingPassLock, c.pendingBuyToken) = config.pendingTokens();
        c.tokensEta = config.tokensEta();
        c.pendingSplit = config.pendingSplit();
        c.splitEta = config.splitEta();
        c.anchorEpoch = core.anchorEpoch();
        c.anchorStale = core.anchorStale();
    }

    function greenwood() public view returns (Greenwood memory g) {
        (g.fairActive, g.fairId) = core.activeFair();
        g.salesPaused = core.salesPaused();
        g.accounted = core.accounted();
        g.usdgBalance = core.usdg().balanceOf(address(core));
        g.solvent = g.usdgBalance >= g.accounted;
        g.almsThisFair = core.almsByFair(g.fairId);
        g.almsCarriedIn = core.almsCarriedIn(g.fairId);
        g.bonfirePending = core.bonfirePending();
        g.tollPending = core.tollPending();
        g.vaultBuyPending = core.vaultBuyPending();
        g.vaultBurnPending = core.vaultBurnPending();
        g.vaultLiqUsdg = core.vaultLiqUsdg();
        g.vaultFairsBurnUsdg = core.vaultFairsBurnUsdg();
        if (address(vault) != address(0)) {
            (address play,, address buy) = config.tokens();
            g.vaultBuyTokenHeld = vault.heldOf(buy);
            g.vaultPlayTokenHeld = vault.heldOf(play);
            g.vaultLauncher = vault.launcher();
        }
        g.anchorRate = core.anchorRate();
        g.keeper = core.keeper();
    }

    function arrowNow() public view returns (ArrowView memory a) {
        a.roundId = arrow.currentRound();
        a.round = arrow.roundState(a.roundId);
        a.currentPrice = arrow.currentPrice();
        a.timeLeft = arrow.timeLeft();
        a.purse = core.pot(address(arrow), a.roundId);
        a.rollover = core.rollover(address(arrow));
        a.lastShots = arrow.lastShots(a.roundId);
        a.expectedRound = arrow.nextShotRound();
        a.live = a.expectedRound == a.roundId;
    }

    function seatNow() public view returns (SeatView memory s) {
        s.dayId = seat.today();
        s.dayEnd = seat.dayEnd(s.dayId);
        (s.holder, s.since, s.lastPaid) = seat.holderOf(s.dayId);
        s.price = seat.price();
        s.purse = core.pot(address(seat), s.dayId);
        s.rollover = core.rollover(address(seat));
        s.top = seat.leaderboard(s.dayId);
    }

    function player(address who) public view returns (PlayerView memory p) {
        p.hasPass = pass.hasPass(who);
        (, p.passToken, p.passAmount,) = pass.passOf(who);
        p.passSince = pass.heldSince(who);
        p.passUnlockableAt = pass.unlockableAt(who);
        p.claimable = core.claimable(who);
        (, uint256 fairId) = core.activeFair();
        p.playedThisFair = core.playedIn(fairId, who);
        p.arrowShotsThisRound = arrow.countOf(arrow.currentRound(), who);
        p.seatSecsToday = seat.secsOf(seat.today(), who);
    }

    /// @notice Everything the home page needs in one call (configNow() is separate to keep this one small).
    function fair(address who)
        external
        view
        returns (Greenwood memory g, ArrowView memory a, SeatView memory s, PlayerView memory p)
    {
        return (greenwood(), arrowNow(), seatNow(), player(who));
    }
}
