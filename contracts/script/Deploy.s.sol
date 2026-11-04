// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Script, console2} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {FairPass} from "../src/FairPass.sol";
import {GameConfig} from "../src/GameConfig.sol";
import {FairCore} from "../src/FairCore.sol";
import {LastArrow} from "../src/LastArrow.sol";
import {SheriffsSeat} from "../src/SheriffsSeat.sol";
import {AlmsVote} from "../src/AlmsVote.sol";
import {LocksleyVault, ICoreVaultUsdg} from "../src/LocksleyVault.sol";
import {FairLens, IVaultView} from "../src/FairLens.sol";
import {IFairCore, IGameConfig, Tokens, Split} from "../src/interfaces/IFair.sol";
import {BuyRouteV4} from "../src/routes/BuyRouteV4.sol";
import {BuyRouteV3V4, IUniswapV3Pool} from "../src/routes/BuyRouteV3V4.sol";
import {PoolKey} from "../src/interfaces/IV4Minimal.sol";
import {TestToken, TestRoute, ITestMint} from "../src/testnet/TestTokens.sol";
import {MainnetAddrs} from "./Mainnet.s.sol";
import {L2Head} from "./L2.s.sol";
import {LaunchSplit} from "./LaunchSplit.s.sol";
import {RobinAmongThieves} from "../src/RobinAmongThieves.sol";
import {RakeBuyer} from "../src/RakeBuyer.sol";
import {SafeHandover} from "../src/SafeHandover.sol";
import {IIdentityRegistry, IReputationRegistry} from "../src/interfaces/I8004.sol";

/// Shared wiring for both networks.
/// The parts of a Safe the deploy checks read (review M10, M10-b).
interface ISafeView {
    function getThreshold() external view returns (uint256);
    function getOwners() external view returns (address[] memory);
    function getModulesPaginated(address start, uint256 pageSize)
        external
        view
        returns (address[] memory array, address next);
    function nonce() external view returns (uint256);
}

/// The one Safe that owns the game and receives the Alms (Alms Safe = owner Safe). It must be:
///  - a genuine Safe proxy: runtime codehash of the canonical SafeProxy (1.4.1 or 1.5.0 factory), so a contract that
///    only fakes the getters fails, and its singleton (slot 0) the matching SafeL2 1.4.1 / 1.5.0;
///  - exactly the 3 expected owners (SAFE_OWNERS, set-equal, any order) with threshold 2, so a real multisig that an
///    attacker owns (clipboard swap, wrong env var) fails;
///  - no modules, no guard, no module guard;
///  - already used: nonce >= 1. Anyone can create a Safe that LISTS the real owners (setup needs no signatures), but only
///    the owners can execute on it. Before deploying, the signers execute one no-op tx on the Safe (runbook).
abstract contract SafeCheck is Script {
    /// PINNED SAFE ADDRESSES (locked 26 Oct). A Safe's setup can run its own code once (setup's `to`/`data`
    /// delegatecall), which can set the nonce or plant a hidden module, so owners + nonce alone don't prove a Safe is
    /// ours. The deploy therefore only accepts the exact address the owner confirms in the Safe app, written here in a
    /// reviewed commit (an env var could be swapped together with the others). Zero = not pinned yet = no deploy.
    /// Fork rehearsals (script/e2e/*.sh) write their throwaway Safe into the TEMP COPY of this file, never here.
    address internal constant PINNED_MAINNET_SAFE = 0x7c0fc9869f2D41D88CCA675A9A270214d59DA36a; // Confirmed 4 Nov 2026: SafeL2 on 4663
    // Confirmed 29 Oct 2026: SafeL2 1.5.0 on Robinhood Chain testnet (46630).
    address internal constant PINNED_TESTNET_SAFE = 0xDF3d35A99af7A1A3fdE128b8FDFa0D60aE9A1F00;

    /// A1-15: the owner Safe comes from env GOS_SAFE. OWNER_SAFE (the old name, still used by the rehearsal scripts)
    /// is accepted as an alias; if both are set they must agree. Non-zero and a contract, checked before anything else.
    function _safeFromEnv() internal view returns (address) {
        return _pickSafe(vm.envOr("GOS_SAFE", address(0)), vm.envOr("OWNER_SAFE", address(0)));
    }

    function _pickSafe(address gos, address legacy) internal view returns (address safe) {
        if (gos != address(0) && legacy != address(0)) require(gos == legacy, "GOS_SAFE and OWNER_SAFE differ");
        safe = gos != address(0) ? gos : legacy;
        require(safe != address(0), "GOS_SAFE not set");
        require(safe.code.length != 0, "GOS_SAFE has no code on this chain");
    }

    function _requirePinned(address safe, address pinned, string memory name) internal pure {
        require(pinned != address(0), string.concat(name, ": no Safe pinned in script/Deploy.s.sol yet"));
        require(safe == pinned, string.concat(name, ": not the pinned Safe address"));
    }

    address internal constant SAFE_L2_141 = 0x29fcB43b46531BcA003ddC8FCB67FFE91900C762;
    address internal constant SAFE_L2_150 = 0xEdd160fEBBD92E350D4D398fb636302fccd67C7e;
    // runtime codehash of proxies made by SafeProxyFactory 1.4.1 (0x4e1DCf7A…ec67) and 1.5.0 (0x14F2982D…5e7b);
    // read from proxies created on a Robinhood Chain fork, 26 Oct (script/e2e/make_safe.sh; test/fork/SafeCheck)
    bytes32 internal constant PROXY_CODEHASH_141 = 0xd7d408ebcd99b2b70be43e20253d6d92a8ea8fab29bd3be7f55b10032331fb4c;
    bytes32 internal constant PROXY_CODEHASH_150 = 0x4e381985ca68b3e5d27b4425fa581c19cf33146d3f887a3cfca96f55528ea46f;
    bytes32 internal constant GUARD_SLOT = keccak256("guard_manager.guard.address");
    bytes32 internal constant MODULE_GUARD_SLOT = keccak256("module_manager.module_guard.address");

    function _checkSafe(address safe, address[] memory expectedOwners, string memory name) internal view {
        require(safe.code.length > 0, string.concat(name, ": no contract at this address"));
        bytes32 h = safe.codehash;
        address singleton = address(uint160(uint256(vm.load(safe, bytes32(0)))));
        require(
            (h == PROXY_CODEHASH_141 && singleton == SAFE_L2_141)
                || (h == PROXY_CODEHASH_150 && singleton == SAFE_L2_150),
            string.concat(name, ": not a genuine SafeL2 1.4.1/1.5.0 proxy")
        );
        require(ISafeView(safe).getThreshold() == 2, string.concat(name, ": threshold must be 2"));
        address[] memory owners = ISafeView(safe).getOwners();
        require(expectedOwners.length == 3, string.concat(name, ": give exactly 3 expected owners"));
        require(owners.length == 3, string.concat(name, ": must have exactly 3 owners"));
        for (uint256 i; i < 3; i++) {
            bool found;
            for (uint256 j; j < 3; j++) {
                if (owners[j] == expectedOwners[i]) found = true;
            }
            require(found, string.concat(name, ": owners are not the expected 3"));
        }
        require(
            expectedOwners[0] != expectedOwners[1] && expectedOwners[0] != expectedOwners[2]
                && expectedOwners[1] != expectedOwners[2],
            string.concat(name, ": expected owners repeat")
        );
        (address[] memory mods,) = ISafeView(safe).getModulesPaginated(address(1), 10);
        require(mods.length == 0, string.concat(name, ": must have no modules"));
        require(vm.load(safe, GUARD_SLOT) == bytes32(0), string.concat(name, ": must have no guard"));
        require(vm.load(safe, MODULE_GUARD_SLOT) == bytes32(0), string.concat(name, ": must have no module guard"));
        require(
            ISafeView(safe).nonce() >= 1,
            string.concat(name, ": never used: the signers must execute one tx on it first")
        );
    }
}

