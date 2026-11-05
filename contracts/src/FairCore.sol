// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {SafeHandover} from "./SafeHandover.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IFairPass, IBuyRoute, IGameConfig, Split} from "./interfaces/IFair.sol";

interface IAlmsWindows {
    function windowsSet(uint256 fairId) external view returns (bool);
}

/// @title FairCore
/// @notice Holds all USDG. Every shot is split once here, by GameConfig's split (at launch: 60% to that booth round's
///         Purse, 40% to the Greenwood: Locksley Vault 45%, the Alms 20%, the Bonfire 17.5%, the Toll 17.5%). Booths
///         only keep score and report winners; winners pull from here. No loops over users. No owner function can touch
///         Purses, rollovers, claimable balances or the Alms. The keeper buys GameConfig's buy token.
///         Fee-on-transfer and rebasing buy tokens are unsupported. See `_swap`.
contract FairCore is SafeHandover, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ------------------------------------------------------------------ constants
    uint256 public constant BPS = 10_000;
    uint256 public constant MAX_SWAP_USDG = 250e6; // per keeper call
    uint256 public constant RATCHET_BPS = 9500; // minOut >= 95% of the price anchor
    uint256 public constant ANCHOR_DECAY_BPS_PER_HOUR = 100; // the anchor only falls with time: 1% per hour
    uint256 public constant MAX_ANCHOR_RAISE_BPS = 200; // the anchor rises by at most 2% per RAISE_WINDOW
    uint64 public constant RAISE_WINDOW = 4 hours; // slower than the 1%/hour decay, shared by all three ledgers
    uint256 public constant MAX_DECAY_BPS = 3000; // ...and never below 70% without the Safe (floor never below 66.5%)
    /// @notice A1-12: after setup a reset goes through the timelock and, while an anchor is live in the current
    ///         GameConfig epoch, lands within ±30% of the stored (undecayed) anchor at execute time. 30% matches
    ///         MAX_DECAY_BPS: a reset can always restore the last price, or follow a move of up to 30%. A bigger move
    ///         takes a second queued reset (another timelockDelay; only one reset can be pending at a time), so a compromised or mistaken Safe can't set the
    ///         floor to ~0 or freeze buys in one step, and the watcher sees every reset 48h ahead. With no live anchor
    ///         (a new epoch, i.e. a new buy token, which itself waited out GameConfig's 7-day delay) the new token has
    ///         no reference price, so the value is unbounded but still timelocked; queue it during the GameConfig wait
    ///         so buybacks resume on time.
    uint256 public constant MAX_RESET_BPS = 3000;
    uint64 public constant MIN_SWAP_GAP = 50 minutes; // per ledger
    /// @notice Minimum time between new pause starts. Unpause is never limited, and the first pause is immediate.
    uint64 public constant MIN_PAUSE_GAP = 10 minutes;
    uint256 public constant DAILY_SWAP_CAP = 3_000e6; // per ledger per UTC day (busiest example day needs ~2,200)
    uint256 public constant MAX_WINNERS = 12;
    uint256 public constant MAINNET_TIMELOCK = 48 hours;
    /// @notice A chapter lasts at most 35 days, so a mistyped `end` (say, milliseconds) can't keep a chapter running for good
    ///         and with it block GameConfig updates, which execute only between chapters.
    uint64 public constant MAX_FAIR_LENGTH = 35 days;
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    enum BurnSource {
        Bonfire,
        Vault
    }

    /// @dev The three keeper ledgers, each rate-limited and capped on its own.
    uint8 internal constant L_BONFIRE = 0;
    uint8 internal constant L_VAULT_BURN = 1;
    uint8 internal constant L_VAULT_BUY = 2;

    enum Op {
        AddBooth,
        SetKeeper,
        SetTollRecipient,
        SetAlmsSafe,
        SetRoute,
        SetAlmsVote,
        SetVault,
        // Appended (fix/security-four), so the earlier ordinals and their queued op ids keep their meaning.
        RemoveBooth, // A1-11: value = the booth to switch off
        ResetRatchet // A1-12: key = the new anchor, value = address(0)
    }

    struct Fair {
        uint64 start;
        uint64 end;
    }

    // ------------------------------------------------------------------ immutables
    IERC20 public immutable usdg;
    IGameConfig public immutable config;
    IFairPass public immutable fairPass;
    uint256 public immutable timelockDelay;

    // ------------------------------------------------------------------ roles and config
    mapping(address => bool) public isBooth;
    /// @notice A1-11: booths added during setup (Last Arrow, Sheriff's Seat). Every player already trusts these; their
    ///         USDG approval to FairCore was given for them.
    mapping(address => bool) public isLaunchBooth;
    /// @notice A1-11: payer => booth => USDG that booth may still pull (type(uint256).max = unlimited). A booth added
    ///         after setup (through the timelock) can only take a payer's USDG up to what that payer approved for it
    ///         here, so a new booth can't spend the FairCore approval given for the launch booths.
    ///         K16-A03: keyed by the booth's generation, so removing a booth voids every allowance given for it and
    ///         a re-added booth needs fresh approval. Read it with boothAllowance(payer, booth).
    mapping(address => mapping(address => mapping(uint32 => uint256))) internal _boothAllowance;
    /// @notice Bumped each time a booth is removed.
    mapping(address => uint32) public boothGen;
    address public keeper;
    address public tollRecipient;
    address public almsSafe;
    address public almsVote;
    address public vault; // LocksleyVault: receives bought tokens, and is the only caller that can release Vault USDG
    mapping(uint256 => IBuyRoute) public routes;
    bool public setupDone;
    bool public salesPaused;
    mapping(bytes32 => uint256) public queuedAt; // op hash => eta (0 = not queued)
    /// @notice The one ResetRatchet op that may be pending (0 = none), so resets can't be stacked to walk the anchor.
    bytes32 public pendingReset;

    // ------------------------------------------------------------------ fairs
    mapping(uint256 => Fair) public fairs;
    uint256 public fairCount;
    mapping(uint256 => mapping(address => bool)) public playedIn;
    /// @notice A5-01: gross USDG shot by (credited to) a player in a chapter.
    mapping(uint256 => mapping(address => uint256)) public spentIn;
    /// @notice K16-D-A01: USDG awarded to a player from rounds that took their first shot in a chapter.
    mapping(uint256 => mapping(address => uint256)) public wonIn;
    /// @notice The chapter a booth round belongs to (the chapter of its first shot).
    mapping(address => mapping(uint256 => uint256)) public roundFair;

    // ------------------------------------------------------------------ prize money
    mapping(address => mapping(uint256 => uint256)) public pot; // booth => roundKey => Purse
    mapping(address => mapping(uint256 => bool)) public awarded;
    mapping(address => mapping(uint256 => bool)) public seeded;
    mapping(address => uint256) public rollover; // booth => unpaid shares waiting to seed its next round
    mapping(address => uint256) public claimable;

    // ------------------------------------------------------------------ Greenwood ledgers (USDG)
    mapping(uint256 => uint256) public almsByFair;
    /// @notice How much of a chapter's Alms came carried from earlier zero-vote chapters (for the "includes N carried" label).
    mapping(uint256 => uint256) public almsCarriedIn;
    /// @notice K16-A05: released Alms whose transfer to the Alms Safe failed (say, a USDG blocklist). Still owed;
    ///         anyone can push it to the current Alms Safe with flushAlms().
    uint256 public almsEscrow;
    uint256 public bonfirePending;
    uint256 public tollPending;
    uint256 public vaultLiqUsdg; // future $FAIRS/USDG pool side
    uint256 public vaultBuyPending; // buy the buy token and hold it in the Vault
    uint256 public vaultBurnPending; // buy the buy token and burn it
    uint256 public vaultFairsBurnUsdg; // future $FAIRS buy-and-burn

    /// @notice Every USDG the contract owes or has earmarked. Invariant: usdg.balanceOf(this) >= accounted.
    uint256 public accounted;
    /// @notice Buyback price anchor: buy-token wei per USDG unit (6 dp), scaled by 1e18. 0 = no history.
    ///         It rises with the keeper's quote by at most 2% per 4-hour window (all three ledgers share that cap),
    ///         and only falls with time (1% per hour), never below 70% of the high-water `anchorBase` (M-2), so a
    ///         stolen keeper key can't walk it down, and a run of
    ///         manipulated quotes can't compound the floor above the market. A genuine rally above the floor pauses
    ///         buybacks until the decay catches up (about 1% per hour) or the Safe resets it; the USDG waits meanwhile.
    ///         The anchor belongs to the GameConfig epoch it was set in: in any other epoch it counts as unset, and
    ///         buybacks revert NotSeeded until the Safe calls resetRatchet.
    uint256 public anchorRate;
    uint64 public anchorAt;
    uint64 public anchorEpoch;
    /// @notice Decayed anchor at the start of the current raise window. Quotes in the window cannot lift the
    ///         anchor above `raiseBase * (BPS + MAX_ANCHOR_RAISE_BPS) / BPS`.
    uint256 public raiseBase;
    uint64 public raiseWindowStart;
    mapping(uint8 => uint64) public lastSwapAt;
    mapping(uint8 => mapping(uint256 => uint256)) public swappedOnDay; // ledger => UTC day => USDG

    // pause bookkeeping, so booths can stop their clocks while sales are paused
    uint64 public pausedSince;
    uint64 public pausedTotal;
    struct Pause {
        uint64 start;
        uint64 end; // 0 while the pause is still running
    }
    Pause[] internal pauseLog;
    /// @notice M-2: high-water anchor in the current GameConfig epoch. Set by every reset and raised whenever a quote
    ///         lands above it. `decayedAnchor()` never goes below 70% of it, and reset bounds are measured from it.
    uint256 public anchorBase;

    // ------------------------------------------------------------------ events
    event Shot(
        uint256 indexed fairId,
        address indexed booth,
        uint256 indexed roundKey,
        address player,
        address payer,
        uint256 gross,
        uint256 purse,
        uint256 greenwood
    );
    event Seeded(address indexed booth, uint256 indexed roundKey, uint256 amount);
    event Awarded(address indexed booth, uint256 indexed roundKey, address indexed winner, uint256 amount, uint256 rank);
    event RolledOver(address indexed booth, uint256 indexed fromKey, uint256 amount);
    event Claimed(address indexed player, uint256 amount);
    event ClaimedTo(address indexed player, address indexed to, uint256 amount);
    event Burned(address indexed token, uint8 indexed source, uint256 route, uint256 usdgIn, uint256 out, uint256 minOut);
    event BoughtForVault(address indexed token, uint256 route, uint256 usdgIn, uint256 out, uint256 minOut);
    event TollWithdrawn(address indexed to, uint256 amount);
    event AlmsReleased(uint256 indexed fairId, address indexed to, uint256 amount);
    event AlmsEscrowed(uint256 indexed fairId, address indexed to, uint256 amount);
    event AlmsFlushed(address indexed to, uint256 amount);
    event AlmsCarried(uint256 indexed fromFair, uint256 indexed toFair, uint256 amount);
    event VaultUsdgReleased(address indexed to, uint256 amount);
    event FairSet(uint256 indexed fairId, uint64 start, uint64 end);
    event SalesPaused(bool paused);
    event OpQueued(bytes32 indexed id, Op op, uint256 key, address value, uint256 eta);
    event OpExecuted(bytes32 indexed id, Op op, uint256 key, address value);
    event OpCancelled(bytes32 indexed id);
    event BoothAdded(address indexed booth);
    event BoothRemoved(address indexed booth);
    event BoothApproval(address indexed payer, address indexed booth, uint256 amount);
    event KeeperSet(address indexed keeper);
    event TollRecipientSet(address indexed to);
    event AlmsSafeSet(address indexed to);
    event AlmsVoteSet(address indexed almsVote);
    event VaultSet(address indexed vault);
    event RouteSet(uint256 indexed index, address route);
    event RatchetReset(uint256 newAnchor, uint64 epoch);
    event ExcessSwept(address indexed token, address indexed to, uint256 amount);
    event SetupDone();

    // ------------------------------------------------------------------ errors
    error NotBooth();
    error NotKeeper();
    error NotAlmsVote();
    error NotVault();
    error Paused();
    error PauseTooSoon();
    error NoActiveFair();
    error ZeroAmount();
    error AlreadyAwarded();
    error OverPot();
    error BadArrays();
    error OverCap();
    error OverLedger();
    error ZeroMinOut();
    error RatchetTripped(uint256 minOut, uint256 floor);
    error ShortFill(uint256 got, uint256 minOut);
    error NoRoute();
    error TransferMismatch();
    error ZeroAddress();
    error SetupClosed();
    error SetupOpen();
    error NotQueued();
    error TooEarly(uint256 eta);
    error BadFair();
    error FairStarted();
    error RenounceDisabled();
    error NothingToClaim();
    error TooSoon(uint256 next);
    error DailyCap();
    error SetupOnly();
    error WindowsSet();
    error NotSeeded();
    error RouteTokenMismatch();
    error ConfigMismatch();
    error BoothNotApproved();
    error BadOpValue();
    error ResetOutOfBounds(uint256 newAnchor, uint256 lo, uint256 hi);
    error ResetPending(bytes32 id);
    error LowGas();

    // ------------------------------------------------------------------ construction
    /// @param timelockDelay_ 48h on mainnet (enforced), anything on other chains (0 on testnet for fast iteration).
    constructor(IERC20 usdg_, IGameConfig config_, IFairPass fairPass_, address owner_, uint256 timelockDelay_)
        Ownable(owner_)
    {
        if (address(usdg_) == address(0) || address(config_) == address(0) || address(fairPass_) == address(0)) {
            revert ZeroAddress();
        }
        if (config_.usdg() != address(usdg_)) revert ConfigMismatch();
        if (block.chainid == 4663 && timelockDelay_ < MAINNET_TIMELOCK) revert TooEarly(MAINNET_TIMELOCK);
        usdg = usdg_;
        config = config_;
        fairPass = fairPass_;
        timelockDelay = timelockDelay_;
    }

    modifier onlyBooth() {
        if (!isBooth[msg.sender]) revert NotBooth();
        _;
    }

    modifier onlyKeeper() {
        if (msg.sender != keeper) revert NotKeeper();
        _;
    }

    // ================================================================== views

    /// @notice The chapter running now, if any. chapters never overlap, so only the newest two can be live.
    function activeFair() public view returns (bool active, uint256 fairId) {
        uint256 n = fairCount;
        for (uint256 i; i < 2 && i < n; ++i) {
            uint256 id = n - 1 - i;
            Fair memory f = fairs[id];
            if (block.timestamp >= f.start && block.timestamp < f.end) return (true, id);
        }
    }

    /// @notice Total seconds sales have been paused, including a pause still running. Booths use it to stop clocks.
    function pausedSeconds() public view returns (uint256) {
        return pausedTotal + (salesPaused ? block.timestamp - pausedSince : 0);
    }

    function pauseCount() external view returns (uint256) {
        return pauseLog.length;
    }

    /// @notice Seconds of pause overlapping [from, to], counting pauses from log index `fromIdx` on.
    ///         The log is append-only and `start` is non-decreasing, so the scan stops at the first entry that
    ///         begins at or after `to`. A closed entry that ended by `from` adds nothing and is skipped.
    ///         `end == 0` is a pause that is still running, not an entry that ended at time zero.
    function pausedBetween(uint256 fromIdx, uint256 from, uint256 to) external view returns (uint256 total) {
        uint256 n = pauseLog.length;
        for (uint256 i = fromIdx; i < n; ++i) {
            Pause memory p = pauseLog[i];
            if (p.start >= to) break;
            if (p.end != 0 && p.end <= from) continue;
            uint256 s = p.start > from ? p.start : from;
            uint256 e = p.end == 0 ? block.timestamp : p.end;
            if (e > to) e = to;
            if (e > s) total += e - s;
        }
    }

    function vaultUsdg() external view returns (uint256) {
        return vaultLiqUsdg + vaultFairsBurnUsdg;
    }

    /// @notice K16-D-A01: what a player has really put into a chapter: gross shots minus winnings from that chapter's rounds
    ///         (never below 0). Washing a shot through a round you win back no longer counts. AlmsVote's minimum uses it.
    function netSpentIn(uint256 fairId, address player) external view returns (uint256) {
        uint256 s = spentIn[fairId][player];
        uint256 w = wonIn[fairId][player];
        return s > w ? s - w : 0;
    }

    /// @notice What `booth` (added after setup) may still pull from `payer`, for the booth's current generation.
    function boothAllowance(address payer, address booth) public view returns (uint256) {
        return _boothAllowance[payer][booth][boothGen[booth]];
    }

    /// @notice What the keeper buys right now (GameConfig's buy token).
    function buyToken() public view returns (address t) {
        (,, t) = config.tokens();
    }

    /// @notice True when buybacks are closed for want of an anchor in the current GameConfig epoch.
    function anchorStale() external view returns (bool) {
        return anchorRate == 0 || anchorEpoch != config.epoch();
    }

    // ================================================================== booths

    /// @notice Take one shot's USDG from `payer` and split it. `player` gets the credit (Marks, Alms eligibility).
    /// @dev The booth passes its own msg.sender as `payer`, so nobody can spend another wallet's USDG.
    function collect(address payer, address player, uint256 roundKey, uint256 gross) external onlyBooth nonReentrant {
        if (salesPaused) revert Paused();
        if (!isLaunchBooth[msg.sender]) {
            uint32 g = boothGen[msg.sender];
            uint256 allowed = _boothAllowance[payer][msg.sender][g];
            if (allowed < gross) revert BoothNotApproved();
            if (allowed != type(uint256).max) _boothAllowance[payer][msg.sender][g] = allowed - gross;
        }
        if (gross == 0) revert ZeroAmount();
        // K-A01: a round that was already awarded takes no more shots (its pot would be stranded in `accounted`).
        if (awarded[msg.sender][roundKey]) revert AlreadyAwarded();
        (bool active, uint256 fairId) = activeFair();
        if (!active) revert NoActiveFair();

        // First shot of a round: seed its Purse with this booth's rollover.
        if (!seeded[msg.sender][roundKey]) {
            seeded[msg.sender][roundKey] = true;
            roundFair[msg.sender][roundKey] = fairId;
            uint256 r = rollover[msg.sender];
            if (r != 0) {
                rollover[msg.sender] = 0;
                pot[msg.sender][roundKey] += r;
            }
            emit Seeded(msg.sender, roundKey, r);
        }

        // One read of the split per shot. Remainders take the rounding dust, so the parts always add up to `gross`.
        Split memory s = config.split();
        uint256 purse = gross * s.purseBps / BPS;
        uint256 greenwood = gross - purse;
        uint256 alms = greenwood * s.almsBps / BPS;
        uint256 bonfire = greenwood * s.bonfireBps / BPS;
        uint256 toll = greenwood * s.tollBps / BPS;
        uint256 v = greenwood - alms - bonfire - toll; // Locksley Vault + dust
        uint256 vBuy = v * s.vBuyBps / BPS;
        uint256 vLiq = v * s.vLiqBps / BPS;
        uint256 vBurn = v * s.vBurnBps / BPS;

        pot[msg.sender][roundKey] += purse;
        almsByFair[fairId] += alms;
        bonfirePending += bonfire;
        tollPending += toll;
        vaultBuyPending += vBuy;
        vaultLiqUsdg += vLiq;
        vaultBurnPending += vBurn;
        vaultFairsBurnUsdg += v - vBuy - vLiq - vBurn; // dust here
        accounted += gross;
        if (!playedIn[fairId][player]) playedIn[fairId][player] = true;
        spentIn[fairId][player] += gross;

        uint256 before = usdg.balanceOf(address(this));
        usdg.safeTransferFrom(payer, address(this), gross);
        if (usdg.balanceOf(address(this)) - before != gross) revert TransferMismatch();

        emit Shot(fairId, msg.sender, roundKey, player, payer, gross, purse, greenwood);
    }

    /// @notice A1-11: how much of your USDG a booth added after setup may pull (on top of your USDG approval to
    ///         FairCore). Launch booths need none. 0 revokes; type(uint256).max is unlimited. Like ERC-20 approve.
    ///         K16-A04: prefer increaseBoothAllowance / decreaseBoothAllowance to avoid the approve race.
    function approveBooth(address booth, uint256 amount) external {
        _setBoothAllowance(booth, amount);
    }

    function increaseBoothAllowance(address booth, uint256 added) external {
        uint256 cur = boothAllowance(msg.sender, booth);
        _setBoothAllowance(booth, type(uint256).max - cur < added ? type(uint256).max : cur + added);
    }

    /// @notice Lowers the allowance, flooring at 0 (so a pull that lands first can't make this revert).
    function decreaseBoothAllowance(address booth, uint256 removed) external {
        uint256 cur = boothAllowance(msg.sender, booth);
        _setBoothAllowance(booth, cur > removed ? cur - removed : 0);
    }

    function _setBoothAllowance(address booth, uint256 amount) internal {
        _boothAllowance[msg.sender][booth][boothGen[booth]] = amount;
        emit BoothApproval(msg.sender, booth, amount);
    }

    /// @notice A booth reports a settled round's winners, once. Unpaid shares roll over to the booth's next round.
    function award(uint256 roundKey, address[] calldata winners, uint256[] calldata amounts)
        external
        onlyBooth
        nonReentrant
    {
        if (winners.length != amounts.length || winners.length > MAX_WINNERS) revert BadArrays();
        if (awarded[msg.sender][roundKey]) revert AlreadyAwarded();
        awarded[msg.sender][roundKey] = true;
        // A round with no shots still marks itself awarded; it can't have been seeded, so its rollover waits.
        uint256 p = pot[msg.sender][roundKey];
        uint256 f = roundFair[msg.sender][roundKey];
        uint256 paid;
        for (uint256 i; i < winners.length; ++i) {
            uint256 a = amounts[i];
            if (a == 0 || winners[i] == address(0)) continue;
            paid += a;
            claimable[winners[i]] += a;
            wonIn[f][winners[i]] += a;
            emit Awarded(msg.sender, roundKey, winners[i], a, i);
        }
        if (paid > p) revert OverPot();
        pot[msg.sender][roundKey] = 0;
        uint256 rest = p - paid;
        if (rest != 0) {
            rollover[msg.sender] += rest;
            emit RolledOver(msg.sender, roundKey, rest);
        }
    }

    // ================================================================== players

    /// @notice Works even while sales are paused.
    function claim() external nonReentrant {
        uint256 a = _debitClaim();
        usdg.safeTransfer(msg.sender, a);
        emit Claimed(msg.sender, a);
    }

    /// @notice K-A02: claim your winnings to another address (for example if USDG blocklists your wallet, or to pay
    ///         a cold wallet). Debits msg.sender only.
    function claimTo(address to) external nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        uint256 a = _debitClaim();
        usdg.safeTransfer(to, a);
        emit ClaimedTo(msg.sender, to, a);
    }

    function _debitClaim() internal returns (uint256 a) {
        a = claimable[msg.sender];
        if (a == 0) revert NothingToClaim();
        claimable[msg.sender] = 0;
        accounted -= a;
    }

    // ================================================================== keeper: buy and burn

    /// @notice The Bonfire (or the Vault's burn share): buy the buy token and send it to 0xdEaD.
    function burnBuyToken(BurnSource source, uint256 route, uint256 usdgIn, uint256 minOut)
        external
        onlyKeeper
        nonReentrant
        returns (uint256 out)
    {
        if (source == BurnSource.Bonfire) {
            if (usdgIn > bonfirePending) revert OverLedger();
            bonfirePending -= usdgIn;
        } else {
            if (usdgIn > vaultBurnPending) revert OverLedger();
            vaultBurnPending -= usdgIn;
        }
        address token;
        (out, token) = _swap(source == BurnSource.Bonfire ? L_BONFIRE : L_VAULT_BURN, route, usdgIn, minOut, DEAD);
        emit Burned(token, uint8(source), route, usdgIn, out, minOut);
    }

    /// @notice The Vault's buy-and-hold share: buy the buy token and send it to the Locksley Vault.
    function buyForVault(uint256 route, uint256 usdgIn, uint256 minOut)
        external
        onlyKeeper
        nonReentrant
        returns (uint256 out)
    {
        if (vault == address(0)) revert NotVault();
        if (usdgIn > vaultBuyPending) revert OverLedger();
        vaultBuyPending -= usdgIn;
        address token;
        (out, token) = _swap(L_VAULT_BUY, route, usdgIn, minOut, vault);
        emit BoughtForVault(token, route, usdgIn, out, minOut);
    }

    /// @notice The anchor after time decay: 1% per hour since it was last written, at most 30%, and never below 70% of
    ///         `anchorBase` (M-2). 0 = no anchor in the
    ///         current GameConfig epoch.
    function decayedAnchor() public view returns (uint256) {
        uint256 a = anchorRate;
        if (a == 0 || anchorEpoch != config.epoch()) return 0;
        uint256 decay = (block.timestamp - anchorAt) * ANCHOR_DECAY_BPS_PER_HOUR / 1 hours;
        if (decay > MAX_DECAY_BPS) decay = MAX_DECAY_BPS;
        uint256 d = a * (BPS - decay) / BPS;
        // M-2: lower quotes may re-anchor below the last high, but the decayed anchor never goes below 70% of the
        // high-water mark, so repeated low writes can't walk the floor under 66.5% of it without the Safe.
        uint256 stop = anchorBase * (BPS - MAX_DECAY_BPS) / BPS;
        return d < stop ? stop : d;
    }

    /// @notice The current floor rate: 95% of the decayed anchor (buy-token wei per USDG unit, scaled by 1e18).
    function ratchetFloorRate() public view returns (uint256) {
        return decayedAnchor() * RATCHET_BPS / BPS;
    }

    /// @dev Onchain guards on every keeper swap:
    ///  - at most 250 USDG, and at least 50 minutes since this ledger's last swap, and at most 3,000 USDG per UTC day
    ///  - the anchor seeded by the Safe in the current GameConfig epoch, and minOut non-zero and at least the floor
    ///    (95% of an anchor that only falls with time)
    ///  - the route must output GameConfig's buy token and pay at least minOut of it to this contract, which then
    ///    sends exactly that amount on to the recipient
    ///  A thief holding the keeper key gets at most one 250 USDG call per ledger per 50 minutes, each at no worse
    ///  than the floor, and the floor can't be walked down faster than 1% per hour. The Safe revokes immediately.
    ///
    ///  Fee-on-transfer buy tokens are unsupported. `out` is this contract's balance delta of the buy token, and that
    ///  exact amount is transferred onward. A fee taken out of the inbound transfer can leave the delta below minOut,
    ///  and the swap reverts `ShortFill` (the route's own delivery can revert first). When the delta still clears
    ///  minOut, a second fee on the transfer to the vault or to DEAD leaves that recipient with less than `out`.
    ///  The return value and `Burned` / `BoughtForVault` report `out`, so they overstate what arrived. A fee charged
    ///  on top of the outbound amount can make that transfer revert: this contract forwards exactly the delta and
    ///  keeps nothing aside for the fee.
    function _swap(uint8 ledger, uint256 route, uint256 usdgIn, uint256 minOut, address to)
        internal
        returns (uint256 out, address tokenAddr)
    {
        if (usdgIn == 0) revert ZeroAmount();
        if (usdgIn > MAX_SWAP_USDG) revert OverCap();
        if (minOut == 0) revert ZeroMinOut();
        uint256 next = uint256(lastSwapAt[ledger]) + MIN_SWAP_GAP;
        if (lastSwapAt[ledger] != 0 && block.timestamp < next) revert TooSoon(next);
        uint256 day = block.timestamp / 1 days;
        uint256 today_ = swappedOnDay[ledger][day] + usdgIn;
        if (today_ > DAILY_SWAP_CAP) revert DailyCap();
        // No buyback runs until the Safe has seeded the anchor at the real price (v3.6), in the current GameConfig
        // epoch: without one there would be no floor, and the first fill, at whatever price, would become the anchor.
        if (anchorEpoch != config.epoch()) revert NotSeeded();
        uint256 floorRate = ratchetFloorRate();
        if (floorRate == 0) revert NotSeeded();
        uint256 floor = usdgIn * floorRate / 1e18;
        if (minOut < floor) revert RatchetTripped(minOut, floor);
        IBuyRoute r = routes[route];
        if (address(r) == address(0)) revert NoRoute();
        tokenAddr = buyToken(); // read once
        if (r.tokenOut() != tokenAddr) revert RouteTokenMismatch();
        lastSwapAt[ledger] = uint64(block.timestamp);
        swappedOnDay[ledger][day] = today_;
        accounted -= usdgIn;

        // The route pays this contract, not `to`. Anyone can add to the vault's or DEAD's balance mid-swap
        // (RakeBuyer.forward, FeeSplitter.distribute, RobinAmongThieves.flushBondBurn), so a delta measured there
        // could count tokens the route never delivered. Nothing permissionless pays this contract the buy token:
        // FeeSplitter rejects this contract and RakeBuyer as recipients, and RakeBuyer rejects this contract as
        // `forwardTo`. The only buy-token outflow (sweepExcess) is owner-only behind this same lock, so this delta
        // is the fill. A fee-on-transfer buy token is unsupported; see the notice above.
        IERC20 token = IERC20(tokenAddr);
        uint256 before = token.balanceOf(address(this));
        usdg.safeTransfer(address(r), usdgIn);
        r.swapToToken(usdgIn, minOut, address(this));
        out = token.balanceOf(address(this)) - before;
        if (out < minOut) revert ShortFill(out, minOut);
        token.safeTransfer(to, out);

        // Ratchet on the keeper's quote, not the fill. A better fill must not lift the anchor:
        // one windfall, or a sandwich, would leave the floor above the market and freeze later buys.
        // All three ledgers share one 4-hour window, and the anchor cannot rise more than 2% above the
        // decayed anchor at the start of that window. That is slower than the 1%/hour decay.
        uint256 px = minOut * 1e18 / usdgIn;
        uint256 cur = decayedAnchor();
        if (block.timestamp >= uint256(raiseWindowStart) + RAISE_WINDOW) {
            raiseBase = cur;
            raiseWindowStart = uint64(block.timestamp);
        }
        uint256 cap = raiseBase * (BPS + MAX_ANCHOR_RAISE_BPS) / BPS;
        if (px > cap) px = cap;
        if (px > cur) (anchorRate, anchorAt) = (px, uint64(block.timestamp));
        if (px > anchorBase) anchorBase = px; // M-2: the high-water mark only rises here (resets set it)
    }

    // ================================================================== Alms, Toll, Vault

    function releaseAlms(uint256 fairId) external nonReentrant returns (uint256 amount) {
        if (msg.sender != almsVote) revert NotAlmsVote();
        if (almsSafe == address(0)) revert ZeroAddress();
        amount = almsByFair[fairId];
        if (amount == 0) return 0;
        almsByFair[fairId] = 0;
        // K16-A05: a failed transfer (a blocklisted Alms Safe) escrows instead of reverting, so the vote's release
        // never stalls. The USDG stays in `accounted` until flushAlms() delivers it.
        if (_tryTransfer(almsSafe, amount)) {
            accounted -= amount;
            emit AlmsReleased(fairId, almsSafe, amount);
        } else {
            almsEscrow += amount;
            emit AlmsEscrowed(fairId, almsSafe, amount);
        }
    }

    /// @notice Anyone: send escrowed Alms to the current Alms Safe (after the issuer unblocks it, or after the Safe
    ///         moved the Alms Safe through the 48h timelock). Reverts if the transfer still fails.
    function flushAlms() external nonReentrant returns (uint256 amount) {
        if (almsSafe == address(0)) revert ZeroAddress();
        amount = almsEscrow;
        if (amount == 0) revert ZeroAmount();
        almsEscrow = 0;
        accounted -= amount;
        usdg.safeTransfer(almsSafe, amount);
        emit AlmsFlushed(almsSafe, amount);
    }

    /// @dev USDG transfer that reports failure instead of reverting. A caller can't force the escrow path by sending
    ///      too little gas: if the call failed with under 1/64 of the gas left, the whole tx reverts.
    function _tryTransfer(address to, uint256 amount) internal returns (bool) {
        uint256 g = gasleft();
        (bool ok, bytes memory ret) = address(usdg).call(abi.encodeCall(IERC20.transfer, (to, amount)));
        if (ok) {
            if (ret.length == 0) return address(usdg).code.length != 0;
            if (ret.length >= 32 && abi.decode(ret, (bool))) return true;
        }
        if (gasleft() < g / 64) revert LowGas();
        return false;
    }

    /// @notice A chapter whose vote got zero votes: its Alms move to the next chapter and add to that chapter's vote.
    ///         Only AlmsVote can call this; nobody can choose where unvoted Alms go.
    function carryAlms(uint256 fairId) external nonReentrant returns (uint256 amount) {
        if (msg.sender != almsVote) revert NotAlmsVote();
        amount = almsByFair[fairId];
        if (amount == 0) return 0;
        almsByFair[fairId] = 0;
        almsByFair[fairId + 1] += amount;
        almsCarriedIn[fairId + 1] += amount;
        emit AlmsCarried(fairId, fairId + 1, amount);
    }

    function withdrawToll(uint256 amount) external onlyOwner nonReentrant {
        if (tollRecipient == address(0)) revert ZeroAddress();
        if (amount > tollPending) revert OverLedger();
        tollPending -= amount;
        accounted -= amount;
        usdg.safeTransfer(tollRecipient, amount);
        emit TollWithdrawn(tollRecipient, amount);
    }

    /// @notice Only the Locksley Vault can call this, and the Vault only does so for a launcher attached through
    ///         its 7-day timelock. No launcher exists in this build.
    function releaseVaultUsdg(address to) external nonReentrant returns (uint256 amount) {
        if (msg.sender != vault) revert NotVault();
        if (to == address(0)) revert ZeroAddress();
        amount = vaultLiqUsdg + vaultFairsBurnUsdg;
        vaultLiqUsdg = 0;
        vaultFairsBurnUsdg = 0;
        accounted -= amount;
        usdg.safeTransfer(to, amount);
        emit VaultUsdgReleased(to, amount);
    }

    // ================================================================== owner: immediate

    /// @notice Stops new shots and takes only. Claims, unlocks, settles, Alms release and keeper jobs keep working.
    ///         A new pause can start at most once per `MIN_PAUSE_GAP`. The first pause is immediate. Unpause always is.
    function pauseSales(bool paused) external onlyOwner {
        if (paused && !salesPaused) {
            uint256 n = pauseLog.length;
            if (n != 0 && block.timestamp < uint256(pauseLog[n - 1].start) + MIN_PAUSE_GAP) revert PauseTooSoon();
            pausedSince = uint64(block.timestamp);
            pauseLog.push(Pause(uint64(block.timestamp), 0));
        }
        if (!paused && salesPaused) {
            pausedTotal += uint64(block.timestamp) - pausedSince;
            pauseLog[pauseLog.length - 1].end = uint64(block.timestamp);
        }
        salesPaused = paused;
        emit SalesPaused(paused);
    }

    /// @notice Immediate, even while paused: switch off a lost or stolen keeper. Setting a new one is timelocked.
    function revokeKeeper() external onlyOwner {
        keeper = address(0);
        emit KeeperSet(address(0));
    }

    /// @notice Seed the anchor during setup (the deploy script, before finishSetup): the price of the buy token in wei
    ///         per USDG unit, x1e18. A1-12: after setup this reverts; use queue(Op.ResetRatchet, newAnchor, address(0)),
    ///         wait timelockDelay, then execute, bounded by MAX_RESET_BPS. Never clears it: a floor always applies.
    function resetRatchet(uint256 newAnchor) external onlyOwner {
        if (setupDone) revert SetupClosed();
        _resetRatchet(newAnchor);
    }

    /// @notice The range a reset executed now may land in: ±MAX_RESET_BPS around `anchorBase` (the high-water price
    ///         the keeper or the Safe set, before decay), or [1, max] when no anchor is live in this GameConfig epoch.
    function resetBounds() public view returns (uint256 lo, uint256 hi) {
        // M-2: measured from the high-water mark, so a walked-down anchor can't shrink the range the Safe may restore.
        uint256 a = anchorBase;
        if (!setupDone || anchorRate == 0 || anchorEpoch != config.epoch()) return (1, type(uint256).max);
        return (a * (BPS - MAX_RESET_BPS) / BPS, a * (BPS + MAX_RESET_BPS) / BPS);
    }

    function _resetRatchet(uint256 newAnchor) internal {
        if (newAnchor == 0) revert ZeroAmount();
        (uint256 lo, uint256 hi) = resetBounds();
        if (newAnchor < lo || newAnchor > hi) revert ResetOutOfBounds(newAnchor, lo, hi);
        anchorRate = newAnchor;
        anchorAt = uint64(block.timestamp);
        anchorEpoch = config.epoch();
        raiseBase = newAnchor;
        anchorBase = newAnchor;
        raiseWindowStart = uint64(block.timestamp);
        emit RatchetReset(newAnchor, anchorEpoch);
    }

    /// @notice Schedule a chapter. Ids are sequential; chapters never overlap; a chapter can't change once it has started.
    function setFair(uint256 fairId, uint64 start, uint64 end) external onlyOwner {
        if (end <= start) revert BadFair();
        if (end - start > MAX_FAIR_LENGTH) revert BadFair();
        if (fairId < fairCount) {
            if (block.timestamp >= fairs[fairId].start) revert FairStarted();
            // Moving a chapter would leave its Alms windows pointing at the old dates.
            if (almsVote.code.length != 0 && IAlmsWindows(almsVote).windowsSet(fairId)) revert WindowsSet();
        } else if (fairId != fairCount) {
            revert BadFair();
        } else {
            // At most one Chapter scheduled ahead: activeFair only looks at the newest two.
            if (fairId > 1 && block.timestamp < fairs[fairId - 2].end) revert BadFair();
            fairCount = fairId + 1;
        }
        if (start < block.timestamp) revert BadFair();
        if (fairId > 0 && start < fairs[fairId - 1].end) revert BadFair();
        if (fairId + 1 < fairCount && end > fairs[fairId + 1].start) revert BadFair();
        fairs[fairId] = Fair(start, end);
        emit FairSet(fairId, start, end);
    }

    /// @notice USDG above `accounted`, or any other token sent here by mistake. Never touches owed USDG.
    function sweepExcess(IERC20 token, address to) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        uint256 bal = token.balanceOf(address(this));
        uint256 amount = address(token) == address(usdg) ? bal - accounted : bal;
        token.safeTransfer(to, amount);
        emit ExcessSwept(address(token), to, amount); // v3.6.1: so the Safe's post-deploy scan can see it
    }

    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }

    // ================================================================== owner: setup, then timelock

    /// @notice Before finishSetup the owner wires the system directly (one deploy script, no 48h wait). After it,
    ///         every change below goes through queue -> wait timelockDelay -> execute.
    function setupSet(Op op, uint256 key, address value) external onlyOwner {
        if (setupDone) revert SetupClosed();
        _apply(op, key, value);
    }

    function finishSetup() external onlyOwner {
        if (setupDone) revert SetupClosed();
        setupDone = true;
        emit SetupDone();
    }

    function opId(Op op, uint256 key, address value) public pure returns (bytes32) {
        return keccak256(abi.encode(op, key, value));
    }

    function queue(Op op, uint256 key, address value) external onlyOwner returns (bytes32 id) {
        if (!setupDone) revert SetupOpen();
        // The Vault and AlmsVote are fixed at setup: changing them later could bypass the Vault's 7-day launcher rule
        // or release the Alms without the players' vote. K16-A05: the Alms Safe can move, but only through the
        // timelock (at least 48h on mainnet), so a blocklisted Alms Safe can be replaced in public view.
        if (_setupOnly(op)) revert SetupOnly();
        id = opId(op, key, value);
        if (op == Op.ResetRatchet) {
            // Reset walk: one pending reset at a time, so ±MAX_RESET_BPS really is per timelockDelay.
            bytes32 p = pendingReset;
            if (p != bytes32(0) && queuedAt[p] != 0) revert ResetPending(p);
            pendingReset = id;
        }
        uint256 eta = block.timestamp + timelockDelay;
        queuedAt[id] = eta;
        emit OpQueued(id, op, key, value, eta);
    }

    function cancel(bytes32 id) external onlyOwner {
        if (queuedAt[id] == 0) revert NotQueued();
        delete queuedAt[id];
        if (id == pendingReset) pendingReset = bytes32(0);
        emit OpCancelled(id);
    }

    function execute(Op op, uint256 key, address value) external onlyOwner {
        bytes32 id = opId(op, key, value);
        uint256 eta = queuedAt[id];
        if (eta == 0) revert NotQueued();
        if (block.timestamp < eta) revert TooEarly(eta);
        if (_setupOnly(op)) revert SetupOnly();
        delete queuedAt[id];
        if (id == pendingReset) pendingReset = bytes32(0);
        _apply(op, key, value);
        emit OpExecuted(id, op, key, value);
    }

    function _setupOnly(Op op) internal pure returns (bool) {
        return op == Op.SetVault || op == Op.SetAlmsVote;
    }

    function _apply(Op op, uint256 key, address value) internal {
        if (op == Op.ResetRatchet) {
            if (value != address(0)) revert BadOpValue(); // one encoding per reset, so the watcher reads one op id
            _resetRatchet(key);
            return;
        }
        if (op == Op.SetKeeper) {
            keeper = value; // zero allowed: switches buybacks off
            emit KeeperSet(value);
            return;
        }
        if (value == address(0)) revert ZeroAddress();
        if (op == Op.AddBooth) {
            isBooth[value] = true;
            isLaunchBooth[value] = !setupDone; // later booths need each payer's opt-in (A1-11)
            emit BoothAdded(value);
        } else if (op == Op.RemoveBooth) {
            // No more shots or awards from it. An un-awarded pot or rollover stays in `accounted` (never sweepable),
            // and re-adding the booth through the timelock lets it settle. Use pauseSales for an immediate stop.
            isBooth[value] = false;
            isLaunchBooth[value] = false;
            ++boothGen[value]; // K16-A03: every allowance given for it is void; a re-add needs fresh approval
            emit BoothRemoved(value);
        } else if (op == Op.SetTollRecipient) {
            tollRecipient = value;
            emit TollRecipientSet(value);
        } else if (op == Op.SetAlmsSafe) {
            almsSafe = value;
            emit AlmsSafeSet(value);
        } else if (op == Op.SetRoute) {
            routes[key] = IBuyRoute(value);
            emit RouteSet(key, value);
        } else if (op == Op.SetAlmsVote) {
            almsVote = value;
            emit AlmsVoteSet(value);
        } else if (op == Op.SetVault) {
            vault = value;
            emit VaultSet(value);
        }
    }
}
