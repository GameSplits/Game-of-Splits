// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IFairCore, IGameConfig, Tokens} from "../../src/interfaces/IFair.sol";
import {PoolKey} from "../../src/interfaces/IV4Minimal.sol";
import {IIdentityRegistry, IReputationRegistry} from "../../src/interfaces/I8004.sol";
import {GameConfig} from "../../src/GameConfig.sol";
import {FairPass} from "../../src/FairPass.sol";
import {FairCore} from "../../src/FairCore.sol";
import {LastArrow} from "../../src/LastArrow.sol";
import {SheriffsSeat} from "../../src/SheriffsSeat.sol";
import {AlmsVote} from "../../src/AlmsVote.sol";
import {LocksleyVault, ICoreVaultUsdg} from "../../src/LocksleyVault.sol";
import {FairLens, IVaultView} from "../../src/FairLens.sol";
import {RobinAmongThieves} from "../../src/RobinAmongThieves.sol";
import {RakeBuyer} from "../../src/RakeBuyer.sol";
import {BuyRouteV4} from "../../src/routes/BuyRouteV4.sol";
import {TestRoute, TestToken, ITestMint} from "../../src/testnet/TestTokens.sol";
import {MockToken} from "../mocks/Mocks.sol";
import {HiddenBoothTest} from "./HiddenBooth.t.sol";
import {AcceptBase} from "../../script/SafeAccept.s.sol";

/// Quacks like Last Arrow (core + fair pass) but is not that bytecode.
contract FakeArrow {
    address public core;
    address public fairPass;

    constructor(address c, address p) {
        core = c;
        fairPass = p;
    }
}

/// Quacks like a test route (core, token, rate, deployer) but is not TestRoute bytecode.
contract FakeRoute {
    address public core;
    address public tokenOut;
    uint256 public RATE;
    address public deployer;
    address public extraCaller;

    constructor(address c, address t, uint256 rate, address dep) {
        core = c;
        tokenOut = t;
        RATE = rate;
        deployer = dep;
        extraCaller = dep;
    }
}

/// Same rogue booth as the original PoC: pulls a victim's allowance and awards it to the boss.
contract DrainBooth {
    address immutable boss;
    FairCore immutable core;

    constructor(FairCore c, address b) {
        core = c;
        boss = b;
    }

    function drain(address victim, uint256 amount, uint256 roundKey) external {
        require(msg.sender == boss);
        core.collect(victim, boss, roundKey, amount);
        address[] memory w = new address[](1);
        w[0] = boss;
        uint256[] memory a = new uint256[](1);
        a[0] = core.pot(address(this), roundKey);
        core.award(roundKey, w, a);
    }
}

