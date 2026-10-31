// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {console2} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {FairPass} from "../src/FairPass.sol";
import {GameConfig} from "../src/GameConfig.sol";
import {FairCore} from "../src/FairCore.sol";
import {AlmsVote} from "../src/AlmsVote.sol";
import {LocksleyVault, ICoreVaultUsdg} from "../src/LocksleyVault.sol";
import {LastArrow} from "../src/LastArrow.sol";
import {SheriffsSeat} from "../src/SheriffsSeat.sol";
import {FairLens, IVaultView} from "../src/FairLens.sol";
import {TestToken, TestRoute} from "../src/testnet/TestTokens.sol";
import {MainnetAddrs} from "./Mainnet.s.sol";
import {LaunchSplit} from "./LaunchSplit.s.sol";
import {IFairCore, IGameConfig, IBuyRoute, Tokens, Split} from "../src/interfaces/IFair.sol";
import {IIdentityRegistry, IReputationRegistry} from "../src/interfaces/I8004.sol";
import {RobinAmongThieves} from "../src/RobinAmongThieves.sol";
import {RakeBuyer} from "../src/RakeBuyer.sol";
import {PoolKey} from "../src/interfaces/IV4Minimal.sol";
import {BuyRouteV4} from "../src/routes/BuyRouteV4.sol";
import {BuyRouteV3V4, IUniswapV3Pool} from "../src/routes/BuyRouteV3V4.sol";
import {SafeCheck} from "./Deploy.s.sol";

/// Shared checks for the Safe's first batch (mainnet 4663, and testnet 46630 for the rehearsal).
/// Env: OWNER_SAFE (also the Alms Safe), KEEPER, TOLL_RECIPIENT, ANCHOR_SEED, ELIGIBLE_IDS (the same comma-separated
///      list the deploy used; each id must be eligible on chain) or, legacy, ELIGIBLE_COUNT (default 0),
///      DEPLOYMENT_FILE (default deployments/<chainId>.json).
///      SafeAcceptVerify also needs DEPLOYER (the deploy EOA; must match `deployer` in the deployment file).
///      SafeAcceptBatch and SafeAcceptVerify both require OWNER_SAFE to equal the Safe pinned in script/Deploy.s.sol.
///      The mainnet pin is still zero, so a mainnet batch or verify fails closed until that address is written in a
///      reviewed commit.
///      Testnet only: FAIR_START, FAIR_END, and ALMS_SUGGEST/ALMS_VOTE/ALMS_END if windows were set at deploy.
/// The parts of a Safe this script reads. Owners are checked so the deployer is not a signer.
interface ISafeOwners {
    function getOwners() external view returns (address[] memory);
}

/// Getters used to rebuild a deployment. A substituted contract that does not expose them fails the codehash check.
interface IDeployed {
    function owner() external view returns (address);
    function core() external view returns (address);
    function usdg() external view returns (address);
    function config() external view returns (address);
    function fairPass() external view returns (address);
    function pass() external view returns (address);
    function delay() external view returns (uint256);
    function timelockDelay() external view returns (uint256);
    function day0() external view returns (uint256);
    function dayLength() external view returns (uint256);
    function MIN_NOTICE() external view returns (uint256);
    function MIN_WINDOW() external view returns (uint256);
    function tokens() external view returns (address playToken, uint256 passLock, address buyToken);
    function split() external view returns (Split memory);
    function arrow() external view returns (address);
    function seat() external view returns (address);
    function vault() external view returns (address);
    function identity() external view returns (address);
    function reputation() external view returns (address);
    function bondDelay() external view returns (uint256);
    function genesis() external view returns (uint256);
    function keeper() external view returns (address);
    function rakeSink() external view returns (address);
    function houseSink() external view returns (address);
    function pm() external view returns (address);
    function tokenOut() external view returns (address);
    function v3Pool() external view returns (address);
    function weth() external view returns (address);
    function pools() external view returns (PoolKey memory, PoolKey memory);
    function pool() external view returns (PoolKey memory);
    function RATE() external view returns (uint256);
    function deployer() external view returns (address);
    function extraCaller() external view returns (address);
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
    function faucetAmount() external view returns (uint256);
    function minter() external view returns (address);
}

