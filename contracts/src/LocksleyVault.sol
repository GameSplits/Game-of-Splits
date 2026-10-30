// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {SafeHandover} from "./SafeHandover.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface ICoreVaultUsdg {
    function releaseVaultUsdg(address to) external returns (uint256);
}

/// @title LocksleyVault
/// @notice Holds the tokens the keeper buys for the Vault (GameConfig's buy token) for future liquidity. The Vault's
///         USDG (the future pool side and the future burn bucket) stays as ledgers in FairCore.
///         In this build nothing can move either. Later the owner can attach one launcher contract, once, after a
///         7-day timelock announced on-chain; only that launcher can then pull the Vault's tokens and USDG.
///         GameConfig has no reach into the Vault.
contract LocksleyVault is SafeHandover, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant LAUNCHER_DELAY = 7 days;

    ICoreVaultUsdg public immutable core;

    address public queuedLauncher;
    uint256 public launcherEta;
    address public launcher; // set once; zero in this build

    event LauncherQueued(address indexed launcher, uint256 eta);
    event LauncherCancelled(address indexed launcher);
    event LauncherAttached(address indexed launcher);
    event PulledByLauncher(address indexed launcher, address indexed token, uint256 amount);
    event VaultUsdgSkipped(address indexed to);

    error AlreadyAttached();
    error NotQueued();
    error TooEarly(uint256 eta);
    error NotLauncher();
    error ZeroAddress();
    error RenounceDisabled();

    constructor(ICoreVaultUsdg core_, address owner_) Ownable(owner_) {
        if (address(core_) == address(0)) revert ZeroAddress();
        core = core_;
    }

    function heldOf(IERC20 token) external view returns (uint256) {
        return token.balanceOf(address(this));
    }

    /// @notice Announce the launcher; it can be attached 7 days later at the earliest.
    function queueLauncher(address l) external onlyOwner {
        if (launcher != address(0)) revert AlreadyAttached();
        if (l == address(0)) revert ZeroAddress();
        queuedLauncher = l;
        launcherEta = block.timestamp + LAUNCHER_DELAY;
        emit LauncherQueued(l, launcherEta);
    }

    function cancelLauncher() external onlyOwner {
        if (queuedLauncher == address(0)) revert NotQueued();
        emit LauncherCancelled(queuedLauncher);
        queuedLauncher = address(0);
        launcherEta = 0;
    }

    /// @notice One-time. After this, the launcher (and only it) can pull the Vault's funds.
    function attachLauncher() external onlyOwner {
        if (launcher != address(0)) revert AlreadyAttached();
        if (queuedLauncher == address(0)) revert NotQueued();
        if (block.timestamp < launcherEta) revert TooEarly(launcherEta);
        launcher = queuedLauncher;
        queuedLauncher = address(0);
        emit LauncherAttached(launcher);
    }

    /// @notice The launcher takes the full balance of each listed token, and the Vault's USDG from FairCore,
    ///         paid to the launcher. A reverting USDG transfer does not undo the token pull.
    function pull(IERC20[] calldata tokens)
        external
        nonReentrant
        returns (uint256[] memory amounts, uint256 usdgAmount)
    {
        return _pull(tokens, launcher);
    }

    /// @notice Same as `pull(tokens)`, but the Vault's USDG is paid to `to` (a blacklisted launcher can
    ///         name another recipient). Token balances still go to the launcher.
    function pull(IERC20[] calldata tokens, address to)
        external
        nonReentrant
        returns (uint256[] memory amounts, uint256 usdgAmount)
    {
        if (to == address(0)) revert ZeroAddress();
        return _pull(tokens, to);
    }

    /// @dev Tokens move first. If FairCore's USDG transfer reverts, the USDG stays pending there and a later
    ///      pull can release it. The token pull is not rolled back.
    function _pull(IERC20[] calldata tokens, address to)
        internal
        returns (uint256[] memory amounts, uint256 usdgAmount)
    {
        if (msg.sender != launcher || launcher == address(0)) revert NotLauncher();
        amounts = new uint256[](tokens.length);
        for (uint256 i; i < tokens.length; ++i) {
            uint256 a = tokens[i].balanceOf(address(this));
            amounts[i] = a;
            if (a != 0) tokens[i].safeTransfer(launcher, a);
            emit PulledByLauncher(launcher, address(tokens[i]), a);
        }
        try core.releaseVaultUsdg(to) returns (uint256 amount) {
            usdgAmount = amount;
        } catch {
            emit VaultUsdgSkipped(to);
        }
    }

    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }
}
