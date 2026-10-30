// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @title SafeHandover
/// @notice A1-14: lets the deploy script give ownership straight to the owner Safe in the same broadcast that deployed
///         and wired the contract, so the deployer EOA holds no power once the script ends (no window waiting for the
///         Safe's acceptOwnership). Ownable2Step stays for every later transfer.
/// @dev One-shot by construction: only an owner with no code (the fresh deployer EOA) can call it, and only towards a
///      contract (the Safe). Once the Safe owns the contract it cannot use this path, so the Safe's own transfers keep
///      the two-step accept. The deploy script checks the target is the pinned, genuine 2-of-3 Safe before broadcast.
abstract contract SafeHandover is Ownable2Step {
    error HandOverFromEoaOnly();
    error HandOverToContractOnly();

    function handOver(address safe) external onlyOwner {
        if (msg.sender.code.length != 0) revert HandOverFromEoaOnly();
        if (safe.code.length == 0) revert HandOverToContractOnly();
        _transferOwnership(safe); // Ownable2Step: also clears any pending offer
    }
}
