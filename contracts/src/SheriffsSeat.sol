// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IFairCore, IFairPass, IArbSys} from "./interfaces/IFair.sol";

/// @title SheriffsSeat (booth 2)
/// @notice One seat per day (days start 00:00 UTC). Taking it costs 1.5x what the last holder paid, sliding down to
///         1 USDG over one hour of unpaused time; the first take of a day costs 1 USDG. You can't take the seat from
///         yourself. The top 3 by seconds held split the day's Purse 75/20/5. The holder posts a message and picks a
///         colour.
///         Holds no tokens: USDG goes straight from the payer to FairCore, and winners claim from FairCore.
///         While sales are paused nobody can take the seat, so the holder's clock and the price slide both stop:
///         paused time is never credited and never lowers the price.
contract SheriffsSeat is ReentrancyGuard {
    uint256 public constant FLOOR = 1e6; // 1 USDG
    uint256 public constant SLIDE = 1 hours;
    uint256 public constant MAX_MESSAGE_BYTES = 256; // 64 characters x 4-byte UTF-8 worst case
    uint8 public constant PALETTE_SIZE = 8;
    uint256 public constant BPS = 10_000;
    IArbSys public constant ARBSYS = IArbSys(address(0x64));

    struct Day {
        address holder;
        uint64 since;
        uint64 lastTakeAt;
        uint128 lastPaid;
        bool settled;
        uint32 pauseIdx; // FairCore pause-log length when the current holder took the seat
    }

    struct Rank {
        address who;
        uint64 secs;
    }

    IFairCore public immutable core;
    IFairPass public immutable fairPass;
    uint256 public immutable day0; // a 00:00 UTC timestamp
    uint256 public immutable dayLength; // 1 day on mainnet (enforced); shorter on testnet for a compressed Fair

    mapping(uint256 => Day) internal days_;
    mapping(uint256 => mapping(address => uint64)) public secsOf;
    mapping(uint256 => Rank[3]) internal top;
    uint64 public lastTakeL2Block;
    /// @notice The last day that had a take, plus 1 (0 = no take yet; day 0 is a real day).
    uint64 public lastTakeDayPlus1;

    event SeatTaken(
        uint256 indexed dayId,
        address indexed newHolder,
        address indexed prevHolder,
        address payer,
        uint256 price,
        string message,
        uint8 color
    );
    event DaySettled(uint256 indexed dayId, address first, address second, address third, uint256 purse);

    error NoPass();
    error AlreadyHolder();
    error SameBlock();
    error PriceAboveMax(uint256 price, uint256 maxPrice);
    error MessageTooLong();
    error BadColor();
    error DayNotOver();
    error AlreadySettled();
    error BadConfig();

    constructor(IFairCore core_, uint256 day0_, uint256 dayLength_) {
        if (dayLength_ == 0 || day0_ == 0) revert BadConfig();
        // K-D01: a future day0 would make dayId (and every view, FairLens included) underflow until it arrives.
        if (day0_ > block.timestamp) revert BadConfig();
        if (block.chainid == 4663 && (dayLength_ != 1 days || day0_ % 1 days != 0)) revert BadConfig();
        core = core_;
        fairPass = core_.fairPass();
        day0 = day0_;
        dayLength = dayLength_;
    }

    // ================================================================== views

    function dayId(uint256 t) public view returns (uint256) {
        return (t - day0) / dayLength;
    }

    function today() public view returns (uint256) {
        return dayId(block.timestamp);
    }

    function dayEnd(uint256 d) public view returns (uint256) {
        return day0 + (d + 1) * dayLength;
    }

    /// @notice What taking the seat costs right now. The slide counts only unpaused time since the last take.
    function price() public view returns (uint256) {
        Day storage D = days_[today()];
        if (D.holder == address(0)) return FLOOR;
        uint256 t = _held(D, uint64(block.timestamp)); // live seconds since the last take (since == lastTakeAt)
        if (t >= SLIDE) return FLOOR;
        uint256 s = uint256(D.lastPaid) * 3 / 2;
        return FLOOR + (s - FLOOR) * (SLIDE - t) / SLIDE;
    }

    function holderOf(uint256 d) external view returns (address holder, uint64 since, uint128 lastPaid) {
        Day storage D = days_[d];
        return (D.holder, D.since, D.lastPaid);
    }

    function isSettled(uint256 d) external view returns (bool) {
        return days_[d].settled;
    }

    /// @notice Top 3 by seconds held. During the day the current holder's live reign isn't counted until it ends.
    function leaderboard(uint256 d) external view returns (Rank[3] memory) {
        return top[d];
    }

    // ================================================================== play

    /// @notice Take the seat. USDG (the current price, at most `maxPrice`) is pulled from msg.sender; the seat and its
    ///         seconds go to `player` (address(0) = yourself), who must hold a Fair Pass.
    function take(uint256 maxPrice, address player, string calldata message, uint8 color)
        external
        nonReentrant
        returns (uint256 paid)
    {
        if (player == address(0)) player = msg.sender;
        if (!fairPass.hasPass(player)) revert NoPass();
        if (bytes(message).length > MAX_MESSAGE_BYTES) revert MessageTooLong();
        if (color >= PALETTE_SIZE) revert BadColor();
        uint64 l2 = uint64(ARBSYS.arbBlockNumber());
        if (l2 == lastTakeL2Block) revert SameBlock();

        uint256 d = today();
        // Settle the last day that had takes first (if nobody has), so its unfilled shares seed today's Purse, even
        // when quiet days came in between. Every earlier day with takes was settled the same way by the first take
        // after it, so one settle per take is enough. A day with no takes has nothing to pay.
        uint256 ld = lastTakeDayPlus1;
        if (ld != 0 && ld - 1 < d && !days_[ld - 1].settled) _settle(ld - 1);
        lastTakeDayPlus1 = uint64(d + 1);
        Day storage D = days_[d];
        address prev = D.holder;
        if (player == prev) revert AlreadyHolder();
        paid = price();
        if (paid > maxPrice) revert PriceAboveMax(paid, maxPrice);

        uint64 now_ = uint64(block.timestamp);
        if (prev != address(0)) _credit(d, prev, _held(D, now_));
        (D.holder, D.since, D.lastTakeAt, D.lastPaid) = (player, now_, now_, uint128(paid));
        D.pauseIdx = uint32(core.pauseCount());
        lastTakeL2Block = l2;

        core.collect(msg.sender, player, d, paid);
        emit SeatTaken(d, player, prev, msg.sender, paid, message, color);
    }

    /// @notice Permissionless once the day is over: credits the last reign up to midnight and locks in the top 3.
    ///         Fewer than 3 holders: the unfilled shares roll over into the next day's Purse.
    function settle(uint256 d) external nonReentrant {
        if (block.timestamp < dayEnd(d)) revert DayNotOver();
        if (days_[d].settled) revert AlreadySettled();
        _settle(d);
    }

    function _settle(uint256 d) internal {
        Day storage D = days_[d];
        D.settled = true;
        if (D.holder != address(0)) _credit(d, D.holder, _held(D, uint64(dayEnd(d))));

        uint256 purse = core.pot(address(this), d);
        Rank[3] storage T = top[d];
        address[] memory w = new address[](3);
        uint256[] memory a = new uint256[](3);
        (w[0], a[0]) = (T[0].who, purse * 7500 / BPS);
        (w[1], a[1]) = (T[1].who, purse * 2000 / BPS);
        (w[2], a[2]) = (T[2].who, purse * 500 / BPS);
        core.award(d, w, a);
        emit DaySettled(d, T[0].who, T[1].who, T[2].who, purse);
    }

    /// @dev Seconds the current holder held the seat up to `to`, minus any time sales were paused in between.
    function _held(Day storage D, uint64 to) internal view returns (uint64) {
        uint256 wall = to - D.since;
        uint256 paused = core.pausedBetween(D.pauseIdx, D.since, to);
        return uint64(wall - (paused > wall ? wall : paused));
    }

    /// @dev Adds seconds and keeps the top 3 sorted. A newcomer must have strictly more seconds to overtake.
    function _credit(uint256 d, address who, uint64 secs) internal {
        uint64 total = secsOf[d][who] + secs;
        secsOf[d][who] = total;
        Rank[3] storage T = top[d];
        uint256 i = 3;
        for (uint256 j; j < 3; ++j) {
            if (T[j].who == who) {
                i = j;
                break;
            }
        }
        if (i == 3) {
            if (total <= T[2].secs) return;
            i = 2;
            T[2] = Rank(who, total);
        } else {
            T[i].secs = total;
        }
        while (i > 0 && T[i].secs > T[i - 1].secs) {
            // Copy to memory first: a storage-to-storage tuple swap would write the same entry twice.
            Rank memory up = T[i];
            T[i] = T[i - 1];
            T[i - 1] = up;
            --i;
        }
    }
}
