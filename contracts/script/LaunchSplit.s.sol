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

    /// FeeSplitter launch split (the owner, 27 Oct 2026, confirmed for launch 5 Nov 2026): 40% purses, 25% Locksley Vault,
    /// 15% weekly swapper rebate, 10% buy and burn ($wif to 0x...dEaD), 10% toll and ops. DeployFeeSplitter sets it
    /// and SafeAcceptVerify checks it. FEE_SPLIT_BPS="purses,vault,rebate,burn,ops" overrides both the same way.
    function _launchFeeSplit() internal pure returns (FeeSplitter.FeeSplit memory) {
        return FeeSplitter.FeeSplit({pursesBps: 4000, vaultBps: 2500, rebateBps: 1500, burnBps: 1000, opsBps: 1000});
    }

    function _feeSplitFromEnv() internal view returns (FeeSplitter.FeeSplit memory s) {
        uint256[] memory none = new uint256[](0);
        uint256[] memory b = Vm(address(uint160(uint256(keccak256("hevm cheat code"))))).envOr("FEE_SPLIT_BPS", ",", none);
        if (b.length == 0) return _launchFeeSplit();
        require(b.length == 5, "FEE_SPLIT_BPS needs 5 values");
        for (uint256 i; i < 5; ++i) {
            require(b[i] <= 10_000, "FEE_SPLIT_BPS value too big");
        }
        require(b[0] + b[1] + b[2] + b[3] + b[4] == 10_000, "FEE_SPLIT_BPS must sum to 10000");
        s = FeeSplitter.FeeSplit(uint16(b[0]), uint16(b[1]), uint16(b[2]), uint16(b[3]), uint16(b[4]));
    }
}
