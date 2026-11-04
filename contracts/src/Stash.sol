// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {Nonces} from "@openzeppelin/contracts/utils/Nonces.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice The Last Arrow calls Stash uses. `shoot` pulls USDG from the payer and credits `player`.
interface ILastArrow {
    function shoot(uint256 maxPrice, address player, uint256 expectedRound) external returns (uint256 price);
    function currentPrice() external view returns (uint256);
}

/// @notice The Sheriff's Seat calls Stash uses. `take` pulls USDG from the payer and credits `player`.
interface ISheriffsSeat {
    function take(uint256 maxPrice, address player, string calldata message, uint8 color)
        external
        returns (uint256 paid);
    function price() external view returns (uint256);
}

/// @title Stash
/// @notice A player's USDG balance for one-click shots. The main wallet deposits and withdraws. A session key
///         may only shoot Last Arrow or take the Sheriff's Seat, up to a spend limit, until it expires or is revoked.
///         The signed max price is a ceiling. The contract pays the quoted game price, never more, and leaves the
///         unused room in the owner's balance. Relayed shots pay the shot fee, never more than the fee when their key
///         was authorized. Every withdrawal, direct or relayed, pays the fixed withdrawal fee, and a balance at or
///         below that fee cannot be withdrawn. A direct shot from the main wallet pays no shot fee.
///         Fees are kept in the Stash as `feesAccrued` and leave only through `flushFees`, so a fee wallet that
///         cannot receive USDG never blocks a withdrawal or a play.
///         Every owner order (withdraw, authorize, limit, revoke) and every key order shares one nonce per owner.
///         Direct `authorizeKey`, `setLimit` and `revokeKey` also use that nonce, and `cancelNonce` uses it with no
///         other effect, so an order signed at the current nonce and never sent dies once one of these succeeds.
///         Direct `withdraw`, `shoot` and `take` leave the nonce alone; use `cancelNonce` to void a held order.
/// @dev Built on OpenZeppelin SafeERC20, ReentrancyGuard, EIP712, SignatureChecker (ECDSA and ERC-1271) and Nonces.
///      No owner, no pause, no upgrade. `capRaiser` can only raise the launch deposit cap, set the shot fee up to
///      `MAX_SHOT_FEE`, or renounce.
///      Accounting invariant: `usdg.balanceOf(this) >= totalHeld + feesAccrued`.
contract Stash is ReentrancyGuard, EIP712, Nonces {
    using SafeERC20 for IERC20;

    uint256 public constant MAX_SHOT_FEE = 0.25e6;
    uint256 public constant MAX_WITHDRAW_FEE = 2e6;
    uint256 public constant LAUNCH_CAP = 50_000e6;
    uint256 public constant MAX_KEY_EXPIRY = 7 days;
    /// @notice A limit of this value means the balance is the only spend cap.
    uint256 public constant UNLIMITED = type(uint128).max;
    uint256 public constant MAX_PRESETS = 16;
    uint256 public constant MAX_PRESET_BYTES = 64;

    bytes32 public constant SHOOT_TYPEHASH = keccak256(
        "Shoot(address owner,uint256 maxPrice,uint256 expectedRound,uint256 nonce,uint256 deadline,uint256 epoch)"
    );
    bytes32 public constant TAKE_TYPEHASH = keccak256(
        "Take(address owner,uint256 maxPrice,uint8 presetId,uint8 color,uint256 nonce,uint256 deadline,uint256 epoch)"
    );
    bytes32 public constant WITHDRAW_TYPEHASH =
        keccak256("Withdraw(address owner,uint256 amount,uint256 nonce,uint256 deadline)");
    bytes32 public constant AUTHORIZE_TYPEHASH = keccak256(
        "AuthorizeKey(address owner,address key,uint256 limit,uint256 expiry,uint256 nonce,uint256 deadline)"
    );
    bytes32 public constant SET_LIMIT_TYPEHASH =
        keccak256("SetLimit(address owner,uint256 newLimit,uint256 nonce,uint256 deadline)");
    bytes32 public constant REVOKE_TYPEHASH = keccak256("RevokeKey(address owner,uint256 nonce,uint256 deadline)");

    struct Session {
        address key;
        uint48 expiry;
        uint48 epoch;
        uint256 limit;
        uint256 spent;
        /// @dev The shot fee when the key was authorized, the most this session's relayed plays can pay.
        uint256 feeCap;
    }

    struct Shoot {
        address owner;
        uint256 maxPrice;
        uint256 expectedRound;
        uint256 nonce;
        uint256 deadline;
        uint256 epoch;
    }

    struct Take {
        address owner;
        uint256 maxPrice;
        uint8 presetId;
        uint8 color;
        uint256 nonce;
        uint256 deadline;
        uint256 epoch;
    }

    struct Withdrawal {
        address owner;
        uint256 amount;
        uint256 nonce;
        uint256 deadline;
    }

    struct Authorize {
        address owner;
        address key;
        uint256 limit;
        uint256 expiry;
        uint256 nonce;
        uint256 deadline;
    }

    struct LimitChange {
        address owner;
        uint256 newLimit;
        uint256 nonce;
        uint256 deadline;
    }

    struct Revoke {
        address owner;
        uint256 nonce;
        uint256 deadline;
    }

    IERC20 public immutable usdg;
    address public immutable core;
    ILastArrow public immutable arrow;
    ISheriffsSeat public immutable seat;
    address public immutable feeWallet;
    uint256 public immutable withdrawFee;

    address public capRaiser;
    uint256 public cap;
    uint256 public totalHeld;
    /// @notice Fees taken from withdrawals and relayed plays, held here until `flushFees` sends them to `feeWallet`.
    ///         Never part of `totalHeld` and never spendable by players.
    uint256 public feesAccrued;
    mapping(address owner => uint256) internal _balances;
    mapping(address owner => Session) public session;
    string[] internal _presets;
    uint256 public shotFee;

    event Deposited(address indexed owner, uint256 amount);
    event Withdrawn(address indexed owner, uint256 amount, uint256 fee);
    event KeyAuthorized(address indexed owner, address indexed key, uint256 limit, uint48 expiry, uint48 epoch);
    event LimitSet(address indexed owner, uint256 newLimit);
    event KeyRevoked(address indexed owner, address indexed key, uint48 epoch);
    event Played(address indexed owner, address indexed key, address indexed game, uint256 price, uint256 fee);
    event CapRaised(uint256 newCap);
    event CapRaiserRenounced(address indexed previous);
    event ShotFeeSet(uint256 oldFee, uint256 newFee);
    event FeesFlushed(address indexed feeWallet, uint256 amount);
    event NonceCancelled(address indexed owner, uint256 nonce);

    error ZeroAddress();
    error FeeAboveMax();
    error BadFeeWallet();
    error BadPresets();
    error ZeroAmount();
    error OverCap();
    error TransferMismatch();
    error InsufficientBalance();
    error AmountNotAboveFee();
    error BalanceAtOrBelowFee();
    error DeadlineExpired();
    error BadSignature();
    error KeyMissing();
    error KeyExpired();
    error StaleEpoch();
    error OverLimit();
    error ExpiryNotFuture();
    error ExpiryTooFar();
    error LimitBelowSpent();
    error NotCapRaiser();
    error CapNotRaised();
    error BadPreset();
    error PriceAboveMax(uint256 price, uint256 maxPrice);
    error QuoteFailed();

    constructor(
        address core_,
        address arrow_,
        address seat_,
        address usdg_,
        address feeWallet_,
        address capRaiser_,
        uint256 shotFee_,
        uint256 withdrawFee_,
        string[] memory presets_
    ) EIP712("Stash", "1") {
        if (core_ == address(0) || arrow_ == address(0) || seat_ == address(0) || usdg_ == address(0)) {
            revert ZeroAddress();
        }
        if (feeWallet_ == address(0) || capRaiser_ == address(0)) revert ZeroAddress();
        if (core_.code.length == 0 || arrow_.code.length == 0 || seat_.code.length == 0 || usdg_.code.length == 0) {
            revert ZeroAddress();
        }
        if (feeWallet_ == core_ || feeWallet_ == arrow_ || feeWallet_ == seat_ || feeWallet_ == address(this)) {
            revert BadFeeWallet();
        }
        if (shotFee_ > MAX_SHOT_FEE || withdrawFee_ > MAX_WITHDRAW_FEE) revert FeeAboveMax();
        uint256 n = presets_.length;
        if (n == 0 || n > MAX_PRESETS) revert BadPresets();
        for (uint256 i; i < n; ++i) {
            if (!_acceptable(presets_[i])) revert BadPresets();
            _presets.push(presets_[i]);
        }

        usdg = IERC20(usdg_);
        core = core_;
        arrow = ILastArrow(arrow_);
        seat = ISheriffsSeat(seat_);
        feeWallet = feeWallet_;
        capRaiser = capRaiser_;
        shotFee = shotFee_;
        withdrawFee = withdrawFee_;
        cap = LAUNCH_CAP;
    }

    // ================================================================== views

    function balance(address owner) external view returns (uint256) {
        return _balances[owner];
    }

    /// @notice Tokens held above the sum of balances and the accrued fees. Direct transfers land here and stay here.
    function sweepable() external view returns (uint256) {
        return usdg.balanceOf(address(this)) - totalHeld - feesAccrued;
    }

    function presetCount() external view returns (uint256) {
        return _presets.length;
    }

    function preset(uint256 id) external view returns (string memory) {
        if (id >= _presets.length) revert BadPreset();
        return _presets[id];
    }

    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    function hashShoot(Shoot calldata order) external view returns (bytes32) {
        return _hashTypedDataV4(_shootStruct(order));
    }

    function hashTake(Take calldata order) external view returns (bytes32) {
        return _hashTypedDataV4(_takeStruct(order));
    }

    function hashWithdraw(Withdrawal calldata order) external view returns (bytes32) {
        return _hashTypedDataV4(_withdrawStruct(order));
    }

    function hashAuthorize(Authorize calldata order) external view returns (bytes32) {
        return _hashTypedDataV4(_authorizeStruct(order));
    }

    function hashSetLimit(LimitChange calldata order) external view returns (bytes32) {
        return _hashTypedDataV4(_limitStruct(order));
    }

    function hashRevoke(Revoke calldata order) external view returns (bytes32) {
        return _hashTypedDataV4(_revokeStruct(order));
    }

    // ================================================================== owner, direct

    /// @notice Pull `amount` USDG from the caller. The caller must have approved this contract.
    function deposit(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (cap != type(uint256).max && amount > cap - totalHeld) revert OverCap();
        uint256 beforeBal = usdg.balanceOf(address(this));
        usdg.safeTransferFrom(msg.sender, address(this), amount);
        if (usdg.balanceOf(address(this)) - beforeBal != amount) revert TransferMismatch();
        _balances[msg.sender] += amount;
        totalHeld += amount;
        emit Deposited(msg.sender, amount);
    }

    /// @notice Send `amount` minus the withdrawal fee to the caller. The main wallet pays its own gas. A balance at or
    ///         below the fee cannot be withdrawn.
    function withdraw(uint256 amount) external nonReentrant {
        _withdraw(msg.sender, amount, withdrawFee);
    }

    /// @notice Start a new session for `key`. Uses the caller's nonce, so any signed order not yet sent is void.
    function authorizeKey(address key, uint256 limit, uint256 expiry) external nonReentrant {
        _useNonce(msg.sender);
        _authorize(msg.sender, key, limit, expiry);
    }

    /// @notice Change the session spend limit. Uses the caller's nonce, so any signed order not yet sent is void.
    function setLimit(uint256 newLimit) external nonReentrant {
        _useNonce(msg.sender);
        _setLimit(msg.sender, newLimit);
    }

    /// @notice End the session. Uses the caller's nonce, so a held order signed at the current nonce (an AuthorizeKey
    ///         included) cannot bring a key back after this call.
    function revokeKey() external nonReentrant {
        _useNonce(msg.sender);
        _revoke(msg.sender);
    }

    /// @notice Void the caller's signed orders that were never sent, owner and key orders alike, without changing
    ///         the session or the balance. Orders are signed at the current nonce, so one call voids them all.
    function cancelNonce() external {
        emit NonceCancelled(msg.sender, _useNonce(msg.sender));
    }

    /// @notice Shoot as the caller. No shot fee. `maxPrice` is the most the game may charge.
    function shoot(uint256 maxPrice, uint256 expectedRound) external nonReentrant {
        _play(msg.sender, address(0), maxPrice, 0, false, true, expectedRound, 0, 0);
    }

    /// @notice Take the seat as the caller. No shot fee. The message is the preset at `presetId`.
    function take(uint256 maxPrice, uint8 presetId, uint8 color) external nonReentrant {
        _play(msg.sender, address(0), maxPrice, 0, false, false, 0, presetId, color);
    }

    // ================================================================== owner, relayed

    /// @notice Relayed withdrawal. The owner signs. The payout is `amount` minus the withdrawal fee. A balance at or
    ///         below the fee cannot be withdrawn.
    function withdraw(Withdrawal calldata order, bytes calldata signature) external nonReentrant {
        _consumeOwner(order.owner, _withdrawStruct(order), order.nonce, order.deadline, signature);
        _withdraw(order.owner, order.amount, withdrawFee);
    }

    function authorizeKey(Authorize calldata order, bytes calldata signature) external nonReentrant {
        _consumeOwner(order.owner, _authorizeStruct(order), order.nonce, order.deadline, signature);
        _authorize(order.owner, order.key, order.limit, order.expiry);
    }

    function setLimit(LimitChange calldata order, bytes calldata signature) external nonReentrant {
        _consumeOwner(order.owner, _limitStruct(order), order.nonce, order.deadline, signature);
        _setLimit(order.owner, order.newLimit);
    }

    function revokeKey(Revoke calldata order, bytes calldata signature) external nonReentrant {
        _consumeOwner(order.owner, _revokeStruct(order), order.nonce, order.deadline, signature);
        _revoke(order.owner);
    }

    // ================================================================== key

    /// @notice Relayed shot. The active session key signs. A fee is charged only if the shot lands.
    function shoot(Shoot calldata order, bytes calldata signature) external nonReentrant {
        address key = _consumeKey(order.owner, order.epoch, order.deadline, _shootStruct(order), order.nonce, signature);
        _play(order.owner, key, order.maxPrice, _sessionFee(order.owner), true, true, order.expectedRound, 0, 0);
    }

    /// @notice Relayed seat take. The key signs a preset id, not free text.
    function take(Take calldata order, bytes calldata signature) external nonReentrant {
        address key = _consumeKey(order.owner, order.epoch, order.deadline, _takeStruct(order), order.nonce, signature);
        _play(order.owner, key, order.maxPrice, _sessionFee(order.owner), true, false, 0, order.presetId, order.color);
    }

    // ================================================================== fees

    /// @notice Send every accrued fee to `feeWallet`. Anyone may call. The recipient and the amount are fixed by the
    ///         contract, so the caller only picks the time. If the fee wallet cannot receive, this reverts and the fees
    ///         stay accrued, and player balances are not affected.
    function flushFees() external nonReentrant {
        uint256 amount = feesAccrued;
        if (amount == 0) revert ZeroAmount();
        feesAccrued = 0;
        _pay(feeWallet, amount);
        emit FeesFlushed(feeWallet, amount);
    }

    // ================================================================== cap and shot fee

    /// @notice Raise the deposit cap. `type(uint256).max` removes it. The cap cannot fall.
    function raiseCap(uint256 newCap) external {
        if (msg.sender != capRaiser) revert NotCapRaiser();
        if (newCap <= cap) revert CapNotRaised();
        cap = newCap;
        emit CapRaised(newCap);
    }

    /// @notice Set the shot fee, at most `MAX_SHOT_FEE`. A lower fee applies to every session at once. A higher fee
    ///         applies only to sessions authorized after this call. Renouncing the cap raiser freezes the fee.
    function setShotFee(uint256 newFee) external {
        if (msg.sender != capRaiser) revert NotCapRaiser();
        if (newFee > MAX_SHOT_FEE) revert FeeAboveMax();
        emit ShotFeeSet(shotFee, newFee);
        shotFee = newFee;
    }

    /// @notice Give up the cap raiser role for good. This also freezes the shot fee.
    function renounceCapRaiser() external {
        if (msg.sender != capRaiser) revert NotCapRaiser();
        emit CapRaiserRenounced(msg.sender);
        capRaiser = address(0);
    }

    // ================================================================== internals

    function _authorize(address owner, address key, uint256 limit, uint256 expiry) internal {
        if (key == address(0)) revert ZeroAddress();
        if (limit == 0) revert ZeroAmount();
        if (expiry <= block.timestamp) revert ExpiryNotFuture();
        if (expiry > block.timestamp + MAX_KEY_EXPIRY) revert ExpiryTooFar();
        Session storage s = session[owner];
        uint48 epoch = s.epoch + 1;
        s.key = key;
        s.expiry = uint48(expiry);
        s.epoch = epoch;
        s.limit = limit;
        s.spent = 0;
        s.feeCap = shotFee;
        emit KeyAuthorized(owner, key, limit, uint48(expiry), epoch);
    }

    function _setLimit(address owner, uint256 newLimit) internal {
        Session storage s = session[owner];
        if (s.key == address(0)) revert KeyMissing();
        if (newLimit == 0) revert ZeroAmount();
        if (newLimit != UNLIMITED && newLimit < s.spent) revert LimitBelowSpent();
        s.limit = newLimit;
        emit LimitSet(owner, newLimit);
    }

    function _revoke(address owner) internal {
        Session storage s = session[owner];
        address key = s.key;
        if (key == address(0)) revert KeyMissing();
        uint48 epoch = s.epoch + 1;
        s.key = address(0);
        s.expiry = 0;
        s.limit = 0;
        s.spent = 0;
        s.feeCap = 0;
        s.epoch = epoch;
        emit KeyRevoked(owner, key, epoch);
    }

    /// @dev The fee a relayed play pays. A fee raised after the key was authorized does not reach this session.
    function _sessionFee(address owner) internal view returns (uint256) {
        return Math.min(shotFee, session[owner].feeCap);
    }

    /// @dev A balance at or below the fee cannot be withdrawn and stays in the Stash. Above that, the amount must be
    ///      above the fee. A withdrawal may leave a balance at or below the fee. Every withdrawal accrues the fee for
    ///      `flushFees`. Direct and relayed paths share this check.
    function _withdraw(address owner, uint256 amount, uint256 fee) internal {
        uint256 bal = _balances[owner];
        if (bal <= fee) revert BalanceAtOrBelowFee();
        if (amount == 0) revert ZeroAmount();
        if (bal < amount) revert InsufficientBalance();
        if (amount <= fee) revert AmountNotAboveFee();
        _balances[owner] = bal - amount;
        totalHeld -= amount;
        if (fee != 0) feesAccrued += fee;
        _pay(owner, amount - fee);
        emit Withdrawn(owner, amount, fee);
    }

    /// @dev Debits the quoted price plus the fee, then approves FairCore for exactly `maxPrice` and calls the game
    ///      with `player` set to the owner. The approval is cleared to 0. The fee stays here as `feesAccrued`.
    ///      A revert in the game rolls the debit back.
    function _play(
        address owner,
        address key,
        uint256 maxPrice,
        uint256 fee,
        bool useLimit,
        bool isArrow,
        uint256 expectedRound,
        uint8 presetId,
        uint8 color
    ) internal {
        if (maxPrice == 0) revert ZeroAmount();
        string memory message = "";
        if (!isArrow) {
            if (presetId >= _presets.length) revert BadPreset();
            message = _presets[presetId];
        }
        uint256 price = isArrow ? _quoteArrow() : _quoteSeat();
        if (price == 0) revert ZeroAmount();
        if (price > maxPrice) revert PriceAboveMax(price, maxPrice);

        uint256 cost = price + fee;
        uint256 bal = _balances[owner];
        if (bal < cost) revert InsufficientBalance();
        if (useLimit) {
            Session storage s = session[owner];
            uint256 limit = s.limit;
            if (limit != UNLIMITED) {
                uint256 spent = s.spent;
                if (spent > limit || cost > limit - spent) revert OverLimit();
            }
            s.spent = s.spent + cost;
        }
        _balances[owner] = bal - cost;
        totalHeld -= cost;

        uint256 beforeBal = usdg.balanceOf(address(this));
        usdg.forceApprove(core, maxPrice);
        uint256 charged = isArrow ? arrow.shoot(maxPrice, owner, expectedRound) : seat.take(maxPrice, owner, message, color);
        uint256 afterBal = usdg.balanceOf(address(this));
        if (charged != price || afterBal > beforeBal || beforeBal - afterBal != price) revert TransferMismatch();
        usdg.forceApprove(core, 0);
        if (fee != 0) feesAccrued += fee;
        emit Played(owner, key, isArrow ? address(arrow) : address(seat), price, fee);
    }

    function _quoteArrow() internal view returns (uint256 price) {
        (bool ok, bytes memory data) = address(arrow).staticcall(abi.encodeCall(ILastArrow.currentPrice, ()));
        if (!ok || data.length != 32) revert QuoteFailed();
        price = abi.decode(data, (uint256));
    }

    function _quoteSeat() internal view returns (uint256 price) {
        (bool ok, bytes memory data) = address(seat).staticcall(abi.encodeCall(ISheriffsSeat.price, ()));
        if (!ok || data.length != 32) revert QuoteFailed();
        price = abi.decode(data, (uint256));
    }

    function _pay(address to, uint256 amount) internal {
        uint256 beforeBal = usdg.balanceOf(to);
        usdg.safeTransfer(to, amount);
        if (usdg.balanceOf(to) - beforeBal != amount) revert TransferMismatch();
    }

    function _consumeOwner(address owner, bytes32 structHash, uint256 nonce, uint256 deadline, bytes calldata signature)
        internal
    {
        if (block.timestamp > deadline) revert DeadlineExpired();
        if (!SignatureChecker.isValidSignatureNow(owner, _hashTypedDataV4(structHash), signature)) revert BadSignature();
        _useCheckedNonce(owner, nonce);
    }

    function _consumeKey(
        address owner,
        uint256 epoch,
        uint256 deadline,
        bytes32 structHash,
        uint256 nonce,
        bytes calldata signature
    ) internal returns (address key) {
        if (block.timestamp > deadline) revert DeadlineExpired();
        Session storage s = session[owner];
        key = s.key;
        if (key == address(0)) revert KeyMissing();
        if (block.timestamp >= s.expiry) revert KeyExpired();
        if (epoch != s.epoch) revert StaleEpoch();
        if (!SignatureChecker.isValidSignatureNow(key, _hashTypedDataV4(structHash), signature)) revert BadSignature();
        _useCheckedNonce(owner, nonce);
    }

    function _shootStruct(Shoot calldata order) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                SHOOT_TYPEHASH, order.owner, order.maxPrice, order.expectedRound, order.nonce, order.deadline, order.epoch
            )
        );
    }

    function _takeStruct(Take calldata order) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                TAKE_TYPEHASH,
                order.owner,
                order.maxPrice,
                order.presetId,
                order.color,
                order.nonce,
                order.deadline,
                order.epoch
            )
        );
    }

    function _withdrawStruct(Withdrawal calldata order) internal pure returns (bytes32) {
        return keccak256(abi.encode(WITHDRAW_TYPEHASH, order.owner, order.amount, order.nonce, order.deadline));
    }

    function _authorizeStruct(Authorize calldata order) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(AUTHORIZE_TYPEHASH, order.owner, order.key, order.limit, order.expiry, order.nonce, order.deadline)
        );
    }

    function _limitStruct(LimitChange calldata order) internal pure returns (bytes32) {
        return keccak256(abi.encode(SET_LIMIT_TYPEHASH, order.owner, order.newLimit, order.nonce, order.deadline));
    }

    function _revokeStruct(Revoke calldata order) internal pure returns (bytes32) {
        return keccak256(abi.encode(REVOKE_TYPEHASH, order.owner, order.nonce, order.deadline));
    }

    /// @dev Preset lines are shown to players. Empty, too long, or carrying a colon, semicolon or em dash is rejected.
    function _acceptable(string memory text) internal pure returns (bool) {
        bytes memory b = bytes(text);
        uint256 n = b.length;
        if (n == 0 || n > MAX_PRESET_BYTES) return false;
        for (uint256 i; i < n; ++i) {
            bytes1 c = b[i];
            if (c == 0x3a || c == 0x3b) return false;
            if (c == 0xe2 && i + 2 < n && b[i + 1] == 0x80 && b[i + 2] == 0x94) return false;
        }
        return true;
    }
}
