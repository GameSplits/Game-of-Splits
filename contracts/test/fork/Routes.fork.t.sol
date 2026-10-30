// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FairPass} from "../../src/FairPass.sol";
import {FairCore} from "../../src/FairCore.sol";
import {BuyRouteV4} from "../../src/routes/BuyRouteV4.sol";
import {BuyRouteV3V4, IUniswapV3Pool} from "../../src/routes/BuyRouteV3V4.sol";
import {PoolKey, IV4Quoter, QuoteExactSingleParams} from "../../src/interfaces/IV4Minimal.sol";
import {StubBooth} from "../mocks/Mocks.sol";
import {IFairCore, IGameConfig, Tokens, Split} from "../../src/interfaces/IFair.sol";
import {GameConfig} from "../../src/GameConfig.sol";

/// Both keeper routes against the real Robinhood Chain mainnet pools, end to end through FairCore.
/// Run: forge test --match-path "test/fork/*" (needs the public RPC; forks the latest block).
contract RoutesForkTest is Test {
    address constant PM = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant QUOTER = 0x8Dc178eFB8111BB0973Dd9d722ebeFF267c98F94;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant WIF = 0x5173b8eA6923c2d40267890D45C46a3480954773;
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant V3_POOL = 0x52e65B17fB6E5BA00Ed806f37Afcd2DaA50271Ca;
    address constant WIF_HOOK = 0xE5e702641Ea86F4ae6cC3cDaeD2B886f976Be044;
    address constant USDG_HOOK = 0x06a889870C8f83640D6816319f72e2aA579b6080;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    PoolKey usdgPool = PoolKey(address(0), USDG, 0x800000, 10, USDG_HOOK);
    PoolKey wifPool = PoolKey(address(0), WIF, 0, 200, WIF_HOOK);

    FairPass pass;
    FairCore core;
    StubBooth booth;
    BuyRouteV4 routeA;
    BuyRouteV3V4 routeB;
    address owner = makeAddr("ownerSafe");
    address keeper = makeAddr("keeper");
    address vault = makeAddr("vault");
    address ana = makeAddr("ana");

    function setUp() public {
        uint256 forkBlock = vm.envOr("FORK_BLOCK", uint256(0));
        if (forkBlock == 0) vm.createSelectFork("robinhood");
        else vm.createSelectFork("robinhood", forkBlock);

        GameConfig config = new GameConfig(
            owner, USDG, 7 days, Tokens(WIF, 5_000e18, WIF), Split(6000, 2000, 1750, 1750, 2500, 2500, 2500)
        );
        pass = new FairPass(IGameConfig(address(config)), owner);
        core = new FairCore(IERC20(USDG), IGameConfig(address(config)), pass, owner, 48 hours);
        booth = new StubBooth(IFairCore(address(core)));
        routeA = new BuyRouteV4(PM, address(core), usdgPool, wifPool);
        routeB = new BuyRouteV3V4(PM, address(core), IUniswapV3Pool(V3_POOL), USDG, WETH, wifPool);
        uint64 t = uint64(vm.getBlockTimestamp());
        vm.startPrank(owner);
        core.setupSet(FairCore.Op.AddBooth, 0, address(booth));
        core.setupSet(FairCore.Op.SetKeeper, 0, keeper);
        core.setupSet(FairCore.Op.SetVault, 0, vault);
        core.setupSet(FairCore.Op.SetRoute, 0, address(routeA));
        core.setupSet(FairCore.Op.SetRoute, 1, address(routeB));
        core.finishSetup();
        core.setFair(0, t + 1, t + 30 days);
        config.bindCore(address(core));
        vm.stopPrank();
        vm.warp(t + 1);
        assertEq(routeA.tokenOut(), WIF);
        assertEq(routeB.tokenOut(), WIF);

        // 10,000 USDG of shots -> Bonfire 700, each Vault quarter 450
        deal(USDG, ana, 10_000e6);
        vm.startPrank(ana);
        IERC20(USDG).approve(address(core), type(uint256).max);
        booth.shot(ana, 1, 10_000e6);
        vm.stopPrank();

        // v3.6: buybacks need a seeded anchor. Seed at 90% of route A's live price for 100 USDG, standing in for the
        // Safe's 30-min-average seed (a spot quote is fine in a test, never for the real seed).
        uint256 seed = quoteA(100e6) * 1e18 / 100e6 * 90 / 100;
        // A1-12: after setup a seed goes through the timelock (no live anchor yet, so unbounded).
        vm.startPrank(owner);
        core.queue(FairCore.Op.ResetRatchet, seed, address(0));
        vm.warp(vm.getBlockTimestamp() + core.timelockDelay());
        core.execute(FairCore.Op.ResetRatchet, seed, address(0));
        vm.stopPrank();
    }

    function quoteA(uint256 usdgIn) internal returns (uint256 wifOut) {
        (uint256 eth,) = IV4Quoter(QUOTER).quoteExactInputSingle(QuoteExactSingleParams(usdgPool, false, uint128(usdgIn), ""));
        (wifOut,) = IV4Quoter(QUOTER).quoteExactInputSingle(QuoteExactSingleParams(wifPool, true, uint128(eth), ""));
    }

    /// Route B's output, measured by running it on a snapshot and rolling back.
    function dryRunB(uint256 usdgIn) internal returns (uint256 wifOut) {
        uint256 snap = vm.snapshotState();
        uint256 floorMin = usdgIn * core.ratchetFloorRate() / 1e18; // the lowest minOut the seeded floor accepts
        vm.prank(keeper);
        wifOut = core.burnBuyToken(FairCore.BurnSource.Bonfire, 1, usdgIn, floorMin);
        vm.revertToState(snap);
    }

    /// The keeper's quote for either route: simulate its own exact call (eth_call from the keeper address: a call whose
    /// state changes are thrown away) and read the result. No separate v3 quoter needed.
    function simulate(uint8 ledger, uint256 route, uint256 usdgIn) internal returns (uint256 wifOut) {
        uint256 snap = vm.snapshotState();
        uint256 floorMin = usdgIn * core.ratchetFloorRate() / 1e18;
        vm.prank(keeper);
        if (ledger == 2) wifOut = core.buyForVault(route, usdgIn, floorMin);
        else wifOut = core.burnBuyToken(ledger == 0 ? FairCore.BurnSource.Bonfire : FairCore.BurnSource.Vault, route, usdgIn, floorMin);
        vm.revertToState(snap);
    }

    /// Route B: the simulated quote equals the real fill exactly, for a burn (runbook v2 review).
    function test_routeB_burn_simulatedQuote_equalsFill() public {
        uint256 q = simulate(0, 1, 250e6);
        uint256 minOut = q * 985 / 1000; // the keeper's rule: quote - 1.5%
        uint256 before = IERC20(WIF).balanceOf(DEAD);
        vm.prank(keeper);
        uint256 out = core.burnBuyToken(FairCore.BurnSource.Bonfire, 1, 250e6, minOut);
        assertEq(out, q, "route B fill == simulated quote");
        assertEq(IERC20(WIF).balanceOf(DEAD) - before, out);
        _assertRoutesEmpty();
    }

    /// Route B: same for a Vault buy (the $wif lands in the Vault).
    function test_routeB_vaultBuy_simulatedQuote_equalsFill() public {
        uint256 q = simulate(2, 1, 200e6);
        uint256 minOut = q * 985 / 1000;
        vm.prank(keeper);
        uint256 out = core.buyForVault(1, 200e6, minOut);
        assertEq(out, q, "route B fill == simulated quote");
        assertEq(IERC20(WIF).balanceOf(vault), out);
        _assertRoutesEmpty();
    }

    /// Route A: the simulated quote also equals the V4Quoter quote, so one quoting method works for both routes.
    function test_routeA_simulatedQuote_equalsV4Quoter() public {
        assertEq(simulate(1, 0, 150e6), quoteA(150e6));
    }

    function test_routeA_burn_matchesQuote() public {
        uint256 q = quoteA(250e6);
        uint256 before = IERC20(WIF).balanceOf(DEAD);
        vm.prank(keeper);
        uint256 out = core.burnBuyToken(FairCore.BurnSource.Bonfire, 0, 250e6, q * 97 / 100);
        assertEq(out, q, "burned == V4Quoter quote");
        assertEq(IERC20(WIF).balanceOf(DEAD) - before, out);
        _assertRoutesEmpty();
        console.log("route A: 250 USDG ->", out / 1e18, "$wif burned");
    }

    function test_routeB_burn_works_andStaysEmpty() public {
        uint256 before = IERC20(WIF).balanceOf(DEAD);
        uint256 qa = quoteA(250e6);
        vm.prank(keeper);
        uint256 out = core.burnBuyToken(FairCore.BurnSource.Bonfire, 1, 250e6, qa * 90 / 100);
        assertEq(IERC20(WIF).balanceOf(DEAD) - before, out);
        _assertRoutesEmpty();
        console.log("route B: 250 USDG ->", out / 1e18, "$wif burned");
        console.log("route A quote for comparison:", qa / 1e18);
    }

    /// The keeper's rule: quote both, take the better.
    function test_keeperPicksBetterRoute() public {
        uint256 a = quoteA(100e6);
        uint256 b = dryRunB(100e6);
        uint256 route = b > a ? 1 : 0;
        uint256 best = b > a ? b : a;
        vm.prank(keeper);
        uint256 out = core.burnBuyToken(FairCore.BurnSource.Bonfire, route, 100e6, best * 97 / 100);
        assertEq(out, best);
        console.log("better route:", route == 0 ? "A (v4+v4)" : "B (v3+v4)");
    }

    function test_vaultBuy_routeA_holdsInVault() public {
        uint256 q = quoteA(200e6);
        vm.prank(keeper);
        core.buyForVault(0, 200e6, q * 97 / 100);
        assertEq(IERC20(WIF).balanceOf(vault), q);
    }

    /// Someone dumps USDG into the $wif route right before the keeper's call: the keeper's minOut (from the pre-move
    /// quote, minus 3%) makes the buy revert, and the USDG stays in the ledger.
    function test_manipulatedPrice_tripsMinOut_andPotKept() public {
        uint256 q = quoteA(250e6);
        // Front-runner pushes $wif up hard with ETH.
        address whale = makeAddr("whale");
        vm.deal(whale, 200 ether);
        _pumpWif(whale, 20 ether);
        vm.prank(keeper);
        vm.expectRevert();
        core.burnBuyToken(FairCore.BurnSource.Bonfire, 0, 250e6, q * 97 / 100);
        assertEq(core.bonfirePending(), 700e6, "USDG kept for a later run");
    }

    /// After one buy, the ratchet refuses a loose minimum even from the real keeper key.
    function test_ratchet_onRealPools() public {
        uint256 q = quoteA(100e6);
        vm.prank(keeper);
        core.burnBuyToken(FairCore.BurnSource.Bonfire, 0, 100e6, q * 97 / 100);
        vm.warp(vm.getBlockTimestamp() + 50 minutes);
        vm.prank(keeper);
        vm.expectPartialRevert(FairCore.RatchetTripped.selector);
        core.burnBuyToken(FairCore.BurnSource.Bonfire, 0, 100e6, 1);
    }

    /// Audit H1 on real pools: a stolen key fires 50 calls in one block; one per ledger lands, the rest revert.
    function test_H1_stolenKey_oneBlock_boundedToOneCallPerLedger() public {
        uint256 before = core.bonfirePending() + core.vaultBurnPending() + core.vaultBuyPending();
        uint256 landed;
        for (uint256 i; i < 50; ++i) {
            uint8 l = uint8(i % 3);
            vm.prank(keeper);
            if (l == 2) {
                try core.buyForVault(0, 100e6, 1) {
                    ++landed;
                } catch {}
            } else {
                try core.burnBuyToken(l == 0 ? FairCore.BurnSource.Bonfire : FairCore.BurnSource.Vault, 0, 100e6, 1) {
                    ++landed;
                } catch {}
            }
        }
        uint256 spent = before - (core.bonfirePending() + core.vaultBurnPending() + core.vaultBuyPending());
        assertLe(landed, 3, "at most one call per ledger");
        assertLe(spent, 300e6);
    }

    function test_routes_onlyCore() public {
        vm.expectRevert(BuyRouteV4.OnlyCore.selector);
        routeA.swapToToken(1e6, 1, DEAD);
        vm.expectRevert(BuyRouteV3V4.OnlyCore.selector);
        routeB.swapToToken(1e6, 1, DEAD);
        vm.expectRevert(BuyRouteV3V4.NotPool.selector);
        routeB.uniswapV3SwapCallback(1, 1, "");
    }

    function _assertRoutesEmpty() internal view {
        assertEq(IERC20(USDG).balanceOf(address(routeA)), 0);
        assertEq(IERC20(WIF).balanceOf(address(routeA)), 0);
        assertEq(address(routeA).balance, 0);
        assertEq(IERC20(USDG).balanceOf(address(routeB)), 0);
        assertEq(IERC20(WIF).balanceOf(address(routeB)), 0);
        assertEq(IERC20(WETH).balanceOf(address(routeB)), 0);
        assertEq(address(routeB).balance, 0);
    }

    /// Buys $wif with ETH through a throwaway v4 route (same Pons pool), moving the price.
    function _pumpWif(address who, uint256 ethIn) internal {
        Pumper p = new Pumper(PM, wifPool);
        vm.prank(who);
        p.pump{value: ethIn}();
    }
}

import {SwapParams, IPoolManager, IUnlockCallback} from "../../src/interfaces/IV4Minimal.sol";

contract Pumper is IUnlockCallback {
    IPoolManager pm;
    PoolKey key;

    constructor(address pm_, PoolKey memory k) {
        pm = IPoolManager(pm_);
        key = k;
    }

    function pump() external payable {
        pm.unlock(abi.encode(msg.value, msg.sender));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (uint256 ethIn, address to) = abi.decode(data, (uint256, address));
        int256 d = pm.swap(key, SwapParams(true, -int256(ethIn), 4295128740), "");
        int128 out;
        assembly {
            out := signextend(15, d)
        }
        pm.settle{value: ethIn}();
        pm.take(key.currency1, to, uint256(int256(out)));
        return "";
    }
}