abstract contract DeployBase is L2Head, SafeCheck, LaunchSplit {
    /// ELIGIBLE_IDS, refused before any broadcast if it has a zero or a repeated id (SafeAcceptVerify refuses them too).
    function _eligibleEnv() internal view returns (bytes32[] memory ids) {
        ids = vm.envOr("ELIGIBLE_IDS", ",", new bytes32[](0));
        for (uint256 i; i < ids.length; ++i) {
            require(ids[i] != bytes32(0), "ELIGIBLE_IDS has a zero id");
            for (uint256 j; j < i; ++j) {
                require(ids[i] != ids[j], "ELIGIBLE_IDS has a duplicate id");
            }
        }
    }

    uint256 internal constant CONFIG_DELAY_MAINNET = 7 days;
    // ERC-8004 registries (Identity, Reputation) per chain
    address internal constant IDENTITY_4663 = 0x8004A169FB4a3325136EB29fA0ceB6D2e539a432;
    address internal constant REPUTATION_4663 = 0x8004BAa17C55a88189AE136b182e5fdA19dE9b63;
    address internal constant IDENTITY_46630 = 0x8004A818BFB912233c491871b3d84c89A494BD9e;
    address internal constant REPUTATION_46630 = 0x8004B663056A597Dffe9eCcC1965A193B7388713;

    struct Out {
        address usdg;
        address wif;
        address tokenB; // testnet only: a second test token with its own route (zero on mainnet)
        GameConfig config;
        FairPass pass;
        FairCore core;
        LastArrow arrow;
        SheriffsSeat seat;
        AlmsVote alms;
        LocksleyVault vault;
        FairLens lens;
        address routeA;
        address routeB;
        RobinAmongThieves rat;
        RakeBuyer rakeBuyer;
        address rakeRouteA; // RakeBuyer's own routes (a route serves one caller); testnet reuses the test routes
        address rakeRouteB;
    }

    function _today0000Utc() internal view returns (uint256) {
        return (block.timestamp / 1 days) * 1 days;
    }

    /// AlmsVote's minimum notice and minimum suggest/vote window. Mainnet (4663) is always 24h each: the env is ignored
    /// there and the AlmsVote constructor refuses anything shorter. Testnet reads ALMS_MIN_NOTICE / ALMS_MIN_WINDOW
    /// (seconds, default 24h) so a whole Fair can be rehearsed in hours.
    function _almsMinimums() internal view returns (uint64 notice, uint64 window) {
        if (block.chainid == 4663) return (24 hours, 24 hours);
        uint256 n = vm.envOr("ALMS_MIN_NOTICE", uint256(24 hours));
        uint256 w = vm.envOr("ALMS_MIN_WINDOW", uint256(24 hours));
        require(n != 0 && w != 0 && n <= 7 days && w <= 7 days, "ALMS_MIN_NOTICE/ALMS_MIN_WINDOW must be 1s..7d");
        (notice, window) = (uint64(n), uint64(w));
    }

    function _deployGame(
        address usdg,
        address wif,
        address owner,
        uint256 timelock,
        uint256 configDelay,
        uint256 dayLength
    ) internal returns (Out memory o) {
        o.usdg = usdg;
        o.wif = wif;
        o.config = new GameConfig(owner, usdg, configDelay, Tokens(wif, PASS_LOCK, wif), _launchSplit());
        o.pass = new FairPass(IGameConfig(address(o.config)), owner);
        o.core = new FairCore(IERC20(usdg), IGameConfig(address(o.config)), o.pass, owner, timelock);
        o.config.bindCore(address(o.core));
        o.arrow = new LastArrow(IFairCore(address(o.core)));
        o.seat = new SheriffsSeat(IFairCore(address(o.core)), _today0000Utc(), dayLength);
        (uint64 almsNotice, uint64 almsWindow) = _almsMinimums();
        o.alms = new AlmsVote(IFairCore(address(o.core)), owner, almsNotice, almsWindow);
        o.vault = new LocksleyVault(ICoreVaultUsdg(address(o.core)), owner);
        o.lens = new FairLens(o.core, o.arrow, o.seat, IVaultView(address(o.vault)));
    }

    /// Robin Among Thieves and its RakeBuyer: rake to RakeBuyer, house outlaw USDG to LocksleyVault, GameConfig's tokens.
    /// Rounds start at the current :00 or :30 UTC. The deployer owns both until `_handOver`, in the same broadcast.
    function _deployRobin(
        Out memory o,
        address keeper,
        uint256 timelock,
        uint256 bondDelay,
        address identity,
        address reputation
    ) internal {
        o.rakeBuyer = new RakeBuyer(
            IERC20(o.usdg), IGameConfig(address(o.config)), address(o.vault), msg.sender, timelock, address(o.core)
        );
        o.rat = new RobinAmongThieves(
            RobinAmongThieves.Params({
                usdg: IERC20(o.usdg),
                config: IGameConfig(address(o.config)),
                core: IFairCore(address(o.core)),
                identity: IIdentityRegistry(identity),
                reputation: IReputationRegistry(reputation),
                owner: msg.sender,
                timelockDelay: timelock,
                bondDelay: bondDelay,
                genesis: (block.timestamp / 30 minutes) * 30 minutes,
                keeper: keeper,
                rakeSink: address(o.rakeBuyer),
                houseSink: address(o.vault)
            })
        );
        // K-B05: no seed chain exists until the keeper commits one (from currentRound() + 2), so the first rounds
        // could only run on the fallback seed. Entries start paused; the Safe unpauses once the keeper's chain is live.
        o.rat.pauseEntries(true);
    }

    function _wireRakeBuyer(Out memory o, address keeper, uint256 seed) internal {
        RakeBuyer b = o.rakeBuyer;
        b.setupSet(RakeBuyer.Op.SetKeeper, 0, keeper);
        b.setupSet(RakeBuyer.Op.SetRoute, 0, o.rakeRouteA);
        if (o.rakeRouteB != address(0)) b.setupSet(RakeBuyer.Op.SetRoute, 1, o.rakeRouteB);
        b.resetRatchet(seed); // A1-12: only during setup; later resets are timelocked and bounded
        b.finishSetup();
    }

    /// A1-14: in the same broadcast, the deployer hands all seven owned contracts straight to the Safe (no pending
    /// offer). FeeSplitter is not deployed here. K16-A02: a broadcast is a series of txs, not one atomic tx, so the
    /// mainnet run hands each contract over as soon as its last deployer-only call is done (`_give`), and this
    /// catch-all skips the ones already handed over. If a broadcast stops partway, `ResumeHandover` strips the deployer
    /// of what it still owns (docs/DEPLOY_HANDOVER_RUNBOOK.md).
    function _handOver(Out memory o, address safe) internal {
        _give(o.config, safe);
        _give(o.core, safe);
        _give(o.pass, safe);
        _give(o.alms, safe);
        _give(o.vault, safe);
        _give(o.rat, safe);
        _give(o.rakeBuyer, safe);
    }

    /// Hand one contract to the Safe unless it already owns it. Idempotent, so it is safe to call again.
    function _give(SafeHandover c, address safe) internal {
        if (address(c) != address(0) && c.owner() != safe) c.handOver(safe);
    }

    /// K16-A02 recovery: hand over whatever `deployer` still owns. A contract owned by anyone else is left alone.
    function _resume(SafeHandover[7] memory cs, address safe, address deployer) internal {
        for (uint256 i; i < 7; ++i) {
            if (address(cs[i]) != address(0) && cs[i].owner() == deployer) cs[i].handOver(safe);
        }
    }

    function _requireNoneOwned(SafeHandover[7] memory cs, address deployer) internal view {
        for (uint256 i; i < 7; ++i) {
            if (address(cs[i]) == address(0)) continue;
            require(cs[i].owner() != deployer && cs[i].pendingOwner() != deployer, "resume: deployer still owns one");
        }
    }

    /// After the broadcast: the Safe owns all seven, nothing is pending, and the deployer is neither.
    function _requireHandedOver(Out memory o, address safe, address deployer) internal view {
        require(safe != deployer, "handover: Safe is the deployer");
        Ownable2Step[7] memory cs = [
            Ownable2Step(o.config),
            Ownable2Step(o.core),
            Ownable2Step(o.pass),
            Ownable2Step(o.alms),
            Ownable2Step(o.vault),
            Ownable2Step(o.rat),
            Ownable2Step(o.rakeBuyer)
        ];
        for (uint256 i; i < 7; ++i) {
            require(cs[i].owner() == safe, "handover: Safe isn't the owner");
            require(cs[i].pendingOwner() == address(0), "handover: an ownership offer is pending");
        }
    }

    /// Robin Among Thieves and RakeBuyer as deployed: wiring, launch values, bonds off, owned by `safe`.
    function _checkRobin(Out memory o, address keeper, address identity, address reputation, address safe)
        internal
        view
    {
        RobinAmongThieves r = o.rat;
        require(address(r.usdg()) == o.usdg && address(r.config()) == address(o.config), "robin wiring");
        require(address(r.fairPass()) == address(o.pass), "robin pass");
        require(address(r.identity()) == identity && address(r.reputation()) == reputation, "robin registries");
        require(r.rakeSink() == address(o.rakeBuyer) && r.houseSink() == address(o.vault), "robin sinks");
        require(r.keeper() == keeper && r.licenceAmount() == 1000e18 && r.drawBps() == 2500, "robin params");
        require(!r.bondsEnabled() && r.minBond() == 0 && r.bondOpEta() == 0, "bonds off at launch");
        require(r.genesis() % 30 minutes == 0 && r.entriesPaused(), "robin rounds (entries paused, K-B05)");
        require(r.owner() == safe && r.pendingOwner() == address(0), "robin owned by the Safe");
        RakeBuyer b = o.rakeBuyer;
        require(address(b.usdg()) == o.usdg && address(b.config()) == address(o.config), "rakeBuyer wiring");
        require(b.vault() == address(o.vault) && b.keeper() == keeper && b.setupDone(), "rakeBuyer vault/keeper");
        require(address(b.routes(0)) == o.rakeRouteA && b.anchorRate() != 0, "rakeBuyer route/seed");
        require(b.forwardTo() == address(0), "rakeBuyer forwardTo must be unset (forwards go to the vault)");
        require(b.owner() == safe && b.pendingOwner() == address(0), "rakeBuyer owned by the Safe");
    }

    function _wire(Out memory o, address keeper, address toll, address almsSafe, uint256 seed) internal {
        FairCore c = o.core;
        c.setupSet(FairCore.Op.AddBooth, 0, address(o.arrow));
        c.setupSet(FairCore.Op.AddBooth, 0, address(o.seat));
        c.setupSet(FairCore.Op.SetKeeper, 0, keeper);
        c.setupSet(FairCore.Op.SetTollRecipient, 0, toll);
        c.setupSet(FairCore.Op.SetAlmsSafe, 0, almsSafe);
        c.setupSet(FairCore.Op.SetAlmsVote, 0, address(o.alms));
        c.setupSet(FairCore.Op.SetVault, 0, address(o.vault));
        c.setupSet(FairCore.Op.SetRoute, 0, o.routeA);
        if (o.routeB != address(0)) c.setupSet(FairCore.Op.SetRoute, 1, o.routeB);
        c.resetRatchet(seed); // A1-12: only during setup; later resets are timelocked and bounded
        c.finishSetup();
    }

    /// GameConfig as deployed: bound to FairCore, launch values, epoch 0, nothing queued, owned by the Safe.
    function _checkConfig(GameConfig c, address core, address wif, address safe) internal view {
        (address play, uint256 lockAmt, address buy) = c.tokens();
        _requireLaunchTokens(play, lockAmt, buy, wif);
        require(c.core() == core && c.epoch() == 0, "config core/epoch");
        require(c.tokensEta() == 0 && c.splitEta() == 0, "config update queued");
        require(c.delay() == CONFIG_DELAY_MAINNET, "config delay");
        require(c.owner() == safe && c.pendingOwner() == address(0), "config owned by the Safe");
        Split memory s = c.split();
        Split memory l = _launchSplit();
        require(keccak256(abi.encode(s)) == keccak256(abi.encode(l)), "config split");
    }

    /// The mainnet deployer is a fresh single-use EOA: nonce 0, so the key has never sent a transaction. It holds only
    /// gas ETH, it is never a Safe signer, and it should hold no USDG or $wif (a balance only warns, L-5). It is not
    /// the keeper and not the toll recipient. SafeAcceptVerify repeats the role checks after the Safe accepts, against owner, pending owner and
    /// every other role the contracts expose.
    function _requireFreshDeployer(
        address deployer,
        address safe,
        address keeper,
        address toll,
        address[] memory safeOwners,
        address usdg,
        address wif
    ) internal view {
        require(deployer != address(0), "deployer missing");
        require(deployer.code.length == 0, "deployer must be an EOA");
        require(vm.getNonce(deployer) == 0, "deployer nonce isn't 0");
        require(deployer != safe, "deployer is the Safe");
        require(deployer != keeper, "deployer is the keeper");
        require(deployer != toll, "deployer is the toll recipient");
        for (uint256 i; i < safeOwners.length; ++i) {
            require(safeOwners[i] != deployer, "deployer is a Safe signer");
        }
        // L-5: a balance is not power, and anyone can send dust to the deployer to block a deploy or a verify.
        // Warn so it gets swept to the Safe, but don't refuse.
        if (IERC20(usdg).balanceOf(deployer) != 0) {
            console2.log("  WARNING deployer holds USDG: sweep it to the Safe");
        }
        if (IERC20(wif).balanceOf(deployer) != 0) {
            console2.log("  WARNING deployer holds $wif: sweep it to the Safe");
        }
    }

    /// Real broadcasts write deployments/<chainId>.json. Simulations (dry runs) write deployments/dryrun-<chainId>.json,
    /// which is gitignored, so simulated addresses can never be mistaken for, or committed as, a real deployment.
    /// @param startBlock the L2 head read from the node before the broadcast (a lower bound on the deploy block).
    /// @param deployer the EOA that broadcast (recorded so SafeAcceptVerify can check it has no power left).
    function _write(Out memory o, uint256 startBlock, address deployer) internal {
        string memory id = vm.toString(block.chainid);
        string memory path = vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)
            ? string.concat("deployments/", id, ".json")
            : string.concat("deployments/dryrun-", id, ".json");
        string memory k = "deploy";
        vm.serializeUint(k, "chainId", block.chainid);
        vm.serializeUint(k, "startBlock", startBlock); // L2 block number, from eth_blockNumber (audit v3.6 M1)
        vm.serializeAddress(k, "deployer", deployer);
        vm.serializeAddress(k, "usdg", o.usdg);
        vm.serializeAddress(k, "wif", o.wif);
        vm.serializeAddress(k, "tokenB", o.tokenB);
        vm.serializeAddress(k, "gameConfig", address(o.config));
        vm.serializeAddress(k, "fairPass", address(o.pass));
        vm.serializeAddress(k, "fairCore", address(o.core));
        vm.serializeAddress(k, "lastArrow", address(o.arrow));
        vm.serializeAddress(k, "sheriffsSeat", address(o.seat));
        vm.serializeAddress(k, "almsVote", address(o.alms));
        vm.serializeAddress(k, "locksleyVault", address(o.vault));
        vm.serializeAddress(k, "fairLens", address(o.lens));
        vm.serializeAddress(k, "routeA", o.routeA);
        vm.serializeAddress(k, "robinAmongThieves", address(o.rat));
        vm.serializeAddress(k, "rakeBuyer", address(o.rakeBuyer));
        vm.serializeAddress(k, "rakeRouteA", o.rakeRouteA);
        vm.serializeAddress(k, "rakeRouteB", o.rakeRouteB);
        string memory j = vm.serializeAddress(k, "routeB", o.routeB);
        vm.writeJson(j, path);
        console2.log("wrote", path);
    }
}

