// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Script, console2} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {Stash} from "../src/Stash.sol";

/// @notice Deploy Stash on Robinhood Chain testnet (chain id 46630) only.
///         Dry-run without `--broadcast`. The deployer key stays in the environment (`--private-key`).
contract DeployStash is Script {
    using stdJson for string;

    uint256 public constant SHOT_FEE = 0.05e6;
    uint256 public constant WITHDRAW_FEE = 1e6;
    // DeployTestnet at 7555b64, chain 46630. The script refuses any other booth set.
    address public constant FAIR_CORE = 0xc76d5ED46786e67Fb5925928af18C08da7078Cf0;
    address public constant LAST_ARROW = 0x14700ccE7f3c0Fc7E1DA3BA303Fe632E52197316;
    address public constant SHERIFFS_SEAT = 0x4f811cAAa659341a4d0066731F2bCa1b60e3F8ef;
    address public constant USDG = 0xA173301d53E1cA0790A6f8d074F515bFc543980c;

    function presetLines() public pure returns (string[] memory lines) {
        lines = new string[](16);
        lines[0] = "The seat is taken";
        lines[1] = "Not today";
        lines[2] = "Hold fast";
        lines[3] = "Make way";
        lines[4] = "Still here";
        lines[5] = "Your move";
        lines[6] = "Too slow";
        lines[7] = "Step aside";
        lines[8] = "Short reign";
        lines[9] = "The clock runs";
        lines[10] = "Stand clear";
        lines[11] = "Try again";
        lines[12] = "Mine for now";
        lines[13] = "Last word";
        lines[14] = "Come closer";
        lines[15] = "Next";
    }

    function run() external {
        require(block.chainid == 46630, "Stash deploys on chain 46630 only");
        require(SHOT_FEE <= 0.25e6, "shot fee above max");
        require(WITHDRAW_FEE <= 2e6, "withdraw fee above max");

        string memory json = vm.readFile("deployments/46630.json");
        address core = json.readAddress(".fairCore");
        address arrow = json.readAddress(".lastArrow");
        address seat = json.readAddress(".sheriffsSeat");
        address usdg = json.readAddress(".usdg");
        require(core == FAIR_CORE, "fairCore is not the 7555 testnet deployment");
        require(arrow == LAST_ARROW, "lastArrow is not the 7555 testnet deployment");
        require(seat == SHERIFFS_SEAT, "sheriffsSeat is not the 7555 testnet deployment");
        require(usdg == USDG, "usdg is not the 7555 testnet deployment");
        address feeWallet = vm.envAddress("STASH_FEE_WALLET");
        address capRaiser = vm.envAddress("STASH_CAP_RAISER");

        vm.startBroadcast();
        Stash stash = new Stash(core, arrow, seat, usdg, feeWallet, capRaiser, SHOT_FEE, WITHDRAW_FEE, presetLines());
        vm.stopBroadcast();

        console2.log("Stash", address(stash));
    }
}
