// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IBuyRoute} from "../interfaces/IFair.sol";
import {PoolKey, SwapParams, IPoolManager, IUnlockCallback} from "../interfaces/IV4Minimal.sol";

interface IUniswapV3Pool {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96, bytes calldata data)
        external
        returns (int256 amount0, int256 amount1);
}

interface IWETH {
    function withdraw(uint256) external;
}

/// @title BuyRouteV3V4 (route B)
/// @notice USDG -> WETH on the v3 USDG/WETH 0.01% pool, unwrap to ETH, then ETH -> tokenOut on an ETH/tokenOut v4 pool
///         (at launch the WIF/ETH pool, Pons hook), with tokenOut taken straight to the recipient. One deployment per
///         output token; its pools are immutable. Swaps the pool directly (no router, no Permit2, no
///         approvals). Holds nothing between calls. Only FairCore can call it.
contract BuyRouteV3V4 is IBuyRoute, IUnlockCallback {
    using SafeERC20 for IERC20;

    uint160 internal constant MIN_SQRT_PRICE_PLUS_1 = 4295128740;
    uint160 internal constant MAX_SQRT_RATIO_MINUS_1 = 1461446703485210103287273052203988822378723970341;

    IPoolManager public immutable pm;
    address public immutable core;
    IUniswapV3Pool public immutable v3Pool;
    address public immutable usdg;
    address public immutable weth;
    address public immutable tokenOut; // the token this route buys (the pool's currency1)
    bool internal immutable usdgIsToken0;
    PoolKey internal outPool; // ETH (currency0) / tokenOut (currency1)

    error OnlyCore();
    error NotPool();
    error NotPoolManager();
    error ShortFill();
    error BadPool();
    error NotWeth();

    constructor(address pm_, address core_, IUniswapV3Pool v3Pool_, address usdg_, address weth_, PoolKey memory outPool_) {
        address t0 = v3Pool_.token0();
        address t1 = v3Pool_.token1();
        if (!((t0 == usdg_ && t1 == weth_) || (t0 == weth_ && t1 == usdg_))) revert BadPool();
        if (outPool_.currency0 != address(0)) revert BadPool();
        (pm, core, v3Pool, usdg, weth, tokenOut) = (IPoolManager(pm_), core_, v3Pool_, usdg_, weth_, outPool_.currency1);
        usdgIsToken0 = t0 == usdg_;
        outPool = outPool_;
    }

    /// @notice The ETH/tokenOut v4 pool. Its key is fixed at construction; acceptance reads it.
    function pool() external view returns (PoolKey memory) {
        return outPool;
    }

    /// @notice Accepts ETH only from WETH, unwrapped on the v3 leg.
    receive() external payable {
        if (msg.sender != weth) revert NotWeth();
    }

    /// @notice Only FairCore. Swaps `usdgIn` USDG to `tokenOut` and pays `recipient` (FairCore passes itself).
    /// @return out Amount of `tokenOut` taken from the v4 pool. FairCore recounts this by its own balance.
    function swapToToken(uint256 usdgIn, uint256 minOut, address recipient) external returns (uint256 out) {
        if (msg.sender != core) revert OnlyCore();
        // Leg 1: exact-input USDG -> WETH on v3. In v3, a positive amountSpecified is exact input.
        bool zeroForOne = usdgIsToken0;
        (int256 a0, int256 a1) = v3Pool.swap(
            address(this), zeroForOne, int256(usdgIn), zeroForOne ? MIN_SQRT_PRICE_PLUS_1 : MAX_SQRT_RATIO_MINUS_1, ""
        );
        int256 wethDelta = zeroForOne ? a1 : a0; // negative = received
        int256 usdgDelta = zeroForOne ? a0 : a1; // positive = paid
        // All of usdgIn must have been taken (a price-limit stop would leave USDG stranded here).
        if (wethDelta >= 0 || usdgDelta != int256(usdgIn)) revert ShortFill();
        uint256 wethOut = uint256(-wethDelta);
        IWETH(weth).withdraw(wethOut);
        // Leg 2: exact-input ETH -> tokenOut on v4.
        out = abi.decode(pm.unlock(abi.encode(wethOut, recipient)), (uint256));
        if (out < minOut) revert ShortFill(); // FairCore measures its own balance and forwards that amount
    }

    /// @dev v3 pays us first, then asks for the USDG it is owed.
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
        if (msg.sender != address(v3Pool)) revert NotPool();
        int256 owed = usdgIsToken0 ? amount0Delta : amount1Delta;
        if (owed > 0) IERC20(usdg).safeTransfer(msg.sender, uint256(owed));
    }

    /// @notice PoolManager callback for the ETH to tokenOut leg. Settles the ETH and takes `tokenOut` to the recipient.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(pm)) revert NotPoolManager();
        (uint256 ethIn, address recipient) = abi.decode(data, (uint256, address));
        int256 d = pm.swap(outPool, SwapParams(true, -int256(ethIn), MIN_SQRT_PRICE_PLUS_1), "");
        int128 out = _a1(d);
        if (out <= 0 || uint256(int256(-_a0(d))) != ethIn) revert ShortFill();
        pm.settle{value: ethIn}();
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