/// DeployTestnet's sends and post checks, shared with test/unit/TestnetDeployVerify.t.sol.
abstract contract TestnetBase is DeployBase {
    /// Everything DeployTestnet sends, from `me` (the broadcast sender). Split out so a test can run the exact same
    /// deploy under a prank and feed its recorded logs to SafeAcceptVerify's scan (test/unit/TestnetDeployVerify.t.sol).
    function _deployTestnet(address me, address newOwner, uint64 start, uint64 end, uint256 dayLen)
        internal
        returns (Out memory o)
    {
        uint64 ws = uint64(vm.envOr("ALMS_SUGGEST", uint256(0)));
        bytes32[] memory eligible = _eligibleEnv();
        address keeper = vm.envOr("KEEPER", me);
        address toll = vm.envOr("TOLL_RECIPIENT", me);
        address almsSafe = vm.envOr("ALMS_SAFE", newOwner != address(0) ? newOwner : me);
        if (newOwner != address(0)) require(almsSafe == newOwner, "ALMS_SAFE must be the owner Safe");
        TestRoute route = new TestRoute(781_250e12); // 781.25 tWIF per USDG
        TestRoute routeB = new TestRoute(vm.envOr("TOKEN_B_RATE", uint256(100e12))); // 100 tTKB per USDG by default
        TestToken usdg = new TestToken("Test USDG", "tUSDG", 6, 1_000e6, address(0));
        TestToken wif = new TestToken("Test World is Flat", "tWIF", 18, 50_000e18, address(route));
        TestToken tokenB = new TestToken("Test Token B", "tTKB", 18, 50_000e18, address(routeB));
        // GameConfig delay on testnet: CONFIG_DELAY seconds (default 0), so config updates can be exercised quickly
        o = _deployGame(address(usdg), address(wif), me, 0, vm.envOr("CONFIG_DELAY", uint256(0)), dayLen);
        route.wire(address(o.core), ITestMint(address(wif)));
        routeB.wire(address(o.core), ITestMint(address(tokenB)));
        o.tokenB = address(tokenB);
        o.routeA = address(route);
        o.routeB = address(routeB); // route 1 buys tTKB; FairCore only uses a route whose tokenOut is the buy token
        _wire(o, keeper, toll, almsSafe, route.RATE() * 1e18); // v3.6: buybacks need a seeded anchor
        _deployRobin(o, keeper, 0, vm.envOr("BOND_DELAY", uint256(0)), IDENTITY_46630, REPUTATION_46630);
        route.wireExtra(address(o.rakeBuyer));
        routeB.wireExtra(address(o.rakeBuyer));
        (o.rakeRouteA, o.rakeRouteB) = (address(route), address(routeB));
        _wireRakeBuyer(o, keeper, route.RATE() * 1e18);
        o.core.setFair(0, start, end);
        if (ws != 0) o.alms.setAlmsWindows(0, ws, uint64(vm.envUint("ALMS_VOTE")), uint64(vm.envUint("ALMS_END")));
        if (eligible.length != 0) o.alms.setEligible(eligible);
        if (newOwner != address(0)) _handOver(o, newOwner); // A1-14: same broadcast, no pending window
    }

    /// DeployTestnet's post-broadcast checks.
    function _checkTestnet(Out memory o, address me, address newOwner) internal view {
        (uint64 n, uint64 w) = _almsMinimums();
        require(o.alms.MIN_NOTICE() == n && o.alms.MIN_WINDOW() == w, "Alms minimums");
        if (newOwner != address(0)) _requireHandedOver(o, newOwner, me);
        require(o.core.anchorRate() == TestRoute(o.routeA).RATE() * 1e18 && !o.core.anchorStale(), "anchor seeded");
        require(o.config.core() == address(o.core) && o.config.epoch() == 0, "config bound");
        _checkRobin(o, vm.envOr("KEEPER", me), IDENTITY_46630, REPUTATION_46630, newOwner != address(0) ? newOwner : me);
    }
}

