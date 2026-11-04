// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IFairCore, IGameConfig, Tokens, Split} from "../../src/interfaces/IFair.sol";
import {PoolKey} from "../../src/interfaces/IV4Minimal.sol";
import {IIdentityRegistry, IReputationRegistry} from "../../src/interfaces/I8004.sol";
import {GameConfig} from "../../src/GameConfig.sol";
import {FairPass} from "../../src/FairPass.sol";
import {FairCore} from "../../src/FairCore.sol";
import {LastArrow} from "../../src/LastArrow.sol";
import {SheriffsSeat} from "../../src/SheriffsSeat.sol";
import {AlmsVote} from "../../src/AlmsVote.sol";
import {LocksleyVault, ICoreVaultUsdg} from "../../src/LocksleyVault.sol";
import {RobinAmongThieves} from "../../src/RobinAmongThieves.sol";
import {RakeBuyer} from "../../src/RakeBuyer.sol";
import {MockToken} from "../mocks/Mocks.sol";
import {AcceptBase} from "../../script/SafeAccept.s.sol";
import {DeployerPowerHarness} from "./DeployerPowerless.t.sol";

/// A booth contract the deployer controls. Not the deployer address, so `isBooth(deployer)` is false and the
/// post-accept role check does not see it. FairCore.collect trusts whatever booth it was given as the payer.
contract RogueBooth {
    address public immutable boss;

    constructor(FairCore, address b) {
        boss = b;
    }
}

/// Exposes Verify's pin check, the on-chain FairCore setup scan, and the same counts over recorded logs.
contract VerifyHarness is AcceptBase {
    function requirePinnedOwner(address safe) external view {
        _requirePinnedOwner(safe);
    }

    function pins() external pure returns (address mainnet, address testnet) {
        return (PINNED_MAINNET_SAFE, PINNED_TESTNET_SAFE);
    }

    /// Verify's FairCore setup counts. The script reads `eth_getLogs`; a Foundry test has no RPC log index, so the
    /// deploy is captured with `vm.recordLogs` and checked with the same wants and the same rejection `_scan` uses.
    /// The chunked `eth_getLogs` path itself is `script/e2e/anvil_hidden_booth.sh`.
    function verifyFairCoreSetup(address core, address routeB) external view {
        _requireFairCoreSetupLogs(vm.getRecordedLogs(), core, routeB);
    }

    function assertBytecode(D memory d) external {
        _assertBytecode(d);
    }

    function assertV4Route(address route, address core_, address token, string calldata name) external {
        _assertOneRoute(route, core_, token, true, name);
    }

    function assertTestToken(address token, string calldata name) external {
        _assertTestToken(token, name);
    }

    function v4Pools() external pure returns (address pm_, PoolKey memory usdgKey, PoolKey memory wifKey) {
        return (PM, _usdgPool(), _wifPool());
    }
}

