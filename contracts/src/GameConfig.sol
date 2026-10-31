// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {SafeHandover} from "./SafeHandover.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Tokens, Split, IFairCore} from "./interfaces/IFair.sol";

/// @title GameConfig
/// @notice Safe-owned config with a 7-day timelock: the play token, the pass amount, the buy token and the shot split.
///         Every update is queue -> wait `delay` -> execute, one pending update of each kind at a time, with events.
///         Updates execute only while no Fair is running, and token updates increase `epoch`; FairCore's price
///         anchor is tied to the epoch it was set in. Fair Passes keep the token and amount they were locked with, and
///         nothing here can reach the Vault, the Purses or any USDG.
contract GameConfig is SafeHandover {
    uint256 public constant BPS = 10_000;
    uint256 public constant MAINNET_DELAY = 7 days;

    // split caps: every destination has a cap
    uint256 public constant PURSE_MIN = 5000; // of the shot
    uint256 public constant PURSE_MAX = 8000;
    uint256 public constant ALMS_MIN = 1000; // of the Greenwood: protects the charity promise
    uint256 public constant PART_MAX = 5000; // every other destination, remainders included

    uint256 public immutable delay;
    address public immutable usdg;

    Tokens internal _tokens;
    Split internal _split;
    uint64 public epoch; // +1 on every executed token update
    address public core; // bound once, so both executes can check that no Fair is running

    Tokens internal _pendingTokens;
    uint256 public tokensEta; // 0 = nothing pending
    Split internal _pendingSplit;
    uint256 public splitEta; // 0 = nothing pending

    event CoreBound(address core);
    event TokensQueued(uint64 nextEpoch, address playToken, uint256 passLock, address buyToken, uint256 eta);
    event TokensCancelled();
    event TokensExecuted(uint64 indexed epoch, address playToken, uint256 passLock, address buyToken);
    event SplitQueued(Split s, uint256 eta);
    event SplitCancelled();
    event SplitExecuted(Split s);

    error ZeroAddress();
    error NotAContract(address token);
    error TokenIsUsdg();
    error BadDecimals(address token);
    error BadPassLock();
    error BadSplit();
    error DelayTooShort();
    error AlreadyBound();
    error CoreNotBound();
    error AlreadyPending();
    error NothingPending();
    error TooEarly(uint256 eta);
    error FairActive(uint256 fairId);
    error RenounceDisabled();

    /// @param delay_ at least 7 days on mainnet (4663); 0 is allowed on other chains (testnet).
    constructor(address owner_, address usdg_, uint256 delay_, Tokens memory t0, Split memory s0) Ownable(owner_) {
        if (usdg_ == address(0)) revert ZeroAddress();
        if (block.chainid == 4663 && delay_ < MAINNET_DELAY) revert DelayTooShort();
        (delay, usdg) = (delay_, usdg_);
        _checkTokens(t0);
        _checkSplit(s0);
        (_tokens, _split) = (t0, s0);
    }

    // ------------------------------------------------------------------ views

    /// @notice The play token, the amount a new pass locks, and the buy token.
    function tokens() external view returns (address playToken, uint256 passLock, address buyToken) {
        return (_tokens.playToken, _tokens.passLock, _tokens.buyToken);
    }

    /// @notice The shot split in force.
    function split() external view returns (Split memory) {
        return _split;
    }

    /// @notice The queued token update. Zero addresses and a zero amount when nothing is queued.
    function pendingTokens() external view returns (address playToken, uint256 passLock, address buyToken) {
        return (_pendingTokens.playToken, _pendingTokens.passLock, _pendingTokens.buyToken);
    }

    /// @notice The queued split. Zeros when nothing is queued.
    function pendingSplit() external view returns (Split memory) {
        return _pendingSplit;
    }

    // ------------------------------------------------------------------ owner

    /// @notice Once, by the deploy script, right after FairCore exists.
    function bindCore(address core_) external onlyOwner {
        if (core != address(0)) revert AlreadyBound();
        if (core_ == address(0)) revert ZeroAddress();
        core = core_;
        emit CoreBound(core_);
    }

    /// @notice One pending update at a time: cancel and queue again for a different target (a fresh delay), so the
    ///         queued values players see can't change while they wait.
    function queueTokens(Tokens calldata t) external onlyOwner {
        if (tokensEta != 0) revert AlreadyPending();
        _checkTokens(t);
        _pendingTokens = t;
        tokensEta = block.timestamp + delay;
        emit TokensQueued(epoch + 1, t.playToken, t.passLock, t.buyToken, tokensEta);
    }

    /// @notice Drop the queued token update. Queue again to start a fresh delay.
    function cancelTokens() external onlyOwner {
        if (tokensEta == 0) revert NothingPending();
        delete _pendingTokens;
        tokensEta = 0;
        emit TokensCancelled();
    }

    /// @notice After the delay, and only while no Fair is running.
    function executeTokens() external onlyOwner {
        uint256 eta = tokensEta;
        if (eta == 0) revert NothingPending();
        if (block.timestamp < eta) revert TooEarly(eta);
        if (core == address(0)) revert CoreNotBound();
        (bool active, uint256 fairId) = IFairCore(core).activeFair();
        if (active) revert FairActive(fairId);
        Tokens memory t = _pendingTokens;
        _tokens = t;
        delete _pendingTokens;
        tokensEta = 0;
        uint64 e = ++epoch;
        emit TokensExecuted(e, t.playToken, t.passLock, t.buyToken);
    }

    /// @notice Same pattern for the split, and it too executes only between Fairs, so a Fair's rules never change
    ///         while it runs. It applies to shots taken after it executes: each shot is split once, atomically, so no
    ///         money already in a ledger moves.
    function queueSplit(Split calldata s) external onlyOwner {
        if (splitEta != 0) revert AlreadyPending();
        _checkSplit(s);
        _pendingSplit = s;
        splitEta = block.timestamp + delay;
        emit SplitQueued(s, splitEta);
    }

    /// @notice Drop the queued split. Queue again to start a fresh delay.
    function cancelSplit() external onlyOwner {
        if (splitEta == 0) revert NothingPending();
        delete _pendingSplit;
        splitEta = 0;
        emit SplitCancelled();
    }

    /// @notice After the delay, and only while no Fair is running.
    function executeSplit() external onlyOwner {
        uint256 eta = splitEta;
        if (eta == 0) revert NothingPending();
        if (block.timestamp < eta) revert TooEarly(eta);
        if (core == address(0)) revert CoreNotBound();
        (bool active, uint256 fairId) = IFairCore(core).activeFair();
        if (active) revert FairActive(fairId);
        Split memory s = _pendingSplit;
        _split = s;
        delete _pendingSplit;
        splitEta = 0;
        emit SplitExecuted(s);
    }

    /// @notice Disabled. The Safe stays the owner.
    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }

    // ------------------------------------------------------------------ validation

    function _checkTokens(Tokens memory t) internal view {
        if (t.playToken == address(0) || t.buyToken == address(0)) revert ZeroAddress();
        if (t.playToken.code.length == 0) revert NotAContract(t.playToken);
        if (t.buyToken.code.length == 0) revert NotAContract(t.buyToken);
        if (t.playToken == usdg || t.buyToken == usdg) revert TokenIsUsdg();
        if (t.passLock == 0 || t.passLock > type(uint128).max) revert BadPassLock();
        _checkDecimals(t.playToken);
        _checkDecimals(t.buyToken);
    }

    /// @dev Play and buy tokens are 18-decimal ERC-20s. A token with no `decimals()` is rejected too.
    function _checkDecimals(address token) internal view {
        try IERC20Metadata(token).decimals() returns (uint8 d) {
            if (d != 18) revert BadDecimals(token);
        } catch {
            revert BadDecimals(token);
        }
    }

    /// @dev Every destination is capped, remainders included, and the parts always add up to the whole (the
    ///      remainders are implicit), so FairCore's split can never strand or over-assign a unit.
    function _checkSplit(Split memory s) internal pure {
        if (s.purseBps < PURSE_MIN || s.purseBps > PURSE_MAX) revert BadSplit();
        uint256 gw = uint256(s.almsBps) + s.bonfireBps + s.tollBps;
        if (s.almsBps < ALMS_MIN || s.almsBps > PART_MAX || s.bonfireBps > PART_MAX || s.tollBps > PART_MAX) {
            revert BadSplit();
        }
        if (gw > BPS || BPS - gw > PART_MAX) revert BadSplit(); // the Vault's share is the Greenwood remainder
        uint256 v = uint256(s.vBuyBps) + s.vLiqBps + s.vBurnBps;
        if (s.vBuyBps > PART_MAX || s.vLiqBps > PART_MAX || s.vBurnBps > PART_MAX) revert BadSplit();
        if (v > BPS || BPS - v > PART_MAX) revert BadSplit(); // vaultFairsBurnUsdg is the Vault remainder
    }
}