/// Testnet (46630): test USDG and $wif with a public faucet, a test buyback route, zero timelock.
/// The deployer is a fresh single-use EOA and is not a Safe owner. Signer 1 (0xb44F…50bA) stays a Safe owner.
/// SafeAcceptVerify's no-leftover-power check applies here unchanged. Do not deploy from `gos-mainnet` or from signer 1.
/// Password typed at the prompt only (never a password file).
///   cast wallet import gos-testnet --interactive
///   forge script script/Deploy.s.sol:DeployTestnet --rpc-url robinhood_testnet --broadcast \
///     --account gos-testnet --sender <that address>
/// Env (optional): SEAT_DAY_SECONDS (default 86400; e.g. 600 for a compressed Fair), FAIR_START, FAIR_END,
///                 TESTNET_OWNER (the pinned testnet Safe; ownership is handed to it in the same broadcast).
///   For the Safe rehearsal (mirror the mainnet flow): TESTNET_OWNER = the testnet Safe (also the Alms Safe), SAFE_OWNERS
///   (its 3 owners), plus KEEPER, TOLL_RECIPIENT, ALMS_SUGGEST/ALMS_VOTE/ALMS_END (Fair 0 windows; must pass the W1 rules) and
///   ELIGIBLE_IDS. KEEPER and TOLL_RECIPIENT must not be the deployer: SafeAcceptVerify refuses a deployer who still holds
///   a role. Then run script/SafeAccept.s.sol:SafeAcceptVerify against testnet (nothing for the Safe to accept).
contract DeployTestnet is TestnetBase {
    function run() external {
        require(block.chainid == 46630, "testnet only");
        uint256 dayLen = vm.envOr("SEAT_DAY_SECONDS", uint256(1 days));
        uint64 start = uint64(vm.envOr("FAIR_START", block.timestamp + 120));
        uint64 end = uint64(vm.envOr("FAIR_END", block.timestamp + 7 days));
        address newOwner = vm.envOr("TESTNET_OWNER", address(0));
        // the rehearsal mirrors mainnet: one genuine 2-of-3 Safe with the pinned owners, also the Alms Safe
        if (newOwner != address(0)) {
            _requirePinned(newOwner, PINNED_TESTNET_SAFE, "TESTNET_OWNER");
            _checkSafe(newOwner, vm.envAddress("SAFE_OWNERS", ","), "TESTNET_OWNER");
        }
        uint256 startBlock = _l2Head(); // before the broadcast: a lower bound on the deploy block

        vm.startBroadcast();
        address me = msg.sender;
        Out memory o = _deployTestnet(me, newOwner, start, end, dayLen);
        vm.stopBroadcast();
        _checkTestnet(o, me, newOwner);
        _write(o, startBlock, me);
    }
}

