// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {console2} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {FeeSplitter} from "../src/FeeSplitter.sol";
import {SafeCheck} from "./Deploy.s.sol";
import {LaunchSplit} from "./LaunchSplit.s.sol";

interface IOwned {
    function owner() external view returns (address);
}

/// @notice BLK-5: deploy FeeSplitter on Robinhood Chain (4663, or 46630 for the rehearsal) right after the main deploy,
///         from the same deployer keystore, before SafeAcceptVerify. The pinned Safe is the owner from the
///         constructor, so the deployer never owns it and there is nothing to hand over. Recipients and the split
///         change only through the Safe's `queue` / 7 days / `execute`.
///
///         Reads `wif`, `fairCore`, `rakeBuyer` and `locksleyVault` from deployments/<chainId>.json and refuses unless
///         the Safe already owns FairCore (the main deploy finished). Adds `feeSplitter` to that file on a broadcast
///         (a dry run writes deployments/dryrun-<chainId>.json). SafeAcceptVerify then checks it, and on mainnet
///         Verify fails while the file has no `feeSplitter`.
///
///         Env (required): GOS_SAFE (or OWNER_SAFE, the pinned Safe), SAFE_OWNERS, PURSES, REBATE, BURN_BUYER, OPS.
///         There are no defaults for the four holding addresses. Each must be an EOA or the Safe itself (the same
///         rule SafeAcceptVerify applies), and none may be the deployer. The vault leg is always the Locksley Vault.
///         Optional: FEE_SPLIT_BPS="purses,vault,rebate,burn,ops" (default 4000,2500,1500,1000,1000).
///           forge script script/DeployFeeSplitter.s.sol:DeployFeeSplitter --rpc-url robinhood \
///             --broadcast --slow --account gos-mainnet --sender <DEPLOYER>
contract DeployFeeSplitter is SafeCheck, LaunchSplit {
    function run() external {
        require(block.chainid == 4663 || block.chainid == 46630, "Robinhood Chain only");
        address safe = _safeFromEnv();
        _requirePinned(safe, block.chainid == 4663 ? PINNED_MAINNET_SAFE : PINNED_TESTNET_SAFE, "GOS_SAFE");
        _checkSafe(safe, vm.envAddress("SAFE_OWNERS", ","), "GOS_SAFE");

        string memory id = vm.toString(block.chainid);
        string memory file = string.concat("deployments/", id, ".json");
        string memory j = vm.readFile(file);
        require(vm.parseJsonUint(j, ".chainId") == block.chainid, "deployment file is for another chain");
        require(!vm.keyExistsJson(j, ".feeSplitter"), "deployment file already has a feeSplitter");
        address wif = vm.parseJsonAddress(j, ".wif");
        address core = vm.parseJsonAddress(j, ".fairCore");
        address rake = vm.parseJsonAddress(j, ".rakeBuyer");
        address vault = vm.parseJsonAddress(j, ".locksleyVault");
        require(wif.code.length != 0 && core.code.length != 0, "wif or FairCore missing");
        require(rake.code.length != 0 && vault.code.length != 0, "RakeBuyer or Locksley Vault missing");
        require(IOwned(core).owner() == safe && IOwned(rake).owner() == safe, "main deploy not handed to the Safe");

        FeeSplitter.Recipients memory r = FeeSplitter.Recipients({
            purses: vm.envAddress("PURSES"),
            vault: vault,
            rebate: vm.envAddress("REBATE"),
            burnBuyer: vm.envAddress("BURN_BUYER"),
            ops: vm.envAddress("OPS")
        });
        (, address sender,) = vm.readCallers();
        _holding(r.purses, safe, sender, "PURSES");
        _holding(r.rebate, safe, sender, "REBATE");
        _holding(r.burnBuyer, safe, sender, "BURN_BUYER");
        _holding(r.ops, safe, sender, "OPS");
        FeeSplitter.FeeSplit memory s = _feeSplitFromEnv();

        vm.startBroadcast();
        FeeSplitter fs = new FeeSplitter(wif, safe, r, s, core, rake);
        vm.stopBroadcast();

        require(fs.owner() == safe && fs.pendingOwner() == address(0), "FeeSplitter owner");
        require(fs.wif() == wif && fs.fairCore() == core && fs.rakeBuyer() == rake, "FeeSplitter immutables");
        require(fs.vault() == vault && fs.TIMELOCK() == 7 days, "FeeSplitter vault or timelock");

        string memory out = vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)
            ? file
            : string.concat("deployments/dryrun-", id, ".json");
        string memory k = "withFeeSplitter";
        vm.serializeJson(k, j);
        vm.writeJson(vm.serializeAddress(k, "feeSplitter", address(fs)), out);
        console2.log("FeeSplitter", address(fs));
        console2.log("owner (Safe)", safe);
        console2.log("split bps purses vault rebate burn ops", s.pursesBps, s.vaultBps);
        console2.log("  ", s.rebateBps, s.burnBps, s.opsBps);
        console2.log("wrote", out);
    }

    function _holding(address a, address safe, address sender, string memory name) internal view {
        require(a != address(0), string.concat(name, " not set"));
        require(a != sender, string.concat(name, " is the deployer"));
        require(a.code.length == 0 || a == safe, string.concat(name, " must be an EOA or the Safe"));
    }
}
