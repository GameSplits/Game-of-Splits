// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

/// @notice Stand-in for ArbSys at 0x64 on a local anvil fork. The number moves with time.
contract ForkArb {
    function arbBlockNumber() external view returns (uint256) {
        return 5_000_000 + block.timestamp;
    }

    function arbBlockHash(uint256) external pure returns (bytes32) {
        return bytes32(uint256(1));
    }
}
