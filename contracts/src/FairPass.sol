// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {SafeHandover} from "./SafeHandover.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IFairPass, IGameConfig} from "./interfaces/IFair.sol";

/// @title FairPass
/// @notice Lock the play token once to play (the token and amount come from GameConfig: 5,000 $wif at launch).
///         Unlock any time after 24 hours to get back exactly the token and amount you locked. Each pass records its
///         own token and amount when it is made, and unlocking reads only that record, never GameConfig.
///         The 24-hour minimum hold makes a pass a real per-wallet cost: a flash loan can't be repaid inside the
///         transaction, and one stack can't be passed from wallet to wallet every second.
///         Nobody, including the owner, can move locked tokens or delay an unlock past the 24 hours. The owner can
///         only sweep tokens sent here by mistake, above what is locked, and a sweep that would leave any locked
///         token short reverts.
contract FairPass is IFairPass, SafeHandover, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant MIN_HOLD = 24 hours;

    struct Pass {
        uint64 at; // 0 = no pass
        address token;
        uint128 amount;
    }

    IGameConfig public immutable config;
    mapping(address => Pass) public passes;
    mapping(address => uint256) public totalLocked; // per token
    address[] public lockedTokens; // append-only: the first lock of each token address
    mapping(address => bool) internal _seen;

    event Locked(address indexed player, address indexed token, uint256 amount, uint64 at);
    event Unlocked(address indexed player, address indexed token, uint256 amount, uint64 at);
    event ExcessSwept(address indexed token, address indexed to, uint256 amount);

    error AlreadyLocked();
    error NoPass();
    error HoldNotOver(uint256 until);
    error TransferMismatch();
    error TokenChanged();
    error RenounceDisabled();
    error ZeroAddress();
    error SweepTouchedLocks(address token);

    constructor(IGameConfig config_, address owner_) Ownable(owner_) {
        if (address(config_) == address(0)) revert ZeroAddress();
        config = config_;
    }

    /// @notice Lock the current play token. `expectedToken` and `maxAmount` are what the player saw: if GameConfig's
    ///         values differ when the transaction lands, it reverts instead of locking something else.
    function lock(address expectedToken, uint256 maxAmount) external nonReentrant {
        if (passes[msg.sender].at != 0) revert AlreadyLocked();
        (address t, uint256 amt,) = config.tokens();
        if (t != expectedToken || amt > maxAmount) revert TokenChanged();
        uint64 at = uint64(block.timestamp);
        passes[msg.sender] = Pass(at, t, uint128(amt)); // GameConfig caps passLock at uint128
        totalLocked[t] += amt;
        IERC20 token = IERC20(t);
        uint256 before = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amt);
        if (token.balanceOf(address(this)) - before != amt) revert TransferMismatch();
        if (!_seen[t]) {
            // First lock of this address. The list only grows when the play token changes between chapters.
            _seen[t] = true;
            lockedTokens.push(t);
        }
        emit Locked(msg.sender, t, amt, at);
    }

    /// @notice Any time from 24 hours after locking. Never blocked by a pause, the owner or GameConfig: it pays back the
    ///         recorded token and amount. Unlocking forfeits the Alms vote for any Chapter not yet voted on and the
    ///         "held all chapter" Marks multiplier.
    function unlock() external nonReentrant {
        Pass memory p = passes[msg.sender];
        if (p.at == 0) revert NoPass();
        if (block.timestamp < uint256(p.at) + MIN_HOLD) revert HoldNotOver(uint256(p.at) + MIN_HOLD);
        delete passes[msg.sender];
        totalLocked[p.token] -= p.amount;
        IERC20(p.token).safeTransfer(msg.sender, p.amount);
        emit Unlocked(msg.sender, p.token, p.amount, uint64(block.timestamp));
    }

    /// @notice A pass counts for play only if it is locked in the current play token. The amount isn't re-checked,
    ///         so a later change of the pass amount leaves existing passes in the same token valid.
    function hasPass(address a) external view returns (bool) {
        Pass memory p = passes[a];
        if (p.at == 0) return false;
        (address t,,) = config.tokens();
        return p.token == t;
    }

    /// @notice When the current pass was locked, whatever its token; 0 if none.
    function heldSince(address a) external view returns (uint64) {
        return passes[a].at;
    }

    /// @notice Same as heldSince (kept for ABI continuity).
    function lockedAt(address a) external view returns (uint64) {
        return passes[a].at;
    }

    /// @notice The earliest time this wallet can unlock; 0 if it holds no pass.
    function unlockableAt(address a) external view returns (uint256) {
        uint256 at = passes[a].at;
        return at == 0 ? 0 : at + MIN_HOLD;
    }

    /// @notice The pass as recorded, and whether it counts for play right now.
    function passOf(address a) external view returns (uint64 at, address token, uint256 amount, bool current) {
        Pass memory p = passes[a];
        (address t,,) = config.tokens();
        return (p.at, p.token, p.amount, p.at != 0 && p.token == t);
    }

    /// @notice Return tokens sent here by mistake. Only the amount above what is locked in that token can leave.
    ///         Each locked token's balance is recorded before the transfer. The sweep reverts if any locked token is
    ///         left short, or if any locked token other than the one swept changed balance, so two addresses of one
    ///         ledger cannot be used to take principal.
    function sweepExcess(IERC20 token, address to) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        uint256 excess = token.balanceOf(address(this)) - totalLocked[address(token)];
        uint256 n = lockedTokens.length;
        uint256[] memory before = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            before[i] = IERC20(lockedTokens[i]).balanceOf(address(this));
        }
        token.safeTransfer(to, excess);
        for (uint256 i; i < n; ++i) {
            address t = lockedTokens[i];
            uint256 b = IERC20(t).balanceOf(address(this));
            if (b < totalLocked[t] || (t != address(token) && b != before[i])) revert SweepTouchedLocks(t);
        }
        emit ExcessSwept(address(token), to, excess);
    }

    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }
}