abstract contract AcceptBase is MainnetAddrs, SafeCheck, LaunchSplit {
    uint256 constant LOG_CHUNK = 500_000;
    uint256 constant MAX_SPAN = 5_000_000; // ~6 days of L2 blocks: a stale or L1-numbered file fails loudly
    uint256 constant SEED_MAX_AGE = 30 minutes;

    struct D {
        GameConfig config;
        FairCore core;
        FairPass pass;
        AlmsVote alms;
        LocksleyVault vault;
        address usdg;
        address wif;
        address arrow;
        address seat;
        address routeA;
        address routeB;
        uint256 startBlock;
        RobinAmongThieves rat;
        RakeBuyer rakeBuyer;
        address rakeRouteA;
        address rakeRouteB;
        address deployer;
        FairLens lens;
        address tokenB; // testnet route B's token; zero on mainnet
    }

    function _file() internal view returns (string memory) {
        return vm.envOr("DEPLOYMENT_FILE", string.concat("deployments/", vm.toString(block.chainid), ".json"));
    }

    function _load() internal view returns (D memory d) {
        require(block.chainid == 4663 || block.chainid == 46630, "Robinhood Chain only");
        string memory j = vm.readFile(_file());
        require(vm.parseJsonUint(j, ".chainId") == block.chainid, "deployment file is for another chain");
        d.config = GameConfig(vm.parseJsonAddress(j, ".gameConfig"));
        d.core = FairCore(vm.parseJsonAddress(j, ".fairCore"));
        d.pass = FairPass(vm.parseJsonAddress(j, ".fairPass"));
        d.alms = AlmsVote(vm.parseJsonAddress(j, ".almsVote"));
        d.vault = LocksleyVault(vm.parseJsonAddress(j, ".locksleyVault"));
        d.usdg = vm.parseJsonAddress(j, ".usdg");
        d.wif = vm.parseJsonAddress(j, ".wif");
        d.arrow = vm.parseJsonAddress(j, ".lastArrow");
        d.seat = vm.parseJsonAddress(j, ".sheriffsSeat");
        d.routeA = vm.parseJsonAddress(j, ".routeA");
        d.routeB = vm.parseJsonAddress(j, ".routeB");
        d.startBlock = vm.parseJsonUint(j, ".startBlock");
        d.rat = RobinAmongThieves(vm.parseJsonAddress(j, ".robinAmongThieves"));
        d.rakeBuyer = RakeBuyer(vm.parseJsonAddress(j, ".rakeBuyer"));
        d.rakeRouteA = vm.parseJsonAddress(j, ".rakeRouteA");
        d.rakeRouteB = vm.parseJsonAddress(j, ".rakeRouteB");
        d.deployer = vm.parseJsonAddress(j, ".deployer");
        d.lens = FairLens(vm.parseJsonAddress(j, ".fairLens"));
        d.tokenB = vm.parseJsonAddress(j, ".tokenB");
    }

    /// After the Safe accepts: the deployer EOA has no owner, pending owner, or other role on any game contract, is
    /// not a Safe signer, and holds no USDG or $wif. Routes, LastArrow, SheriffsSeat and FairLens expose no owner or
    /// role (mainnet routes are immutable; the testnet route's one-shot `wire` is already spent). There is no
    /// AccessControl role on these contracts. The named roles below are every address authority they do expose.
    function _assertDeployerHasNoPower(D memory d, address deployer, address safe, address[] memory safeOwners)
        internal
        view
    {
        require(deployer != address(0), "deployer missing from the deployment file");
        require(deployer == d.deployer, "DEPLOYER doesn't match the deployment file");
        require(deployer != safe, "deployer is the Safe");
        for (uint256 i; i < safeOwners.length; ++i) {
            require(safeOwners[i] != deployer, "deployer is a Safe signer");
        }
        _noOwnerRole(d.config, deployer, "GameConfig");
        _noOwnerRole(d.core, deployer, "FairCore");
        _noOwnerRole(d.pass, deployer, "FairPass");
        _noOwnerRole(d.alms, deployer, "AlmsVote");
        _noOwnerRole(d.vault, deployer, "LocksleyVault");
        _noOwnerRole(d.rat, deployer, "RobinAmongThieves");
        _noOwnerRole(d.rakeBuyer, deployer, "RakeBuyer");
        require(d.core.keeper() != deployer, "deployer is the FairCore keeper");
        require(d.rat.keeper() != deployer, "deployer is the Robin keeper");
        require(d.rakeBuyer.keeper() != deployer, "deployer is the RakeBuyer keeper");
        require(d.core.tollRecipient() != deployer, "deployer is the toll recipient");
        require(d.core.almsSafe() != deployer, "deployer is the Alms Safe");
        require(d.core.almsVote() != deployer && d.core.vault() != deployer, "deployer is wired as alms vote or vault");
        require(!d.core.isBooth(deployer), "deployer is a booth");
        require(
            address(d.core.routes(0)) != deployer && address(d.core.routes(1)) != deployer, "deployer is a buy route"
        );
        require(d.vault.queuedLauncher() != deployer, "deployer is the queued vault launcher");
        require(d.vault.launcher() != deployer, "deployer is the vault launcher");
        require(d.rat.rakeSink() != deployer && d.rat.houseSink() != deployer, "deployer is a Robin sink");
        require(
            address(d.rakeBuyer.routes(0)) != deployer && address(d.rakeBuyer.routes(1)) != deployer,
            "deployer is a rake route"
        );
        // L-5: a balance is not power, and anyone can send dust to the deployer to block a deploy or a verify.
        // Warn so it gets swept to the Safe, but don't refuse.
        if (IERC20(d.usdg).balanceOf(deployer) != 0) {
            console2.log("  WARNING deployer holds USDG: sweep it to the Safe");
        }
        if (IERC20(d.wif).balanceOf(deployer) != 0) {
            console2.log("  WARNING deployer holds $wif: sweep it to the Safe");
        }
    }

    function _noOwnerRole(Ownable2Step c, address deployer, string memory name) internal view {
        require(c.owner() != deployer, string.concat(name, ": deployer is still the owner"));
        require(c.pendingOwner() != deployer, string.concat(name, ": deployer is the pending owner"));
    }

    function _mainnet() internal view returns (bool) {
        return block.chainid == 4663;
    }

    /// Batch and Verify refuse any owner Safe other than the one pinned in script/Deploy.s.sol. Mainnet's pin is still
    /// zero, so a mainnet batch or verify fails closed until that address is written in a reviewed commit.
    function _requirePinnedOwner(address safe) internal view {
        require(block.chainid == 4663 || block.chainid == 46630, "Robinhood Chain only");
        _requirePinned(safe, _mainnet() ? PINNED_MAINNET_SAFE : PINNED_TESTNET_SAFE, "OWNER_SAFE");
    }

    function _head(D memory d) internal returns (uint256 head) {
        head = _l2Head();
        require(head >= d.startBlock && head - d.startBlock < MAX_SPAN, "startBlock isn't a recent L2 block number");
    }

    /// The seed is checked against an independent source: the live quote on mainnet, the fixed test rate on testnet.
    function _checkSeedFor(D memory d, uint256 seed) internal {
        if (_mainnet()) {
            _checkSeed(seed);
        } else {
            require(seed == TestRoute(d.routeA).RATE() * 1e18, "testnet seed must be the test route's rate");
        }
    }

    function _checkWiring(D memory d) internal view {
        if (_mainnet()) {
            require(d.usdg == USDG && d.wif == WIF, "token addresses in the file");
            require(d.core.timelockDelay() == 48 hours, "timelock");
        }
        require(address(d.core.usdg()) == d.usdg && address(d.core.config()) == address(d.config), "core wiring");
        require(address(d.pass.config()) == address(d.config) && d.config.core() == address(d.core), "config wiring");
        (address play, uint256 lockAmt, address buy) = d.config.tokens();
        _requireLaunchTokens(play, lockAmt, buy, d.wif);
        require(d.config.epoch() == 0 && d.config.tokensEta() == 0 && d.config.splitEta() == 0, "config update queued");
        // the constructor emits no event, so only this check catches a deploy made with another split
        require(keccak256(abi.encode(d.config.split())) == keccak256(abi.encode(_launchSplit())), "config split");
        if (_mainnet()) require(d.config.delay() == 7 days, "config delay");
        require(d.core.setupDone(), "setup still open");
        require(d.core.isBooth(d.arrow) && d.core.isBooth(d.seat), "booths");
        require(address(d.core.routes(0)) == d.routeA && address(d.core.routes(1)) == d.routeB, "routes");
        require(d.core.keeper() == vm.envAddress("KEEPER"), "keeper changed (or revoked) since deploy");
        require(d.core.tollRecipient() == vm.envAddress("TOLL_RECIPIENT"), "toll recipient");
        require(d.core.almsSafe() == _safeFromEnv(), "alms safe is the owner Safe");
        require(d.core.almsVote() == address(d.alms) && d.core.vault() == address(d.vault), "alms/vault wiring");
        require(!d.core.salesPaused(), "sales paused");
        require(d.vault.launcher() == address(0) && d.vault.queuedLauncher() == address(0), "launcher queued");
        (uint64 fs, uint64 fe, uint64 ws, uint64 wv, uint64 we) = _expectedFair0();
        (uint64 s, uint64 e) = d.core.fairs(0);
        require(s == fs && e == fe && d.core.fairCount() == 1, "Fair 0");
        (uint64 a, uint64 b, uint64 c) = d.alms.windows(0);
        require(a == ws && b == wv && c == we, "Alms windows");
        _checkRobin(d);
    }

    /// Robin Among Thieves and RakeBuyer: GameConfig's tokens, the chain's ERC-8004 registries, sinks, keeper, launch
    /// values, bonds off and nothing queued; RakeBuyer's routes buy the buy token.
    function _checkRobin(D memory d) internal view {
        RobinAmongThieves r = d.rat;
        (address idr, address rep) = _mainnet()
            ? (0x8004A169FB4a3325136EB29fA0ceB6D2e539a432, 0x8004BAa17C55a88189AE136b182e5fdA19dE9b63)
            : (0x8004A818BFB912233c491871b3d84c89A494BD9e, 0x8004B663056A597Dffe9eCcC1965A193B7388713);
        require(address(r.usdg()) == d.usdg && address(r.config()) == address(d.config), "robin wiring");
        require(address(r.fairPass()) == address(d.pass), "robin pass");
        require(address(r.identity()) == idr && address(r.reputation()) == rep, "robin registries");
        require(r.rakeSink() == address(d.rakeBuyer) && r.houseSink() == address(d.vault), "robin sinks");
        require(r.keeper() == vm.envAddress("KEEPER"), "robin keeper");
        // K-B05: the deploy pauses entries until the keeper's seed chain is live; the scan expects exactly that one
        // EntriesPaused, so a Safe un-pause before this verify ran shows up both here and as a wrong count.
        require(r.entriesPaused(), "robin entries must start paused (K-B05)");
        require(r.licenceAmount() == 1000e18 && r.drawBps() == 2500, "robin params");
        require(!r.bondsEnabled() && r.minBond() == 0 && r.bondOpEta() == 0, "bonds must be off at launch");
        if (_mainnet()) require(r.timelockDelay() == 48 hours && r.bondDelay() == 7 days, "robin delays");
        RakeBuyer b = d.rakeBuyer;
        require(address(b.usdg()) == d.usdg && address(b.config()) == address(d.config), "rakeBuyer wiring");
        require(
            b.vault() == address(d.vault) && b.keeper() == vm.envAddress("KEEPER") && b.setupDone(),
            "rakeBuyer vault/keeper"
        );
        require(address(b.routes(0)) == d.rakeRouteA && address(b.routes(1)) == d.rakeRouteB, "rakeBuyer routes");
        require(b.forwardTo() == address(0), "rakeBuyer forwardTo must be unset (forwards go to the vault)");
        require(IBuyRoute(d.rakeRouteA).tokenOut() == d.wif, "rakeBuyer route A token");
        if (_mainnet()) {
            require(IBuyRoute(d.rakeRouteB).tokenOut() == d.wif, "rakeBuyer route B token");
            require(b.timelockDelay() == 48 hours, "rakeBuyer timelock");
            _checkRakeRoutes(d);
        }
    }

    /// Same shape as Deploy's FairCore route checks, for RakeBuyer's own routes: caller, pool manager, both pool
    /// keys (currencies, fee, tick spacing, hooks) and route B's v3 pool. Testnet routes are TestRoutes, so mainnet only.
    function _checkRakeRoutes(D memory d) internal view {
        BuyRouteV4 a = BuyRouteV4(d.rakeRouteA);
        BuyRouteV3V4 routeB = BuyRouteV3V4(payable(d.rakeRouteB));
        require(a.core() == address(d.rakeBuyer) && address(a.pm()) == PM, "rake route A core/pm");
        require(routeB.core() == address(d.rakeBuyer) && address(routeB.pm()) == PM, "rake route B core/pm");
        require(
            address(routeB.v3Pool()) == V3_POOL && routeB.usdg() == USDG && routeB.weth() == WETH, "rake route B v3"
        );
        (PoolKey memory usdgKey, PoolKey memory wifKey) = a.pools();
        require(_sameKey(usdgKey, _usdgPool()) && _sameKey(wifKey, _wifPool()), "rake route A pools");
        require(_sameKey(routeB.pool(), _wifPool()), "rake route B pool");
    }

    function _sameKey(PoolKey memory a, PoolKey memory b) internal pure returns (bool) {
        return a.currency0 == b.currency0 && a.currency1 == b.currency1 && a.fee == b.fee
            && a.tickSpacing == b.tickSpacing && a.hooks == b.hooks;
    }

    function _expectedFair0() internal view returns (uint64, uint64, uint64, uint64, uint64) {
        // timeline A1 (30 Oct): Fair 2 Nov 00:00 -> 4 Nov 00:00, suggest 2 Nov 12:00, vote 3 Nov 12:00, end 4 Nov 12:00
        if (_mainnet()) return (1793577600, 1793750400, 1793620800, 1793707200, 1793793600);
        return (
            uint64(vm.envUint("FAIR_START")),
            uint64(vm.envUint("FAIR_END")),
            uint64(vm.envOr("ALMS_SUGGEST", uint256(0))),
            uint64(vm.envOr("ALMS_VOTE", uint256(0))),
            uint64(vm.envOr("ALMS_END", uint256(0)))
        );
    }

    /// Every owner action on the four contracts leaves one of these events. `resets` is how many anchor resets are
    /// expected in the window (1 = the deploy's seed). `offers` is how many `OwnershipTransferStarted` per contract
    /// (0 since A1-14: the deploy hands ownership straight to the Safe; an offer now means an unplanned transfer).
    function _scan(D memory d, uint256 from, uint256 to, uint256 resets, uint256 offers) internal view {
        _expectAll(_scanWants(d, resets, offers), from, to);
    }

    /// One expected event count: `want` logs with topic0 = keccak(sig) emitted by `target`.
    struct Want {
        address target;
        string sig;
        uint256 want;
    }

    /// Appends to a list built with spare capacity (`_wants`); the length word is the fill count.
    function _w(Want[] memory w, address target, string memory sig, uint256 want) internal pure {
        uint256 n = w.length;
        require(n < WANTS_CAP, "scan table full: raise WANTS_CAP");
        assembly ("memory-safe") {
            mstore(w, add(n, 1))
        }
        w[n] = Want(target, sig, want);
    }

    uint256 internal constant WANTS_CAP = 128;

    function _wants(uint256 cap) internal pure returns (Want[] memory w) {
        require(cap == WANTS_CAP, "use WANTS_CAP");
        w = new Want[](cap);
        assembly ("memory-safe") {
            mstore(w, 0)
        }
    }

    /// The scan's table. `_scan` counts it with eth_getLogs; `_expectAllLogs` counts it over logs recorded in-process (tests).
    function _scanWants(D memory d, uint256 resets, uint256 offers) internal view returns (Want[] memory w) {
        w = _wants(WANTS_CAP); // room for every line below (about 70) plus the Verify extras
        // GameConfig
        _w(w, address(d.config), "CoreBound(address)", 1);
        _w(w, address(d.config), "TokensQueued(uint64,address,uint256,address,uint256)", 0);
        _w(w, address(d.config), "TokensCancelled()", 0);
        _w(w, address(d.config), "TokensExecuted(uint64,address,uint256,address)", 0);
        _w(w, address(d.config), "SplitQueued((uint16,uint16,uint16,uint16,uint16,uint16,uint16),uint256)", 0);
        _w(w, address(d.config), "SplitCancelled()", 0);
        _w(w, address(d.config), "SplitExecuted((uint16,uint16,uint16,uint16,uint16,uint16,uint16))", 0);
        _w(w, address(d.config), "OwnershipTransferStarted(address,address)", offers);
        // FairCore
        _w(w, address(d.core), "OpQueued(bytes32,uint8,uint256,address,uint256)", 0);
        _w(w, address(d.core), "OpExecuted(bytes32,uint8,uint256,address)", 0);
        _w(w, address(d.core), "OpCancelled(bytes32)", 0);
        _w(w, address(d.core), "BoothRemoved(address)", 0);
        _w(w, address(d.core), "SalesPaused(bool)", 0);
        _w(w, address(d.core), "RatchetReset(uint256,uint64)", resets);
        _w(w, address(d.core), "KeeperSet(address)", 1); // the setup wiring; a revoke would add one
        _w(w, address(d.core), "FairSet(uint256,uint64,uint64)", 1);
        _w(w, address(d.core), "TollWithdrawn(address,uint256)", 0);
        _w(w, address(d.core), "ExcessSwept(address,address,uint256)", 0);
        // Booths and routes are non-enumerable mappings: count every write, so a planted extra one fails the scan.
        {
            (string[] memory fs, uint256[] memory fw) = _fairCoreSetupWants(d.routeB);
            for (uint256 i; i < fs.length; ++i) {
                _w(w, address(d.core), fs[i], fw[i]);
            }
        }
        _w(w, address(d.core), "OwnershipTransferStarted(address,address)", offers);
        // FairPass
        _w(w, address(d.pass), "ExcessSwept(address,address,uint256)", 0);
        _w(w, address(d.pass), "OwnershipTransferStarted(address,address)", offers);
        // AlmsVote
        (,, uint64 ws,,) = _expectedFair0();
        _w(w, address(d.alms), "WindowsSet(uint256,uint64,uint64,uint64)", ws == 0 ? 0 : 1);
        _w(w, address(d.alms), "WindowsCleared(uint256)", 0);
        _w(w, address(d.alms), "EligibleSet(bytes32,uint64)", _eligibleCount()); // L-7
        _w(w, address(d.alms), "ReceiptPosted(uint256,uint32,bytes32,string)", 0);
        _w(w, address(d.alms), "OwnershipTransferStarted(address,address)", offers);
        // LocksleyVault
        _w(w, address(d.vault), "LauncherQueued(address,uint256)", 0);
        _w(w, address(d.vault), "LauncherCancelled(address)", 0);
        _w(w, address(d.vault), "LauncherAttached(address)", 0);
        _w(w, address(d.vault), "OwnershipTransferStarted(address,address)", offers);
        // Robin Among Thieves
        _w(w, address(d.rat), "OpQueued(bytes32,uint8,uint256,address,uint256)", 0);
        _w(w, address(d.rat), "OpExecuted(bytes32,uint8,uint256,address)", 0);
        _w(w, address(d.rat), "OpCancelled(bytes32)", 0);
        _w(w, address(d.rat), "KeeperSet(address)", 1); // the constructor; a revoke would add one
        _w(w, address(d.rat), "EntriesPaused(bool)", 1); // K-B05: the deploy's own pauseEntries(true)
        _w(w, address(d.rat), "HouseSet(uint256,bool)", 0);
        _w(w, address(d.rat), "HouseRequested(uint256)", 0);
        _w(w, address(d.rat), "BondsQueued(bool,uint128,uint256)", 0);
        _w(w, address(d.rat), "BondsExecuted(bool,uint128)", 0);
        _w(w, address(d.rat), "BondsCancelled()", 0);
        _w(w, address(d.rat), "ExcessSwept(address,address,uint256)", 0);
        _w(w, address(d.rat), "OwnershipTransferStarted(address,address)", offers);
        // RakeBuyer
        _w(w, address(d.rakeBuyer), "OpQueued(bytes32,uint8,uint256,address,uint256)", 0);
        _w(w, address(d.rakeBuyer), "OpExecuted(bytes32,uint8,uint256,address)", 0);
        _w(w, address(d.rakeBuyer), "OpCancelled(bytes32)", 0);
        _w(w, address(d.rakeBuyer), "KeeperSet(address)", 1);
        _w(w, address(d.rakeBuyer), "RouteSet(uint256,address)", d.rakeRouteB == address(0) ? 1 : 2);
        _w(w, address(d.rakeBuyer), "SetupDone()", 1);
        _w(w, address(d.rakeBuyer), "RatchetReset(uint256,uint64)", resets);
        _w(w, address(d.rakeBuyer), "ExcessSwept(address,address,uint256)", 0);
        _w(w, address(d.rakeBuyer), "Reconciled(uint256,uint256,uint256)", 0);
        // M-3: setupSet(SetForwardTo) before finishSetup would redirect every forward; the deploy never sets it
        _w(w, address(d.rakeBuyer), "ForwardToSet(address)", 0);
        _w(w, address(d.rakeBuyer), "OwnershipTransferStarted(address,address)", offers);
    }

    function _topics(bytes32 sig) internal pure returns (bytes32[] memory t) {
        t = new bytes32[](1);
        t[0] = sig;
    }

    /// Number of matching logs in [f, t]. Reads only the array length from the raw return data: decoding the full
    /// log structs runs the compiler out of stack, and the scan only needs counts.
    function _chunkCount(address target, bytes32 sig, uint256 f, uint256 t) internal view returns (uint256 n) {
        (bool ok, bytes memory ret) =
            address(vm).staticcall(abi.encodeWithSelector(VmSafe.eth_getLogs.selector, f, t, target, _topics(sig)));
        require(ok && ret.length >= 64, "eth_getLogs failed");
        assembly ("memory-safe") {
            n := mload(add(ret, 64)) // [offset][length]...
        }
    }

    function _count(address target, bytes32 sig, uint256 from, uint256 to) internal view returns (uint256 n) {
        for (uint256 f = from; f <= to; f += LOG_CHUNK) {
            n += _chunkCount(target, sig, f, f + LOG_CHUNK - 1 > to ? to : f + LOG_CHUNK - 1);
        }
    }

    function _expectN(address target, string memory sig, uint256 want, uint256 from, uint256 to) internal view {
        _expect(target, sig, want, from, to);
    }

    function _expect(address target, string memory sig, uint256 want, uint256 from, uint256 to) internal view {
        _rejectWrongCount(sig, _count(target, keccak256(bytes(sig)), from, to), want);
    }

    function _expectAll(Want[] memory w, uint256 from, uint256 to) internal view {
        for (uint256 i; i < w.length; ++i) {
            _expect(w[i].target, w[i].sig, w[i].want, from, to);
        }
    }

    /// Same table, counted over logs captured in-process with `vm.recordLogs` (a Foundry test has no RPC log index).
    function _expectAllLogs(Want[] memory w, VmSafe.Log[] memory logs) internal pure {
        for (uint256 i; i < w.length; ++i) {
            _rejectWrongCount(w[i].sig, _countTopic(logs, w[i].target, keccak256(bytes(w[i].sig))), w[i].want);
        }
    }

    /// Everything Verify checks on live state (the event scan is separate: `_verifyWants`).
    /// L-7: the charity ids the deploy set. No zero or duplicate ids, so one EligibleSet per id is exact.
    function _eligibleIds() internal view returns (bytes32[] memory ids) {
        ids = vm.envOr("ELIGIBLE_IDS", ",", new bytes32[](0));
        for (uint256 i; i < ids.length; ++i) {
            require(ids[i] != bytes32(0), "ELIGIBLE_IDS has a zero id");
            for (uint256 j; j < i; ++j) {
                require(ids[i] != ids[j], "ELIGIBLE_IDS has a duplicate id");
            }
        }
    }

    /// L-7: with ELIGIBLE_IDS set, the expected EligibleSet count is its length (ELIGIBLE_COUNT, if also set, must agree).
    function _eligibleCount() internal view returns (uint256 n) {
        n = _eligibleIds().length;
        uint256 legacy = vm.envOr("ELIGIBLE_COUNT", n);
        require(legacy == n || n == 0, "ELIGIBLE_COUNT does not match ELIGIBLE_IDS");
        if (n == 0) n = legacy;
    }

    function _requireEligible(AlmsVote alms, bytes32[] memory ids) internal view {
        for (uint256 i; i < ids.length; ++i) {
            require(alms.eligibleAt(ids[i]) != 0, "a charity id from ELIGIBLE_IDS is not eligible on chain");
        }
    }

    function _verifyState(D memory d, address safe, uint256 seed, address[] memory safeOwners) internal {
        require(d.core.owner() == safe && d.pass.owner() == safe, "Safe doesn't own everything");
        require(d.alms.owner() == safe && d.vault.owner() == safe, "Safe doesn't own everything");
        require(
            d.core.pendingOwner() == address(0) && d.pass.pendingOwner() == address(0), "an ownership offer is open"
        );
        require(
            d.alms.pendingOwner() == address(0) && d.vault.pendingOwner() == address(0), "an ownership offer is open"
        );
        require(d.config.owner() == safe && d.config.pendingOwner() == address(0), "Safe doesn't own GameConfig");
        require(d.rat.owner() == safe && d.rat.pendingOwner() == address(0), "Safe doesn't own Robin Among Thieves");
        require(d.rakeBuyer.owner() == safe && d.rakeBuyer.pendingOwner() == address(0), "Safe doesn't own RakeBuyer");
        require(d.rakeBuyer.anchorRate() == seed && d.rakeBuyer.anchorEpoch() == d.config.epoch(), "RakeBuyer anchor");
        _requireEligible(d.alms, _eligibleIds()); // L-7
        require(d.core.anchorRate() == seed && d.core.ratchetFloorRate() != 0, "anchor isn't the deploy's seed");
        require(d.core.anchorEpoch() == d.config.epoch(), "anchor epoch");
        // M-2: the high-water mark starts at the seed and only rises on a buy
        require(d.core.anchorBase() >= seed && d.rakeBuyer.anchorBase() >= seed, "anchor high-water below the seed");
        _assertBytecode(d);
        _checkWiring(d);
        _assertDeployerHasNoPower(d, vm.envAddress("DEPLOYER"), safe, safeOwners);
    }

    /// SafeAcceptVerify's full table: the scan (one seed per anchor, no offers) plus two OwnershipTransferred on each
    /// contract that has an owner-set constructor (to the deployer, then to the Safe).
    function _verifyWants(D memory d) internal view returns (Want[] memory w) {
        w = _scanWants(d, 1, 0);
        _w(w, address(d.core), "OwnershipTransferred(address,address)", 2);
        _w(w, address(d.config), "OwnershipTransferred(address,address)", 2);
        _w(w, address(d.rat), "OwnershipTransferred(address,address)", 2);
        _w(w, address(d.rakeBuyer), "OwnershipTransferred(address,address)", 2);
    }

    /// FairCore setup writes the scan must see. `indexed` is not part of the signature. `routeB == address(0)` expects
    /// one `RouteSet` (route 0 only); any other routeB expects two. A further `RouteSet`, including index >= 2, or a
    /// third `BoothAdded`, fails the count.
    function _fairCoreSetupWants(address routeB) internal pure returns (string[] memory sigs, uint256[] memory wants) {
        sigs = new string[](7);
        wants = new uint256[](7);
        sigs[0] = "BoothAdded(address)";
        wants[0] = 2; // LastArrow, SheriffsSeat
        sigs[1] = "RouteSet(uint256,address)";
        wants[1] = routeB == address(0) ? 1 : 2;
        sigs[2] = "SetupDone()";
        wants[2] = 1;
        sigs[3] = "TollRecipientSet(address)";
        wants[3] = 1;
        sigs[4] = "AlmsSafeSet(address)";
        wants[4] = 1;
        sigs[5] = "AlmsVoteSet(address)";
        wants[5] = 1;
        sigs[6] = "VaultSet(address)";
        wants[6] = 1;
    }

    function _expectFairCoreSetup(address core, address routeB, uint256 from, uint256 to) internal view {
        (string[] memory sigs, uint256[] memory wants) = _fairCoreSetupWants(routeB);
        uint256 n = sigs.length;
        for (uint256 i; i < n; ++i) {
            _expect(core, sigs[i], wants[i], from, to);
        }
    }

    /// Same expected counts as the on-chain scan, over logs captured in-process. Tests record the deploy with
    /// `vm.recordLogs` and feed that array here; the script itself counts via `eth_getLogs` in `_expect`.
    function _requireFairCoreSetupLogs(VmSafe.Log[] memory logs, address core, address routeB) internal pure {
        (string[] memory sigs, uint256[] memory wants) = _fairCoreSetupWants(routeB);
        uint256 n = sigs.length;
        for (uint256 i; i < n; ++i) {
            _rejectWrongCount(sigs[i], _countTopic(logs, core, keccak256(bytes(sigs[i]))), wants[i]);
        }
    }

    function _countTopic(VmSafe.Log[] memory logs, address emitter, bytes32 topic0) internal pure returns (uint256 n) {
        uint256 len = logs.length;
        for (uint256 i; i < len; ++i) {
            VmSafe.Log memory log = logs[i];
            if (log.emitter == emitter && log.topics.length != 0 && log.topics[0] == topic0) ++n;
        }
    }

    function _rejectWrongCount(string memory sig, uint256 found, uint256 want) internal pure {
        if (found != want) {
            console2.log("UNEXPECTED EVENT COUNT:", sig);
            console2.log("  expected", want, "found", found);
            revert("an owner action happened that nobody planned: investigate before going on");
        }
    }

    /// Runtime code of every contract in the deployment file must equal a reference deploy built here. Constructor
    /// arguments come from the live contract's getters, so immutables (core, day0, pool-derived token, test-route
    /// rate, and so on) match. A rogue listed as Last Arrow, Sheriff's Seat, a route, or any other name fails even
    /// when the BoothAdded / RouteSet counts match. Event counts do not see bytecode.
    function _assertBytecode(D memory d) internal {
        _assertConfigCode(d);
        _assertPassCode(d);
        _assertCoreCode(d);
        _assertArrowCode(d);
        _assertSeatCode(d);
        _assertAlmsCode(d);
        _assertVaultCode(d);
        _assertLensCode(d);
        _assertRobinCode(d);
        _assertRakeCode(d);
        _assertRoutes(d);
        if (block.chainid == 46630) {
            _assertTestToken(d.usdg, "usdg");
            _assertTestToken(d.wif, "wif");
            if (d.tokenB != address(0)) _assertTestToken(d.tokenB, "tokenB");
        }
    }

    function _bad(string memory name) internal pure returns (string memory) {
        return string.concat(name, ": bytecode mismatch");
    }

    /// `address.codehash` is EXTCODEHASH. The reference is a same-compiler deploy, so equal hashes mean equal runtime
    /// bytecode, immutables included.
    function _match(address live, address built, string memory name) internal view {
        bytes32 got;
        bytes32 want = built.codehash;
        assembly ("memory-safe") {
            got := extcodehash(live)
        }
        require(live.code.length != 0 && built.code.length != 0 && got == want && got != bytes32(0), _bad(name));
    }

    function _addr(address c, bytes4 sel, string memory name) internal view returns (address a) {
        (bool ok, bytes memory ret) = c.staticcall(abi.encodeWithSelector(sel));
        require(ok && ret.length >= 32, _bad(name));
        a = abi.decode(ret, (address));
    }

    function _uint(address c, bytes4 sel, string memory name) internal view returns (uint256 n) {
        (bool ok, bytes memory ret) = c.staticcall(abi.encodeWithSelector(sel));
        require(ok && ret.length >= 32, _bad(name));
        n = abi.decode(ret, (uint256));
    }

    function _str(address c, string memory sig, string memory name) internal view returns (string memory s) {
        (bool ok, bytes memory ret) = c.staticcall(abi.encodeWithSignature(sig));
        require(ok && ret.length >= 64, _bad(name));
        s = abi.decode(ret, (string));
    }

    function _tokensOf(address c, string memory name)
        internal
        view
        returns (address play, uint256 lockAmt, address buy)
    {
        try IDeployed(c).tokens() returns (address p, uint256 a, address b) {
            return (p, a, b);
        } catch {
            revert(_bad(name));
        }
    }

    function _splitOf(address c, string memory name) internal view returns (Split memory s) {
        try IDeployed(c).split() returns (Split memory got) {
            return got;
        } catch {
            revert(_bad(name));
        }
    }

    function _poolsOf(address c, string memory name) internal view returns (PoolKey memory a, PoolKey memory b) {
        try IDeployed(c).pools() returns (PoolKey memory x, PoolKey memory y) {
            return (x, y);
        } catch {
            revert(_bad(name));
        }
    }

    function _poolOf(address c, string memory name) internal view returns (PoolKey memory k) {
        try IDeployed(c).pool() returns (PoolKey memory got) {
            return got;
        } catch {
            revert(_bad(name));
        }
    }

    function _assertConfigCode(D memory d) internal {
        string memory n = "gameConfig";
        address usdg_ = _addr(address(d.config), IDeployed.usdg.selector, n);
        uint256 delay_ = _uint(address(d.config), IDeployed.delay.selector, n);
        (address play, uint256 lockAmt, address buy) = _tokensOf(address(d.config), n);
        Split memory s = _splitOf(address(d.config), n);
        address owner_ = _addr(address(d.config), IDeployed.owner.selector, n);
        require(usdg_ == d.usdg, "gameConfig: usdg");
        try new GameConfig(owner_, usdg_, delay_, Tokens(play, lockAmt, buy), s) returns (GameConfig ref) {
            _match(address(d.config), address(ref), n);
        } catch {
            revert(_bad(n));
        }
    }

    function _assertPassCode(D memory d) internal {
        string memory n = "fairPass";
        address cfg = _addr(address(d.pass), IDeployed.config.selector, n);
        address owner_ = _addr(address(d.pass), IDeployed.owner.selector, n);
        require(cfg == address(d.config), "fairPass: config");
        try new FairPass(IGameConfig(cfg), owner_) returns (FairPass ref) {
            _match(address(d.pass), address(ref), n);
        } catch {
            revert(_bad(n));
        }
    }

    function _assertCoreCode(D memory d) internal {
        string memory n = "fairCore";
        address usdg_ = _addr(address(d.core), IDeployed.usdg.selector, n);
        address cfg = _addr(address(d.core), IDeployed.config.selector, n);
        address pass_ = _addr(address(d.core), IDeployed.fairPass.selector, n);
        uint256 tl = _uint(address(d.core), IDeployed.timelockDelay.selector, n);
        address owner_ = _addr(address(d.core), IDeployed.owner.selector, n);
        require(usdg_ == d.usdg && cfg == address(d.config) && pass_ == address(d.pass), "fairCore: wiring");
        try new FairCore(IERC20(usdg_), IGameConfig(cfg), FairPass(pass_), owner_, tl) returns (FairCore ref) {
            _match(address(d.core), address(ref), n);
        } catch {
            revert(_bad(n));
        }
    }

    function _assertArrowCode(D memory d) internal {
        string memory n = "lastArrow";
        require(_addr(d.arrow, IDeployed.core.selector, n) == address(d.core), "lastArrow: core");
        require(_addr(d.arrow, IDeployed.fairPass.selector, n) == address(d.pass), "lastArrow: pass");
        try new LastArrow(IFairCore(address(d.core))) returns (LastArrow ref) {
            _match(d.arrow, address(ref), n);
        } catch {
            revert(_bad(n));
        }
    }

    function _assertSeatCode(D memory d) internal {
        string memory n = "sheriffsSeat";
        require(_addr(d.seat, IDeployed.core.selector, n) == address(d.core), "sheriffsSeat: core");
        require(_addr(d.seat, IDeployed.fairPass.selector, n) == address(d.pass), "sheriffsSeat: pass");
        uint256 day0 = _uint(d.seat, IDeployed.day0.selector, n);
        uint256 dayLen = _uint(d.seat, IDeployed.dayLength.selector, n);
        try new SheriffsSeat(IFairCore(address(d.core)), day0, dayLen) returns (SheriffsSeat ref) {
            _match(d.seat, address(ref), n);
        } catch {
            revert(_bad(n));
        }
    }

    function _assertAlmsCode(D memory d) internal {
        string memory n = "almsVote";
        address core_ = _addr(address(d.alms), IDeployed.core.selector, n);
        address owner_ = _addr(address(d.alms), IDeployed.owner.selector, n);
        require(core_ == address(d.core), "almsVote: core");
        require(_addr(address(d.alms), IDeployed.fairPass.selector, n) == address(d.pass), "almsVote: pass");
        uint256 notice = _uint(address(d.alms), IDeployed.MIN_NOTICE.selector, n);
        uint256 window = _uint(address(d.alms), IDeployed.MIN_WINDOW.selector, n);
        if (_mainnet()) {
            require(notice == 24 hours && window == 24 hours, "almsVote: mainnet minimums must be 24h");
        } else {
            require(
                notice == vm.envOr("ALMS_MIN_NOTICE", uint256(24 hours))
                    && window == vm.envOr("ALMS_MIN_WINDOW", uint256(24 hours)),
                "almsVote: minimums differ from ALMS_MIN_NOTICE/ALMS_MIN_WINDOW"
            );
        }
        require(notice <= type(uint64).max && window <= type(uint64).max, _bad(n));
        try new AlmsVote(IFairCore(core_), owner_, uint64(notice), uint64(window)) returns (AlmsVote ref) {
            _match(address(d.alms), address(ref), n);
        } catch {
            revert(_bad(n));
        }
    }

    function _assertVaultCode(D memory d) internal {
        string memory n = "locksleyVault";
        address core_ = _addr(address(d.vault), IDeployed.core.selector, n);
        address owner_ = _addr(address(d.vault), IDeployed.owner.selector, n);
        require(core_ == address(d.core), "locksleyVault: core");
        try new LocksleyVault(ICoreVaultUsdg(core_), owner_) returns (LocksleyVault ref) {
            _match(address(d.vault), address(ref), n);
        } catch {
            revert(_bad(n));
        }
    }

    function _assertLensCode(D memory d) internal {
        string memory n = "fairLens";
        address core_ = _addr(address(d.lens), IDeployed.core.selector, n);
        address arrow_ = _addr(address(d.lens), IDeployed.arrow.selector, n);
        address seat_ = _addr(address(d.lens), IDeployed.seat.selector, n);
        address vault_ = _addr(address(d.lens), IDeployed.vault.selector, n);
        require(core_ == address(d.core) && arrow_ == d.arrow && seat_ == d.seat && vault_ == address(d.vault), "fairLens: wiring");
        require(_addr(address(d.lens), IDeployed.pass.selector, n) == address(d.pass), "fairLens: pass");
        require(_addr(address(d.lens), IDeployed.config.selector, n) == address(d.config), "fairLens: config");
        try new FairLens(FairCore(core_), LastArrow(arrow_), SheriffsSeat(seat_), IVaultView(vault_)) returns (FairLens ref)
        {
            _match(address(d.lens), address(ref), n);
        } catch {
            revert(_bad(n));
        }
    }

    function _robinParams(D memory d) internal view returns (RobinAmongThieves.Params memory p) {
        string memory n = "robinAmongThieves";
        RobinAmongThieves r = d.rat;
        p.usdg = IERC20(_addr(address(r), IDeployed.usdg.selector, n));
        p.config = IGameConfig(_addr(address(r), IDeployed.config.selector, n));
        p.core = IFairCore(address(d.core));
        p.identity = IIdentityRegistry(_addr(address(r), IDeployed.identity.selector, n));
        p.reputation = IReputationRegistry(_addr(address(r), IDeployed.reputation.selector, n));
        p.owner = _addr(address(r), IDeployed.owner.selector, n);
        p.timelockDelay = _uint(address(r), IDeployed.timelockDelay.selector, n);
        p.bondDelay = _uint(address(r), IDeployed.bondDelay.selector, n);
        p.genesis = _uint(address(r), IDeployed.genesis.selector, n);
        p.keeper = _addr(address(r), IDeployed.keeper.selector, n);
        p.rakeSink = _addr(address(r), IDeployed.rakeSink.selector, n);
        p.houseSink = _addr(address(r), IDeployed.houseSink.selector, n);
        require(address(p.usdg) == d.usdg && address(p.config) == address(d.config), "robinAmongThieves: wiring");
        require(_addr(address(r), IDeployed.fairPass.selector, n) == address(d.pass), "robinAmongThieves: pass");
        require(p.rakeSink == address(d.rakeBuyer) && p.houseSink == address(d.vault), "robinAmongThieves: sinks");
    }

    function _assertRobinCode(D memory d) internal {
        RobinAmongThieves.Params memory p = _robinParams(d);
        try new RobinAmongThieves(p) returns (RobinAmongThieves ref) {
            _match(address(d.rat), address(ref), "robinAmongThieves");
        } catch {
            revert(_bad("robinAmongThieves"));
        }
    }

    function _assertRakeCode(D memory d) internal {
        string memory n = "rakeBuyer";
        RakeBuyer b = d.rakeBuyer;
        address usdg_ = _addr(address(b), IDeployed.usdg.selector, n);
        address cfg = _addr(address(b), IDeployed.config.selector, n);
        address vault_ = _addr(address(b), IDeployed.vault.selector, n);
        uint256 tl = _uint(address(b), IDeployed.timelockDelay.selector, n);
        address owner_ = _addr(address(b), IDeployed.owner.selector, n);
        require(usdg_ == d.usdg && cfg == address(d.config) && vault_ == address(d.vault), "rakeBuyer: wiring");
        try new RakeBuyer(IERC20(usdg_), IGameConfig(cfg), vault_, owner_, tl) returns (RakeBuyer ref) {
            _match(address(b), address(ref), n);
        } catch {
            revert(_bad(n));
        }
    }

    /// Route A is BuyRouteV4 on mainnet and a TestRoute off mainnet. Route B is BuyRouteV3V4 on mainnet. Testnet
    /// reuses those TestRoutes for RakeBuyer (`extraCaller`). Each route's `core()` is the contract that calls it,
    /// and mainnet pool keys are the configured USDG and $wif pools.
    function _assertRoutes(D memory d) internal {
        _assertOneRoute(d.routeA, address(d.core), d.wif, true, "routeA");
        if (d.routeB != address(0)) {
            address tokenB = _mainnet() ? d.wif : d.tokenB;
            require(tokenB != address(0), "routeB: token");
            _assertOneRoute(d.routeB, address(d.core), tokenB, false, "routeB");
        }
        if (_mainnet()) {
            _assertOneRoute(d.rakeRouteA, address(d.rakeBuyer), d.wif, true, "rakeRouteA");
            if (d.rakeRouteB != address(0)) {
                _assertOneRoute(d.rakeRouteB, address(d.rakeBuyer), d.wif, false, "rakeRouteB");
            }
        } else {
            require(d.rakeRouteA == d.routeA, "rakeRouteA: testnet reuses route A");
            require(d.rakeRouteB == d.routeB, "rakeRouteB: testnet reuses route B");
            require(_addr(d.routeA, IDeployed.extraCaller.selector, "rakeRouteA") == address(d.rakeBuyer), "rakeRouteA: caller");
            if (d.routeB != address(0)) {
                require(
                    _addr(d.routeB, IDeployed.extraCaller.selector, "rakeRouteB") == address(d.rakeBuyer),
                    "rakeRouteB: caller"
                );
            }
        }
    }

    function _assertOneRoute(address route, address expectedCore, address expectedToken, bool isV4, string memory name)
        internal
    {
        require(_addr(route, IDeployed.core.selector, name) == expectedCore, string.concat(name, ": core"));
        require(_addr(route, IDeployed.tokenOut.selector, name) == expectedToken, string.concat(name, ": token"));
        if (_mainnet()) {
            if (isV4) _assertV4Code(route, expectedCore, name);
            else _assertV3V4Code(route, expectedCore, expectedToken, name);
        } else {
            _assertTestRouteCode(route, name);
        }
    }

    function _assertV4Code(address route, address expectedCore, string memory name) internal {
        require(_addr(route, IDeployed.pm.selector, name) == PM, string.concat(name, ": pool manager"));
        (PoolKey memory usdgKey, PoolKey memory outKey) = _poolsOf(route, name);
        require(_sameKey(usdgKey, _usdgPool()) && _sameKey(outKey, _wifPool()), string.concat(name, ": pools"));
        try new BuyRouteV4(PM, expectedCore, usdgKey, outKey) returns (BuyRouteV4 ref) {
            _match(route, address(ref), name);
        } catch {
            revert(_bad(name));
        }
    }

    function _assertV3V4Code(address route, address expectedCore, address expectedToken, string memory name) internal {
        require(_addr(route, IDeployed.pm.selector, name) == PM, string.concat(name, ": pool manager"));
        address v3 = _addr(route, IDeployed.v3Pool.selector, name);
        address usdg_ = _addr(route, IDeployed.usdg.selector, name);
        address weth_ = _addr(route, IDeployed.weth.selector, name);
        require(v3 == V3_POOL && usdg_ == USDG && weth_ == WETH, string.concat(name, ": v3"));
        PoolKey memory outKey = _poolOf(route, name);
        require(_sameKey(outKey, _wifPool()) && outKey.currency1 == expectedToken, string.concat(name, ": pools"));
        try new BuyRouteV3V4(PM, expectedCore, IUniswapV3Pool(v3), usdg_, weth_, outKey) returns (BuyRouteV3V4 ref) {
            _match(route, address(ref), name);
        } catch {
            revert(_bad(name));
        }
    }

    /// TestRoute bakes `msg.sender` in as `deployer` and the rate as an immutable. Rebuild with that same sender.
    function _assertTestRouteCode(address route, string memory name) internal {
        uint256 rate = _uint(route, IDeployed.RATE.selector, name);
        address dep = _addr(route, IDeployed.deployer.selector, name);
        vm.prank(dep);
        try new TestRoute(rate) returns (TestRoute ref) {
            _match(route, address(ref), name);
        } catch {
            revert(_bad(name));
        }
    }

    /// Testnet USDG / $wif / token B. Name and symbol are storage; decimals, faucet amount and minter are immutables.
    function _assertTestToken(address token, string memory name) internal {
        string memory n = _str(token, "name()", name);
        string memory s = _str(token, "symbol()", name);
        uint8 dec = uint8(_uint(token, IDeployed.decimals.selector, name));
        uint256 faucet = _uint(token, IDeployed.faucetAmount.selector, name);
        address minter_ = _addr(token, IDeployed.minter.selector, name);
        try new TestToken(n, s, dec, faucet, minter_) returns (TestToken ref) {
            _match(token, address(ref), name);
        } catch {
            revert(_bad(name));
        }
    }
}

