// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {DeployMainnet} from "../Deploy.s.sol";
import {Split} from "../../src/interfaces/IFair.sol";

/// Rehearsal only (script/e2e/accept_flow.sh step 4d, on a local fork): the mainnet deploy built with a split other
/// than the launch split, still inside GameConfig's caps. The constructor emits no event for it, so SafeAccept's own
/// split check is what must refuse it.
contract DeployMainnetOtherSplit is DeployMainnet {
    function _launchSplit() internal pure override returns (Split memory) {
        return Split({purseBps: 5000, almsBps: 2000, bonfireBps: 1000, tollBps: 5000, vBuyBps: 2500, vLiqBps: 2500, vBurnBps: 2500});
    }
}
