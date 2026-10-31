// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

/// @notice What the game plays and buys with, read from GameConfig.
struct Tokens {
    address playToken; // the token a Fair Pass locks
    uint256 passLock; // how much of it a new pass locks
    address buyToken; // what the Bonfire burns and the Vault buys
}

/// @notice The shot split. purse is of the shot; alms/bonfire/toll are of the Greenwood (the Vault takes the rest);
///         vBuy/vLiq/vBurn are of the Vault (vaultFairsBurnUsdg takes the rest plus dust).
struct Split {
    uint16 purseBps;
    uint16 almsBps;
    uint16 bonfireBps;
    uint16 tollBps;
    uint16 vBuyBps;
    uint16 vLiqBps;
    uint16 vBurnBps;
}

interface IGameConfig {
    function tokens() external view returns (address playToken, uint256 passLock, address buyToken);
    function split() external view returns (Split memory);
    function epoch() external view returns (uint64);
    function usdg() external view returns (address);
}

interface IFairPass {
    function hasPass(address a) external view returns (bool);
    function heldSince(address a) external view returns (uint64);
}

/// @notice A buyback route for one token. FairCore sends `usdgIn` USDG to the route first, then calls swap with
///         itself as `recipient`, and checks `tokenOut()` is the current buy token before every swap. FairCore counts
///         the buy token by its own balance and forwards that amount. Fee-on-transfer buy tokens are unsupported.
interface IBuyRoute {
    function tokenOut() external view returns (address);
    function swapToToken(uint256 usdgIn, uint256 minOut, address recipient) external returns (uint256 out);
}

interface IFairCore {
    function collect(address payer, address player, uint256 roundKey, uint256 gross) external;
    function award(uint256 roundKey, address[] calldata winners, uint256[] calldata amounts) external;
    function pot(address booth, uint256 roundKey) external view returns (uint256);
    function fairPass() external view returns (IFairPass);
    function playedIn(uint256 fairId, address player) external view returns (bool);
    function spentIn(uint256 fairId, address player) external view returns (uint256);
    function netSpentIn(uint256 fairId, address player) external view returns (uint256);
    function releaseAlms(uint256 fairId) external returns (uint256 amount);
    function carryAlms(uint256 fairId) external returns (uint256 amount);
    function activeFair() external view returns (bool active, uint256 fairId);
    function pausedSeconds() external view returns (uint256);
    function pauseCount() external view returns (uint256);
    function pausedBetween(uint256 fromIdx, uint256 from, uint256 to) external view returns (uint256);
    function fairs(uint256 fairId) external view returns (uint64 start, uint64 end);
}

/// @notice Read by FairCore so booths don't need to know about each other.
interface IArbSys {
    function arbBlockNumber() external view returns (uint256);
    /// @dev Hash of an earlier L2 block. On Robinhood Chain mainnet (4663) and testnet (46630) this
    ///      reverts `InvalidBlockNumber` for the current block and for a block older than 256. It does not return 0.
    function arbBlockHash(uint256 arbBlockNum) external view returns (bytes32);
}