/// H-01: a booth or route planted with setupSet before finishSetup used to pass Verify, because `isBooth` and
/// `routes` are non-enumerable and the scan did not count FairCore's BoothAdded / RouteSet. The planted booth is a
/// contract, so the deployer-role check still passes; the event counts are what reject it.
contract HiddenBoothTest is Test {
    uint256 constant T0 = 1_800_000_000;
    bytes constant UNPLANNED = "an owner action happened that nobody planned: investigate before going on";

    DeployerPowerHarness internal power;
    VerifyHarness internal scanH;

    address internal deployer = makeAddr("deployer");
    address internal safe_ = makeAddr("safe");
    address internal keeper = makeAddr("keeper");
    address internal toll = makeAddr("toll");

    MockToken internal usdg;
    MockToken internal wif;
    GameConfig internal config;
    FairPass internal pass;
    FairCore internal core;
    AlmsVote internal alms;
    LocksleyVault internal vault;
    RobinAmongThieves internal rat;
    RakeBuyer internal rakeBuyer;
    address internal arrow;
    address internal seat;
    address internal routeA;
    address internal routeB;
    address internal rakeRouteA;
    address internal rogue;

    function setUp() public {
        power = new DeployerPowerHarness();
        scanH = new VerifyHarness();
        vm.allowCheatcodes(address(scanH));
        vm.warp(T0);
        vm.setEnv("FAIR_START", vm.toString(T0 + 1 hours));
        vm.setEnv("FAIR_END", vm.toString(T0 + 7 days));
    }

    function _owners() internal returns (address[] memory o) {
        o = new address[](3);
        o[0] = makeAddr("signer1");
        o[1] = makeAddr("signer2");
        o[2] = makeAddr("signer3");
    }

    function _split() internal pure returns (Split memory) {
        return Split({
            purseBps: 6000, almsBps: 2000, bonfireBps: 1750, tollBps: 1750, vBuyBps: 2500, vLiqBps: 2500, vBurnBps: 2500
        });
    }

    function _hand(Ownable2Step c) internal {
        vm.prank(deployer);
        c.transferOwnership(safe_);
        vm.prank(safe_);
        c.acceptOwnership();
    }

    /// Deploy wiring, then the Safe's accept and re-seed, so Verify's scan (resets = 2) is what a clean ownership transfer emits.
    /// `extraBooth` is one more AddBooth. `extraRoute` is a SetRoute at index 2. `withRouteB` is the second buy route.
    function _deployScenario(bool extraBooth, bool extraRoute, bool withRouteB) internal {
        usdg = new MockToken("Global Dollar", "USDG", 6);
        wif = new MockToken("World is Flat", "WIF", 18);
        config =
            new GameConfig(deployer, address(usdg), 7 days, Tokens(address(wif), 5_000e18, address(wif)), _split());
        pass = new FairPass(IGameConfig(address(config)), deployer);
        core = new FairCore(IERC20(address(usdg)), IGameConfig(address(config)), pass, deployer, 48 hours);
        vm.prank(deployer);
        config.bindCore(address(core));
        alms = new AlmsVote(IFairCore(address(core)), deployer, 24 hours, 24 hours);
        vault = new LocksleyVault(ICoreVaultUsdg(address(core)), deployer);
        rakeBuyer = new RakeBuyer(IERC20(address(usdg)), IGameConfig(address(config)), address(vault), deployer, 0, address(core));
        rat = new RobinAmongThieves(
            RobinAmongThieves.Params({
                usdg: IERC20(address(usdg)),
                config: IGameConfig(address(config)),
                core: IFairCore(address(core)),
                identity: IIdentityRegistry(makeAddr("id")),
                reputation: IReputationRegistry(makeAddr("rep")),
                owner: deployer,
                timelockDelay: 0,
                bondDelay: 0,
                genesis: T0,
                keeper: keeper,
                rakeSink: address(rakeBuyer),
                houseSink: address(vault)
            })
        );
        arrow = address(new LastArrow(IFairCore(address(core))));
        seat = address(new SheriffsSeat(IFairCore(address(core)), 1 days, 1 days));
        routeA = makeAddr("routeA");
        routeB = withRouteB ? makeAddr("routeB") : address(0);
        rakeRouteA = makeAddr("rakeRouteA");
        if (extraBooth) rogue = address(new RogueBooth(core, deployer));

        vm.startPrank(deployer);
        core.setupSet(FairCore.Op.SetKeeper, 0, keeper);
        core.setupSet(FairCore.Op.SetTollRecipient, 0, toll);
        core.setupSet(FairCore.Op.SetAlmsSafe, 0, safe_);
        core.setupSet(FairCore.Op.SetAlmsVote, 0, address(alms));
        core.setupSet(FairCore.Op.SetVault, 0, address(vault));
        core.setupSet(FairCore.Op.AddBooth, 0, arrow);
        core.setupSet(FairCore.Op.AddBooth, 0, seat);
        if (extraBooth) core.setupSet(FairCore.Op.AddBooth, 0, rogue);
        core.setupSet(FairCore.Op.SetRoute, 0, routeA);
        if (withRouteB) core.setupSet(FairCore.Op.SetRoute, 1, routeB);
        if (extraRoute) core.setupSet(FairCore.Op.SetRoute, 2, makeAddr("routeExtra"));
        core.resetRatchet(1e18);
        core.finishSetup();
        core.setFair(0, uint64(T0 + 1 hours), uint64(T0 + 7 days));
        rakeBuyer.setupSet(RakeBuyer.Op.SetKeeper, 0, keeper);
        rakeBuyer.setupSet(RakeBuyer.Op.SetRoute, 0, rakeRouteA);
        rakeBuyer.resetRatchet(1e18);
        rakeBuyer.finishSetup();
        vm.stopPrank();

        _hand(config);
        _hand(core);
        _hand(pass);
        _hand(alms);
        _hand(vault);
        _hand(rat);
        _hand(rakeBuyer);
        // A1-14: no Safe re-seed any more; the deploy's seed (before finishSetup) stands.
    }

    function _pack() internal view returns (AcceptBase.D memory d) {
        d.config = config;
        d.core = core;
        d.pass = pass;
        d.alms = alms;
        d.vault = vault;
        d.rat = rat;
        d.rakeBuyer = rakeBuyer;
        d.usdg = address(usdg);
        d.wif = address(wif);
        d.deployer = deployer;
        d.arrow = arrow;
        d.seat = seat;
        d.routeA = routeA;
        d.routeB = routeB;
        d.rakeRouteA = rakeRouteA;
    }

    function _check() internal {
        power.check(_pack(), deployer, safe_, _owners());
    }

    function _passScan() internal view {
        scanH.verifyFairCoreSetup(address(core), routeB);
    }

    function test_cleanDeploy_twoRoutes_verifyPasses() public {
        vm.recordLogs();
        _deployScenario(false, false, true);
        assertTrue(core.isBooth(arrow) && core.isBooth(seat));
        assertEq(address(core.routes(0)), routeA);
        assertEq(address(core.routes(1)), routeB);
        assertTrue(core.setupDone());
        _check();
        _passScan();
    }

    function test_cleanDeploy_oneRoute_verifyPasses() public {
        vm.recordLogs();
        _deployScenario(false, false, false);
        assertEq(routeB, address(0));
        assertEq(address(core.routes(1)), address(0));
        _check();
        _passScan();
    }

    function test_hiddenBooth_rejectedByVerify() public {
        vm.recordLogs();
        _deployScenario(true, false, true);
        assertTrue(core.isBooth(rogue));
        assertFalse(core.isBooth(deployer));
        assertTrue(core.setupDone());
        // The role check still misses a booth that is not the deployer address. The event count is the rejection.
        _check();
        vm.expectRevert(UNPLANNED);
        scanH.verifyFairCoreSetup(address(core), routeB);
    }

    function test_extraRoute_rejectedByVerify() public {
        vm.recordLogs();
        _deployScenario(false, true, true);
        assertEq(address(core.routes(2)), makeAddr("routeExtra"));
        _check();
        vm.expectRevert(UNPLANNED);
        scanH.verifyFairCoreSetup(address(core), routeB);
    }

    function test_verify_mainnetPin_onlyThePinnedSafe() public {
        vm.chainId(4663);
        (address mainnet,) = scanH.pins();
        assertEq(mainnet, 0x7c0fc9869f2D41D88CCA675A9A270214d59DA36a);
        scanH.requirePinnedOwner(mainnet);
        vm.expectRevert(bytes("OWNER_SAFE: not the pinned Safe address"));
        scanH.requirePinnedOwner(safe_);
    }

    function test_verify_testnetPin_onlyThePinnedSafe() public {
        vm.chainId(46630);
        (, address testnet) = scanH.pins();
        assertEq(testnet, 0xDF3d35A99af7A1A3fdE128b8FDFa0D60aE9A1F00);
        scanH.requirePinnedOwner(testnet);
        vm.expectRevert(bytes("OWNER_SAFE: not the pinned Safe address"));
        scanH.requirePinnedOwner(safe_);
    }

    function test_verify_otherChain_refused() public {
        vm.expectRevert(bytes("Robinhood Chain only"));
        scanH.requirePinnedOwner(safe_);
    }
}