/// Mainnet (4663). the owner's explicit approval on the day, from a fresh single-use deployer EOA (never the testnet key).
/// The deployer holds only gas ETH. Its nonce is 0: the key has never sent a transaction. It is never a Safe signer,
/// and it should hold no USDG or $wif (a balance only warns). It is not the keeper and not the toll recipient.
/// Create the keystore on the deploy machine. The password is typed at the prompt only:
/// never `--password`, `--password-file`, `--unsafe-password`, or `CAST_UNSAFE_PASSWORD`, and never shell history.
///   cast wallet import gos-mainnet --interactive
///   cast wallet address --account gos-mainnet
///   forge script script/Deploy.s.sol:DeployMainnet --rpc-url robinhood --broadcast --slow \
///     --account gos-mainnet --sender <that address>
/// `--slow` sends each tx only after the previous one is mined, so a dropped tx stops the run in order (K16-A02).
/// If the run stops partway, follow docs/DEPLOY_HANDOVER_RUNBOOK.md (ResumeHandover, then redeploy fresh).
/// QuoteAnchor (script/Mainnet.s.sol) is read-only and takes no account. The broadcast ends by handing ownership of all
/// seven contracts to the Safe (A1-14). Then SafeAcceptVerify checks the deployer has no power left, then sweep leftover
/// gas ETH to the Safe and delete the keystore (runbook).
/// Env (required): GOS_SAFE (the owner Safe, also the Alms Safe; must equal PINNED_MAINNET_SAFE; OWNER_SAFE is
///   accepted as an alias and must match if both are set), SAFE_OWNERS (its 3 owners, comma-separated), KEEPER,
///   TOLL_RECIPIENT, ANCHOR_SEED (the 30-min average from
///   `forge script script/Mainnet.s.sol:QuoteAnchor`; the script refuses a seed more than 20% from the live quote).
/// Env (required): ELIGIBLE_IDS (comma-separated bytes32 donate.gg configIds, see contracts/eligible/fair0.json).
///   Fair 0's suggestions open 2 Nov 12:00 UTC, so the allowlist is set in the deploy itself.
/// Deadline: setAlmsWindows needs 24h notice before suggestions open (2 Nov 12:00 UTC), so the script refuses to run
///   after 1 Nov 11:00 UTC (18:00 Bangkok), leaving an hour for the broadcast to land.
/// After broadcast: run script/SafeAccept.s.sol:SafeAcceptVerify (read-only checks + log scan). There is no accept batch:
///   the Safe already owns everything. ANCHOR_SEED stands; a later re-seed is a queued, bounded Op.ResetRatchet (48h).
contract DeployMainnet is DeployBase, MainnetAddrs {
    // Fair 0, the Nottingham Fair (timeline A1, 30 Oct): 2 Nov 00:00 UTC -> 4 Nov 00:00 UTC, so the whole Fair
    // ends before round one of judging closes (4 Nov 17:30 UTC).
    uint64 constant FAIR0_START = 1793577600;
    uint64 constant FAIR0_END = 1793750400;
    // Alms: suggest 2 Nov 12:00 -> 3 Nov 12:00 UTC, vote 3 Nov 12:00 -> 4 Nov 12:00 UTC (5.5h before round one closes).
    uint64 constant ALMS0_SUGGEST = 1793620800;
    uint64 constant ALMS0_VOTE = 1793707200;
    uint64 constant ALMS0_END = 1793793600;
    // Latest start of the run: 24h notice for the Alms windows plus an hour for the broadcast (1 Nov 11:00 UTC).
    uint64 constant DEPLOY_BY = ALMS0_SUGGEST - 25 hours;

    function run() external {
        require(block.chainid == 4663, "mainnet only");
        address safe = _safeFromEnv(); // GOS_SAFE (OWNER_SAFE accepted as an alias; both set must agree)
        address keeper = vm.envAddress("KEEPER");
        address toll = vm.envAddress("TOLL_RECIPIENT");
        // The Alms Safe IS the owner Safe. ALMS_SAFE may be omitted; if given it must match.
        address almsSafe = vm.envOr("ALMS_SAFE", safe);
        require(almsSafe == safe, "ALMS_SAFE must be the owner Safe");
        _requirePinned(safe, PINNED_MAINNET_SAFE, "GOS_SAFE");
        address[] memory safeOwners = vm.envAddress("SAFE_OWNERS", ",");
        _checkSafe(safe, safeOwners, "GOS_SAFE");
        // --sender / --account. Checked before the broadcast so a bad deployer never deploys.
        address deployer = msg.sender;
        _requireFreshDeployer(deployer, safe, keeper, toll, safeOwners, USDG, WIF);
        require(block.timestamp <= DEPLOY_BY, "too late: deploy by 1 Nov 11:00 UTC (Alms need 24h notice)");
        bytes32[] memory eligible = _eligibleEnv();
        require(eligible.length != 0, "ELIGIBLE_IDS required: suggestions open 2 Nov 12:00 UTC");
        uint256 seed = vm.envUint("ANCHOR_SEED");
        _checkSeed(seed); // simulation only, before the broadcast
        uint256 startBlock = _l2Head(); // before the broadcast: a lower bound on the deploy block

        PoolKey memory usdgPool = _usdgPool();
        PoolKey memory wifPool = _wifPool();

        vm.startBroadcast();
        require(msg.sender == deployer, "broadcast sender isn't the deployer");
        Out memory o = _deployGame(USDG, WIF, msg.sender, 48 hours, CONFIG_DELAY_MAINNET, 1 days);
        // K16-A02: each contract goes to the Safe right after its last deployer-only call, so a broadcast that stops
        // partway leaves as little as possible with the deployer. ResumeHandover finishes the rest (runbook).
        _give(o.config, safe); // bound to FairCore in _deployGame; nothing else needs the deployer
        _give(o.pass, safe);
        _give(o.vault, safe);
        o.routeA = address(new BuyRouteV4(PM, address(o.core), usdgPool, wifPool));
        o.routeB = address(new BuyRouteV3V4(PM, address(o.core), IUniswapV3Pool(V3_POOL), USDG, WETH, wifPool));
        _wire(o, keeper, toll, almsSafe, seed); // v3.6: no buyback can run before the anchor is seeded
        o.core.setFair(0, FAIR0_START, FAIR0_END);
        _give(o.core, safe);
        o.alms.setAlmsWindows(0, ALMS0_SUGGEST, ALMS0_VOTE, ALMS0_END);
        if (eligible.length != 0) o.alms.setEligible(eligible);
        _give(o.alms, safe);
        _deployRobin(o, keeper, 48 hours, 7 days, IDENTITY_4663, REPUTATION_4663);
        _give(o.rat, safe);
        o.rakeRouteA = address(new BuyRouteV4(PM, address(o.rakeBuyer), usdgPool, wifPool));
        o.rakeRouteB = address(new BuyRouteV3V4(PM, address(o.rakeBuyer), IUniswapV3Pool(V3_POOL), USDG, WETH, wifPool));
        _wireRakeBuyer(o, keeper, seed);
        _give(o.rakeBuyer, safe);
        _handOver(o, safe); // A1-14/A1-15: catch-all, a no-op when every stage above landed
        vm.stopBroadcast();
        _requireHandedOver(o, safe, deployer);

        require(address(o.core.usdg()) == USDG && address(o.core.config()) == address(o.config), "core wiring");
        _checkConfig(o.config, address(o.core), WIF, safe);
        require(o.core.isBooth(address(o.arrow)) && o.core.isBooth(address(o.seat)), "booths");
        require(o.core.timelockDelay() == 48 hours && o.core.setupDone(), "timelock");
        require(address(o.core.routes(0)) == o.routeA && address(o.core.routes(1)) == o.routeB, "routes");
        require(o.core.keeper() == keeper && o.core.tollRecipient() == toll, "keeper/toll");
        require(o.core.almsSafe() == almsSafe && o.core.almsVote() == address(o.alms), "alms wiring");
        require(o.core.vault() == address(o.vault), "vault wiring");
        require(o.core.anchorRate() == seed && o.core.ratchetFloorRate() != 0, "anchor seeded");
        (uint64 fs, uint64 fe) = o.core.fairs(0);
        require(fs == FAIR0_START && fe == FAIR0_END && o.core.fairCount() == 1, "Fair 0");
        (uint64 ws, uint64 wv, uint64 we) = o.alms.windows(0);
        require(ws == ALMS0_SUGGEST && wv == ALMS0_VOTE && we == ALMS0_END, "Alms windows");
        require(o.alms.MIN_NOTICE() == 24 hours && o.alms.MIN_WINDOW() == 24 hours, "Alms minimums");
        require(o.seat.dayLength() == 1 days && o.seat.day0() % 1 days == 0, "UTC days");
        require(o.seat.day0() <= FAIR0_START, "Seat days start by Fair 0");
        require(BuyRouteV4(o.routeA).core() == address(o.core), "route A core");
        require(BuyRouteV3V4(payable(o.routeB)).core() == address(o.core), "route B core");
        require(address(BuyRouteV3V4(payable(o.routeB)).v3Pool()) == V3_POOL, "route B pool");
        require(
            BuyRouteV4(o.routeA).tokenOut() == WIF && BuyRouteV3V4(payable(o.routeB)).tokenOut() == WIF, "route tokens"
        );
        (PoolKey memory ua, PoolKey memory wa) = BuyRouteV4(o.routeA).pools();
        require(ua.currency1 == USDG && ua.hooks == USDG_HOOK && wa.currency1 == WIF && wa.hooks == WIF_HOOK, "A pools");
        require(address(o.arrow.core()) == address(o.core) && address(o.seat.core()) == address(o.core), "booth core");
        require(
            address(o.pass.config()) == address(o.config) && address(o.vault.core()) == address(o.core),
            "pass/vault wiring"
        );
        for (uint256 i; i < eligible.length; ++i) {
            require(o.alms.eligibleAt(eligible[i]) != 0, "eligible");
        }
        _checkRobin(o, keeper, IDENTITY_4663, REPUTATION_4663, safe);
        require(o.rat.timelockDelay() == 48 hours && o.rat.bondDelay() == 7 days, "robin delays");
        require(o.rakeBuyer.timelockDelay() == 48 hours && o.rakeBuyer.anchorRate() == seed, "rakeBuyer delay/seed");
        require(BuyRouteV4(o.rakeRouteA).core() == address(o.rakeBuyer), "rake route A caller");
        require(BuyRouteV3V4(payable(o.rakeRouteB)).core() == address(o.rakeBuyer), "rake route B caller");
        require(
            BuyRouteV4(o.rakeRouteA).tokenOut() == WIF && BuyRouteV3V4(payable(o.rakeRouteB)).tokenOut() == WIF,
            "rake route tokens"
        );
        _write(o, startBlock, deployer);
    }
}