/// OBSOLETE since A1-14/A1-15. The deploy now hands ownership of all seven contracts straight to the Safe in the same
/// broadcast, and seeds both anchors before `finishSetup`, so there is nothing for the Safe to accept or re-seed (and a
/// post-setup `resetRatchet` reverts: re-seeds are a queued, bounded Op.ResetRatchet). Kept so an old runbook step fails
/// loudly instead of writing a batch that would revert. Run SafeAcceptVerify instead.
contract SafeAcceptBatch is AcceptBase {
    function run() external pure {
        revert("SafeAcceptBatch is obsolete: the deploy hands ownership to the Safe (A1-14). Run SafeAcceptVerify.");
    }
}

/// READ-ONLY. Run right after the deploy, before the Safe does anything else. Confirms `GOS_SAFE` (or its alias
/// `OWNER_SAFE`) is the Safe pinned in script/Deploy.s.sol (mainnet refuses while that pin is zero), the Safe owns all
/// seven contracts with nothing pending, the anchor is the deploy's seed, the wiring is unchanged, the deployer EOA
/// (`DEPLOYER`, matching the deployment file) has no owner, pending owner or other role left (USDG or $wif dust on it
/// only prints a WARNING, L-5), and that no owner action happened besides the deploy (scanned from the deploy to the
/// current head). The scan counts FairCore's booths and routes, which are non-enumerable mappings: exactly two
/// `BoothAdded` (Last Arrow and Sheriff's Seat), `RouteSet` once per deployed route, one `SetupDone`, and one each of
/// `TollRecipientSet`, `AlmsSafeSet`, `AlmsVoteSet` and `VaultSet`. An extra booth or a route at index 2 or higher
/// fails it. Every contract in the deployment file (FairCore, FairPass, GameConfig, Last Arrow, Sheriff's Seat,
/// AlmsVote, LocksleyVault, FairLens, Robin Among Thieves, RakeBuyer, each route, and on testnet the test tokens) must
/// have the runtime codehash of a reference deploy built in this script from that contract's own constructor arguments.
/// A rogue listed under one of those names fails here even when the event counts match. Each route's `core()` must be
/// the contract that calls it, and on mainnet its pool keys must be the configured $wif/USDG pools. No key: this script
/// does not broadcast.
///   forge script script/SafeAccept.s.sol:SafeAcceptVerify --rpc-url robinhood          (or robinhood_testnet)
contract SafeAcceptVerify is AcceptBase {
    function run() external {
        address safe = _safeFromEnv();
        _requirePinnedOwner(safe);
        D memory d = _load();
        _verifyState(d, safe, vm.envUint("ANCHOR_SEED"), ISafeOwners(safe).getOwners());
        uint256 head = _head(d);

        // Run this right after the deploy, before the Safe does anything else: the scan runs to the current head and
        // expects exactly the deploy's actions (one seed per anchor, no ownership offer). Any other owner action fails.
        _expectAll(_verifyWants(d), d.startBlock, head);
        console2.log(
            "verified: Safe owns all seven, deployer has no power, anchor = Safe seed, no unplanned owner action up to block",
            head
        );
    }
}
