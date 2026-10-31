// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IBuyRoute} from "../interfaces/IFair.sol";
import {PoolKey, SwapParams, IPoolManager, IUnlockCallback} from "../interfaces/IV4Minimal.sol";

/// @title BuyRouteV4 (route A)
/// @notice USDG -> ETH on the ETH/USDG v4 pool (Fables hook), then ETH -> tokenOut on an ETH/tokenOut v4 pool (at launch
///         the WIF/ETH pool, Pons hook), inside one PoolManager unlock, with tokenOut taken straight to the recipient.
///         One deployment per output token; its pool keys are immutable. No approvals: USDG is sent
///         in first and settled. Holds nothing between calls. Only FairCore can call it.
contract BuyRouteV4 is IBuyRoute, IUnlockCallback {
    using SafeERC20 for IERC20;

    uint160 internal constant MIN_SQRT_PRICE_PLUS_1 = 4295128740;
    uint160 internal constant MAX_SQRT_PRICE_MINUS_1 = 1461446703485210103287273052203988822378723970341;

    IPoolManager public immutable pm;
    address public immutable core;
    address public immutable usdg;
    address public immutable tokenOut; // the token this route buys (the pool's currency1)
    PoolKey internal usdgPool; // ETH (currency0) / USDG (currency1)
    PoolKey internal outPool; // ETH (currency0) / tokenOut (currency1)

    error OnlyCore();
    error NotPoolManager();
    error ShortFill();
    error BadPool();

    constructor(address pm_, address core_, PoolKey memory usdgPool_, PoolKey memory outPool_) {
        if (usdgPool_.currency0 != address(0) || outPool_.currency0 != address(0)) revert BadPool();
        (pm, core) = (IPoolManager(pm_), core_);
        (usdg, tokenOut) = (usdgPool_.currency1, outPool_.currency1);
        (usdgPool, outPool) = (usdgPool_, outPool_);
    }

    /// @notice The USDG/ETH pool, then the ETH/tokenOut pool. Both keys are fixed at construction.
    function pools() external view returns (PoolKey memory, PoolKey memory) {
        return (usdgPool, outPool);
    }

    /// @notice Only FairCore. Swaps `usdgIn` USDG to `tokenOut` and pays `recipient` (FairCore passes itself).
    /// @return out Amount of `tokenOut` taken from the pool. FairCore recounts this by its own balance.
    function swapToToken(uint256 usdgIn, uint256 minOut, address recipient) external returns (uint256 out) {
        if (msg.sender != core) revert OnlyCore();
        out = abi.decode(pm.unlock(abi.encode(usdgIn, recipient)), (uint256));
        if (out < minOut) revert ShortFill(); // FairCore measures its own balance and forwards that amount
    }

    /// @notice PoolManager callback for the two-leg swap. Settles the USDG and takes `tokenOut` to the recipient.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(pm)) revert NotPoolManager();
        (uint256 usdgIn, address recipient) = abi.decode(data, (uint256, address));
        // Leg 1: exact-input USDG -> ETH (oneForZero). v4: amountSpecified < 0 means exact input.
        int256 d1 = pm.swap(usdgPool, SwapParams(false, -int256(usdgIn), MAX_SQRT_PRICE_MINUS_1), "");
        int128 eth = _a0(d1);
        if (eth <= 0 || uint256(int256(-_a1(d1))) != usdgIn) revert ShortFill();
        // Leg 2: exact-input all of that ETH -> tokenOut. The ETH deltas cancel inside the unlock.
        int256 d2 = pm.swap(outPool, SwapParams(true, -int256(eth), MIN_SQRT_PRICE_PLUS_1), "");
        if (_a0(d2) != -eth) revert ShortFill();
        int128 out = _a1(d2);
        if (out <= 0) revert ShortFill();
        pm.sync(usdg);
        IERC20(usdg).safeTransfer(address(pm), usdgIn);
        pm.settle();
        pm.take(tokenOut, recipient, uint256(int256(out)));
        return abi.encode(uint256(int256(out)));
    }

    /// @dev High 128 bits of a v4 balance delta (currency0).
    function _a0(int256 d) internal pure returns (int128 a) {
        assembly {
            a := sar(128, d)
        }
    }

    /// @dev Low 128 bits of a v4 balance delta (currency1), sign-extended.
    function _a1(int256 d) internal pure returns (int128 a) {
        assembly {
            a := signextend(15, d)
        }
    }
}
