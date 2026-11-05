// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {console2} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {FeeSplitter} from "../src/FeeSplitter.sol";
import {SafeCheck} from "./Deploy.s.sol";
import {LaunchSplit} from "./LaunchSplit.s.sol";
import {MainnetAddrs} from "./Mainnet.s.sol";

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
///         Env (required): GOS_SAFE (or OWNER_SAFE, the pinned Safe), SAFE_OWNERS. On mainnet the split is fixed to
///         `_launchFeeSplit` (option b, 0/5000/0/4000/1000) and the four holding legs are the Safe (`_feeLegs`), and
///         FEE_SPLIT_BPS is refused (DS-1). PURSES, REBATE, BURN_BUYER and OPS may be left unset there, and if set they
///         must equal the Safe. On 46630 those four are required, and FEE_SPLIT_BPS may override the split. Each holding
///         leg must be an EOA or the Safe, none may be the deployer, and the vault leg is always the Locksley Vault.
///         On mainnet `wif` in the file must be the real $wif (DS-2), checked before anything is sent.
///
///         Resumable (DS-4). Rerun the same command after any failure.
///           * The file has `feeSplitter` and it is live with the expected owner, immutables, legs and split: prints
///             "already deployed" and sends nothing.
///           * The file has `feeSplitter` but there is no code there, or it differs: refuses. Check the address by hand
///             in the explorer, then remove the key or fix it.
///           * No `feeSplitter` in the file but broadcast/DeployFeeSplitter.s.sol/<chainId>/run-latest.json has a
///             create whose address is live and matches: adopts that address into the file, sends nothing.
///           * Otherwise deploys one new FeeSplitter.
///           forge script script/DeployFeeSplitter.s.sol:DeployFeeSplitter --rpc-url robinhood \
///             --broadcast --slow --account gos-mainnet --sender <DEPLOYER>
contract DeployFeeSplitter is MainnetAddrs, SafeCheck, LaunchSplit {
    function run() external {
        require(block.chainid == 4663 || block.chainid == 46630, "Robinhood Chain only");
        address safe = _safeFromEnv();
        _requirePinned(safe, block.chainid == 4663 ? PINNED_MAINNET_SAFE : PINNED_TESTNET_SAFE, "GOS_SAFE");
        _checkSafe(safe, vm.envAddress("SAFE_OWNERS", ","), "GOS_SAFE");

        string memory id = vm.toString(block.chainid);
        string memory file = string.concat("deployments/", id, ".json");
        string memory j = vm.readFile(file);
        require(vm.parseJsonUint(j, ".chainId") == block.chainid, "deployment file is for another chain");
        address wif = vm.parseJsonAddress(j, ".wif");
        address core = vm.parseJsonAddress(j, ".fairCore");
        address rake = vm.parseJsonAddress(j, ".rakeBuyer");
        address vault = vm.parseJsonAddress(j, ".locksleyVault");
        if (block.chainid == 4663) require(wif == WIF, "wif in deployments/4663.json is not the mainnet $wif");
        require(wif.code.length != 0 && core.code.length != 0, "wif or FairCore missing");
        require(rake.code.length != 0 && vault.code.length != 0, "RakeBuyer or Locksley Vault missing");
        require(IOwned(core).owner() == safe && IOwned(rake).owner() == safe, "main deploy not handed to the Safe");

        (, address sender,) = vm.readCallers();
        FeeSplitter.Recipients memory r = _feeLegs(safe, vault, sender);
        _holding(r.purses, safe, sender, "PURSES");
        _holding(r.rebate, safe, sender, "REBATE");
        _holding(r.burnBuyer, safe, sender, "BURN_BUYER");
        _holding(r.ops, safe, sender, "OPS");
        FeeSplitter.FeeSplit memory s = _feeSplitFromEnv();

        if (vm.keyExistsJson(j, ".feeSplitter")) {
            address have = vm.parseJsonAddress(j, ".feeSplitter");
            require(
                _isExpected(have, wif, safe, core, rake, s, r),
                "deployment file has a feeSplitter that is not live or not the expected one, check it by hand"
            );
            console2.log("already deployed, nothing sent. FeeSplitter", have);
            return;
        }
        address prior = _fromLastBroadcast(id);
        if (prior != address(0) && _isExpected(prior, wif, safe, core, rake, s, r)) {
            console2.log("adopting the FeeSplitter from the last broadcast, nothing sent", prior);
            _write(j, _out(file, id), prior);
            return;
        }

        vm.startBroadcast();
        FeeSplitter fs = new FeeSplitter(wif, safe, r, s, core, rake);
        vm.stopBroadcast();
        require(_isExpected(address(fs), wif, safe, core, rake, s, r), "FeeSplitter state after deploy");

        string memory out = _out(file, id);
        _write(j, out, address(fs));
        console2.log("FeeSplitter", address(fs));
        console2.log("owner (Safe)", safe);
        console2.log("split bps purses vault rebate burn ops", s.pursesBps, s.vaultBps);
        console2.log("  ", s.rebateBps, s.burnBps, s.opsBps);
        console2.log("wrote", out);
    }

    /// A broadcast writes deployments/<chainId>.json, a dry run deployments/dryrun-<chainId>.json.
    function _out(string memory file, string memory id) internal view returns (string memory) {
        return vm.isContext(VmSafe.ForgeContext.ScriptBroadcast) ? file : string.concat("deployments/dryrun-", id, ".json");
    }

    function _write(string memory j, string memory out, address fs) internal {
        string memory k = "withFeeSplitter";
        vm.serializeJson(k, j);
        vm.writeJson(vm.serializeAddress(k, "feeSplitter", fs), out);
    }

    /// The live contract at `a` is a FeeSplitter with exactly this owner, immutables, legs and split.
    function _isExpected(
        address a,
        address wif,
        address safe,
        address core,
        address rake,
        FeeSplitter.FeeSplit memory s,
        FeeSplitter.Recipients memory r
    ) internal view returns (bool) {
        if (a.code.length == 0) return false;
        FeeSplitter fs = FeeSplitter(payable(a));
        try fs.TIMELOCK() returns (uint256 t) {
            if (t != 7 days) return false;
        } catch {
            return false;
        }
        return fs.owner() == safe && fs.pendingOwner() == address(0) && fs.wif() == wif && fs.fairCore() == core
            && fs.rakeBuyer() == rake && _feeSplitterMatches(fs, s, r);
    }

    /// DS-4: the FeeSplitter create in this script's last broadcast, if forge left one, else zero.
    function _fromLastBroadcast(string memory id) internal view returns (address) {
        string memory p = string.concat("broadcast/DeployFeeSplitter.s.sol/", id, "/run-latest.json");
        if (!vm.exists(p)) return address(0);
        string memory b = vm.readFile(p);
        if (!vm.keyExistsJson(b, ".transactions[0].contractAddress")) return address(0);
        return vm.parseJsonAddress(b, ".transactions[0].contractAddress");
    }

    function _holding(address a, address safe, address sender, string memory name) internal view {
        require(a != address(0), string.concat(name, " not set"));
        require(a != sender, string.concat(name, " is the deployer"));
        require(a.code.length == 0 || a == safe, string.concat(name, " must be an EOA or the Safe"));
    }
}
