// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice The parts of the ERC-8004 Identity registry Robin Among Thieves calls.
interface IIdentityRegistry {
    function register(string calldata agentURI) external returns (uint256 agentId);
    function ownerOf(uint256 agentId) external view returns (address);
    function getAgentWallet(uint256 agentId) external view returns (address);
    function transferFrom(address from, address to, uint256 agentId) external;
    function isAuthorizedOrOwner(address spender, uint256 agentId) external view returns (bool);
}

/// @notice The parts of the ERC-8004 Reputation registry Robin Among Thieves calls.
interface IReputationRegistry {
    function giveFeedback(
        uint256 agentId,
        int128 value,
        uint8 valueDecimals,
        string calldata tag1,
        string calldata tag2,
        string calldata endpoint,
        string calldata feedbackURI,
        bytes32 feedbackHash
    ) external;
}
