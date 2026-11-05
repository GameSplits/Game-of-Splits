// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IFairCore, IFairPass, IArbSys} from "./interfaces/IFair.sol";

/// @title LastArrow (booth 1)
/// @notice Rising-price, last-shot-wins rounds. Shot 1 costs 1 USDG; every shot costs 0.5% more than the one before.
///         The round opens with 1 hour on the clock; each shot adds 10 minutes, never past 1 hour from now; the
///         round ends when the clock runs out, with no fixed maximum length (PRICE_CEILING remains an overflow backstop).
///         The Purse (60% of every shot, plus any rollover) pays: 50% to the last shot, 35% to the 10 shots before
///         it (pro-rata by price paid), 15% to whoever fired the most shots in the round.
///         Holds no tokens: USDG goes straight from the payer to FairCore, and winners claim from FairCore.
///         The clock stops while sales are paused, so a pause can't be used to end a round on a chosen shot.
contract LastArrow is ReentrancyGuard {
    // ------------------------------------------------------------------ rules
    uint256 public constant START_PRICE = 1e6; // 1 USDG
    uint256 public constant STEP_NUM = 1005;
    uint256 public constant STEP_DEN = 1000;
    uint256 public constant PRICE_CEILING = 1e18; // 1e12 USDG: overflow guard only (about shot 5,540)
    uint64 public constant OPEN_TIME = 1 hours;
    uint64 public constant BUMP = 10 minutes;
    uint64 public constant MAX_CLOCK = 1 hours;
    uint256 public constant LATE_SHOTS = 10;
    uint256 public constant RING = LATE_SHOTS + 1;
    uint256 public constant LAST_BPS = 5000;
    uint256 public constant LATE_BPS = 3500;
    uint256 public constant MOST_BPS = 1500;
    uint256 public constant BPS = 10_000;
    IArbSys public constant ARBSYS = IArbSys(address(0x64));

    struct Round {
        uint64 start;
        uint64 deadline;
        uint64 hardEnd; // always 0: no hard end. Kept so the ABI stays the same. 0 means none, not a timestamp.
        uint32 shots;
        bool settled;
        uint128 nextPrice;
        address lastShooter;
        uint64 lastShotL2Block;
        address leader;
        uint32 leaderCount;
        uint64 pauseMark; // FairCore.pausedSeconds() when the deadline was last written
    }

    struct Entry {
        address shooter;
        uint128 price;
    }

    IFairCore public immutable core;
    IFairPass public immutable fairPass;

    uint256 public currentRound; // 0 = none yet
    mapping(uint256 => Round) internal rounds;
    mapping(uint256 => Entry[RING]) internal recent; // ring buffer of the last 11 shots
    mapping(uint256 => mapping(address => uint32)) public countOf;

    /// @notice `hardEnd` is always 0. The field stays so indexers keep this signature. 0 means there is no hard end.
    event RoundOpened(uint256 indexed roundId, uint64 start, uint64 deadline, uint64 hardEnd);
    event ShotFired(
        uint256 indexed roundId,
        uint32 shotNo,
        address indexed shooter,
        address indexed payer,
        uint256 price,
        uint64 newDeadline
    );
    event RoundSettled(uint256 indexed roundId, address last, address leader, uint256 purse);

    error NoPass();
    error BackToBack();
    error SameBlock();
    error PriceAboveMax(uint256 price, uint256 maxPrice);
    error PriceCeiling();
    error NotEnded();
    error AlreadySettled();
    error NoRound();
    error WrongRound(uint256 expected, uint256 actual);
    /// @notice A-02: a new round needs a full OPEN_TIME window before the chapter ends.
    error ChapterEndingSoon();

    constructor(IFairCore core_) {
        core = core_;
        fairPass = core_.fairPass();
    }

    // ================================================================== views

    /// @dev Seconds of pause since the round's deadline was last written.
    ///      A settled round already folded that shift in, so later pauses do not move it.
    function _shift(Round storage R) internal view returns (uint64) {
        if (R.settled) return 0;
        return uint64(core.pausedSeconds() - R.pauseMark);
    }

    /// @dev Fold paused time into the stored deadline. `hardEnd == 0` means there is no hard end, so it is left
    ///      alone: adding the shift to 0 would store a small number that `roundState` would show as a timestamp.
    ///      A `type(uint64).max` sentinel is not used; this add would overflow it and revert every later shot.
    function _foldPause(Round storage R) internal {
        uint64 sh = _shift(R);
        if (sh == 0) return;
        R.deadline += sh;
        if (R.hardEnd != 0) R.hardEnd += sh;
        R.pauseMark += sh;
    }

    function _live(Round storage R) internal view returns (bool) {
        return R.start != 0 && block.timestamp < uint256(R.deadline) + _shift(R);
    }

    /// @notice The round's deadline with paused time added back. After settle this is the deadline at
    ///         settle, and it does not grow if sales are paused later.
    function effectiveDeadline(uint256 roundId) public view returns (uint256) {
        Round storage R = rounds[roundId];
        return R.start == 0 ? 0 : uint256(R.deadline) + _shift(R);
    }

    /// @notice The round a shot sent now lands in: the current round while it is live, else the next one.
    ///         Pass it to `shoot` as `expectedRound`.
    function nextShotRound() public view returns (uint256) {
        uint256 id = currentRound;
        return _live(rounds[id]) ? id : id + 1;
    }

    /// @notice What the next shot costs (a new round starts at 1 USDG).
    function currentPrice() public view returns (uint256) {
        Round storage R = rounds[currentRound];
        return _live(R) ? R.nextPrice : START_PRICE;
    }

    function timeLeft() external view returns (uint256) {
        Round storage R = rounds[currentRound];
        return _live(R) ? effectiveDeadline(currentRound) - block.timestamp : 0;
    }

    /// @notice Stored round. `hardEnd` is always 0, which means the round has no hard end (not a time to display).
    function roundState(uint256 roundId) external view returns (Round memory) {
        return rounds[roundId];
    }

    /// @notice The last up-to-11 shots, newest first.
    function lastShots(uint256 roundId) external view returns (Entry[] memory out) {
        Round storage R = rounds[roundId];
        uint256 n = R.shots < RING ? R.shots : RING;
        out = new Entry[](n);
        for (uint256 i; i < n; ++i) {
            out[i] = recent[roundId][(R.shots - 1 - i) % RING];
        }
    }

    // ================================================================== play

    /// @notice Fire a shot. USDG (exactly the current price, at most `maxPrice`) is pulled from msg.sender; the shot
    ///         is credited to `player` (pass address(0) for yourself). `player` must hold a Pass.
    ///         Rules against bots: no two shots in a row by the same player, at most one shot per L2 block.
    ///         K16-D-A02: `expectedRound` is the round you mean to shoot in (`nextShotRound()` when you sign). If the
    ///         round you saw ended before the tx lands, the shot would open a new round instead, so it reverts.
    ///         A-02: a new round will not open when the active chapter ends within `OPEN_TIME`. With no active
    ///         chapter FairCore reverts `NoActiveFair` as before. A round that is already live is unaffected and still ends at the chapter hard stop.
    function shoot(uint256 maxPrice, address player, uint256 expectedRound)
        external
        nonReentrant
        returns (uint256 price)
    {
        if (player == address(0)) player = msg.sender;
        uint256 id = currentRound;
        Round storage R = rounds[id];
        bool live = _live(R);
        if ((live ? id : id + 1) != expectedRound) revert WrongRound(expectedRound, live ? id : id + 1);
        if (!live) {
            // The previous round is over: settle it (if nobody has) so its winners are locked in, then open a new one.
            if (id != 0 && !R.settled) _settle(id);
            // A-02: refuse a new round that would open into the last OPEN_TIME of the active chapter.
            // With no active chapter, FairCore still reverts NoActiveFair further down, as before.
            (bool active, uint256 fairId) = core.activeFair();
            if (active) {
                (, uint64 fairEnd) = core.fairs(fairId);
                if (uint64(block.timestamp) + OPEN_TIME >= fairEnd) revert ChapterEndingSoon();
            }
            id = ++currentRound;
            R = rounds[id];
            uint64 t = uint64(block.timestamp);
            (R.start, R.deadline, R.hardEnd, R.nextPrice) = (t, t + OPEN_TIME, 0, uint128(START_PRICE));
            R.pauseMark = uint64(core.pausedSeconds());
            emit RoundOpened(id, t, t + OPEN_TIME, 0);
        }
        if (!fairPass.hasPass(player)) revert NoPass();
        if (player == R.lastShooter) revert BackToBack();
        uint64 l2 = uint64(ARBSYS.arbBlockNumber());
        if (l2 == R.lastShotL2Block) revert SameBlock();
        price = R.nextPrice;
        if (price > maxPrice) revert PriceAboveMax(price, maxPrice);
        if (price > PRICE_CEILING) revert PriceCeiling();

        // Fold any paused time into the stored deadline before bumping. Nothing caps the round's length.
        _foldPause(R);
        uint64 d = R.deadline + BUMP;
        uint64 cap = uint64(block.timestamp) + MAX_CLOCK;
        if (d > cap) d = cap;
        R.deadline = d;

        uint32 shotNo = R.shots;
        recent[id][shotNo % RING] = Entry(player, uint128(price));
        R.shots = shotNo + 1;
        uint32 c = ++countOf[id][player];
        if (c > R.leaderCount) (R.leader, R.leaderCount) = (player, c); // ties stay with whoever got there first
        R.lastShooter = player;
        R.lastShotL2Block = l2;
        R.nextPrice = uint128(price * STEP_NUM / STEP_DEN);

        core.collect(msg.sender, player, id, price);
        emit ShotFired(id, shotNo + 1, player, msg.sender, price, d);
    }

    /// @notice Permissionless once the clock runs out. Locks in the winners; they claim from FairCore.
    function settle(uint256 roundId) external nonReentrant {
        Round storage R = rounds[roundId];
        if (R.start == 0) revert NoRound();
        if (block.timestamp < effectiveDeadline(roundId)) revert NotEnded();
        if (R.settled) revert AlreadySettled();
        _settle(roundId);
    }

    /// @dev Last shot 50%. The k shots before it (k <= 10) share k/10 of the 35%, pro-rata by price; the unfilled
    ///      tenths roll over. Most shots 15%. Rounding dust stays in the Purse and rolls over too.
    function _settle(uint256 id) internal {
        Round storage R = rounds[id];
        // Snapshot the live deadline before marking the round settled (_shift is zero afterwards).
        _foldPause(R);
        R.settled = true;
        uint256 purse = core.pot(address(this), id);
        uint256 n = R.shots;
        uint256 k = n - 1 > LATE_SHOTS ? LATE_SHOTS : n - 1;

        address[] memory w = new address[](k + 2);
        uint256[] memory a = new uint256[](k + 2);
        Entry storage last = recent[id][(n - 1) % RING];
        (w[0], a[0]) = (last.shooter, purse * LAST_BPS / BPS);

        uint256 lateFilled = purse * LATE_BPS * k / (BPS * LATE_SHOTS);
        uint256 sum;
        for (uint256 i = 1; i <= k; ++i) {
            sum += recent[id][(n - 1 - i) % RING].price;
        }
        for (uint256 i = 1; i <= k; ++i) {
            Entry storage e = recent[id][(n - 1 - i) % RING];
            (w[i], a[i]) = (e.shooter, lateFilled * e.price / sum);
        }
        (w[k + 1], a[k + 1]) = (R.leader, purse * MOST_BPS / BPS);

        core.award(id, w, a);
        emit RoundSettled(id, last.shooter, R.leader, purse);
    }
}
