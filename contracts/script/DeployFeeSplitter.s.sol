// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Script, console2} from "forge-std/Script.sol";
import {FeeSplitter} from "../src/FeeSplitter.sol";

/// @notice Dry-run only. Deploys {FeeSplitter} in the simulation and prints the address. Never broadcasts.
///
///         Required env: OWNER, PURSES, VAULT, REBATE, BURN_BUYER, OPS, FAIR_CORE, RAKE_BUYER.
///         Optional: WIF (default Robinhood Chain $wif), and PURSES_BPS / VAULT_BPS / REBATE_BPS / BURN_BPS / OPS_BPS
///         (default 0 / 5000 / 0 / 4000 / 1000, launch split b). The five bps must sum to 10000.
///
///         Purses must be a holding address, not FairCore or a booth: a plain transfer is not credited to a purse.
///         Vault may be LocksleyVault for ERC-20s (`balanceOf` is the ledger). It rejects ETH.
///         $wif's burn leg goes to 0x...dEaD. Every other token is forwarded to BURN_BUYER. No swap is done here.
///         FAIR_CORE and RAKE_BUYER are the deployed contracts. A leg set to either one reverts. Deploy this after
///         both exist. That does not change the order inside Deploy.s.sol, which does not deploy FeeSplitter.
///
///           OWNER=0x.. PURSES=0x.. VAULT=0x.. REBATE=0x.. BURN_BUYER=0x.. OPS=0x.. \
///           FAIR_CORE=0x.. RAKE_BUYER=0x.. \
///             forge script script/DeployFeeSplitter.s.sol:DeployFeeSplitter --rpc-url robinhood
///         Do not pass --broadcast. This script never calls `vm.startBroadcast`, so a broadcast flag sends nothing.
contract DeployFeeSplitter is Script {
    address constant DEFAULT_WIF = 0x5173b8eA6923c2d40267890D45C46a3480954773;

    function run() external {
        address wif_ = vm.envOr("WIF", DEFAULT_WIF);
        FeeSplitter.Recipients memory recipients = FeeSplitter.Recipients({
            purses: vm.envAddress("PURSES"),
            vault: vm.envAddress("VAULT"),
            rebate: vm.envAddress("REBATE"),
            burnBuyer: vm.envAddress("BURN_BUYER"),
            ops: vm.envAddress("OPS")
        });
        FeeSplitter.FeeSplit memory split = FeeSplitter.FeeSplit({
            pursesBps: _bps("PURSES_BPS", 0),
            vaultBps: _bps("VAULT_BPS", 5000),
            rebateBps: _bps("REBATE_BPS", 0),
            burnBps: _bps("BURN_BPS", 4000),
            opsBps: _bps("OPS_BPS", 1000)
        });
        require(
            uint256(split.pursesBps) + split.vaultBps + split.rebateBps + split.burnBps + split.opsBps == 10_000,
            "bps must sum to 10000"
        );
        address fairCore_ = vm.envAddress("FAIR_CORE");
        address rakeBuyer_ = vm.envAddress("RAKE_BUYER");
        require(fairCore_ != address(0) && rakeBuyer_ != address(0), "FAIR_CORE and RAKE_BUYER required");
        require(fairCore_.code.length != 0 && rakeBuyer_.code.length != 0, "FairCore and RakeBuyer must be deployed");
        require(
            recipients.purses != fairCore_ && recipients.vault != fairCore_ && recipients.rebate != fairCore_
                && recipients.burnBuyer != fairCore_ && recipients.ops != fairCore_,
            "leg points at FairCore"
        );
        require(
            recipients.purses != rakeBuyer_ && recipients.vault != rakeBuyer_ && recipients.rebate != rakeBuyer_
                && recipients.burnBuyer != rakeBuyer_ && recipients.ops != rakeBuyer_,
            "leg points at RakeBuyer"
        );

        FeeSplitter deployed = new FeeSplitter(wif_, vm.envAddress("OWNER"), recipients, split, fairCore_, rakeBuyer_);
        require(deployed.fairCore() == fairCore_ && deployed.rakeBuyer() == rakeBuyer_, "constructor args");

        console2.log("dry-run only, nothing broadcast");
        console2.log("chainid", block.chainid);
        console2.log("FeeSplitter", address(deployed));
        console2.log("owner", deployed.owner());
        console2.log("wif", deployed.wif());
        console2.log("fairCore", deployed.fairCore());
        console2.log("rakeBuyer", deployed.rakeBuyer());
        console2.log("purses", deployed.purses());
        console2.log("vault", deployed.vault());
        console2.log("rebate", deployed.rebate());
        console2.log("burnBuyer", deployed.burnBuyer());
        console2.log("ops", deployed.ops());
        console2.log("pursesBps", deployed.pursesBps());
        console2.log("vaultBps", deployed.vaultBps());
        console2.log("rebateBps", deployed.rebateBps());
        console2.log("burnBps", deployed.burnBps());
        console2.log("opsBps", deployed.opsBps());
        console2.log("timelock seconds", deployed.TIMELOCK());
        console2.log("wif burn recipient", deployed.DEAD());
        console2.log("Purses: holding address. FairCore.collect is the only purse credit and it is not a transfer.");
        console2.log("Vault: LocksleyVault counts a plain ERC-20 by balanceOf. It has no receive, so no ETH.");
    }

    function _bps(string memory key, uint256 fallback_) internal view returns (uint16) {
        uint256 v = vm.envOr(key, fallback_);
        require(v <= type(uint16).max, string.concat(key, " exceeds uint16"));
        return uint16(v);
    }
}
