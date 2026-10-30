// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// Local anvil only. Exercises Verify's real eth_getLogs scan (_count → _chunkCount), not vm.recordLogs.
//   bash script/e2e/anvil_hidden_booth.sh
import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IFairCore, IGameConfig, Tokens, Split} from "../../src/interfaces/IFair.sol";
import {GameConfig} from "../../src/GameConfig.sol";
import {FairPass} from "../../src/FairPass.sol";
import {FairCore} from "../../src/FairCore.sol";
import {LastArrow} from "../../src/LastArrow.sol";
import {SheriffsSeat} from "../../src/SheriffsSeat.sol";
import {AlmsVote} from "../../src/AlmsVote.sol";
import {LocksleyVault, ICoreVaultUsdg} from "../../src/LocksleyVault.sol";
import {MockToken} from "../../test/mocks/Mocks.sol";
import {AcceptBase} from "../SafeAccept.s.sol";

contract Rogue {}

contract AnvilDeploy is Script {
    function run(bool extraBooth) external {
        address dep = vm.envAddress("DEP");
        vm.startBroadcast(dep);
        MockToken usdg = new MockToken("Global Dollar", "USDG", 6);
        MockToken wif = new MockToken("World is Flat", "WIF", 18);
        GameConfig config = new GameConfig(
            dep,
            address(usdg),
            7 days,
            Tokens(address(wif), 5_000e18, address(wif)),
            Split({
                purseBps: 6000,
                almsBps: 2000,
                bonfireBps: 1750,
                tollBps: 1750,
                vBuyBps: 2500,
                vLiqBps: 2500,
                vBurnBps: 2500
            })
        );
        FairPass pass = new FairPass(IGameConfig(address(config)), dep);
        FairCore core = new FairCore(IERC20(address(usdg)), IGameConfig(address(config)), pass, dep, 48 hours);
        config.bindCore(address(core));
        AlmsVote alms = new AlmsVote(IFairCore(address(core)), dep, 24 hours, 24 hours);
        LocksleyVault vault = new LocksleyVault(ICoreVaultUsdg(address(core)), dep);
        address arrow = address(new LastArrow(IFairCore(address(core))));
        address seat = address(new SheriffsSeat(IFairCore(address(core)), 1 days, 1 days));
        address rogue = address(new Rogue());
        core.setupSet(FairCore.Op.SetKeeper, 0, address(0xBEEF));
        core.setupSet(FairCore.Op.SetTollRecipient, 0, address(0xB0B));
        core.setupSet(FairCore.Op.SetAlmsSafe, 0, address(0x5AFE));
        core.setupSet(FairCore.Op.SetAlmsVote, 0, address(alms));
        core.setupSet(FairCore.Op.SetVault, 0, address(vault));
        if (extraBooth) core.setupSet(FairCore.Op.AddBooth, 0, rogue);
        core.setupSet(FairCore.Op.AddBooth, 0, arrow);
        core.setupSet(FairCore.Op.AddBooth, 0, seat);
        core.setupSet(FairCore.Op.SetRoute, 0, address(0xA1));
        core.setupSet(FairCore.Op.SetRoute, 1, address(0xB1));
        core.finishSetup();
        vm.stopBroadcast();
        console2.log("CORE", address(core));
    }
}

/// Calls the script's on-chain counter (_expectFairCoreSetup -> _count -> vm.eth_getLogs), including the chunk loop.
contract AnvilScan is AcceptBase {
    function run(address core) external view {
        uint256 head = block.number;
        _expectFairCoreSetup(core, address(0xB1), 0, head);
        console2.log("SCAN PASSED 0..", head);
    }
}
