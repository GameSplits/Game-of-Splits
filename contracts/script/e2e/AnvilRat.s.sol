// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

// Local anvil only (no keys, --unlocked). Deploys a minimal Robin Among Thieves stack for the keeper runner e2e:
//   bash script/e2e/anvil_rat_runner.sh
import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IFairCore, IGameConfig, Tokens, Split} from "../../src/interfaces/IFair.sol";
import {GameConfig} from "../../src/GameConfig.sol";
import {FairPass} from "../../src/FairPass.sol";
import {FairCore} from "../../src/FairCore.sol";
import {RobinAmongThieves} from "../../src/RobinAmongThieves.sol";
import {IIdentityRegistry, IReputationRegistry} from "../../src/interfaces/I8004.sol";
import {MockToken, MockIdentity, MockReputation} from "../../test/mocks/Mocks.sol";

/// ArbSys stand-in for anvil: L2 block = anvil block, hash = anvil blockhash. Its runtime code is copied to 0x64.
contract AnvilArbSys {
    function arbBlockNumber() external view returns (uint256) {
        return block.number;
    }

    function arbBlockHash(uint256 n) external view returns (bytes32) {
        require(n < block.number && block.number - n <= 256, "InvalidBlockNumber");
        return blockhash(n);
    }
}

contract AnvilRatDeploy is Script {
    function run(address keeper, uint256 genesis) external {
        address dep = vm.envAddress("DEP");
        vm.startBroadcast(dep);
        MockToken usdg = new MockToken("Global Dollar", "USDG", 6);
        MockToken wif = new MockToken("World is Flat", "WIF", 18);
        GameConfig config = new GameConfig(
            dep, address(usdg), 7 days, Tokens(address(wif), 5_000e18, address(wif)),
            Split({purseBps: 6000, almsBps: 2000, bonfireBps: 1750, tollBps: 1750, vBuyBps: 2500, vLiqBps: 2500, vBurnBps: 2500})
        );
        FairPass pass = new FairPass(IGameConfig(address(config)), dep);
        FairCore core = new FairCore(IERC20(address(usdg)), IGameConfig(address(config)), pass, dep, 48 hours);
        config.bindCore(address(core));
        MockIdentity idr = new MockIdentity();
        MockReputation rep = new MockReputation(idr);
        AnvilArbSys arb = new AnvilArbSys();
        RobinAmongThieves rat = new RobinAmongThieves(
            RobinAmongThieves.Params({
                usdg: IERC20(address(usdg)),
                config: IGameConfig(address(config)),
                core: IFairCore(address(core)),
                identity: IIdentityRegistry(address(idr)),
                reputation: IReputationRegistry(address(rep)),
                owner: dep,
                timelockDelay: 48 hours,
                bondDelay: 7 days,
                genesis: genesis,
                keeper: keeper,
                rakeSink: address(0xB0B),
                houseSink: address(0xB0C)
            })
        );
        vm.stopBroadcast();
        console2.log("RAT", address(rat));
        console2.log("ARBSYS_IMPL", address(arb));
        console2.log("USDG", address(usdg));
        console2.log("WIF", address(wif));
        console2.log("PASS", address(pass));
    }
}

/// Players 1..n: mint, Pass, register an outlaw, deposit, and enter round r.
contract AnvilRatEnter is Script {
    function run(address rat_, address usdg_, address wif_, address pass_, uint256 r, address[] calldata players) external {
        RobinAmongThieves rat = RobinAmongThieves(rat_);
        MockToken usdg = MockToken(usdg_);
        MockToken wif = MockToken(wif_);
        FairPass pass = FairPass(pass_);
        for (uint256 i; i < players.length; ++i) {
            address p = players[i];
            vm.startBroadcast(p);
            usdg.mint(p, 100e6);
            wif.mint(p, 10_000e18);
            wif.approve(address(pass), type(uint256).max);
            wif.approve(address(rat), type(uint256).max);
            usdg.approve(address(rat), type(uint256).max);
            if (!pass.hasPass(p)) pass.lock(address(wif), 5_000e18);
            uint256 id = rat.registerOutlawNew("ipfs://outlaw", address(0), address(wif), 1000e18);
            rat.deposit(id, 20e6);
            rat.enter(id, r, keccak256(abi.encode(id, r)));
            vm.stopBroadcast();
        }
    }
}
