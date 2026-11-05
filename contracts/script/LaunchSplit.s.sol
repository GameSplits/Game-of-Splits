// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Split} from "../src/interfaces/IFair.sol";

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
}
