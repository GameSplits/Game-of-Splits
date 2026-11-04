// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {console2} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {FairCore} from "../src/FairCore.sol";
import {LastArrow} from "../src/LastArrow.sol";
import {SheriffsSeat} from "../src/SheriffsSeat.sol";
import {Stash} from "../src/Stash.sol";
import {SafeCheck} from "./Deploy.s.sol";
import {MainnetAddrs} from "./Mainnet.s.sol";

/// @notice Deploy Stash on Robinhood Chain mainnet (chain id 4663) only. Stash has no owner. The Safe is the fee wallet
///         and the cap raiser. The booths come from deployments/4663.json if present, else from env FAIR_CORE,
///         LAST_ARROW and SHERIFFS_SEAT. Dry-run without `--broadcast`.
///   forge script script/DeployStashMainnet.s.sol:DeployStashMainnet --rpc-url robinhood
contract DeployStashMainnet is SafeCheck, MainnetAddrs {
    using stdJson for string;

    string internal constant DEPLOYMENT_FILE = "deployments/4663.json";

    uint256 public constant SHOT_FEE = 0.05e6;
    uint256 public constant WITHDRAW_FEE = 1e6;
    address public constant SAFE = 0x7c0fc9869f2D41D88CCA675A9A270214d59DA36a;

    function usdg() public pure returns (address) {
        return USDG;
    }

    function safeOwners() public pure returns (address[] memory owners) {
        owners = new address[](3);
        owners[0] = 0xCA652b365Fa1052d43297907B1eAe5676182Eb5c;
        owners[1] = 0x8AAb7f969f7e6AE1098e4158EA4547F07A3204e2;
        owners[2] = 0x36E54F5366b7d01529BA1abF233314184B876D89;
    }

    function presetLines() public pure returns (string[] memory lines) {
        lines = new string[](16);
        lines[0] = "Off my seat";
        lines[1] = "Skill issue";
        lines[2] = "Diamond hands";
        lines[3] = "Cope harder";
        lines[4] = "Comfy up here";
        lines[5] = "Not your seat";
        lines[6] = "Touch grass";
        lines[7] = "Wen dethrone";
        lines[8] = "Few understand";
        lines[9] = "Gm from the throne";
        lines[10] = "Bow down";
        lines[11] = "Still sitting";
        lines[12] = "Zoom out";
        lines[13] = "Ngmi";
        lines[14] = "Catch me if you can";
        lines[15] = "Wagmi from up here";
    }

    /// @notice The booths this run would use, each checked to be nonzero and to have code.
    function booths() public view returns (address core, address arrow, address seat) {
        if (vm.isFile(DEPLOYMENT_FILE)) {
            string memory json = vm.readFile(DEPLOYMENT_FILE);
            require(json.readAddress(".usdg") == USDG, "deployment file usdg is not mainnet USDG");
            core = json.readAddress(".fairCore");
            arrow = json.readAddress(".lastArrow");
            seat = json.readAddress(".sheriffsSeat");
        } else {
            core = vm.envOr("FAIR_CORE", address(0));
            arrow = vm.envOr("LAST_ARROW", address(0));
            seat = vm.envOr("SHERIFFS_SEAT", address(0));
        }
        _requireCode(core, "FAIR_CORE");
        _requireCode(arrow, "LAST_ARROW");
        _requireCode(seat, "SHERIFFS_SEAT");
    }

    function run() external returns (Stash stash) {
        require(block.chainid == 4663, "Stash deploys on chain 4663 only");
        require(SHOT_FEE <= 0.25e6, "shot fee above max");
        require(WITHDRAW_FEE <= 2e6, "withdraw fee above max");

        (address core, address arrow, address seat) = booths();
        require(address(FairCore(core).usdg()) == USDG, "FairCore usdg is not mainnet USDG");
        require(address(LastArrow(arrow).core()) == core, "LastArrow is not on this FairCore");
        require(address(SheriffsSeat(seat).core()) == core, "SheriffsSeat is not on this FairCore");
        require(FairCore(core).isBooth(arrow) && FairCore(core).isBooth(seat), "booths are not added to FairCore");
        _checkSafe(SAFE, safeOwners(), "SAFE");

        vm.startBroadcast();
        stash = new Stash(core, arrow, seat, USDG, SAFE, SAFE, SHOT_FEE, WITHDRAW_FEE, presetLines());
        vm.stopBroadcast();

        console2.log("Stash", address(stash));
    }

    function _requireCode(address who, string memory name) internal view {
        require(who != address(0), string.concat(name, " missing"));
        require(who.code.length != 0, string.concat(name, " has no code"));
    }
}