/// Regression for booth substitution. Event counts stay at two BoothAdded / two RouteSet when a rogue is
/// listed *as* Last Arrow or *as* route A. Verify's codehash check must reject both. A clean deploy still passes.
contract PoC_HiddenBooth84 is HiddenBoothTest {
    enum V {
        Clean,
        ExtraBooth,
        ReAddArrow,
        OverwriteRoute0ThenRestore,
        Route2,
        RelabelArrow,
        RelabelRoute,
        ExtraBoothAfterSetupDone
    }

    DrainBooth internal drainer;
    FairLens internal lens;
    MockToken internal tokenB;
    address internal rakeRouteB;

    function _deployV(V v) internal {
        usdg = new MockToken("Global Dollar", "USDG", 6);
        wif = new MockToken("World is Flat", "WIF", 18);
        tokenB = new MockToken("Token B", "TKB", 18);
        config = new GameConfig(
            deployer, address(usdg), 7 days, Tokens(address(wif), 5_000e18, address(wif)), _split()
        );
        pass = new FairPass(IGameConfig(address(config)), deployer);
        core = new FairCore(IERC20(address(usdg)), IGameConfig(address(config)), pass, deployer, 48 hours);
        vm.prank(deployer);
        config.bindCore(address(core));
        alms = new AlmsVote(IFairCore(address(core)), deployer, 24 hours, 24 hours);
        vault = new LocksleyVault(ICoreVaultUsdg(address(core)), deployer);
        rakeBuyer = new RakeBuyer(IERC20(address(usdg)), IGameConfig(address(config)), address(vault), deployer, 0);
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
        drainer = new DrainBooth(core, deployer);
        arrow = v == V.RelabelArrow ? address(drainer) : address(new LastArrow(IFairCore(address(core))));
        seat = address(new SheriffsSeat(IFairCore(address(core)), 1 days, 1 days));

        TestRoute rA = new TestRoute(781_250e12);
        TestRoute rB = new TestRoute(100e12);
        if (v != V.RelabelRoute) {
            rA.wire(address(core), ITestMint(address(wif)));
            rA.wireExtra(address(rakeBuyer));
            routeA = address(rA);
        } else {
            routeA = address(drainer);
        }
        rB.wire(address(core), ITestMint(address(tokenB)));
        rB.wireExtra(address(rakeBuyer));
        routeB = address(rB);
        rakeRouteA = routeA;
        rakeRouteB = routeB;
        lens = new FairLens(core, LastArrow(arrow), SheriffsSeat(seat), IVaultView(address(vault)));

        vm.startPrank(deployer);
        core.setupSet(FairCore.Op.SetKeeper, 0, keeper);
        core.setupSet(FairCore.Op.SetTollRecipient, 0, toll);
        core.setupSet(FairCore.Op.SetAlmsSafe, 0, safe_);
        core.setupSet(FairCore.Op.SetAlmsVote, 0, address(alms));
        core.setupSet(FairCore.Op.SetVault, 0, address(vault));
        if (v == V.ExtraBooth) core.setupSet(FairCore.Op.AddBooth, 0, address(drainer));
        core.setupSet(FairCore.Op.AddBooth, 0, arrow);
        core.setupSet(FairCore.Op.AddBooth, 0, seat);
        if (v == V.ReAddArrow) core.setupSet(FairCore.Op.AddBooth, 0, arrow);
        if (v == V.OverwriteRoute0ThenRestore) core.setupSet(FairCore.Op.SetRoute, 0, address(drainer));
        core.setupSet(FairCore.Op.SetRoute, 0, routeA);
        core.setupSet(FairCore.Op.SetRoute, 1, routeB);
        if (v == V.Route2) core.setupSet(FairCore.Op.SetRoute, 2, address(drainer));
        core.resetRatchet(1e18);
        core.finishSetup();
        core.setFair(0, uint64(T0 + 1 hours), uint64(T0 + 7 days));
        rakeBuyer.setupSet(RakeBuyer.Op.SetKeeper, 0, keeper);
        rakeBuyer.setupSet(RakeBuyer.Op.SetRoute, 0, rakeRouteA);
        rakeBuyer.setupSet(RakeBuyer.Op.SetRoute, 1, rakeRouteB);
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

    function _packV() internal view returns (AcceptBase.D memory d) {
        d = _pack();
        d.lens = lens;
        d.tokenB = address(tokenB);
        d.rakeRouteA = rakeRouteA;
        d.rakeRouteB = rakeRouteB;
    }

    function _drainWorks() internal {
        vm.warp(T0 + 2 hours);
        address victim = makeAddr("victim");
        usdg.mint(victim, 1_000e6);
        vm.prank(victim);
        usdg.approve(address(core), type(uint256).max);
        vm.prank(deployer);
        drainer.drain(victim, 1_000e6, 1);
        vm.prank(deployer);
        core.claim();
        assertEq(usdg.balanceOf(victim), 0);
        assertGt(usdg.balanceOf(deployer), 0);
    }

    function test_clean_passes() public {
        vm.recordLogs();
        _deployV(V.Clean);
        _check();
        _passScan();
        scanH.assertBytecode(_packV());
    }

    /// The original PoC: the role check still passes, and Verify's FairCore setup count now refuses.
    function test_PoC_hiddenBooth_nowRejected() public {
        vm.recordLogs();
        _deployV(V.ExtraBooth);
        assertTrue(core.isBooth(address(drainer)));
        _check();
        vm.expectRevert(UNPLANNED);
        scanH.verifyFairCoreSetup(address(core), routeB);
        _drainWorks();
    }

    function test_variant_reAddLegitBooth_rejected() public {
        vm.recordLogs();
        _deployV(V.ReAddArrow);
        _check();
        vm.expectRevert(UNPLANNED);
        scanH.verifyFairCoreSetup(address(core), routeB);
    }

    function test_variant_overwriteRoute0ThenRestore_rejected() public {
        vm.recordLogs();
        _deployV(V.OverwriteRoute0ThenRestore);
        _check();
        vm.expectRevert(UNPLANNED);
        scanH.verifyFairCoreSetup(address(core), routeB);
    }

    function test_variant_route2_rejected() public {
        vm.recordLogs();
        _deployV(V.Route2);
        _check();
        vm.expectRevert(UNPLANNED);
        scanH.verifyFairCoreSetup(address(core), routeB);
    }

    /// Counts stay at two BoothAdded. The rogue is listed as Last Arrow, so the codehash check refuses it.
    /// The pull still succeeds on chain: Verify is the gate.
    function test_variant_relabelRogueAsLastArrow_failsVerify() public {
        vm.recordLogs();
        _deployV(V.RelabelArrow);
        _check();
        _passScan();
        vm.expectRevert(bytes("lastArrow: bytecode mismatch"));
        scanH.assertBytecode(_packV());
        _drainWorks();
    }

    /// Same class of substitution, listed as route A. Counts match. Codehash does not.
    function test_variant_relabelRogueAsRoute_failsVerify() public {
        vm.recordLogs();
        _deployV(V.RelabelRoute);
        _check();
        _passScan();
        assertEq(address(core.routes(0)), address(drainer));
        vm.expectRevert(bytes("routeA: bytecode mismatch"));
        scanH.assertBytecode(_packV());
    }

    /// A BoothAdded topic from another address must not count toward FairCore.
    function test_otherEmitter_ignored() public {
        vm.recordLogs();
        _deployV(V.Clean);
        Emitter e = new Emitter();
        e.fire(address(drainer));
        _passScan();
    }

    /// Mainnet route A: codehash matches a BuyRouteV4 built with the configured pools. A wrong hook is storage, so
    /// the codehash of a genuine route would still match a reference built from its own keys; the pool check refuses it.
    function test_buyRouteV4_exactPoolsPass_wrongHookAndRogueFail() public {
        (address pm, PoolKey memory usdgKey, PoolKey memory wifKey) = scanH.v4Pools();
        address core_ = makeAddr("core");
        BuyRouteV4 good = new BuyRouteV4(pm, core_, usdgKey, wifKey);
        PoolKey memory evilOut = wifKey;
        evilOut.hooks = makeAddr("evilHook");
        BuyRouteV4 evil = new BuyRouteV4(pm, core_, usdgKey, evilOut);
        vm.chainId(4663);
        scanH.assertV4Route(address(good), core_, wifKey.currency1, "routeA");
        vm.expectRevert(bytes("routeA: pools"));
        scanH.assertV4Route(address(evil), core_, wifKey.currency1, "routeA");
        vm.expectRevert(bytes("routeA: core"));
        scanH.assertV4Route(address(good), makeAddr("other"), wifKey.currency1, "routeA");
        vm.expectRevert(bytes("routeA: bytecode mismatch"));
        scanH.assertV4Route(address(this), core_, wifKey.currency1, "routeA");
    }

    /// Getters match the real booth and route. The runtime codehash still does not, so Verify refuses.
    function test_matchingGetters_differentBytecode_fails() public {
        _deployV(V.Clean);
        AcceptBase.D memory asArrow = _packV();
        asArrow.arrow = address(new FakeArrow(address(core), address(pass)));
        vm.expectRevert(bytes("lastArrow: bytecode mismatch"));
        scanH.assertBytecode(asArrow);

        AcceptBase.D memory asRoute = _packV();
        asRoute.routeA = address(new FakeRoute(address(core), address(wif), 781_250e12, address(this)));
        asRoute.rakeRouteA = asRoute.routeA;
        vm.expectRevert(bytes("routeA: bytecode mismatch"));
        scanH.assertBytecode(asRoute);
    }

    /// Testnet tokens: same decimals, faucet and minter reconstruct; a contract that is not a TestToken does not.
    function test_testToken_codehash_rogueFails() public {
        TestToken token = new TestToken("Test USDG", "tUSDG", 6, 1_000e6, address(0));
        scanH.assertTestToken(address(token), "usdg");
        TestToken sameImmutables = new TestToken("Other Name", "OTH", 6, 1_000e6, address(0));
        scanH.assertTestToken(address(sameImmutables), "usdg");
        vm.expectRevert(bytes("usdg: bytecode mismatch"));
        scanH.assertTestToken(address(this), "usdg");
    }
}

contract Emitter {
    event BoothAdded(address indexed booth);

    function fire(address b) external {
        emit BoothAdded(b);
    }
}