/// K16-A02: recovery for a mainnet (or testnet rehearsal) broadcast that stopped partway. Hands every listed contract the
/// deployer still owns to the pinned Safe, then checks the deployer owns none of them. It does not finish setup: a
/// partial deploy is abandoned and redeployed from a new fresh EOA (docs/DEPLOY_HANDOVER_RUNBOOK.md).
/// Env: GOS_SAFE, SAFE_OWNERS, and the addresses from broadcast/Deploy.s.sol/<chainId>/run-latest.json as
/// GAME_CONFIG, FAIR_PASS, FAIR_CORE, ALMS_VOTE, LOCKSLEY_VAULT, ROBIN, RAKE_BUYER (leave out any that never deployed).
///   forge script script/Deploy.s.sol:ResumeHandover --rpc-url robinhood --broadcast --slow \
///     --account gos-mainnet --sender <the deployer>
contract ResumeHandover is DeployBase {
    function run() external {
        address safe = _safeFromEnv();
        _requirePinned(safe, block.chainid == 4663 ? PINNED_MAINNET_SAFE : PINNED_TESTNET_SAFE, "GOS_SAFE");
        _checkSafe(safe, vm.envAddress("SAFE_OWNERS", ","), "GOS_SAFE");
        SafeHandover[7] memory cs = _listed();
        vm.startBroadcast();
        address me = msg.sender;
        _resume(cs, safe, me);
        vm.stopBroadcast();
        _requireNoneOwned(cs, me);
    }

    function _listed() internal view returns (SafeHandover[7] memory cs) {
        string[7] memory names =
            ["GAME_CONFIG", "FAIR_PASS", "FAIR_CORE", "ALMS_VOTE", "LOCKSLEY_VAULT", "ROBIN", "RAKE_BUYER"];
        for (uint256 i; i < 7; ++i) {
            cs[i] = SafeHandover(vm.envOr(names[i], address(0)));
        }
    }
}
