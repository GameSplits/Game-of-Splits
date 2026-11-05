// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Split} from "../src/interfaces/IFair.sol";
import {FeeSplitter} from "../src/FeeSplitter.sol";
import {Vm} from "forge-std/Vm.sol";

/// The launch split and the Pass lock, shared by the deploy (which sets them) and SafeAccept
/// (which checks them independently of the deployer). One constant, so the two scripts can't drift.
abstract contract LaunchSplit {
    /// Launch Pass: 5,000 $wif (29 Oct 2026). The Robin Among Thieves outlaw licence stays 1,000.
    uint256 internal constant PASS_LOCK = 5_000e18;

    function _launchSplit() internal pure virtual returns (Split memory) {
        return Split({purseBps: 6000, almsBps: 2000, bonfireBps: 1750, tollBps: 1750, vBuyBps: 2500, vLiqBps: 2500, vBurnBps: 2500});
    }

    /// Play token and buy token are $wif, and a new pass locks PASS_LOCK. Deploy's check and SafeAcceptVerify both call this.
    function _requireLaunchTokens(address play, uint256 lockAmt, address buy, address wif) internal pure {
        require(play == wif && buy == wif && lockAmt == PASS_LOCK, "config tokens");
    }

    /// FeeSplitter launch split, option b (the owner, 4 Nov 2026), in leg order purses, vault, rebate, burn, ops:
    /// 0% purses, 50% Locksley Vault, 0% weekly swapper rebate, 40% buy and burn ($wif to 0x...dEaD, any other token
    /// to `burnBuyer`), 10% toll and ops. On mainnet (4663) DeployFeeSplitter writes exactly this and SafeAcceptVerify
    /// checks exactly this, and FEE_SPLIT_BPS is refused (DS-1), so the deploy shell can't change what Verify accepts.
    function _launchFeeSplit() internal pure returns (FeeSplitter.FeeSplit memory) {
        return FeeSplitter.FeeSplit({pursesBps: 0, vaultBps: 5000, rebateBps: 0, burnBps: 4000, opsBps: 1000});
    }

    /// The split DeployFeeSplitter sets and Verify expects. Mainnet is always `_launchFeeSplit`. Off mainnet (the 46630
    /// rehearsal) FEE_SPLIT_BPS="purses,vault,rebate,burn,ops" may override it, the same value for both scripts.
    function _feeSplitFromEnv() internal view returns (FeeSplitter.FeeSplit memory s) {
        string memory raw = _vm().envOr("FEE_SPLIT_BPS", string(""));
        uint256[] memory b = bytes(raw).length == 0 ? new uint256[](0) : _vm().envUint("FEE_SPLIT_BPS", ",");
        if (block.chainid == 4663) {
            require(b.length == 0, "FEE_SPLIT_BPS is refused on mainnet, the launch split is fixed in LaunchSplit");
            return _launchFeeSplit();
        }
        if (b.length == 0) return _launchFeeSplit();
        require(b.length == 5, "FEE_SPLIT_BPS needs 5 values");
        for (uint256 i; i < 5; ++i) {
            require(b[i] <= 10_000, "FEE_SPLIT_BPS value too big");
        }
        require(b[0] + b[1] + b[2] + b[3] + b[4] == 10_000, "FEE_SPLIT_BPS must sum to 10000");
        s = FeeSplitter.FeeSplit(uint16(b[0]), uint16(b[1]), uint16(b[2]), uint16(b[3]), uint16(b[4]));
    }

    /// The five FeeSplitter legs DeployFeeSplitter sets and Verify pins (DS-3). The vault leg is always this deploy's
    /// Locksley Vault. On mainnet the other four are the pinned Safe (the owner, 5 Nov 2026). Purses and rebate are 0 bps
    /// but the contract needs a nonzero leg, ops is the Safe (confirmed 23:08 Bangkok), and burn is the Safe because
    /// $wif burns go straight to 0x...dEaD and no separate buy and burn contract is deployed, so only non $wif fees
    /// (ETH, USDG) reach that leg and the Safe buys and burns them by hand. If PURSES, REBATE, BURN_BUYER or OPS is set
    /// on mainnet it must equal the Safe. Off mainnet all four come from env with no defaults. None may be `deployer`.
    function _feeLegs(address safe, address vault, address deployer)
        internal
        view
        returns (FeeSplitter.Recipients memory r)
    {
        if (block.chainid == 4663) {
            r = FeeSplitter.Recipients({purses: safe, vault: vault, rebate: safe, burnBuyer: safe, ops: safe});
            _envMatches("PURSES", safe);
            _envMatches("REBATE", safe);
            _envMatches("BURN_BUYER", safe);
            _envMatches("OPS", safe);
        } else {
            r = FeeSplitter.Recipients({
                purses: _vm().envAddress("PURSES"),
                vault: vault,
                rebate: _vm().envAddress("REBATE"),
                burnBuyer: _vm().envAddress("BURN_BUYER"),
                ops: _vm().envAddress("OPS")
            });
        }
        require(
            r.purses != deployer && r.vault != deployer && r.rebate != deployer && r.burnBuyer != deployer
                && r.ops != deployer,
            "a FeeSplitter leg is the deployer"
        );
    }

    function _envMatches(string memory name, address want) private view {
        string memory v = _vm().envOr(name, string(""));
        if (bytes(v).length == 0) return; // unset, or empty as in .env.example
        require(_vm().parseAddress(v) == want, string.concat(name, " must be the Safe on mainnet"));
    }

    /// True when `fs` has exactly this split and these legs.
    function _feeSplitterMatches(FeeSplitter fs, FeeSplitter.FeeSplit memory w, FeeSplitter.Recipients memory r)
        internal
        view
        returns (bool)
    {
        return fs.pursesBps() == w.pursesBps && fs.vaultBps() == w.vaultBps && fs.rebateBps() == w.rebateBps
            && fs.burnBps() == w.burnBps && fs.opsBps() == w.opsBps && fs.purses() == r.purses && fs.vault() == r.vault
            && fs.rebate() == r.rebate && fs.burnBuyer() == r.burnBuyer && fs.ops() == r.ops;
    }

    function _vm() private pure returns (Vm) {
        return Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    }
}
