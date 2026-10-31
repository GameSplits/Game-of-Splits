// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Script} from "forge-std/Script.sol";

/// Robinhood Chain is an Arbitrum Orbit chain. Some forge versions report the L1 (Ethereum) block number there for
/// both `block.number` and `vm.getBlockNumber()`, while `eth_getLogs` and indexers use L2 block numbers. Always ask
/// the node (audit v3.6 M1).
abstract contract L2Head is Script {
    function _l2Head() internal returns (uint256) {
        bytes memory r = vm.rpc("eth_blockNumber", "[]");
        return uint256(bytes32(r)) >> (256 - r.length * 8);
    }
}
