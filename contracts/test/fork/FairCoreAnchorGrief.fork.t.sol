// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FairPass} from "../../src/FairPass.sol";
import {FairCore} from "../../src/FairCore.sol";
import {BuyRouteV4} from "../../src/routes/BuyRouteV4.sol";
import {GameConfig} from "../../src/GameConfig.sol";
import {StubBooth} from "../mocks/Mocks.sol";
import {IFairCore, IGameConfig, Tokens, Split} from "../../src/interfaces/IFair.sol";
import {PoolKey, IV4Quoter, QuoteExactSingleParams} from "../../src/interfaces/IV4Minimal.sol";
import {AnchorSwapper} from "./RakeAnchorGrief.fork.t.sol";

/// Mainnet-fork check that a reverse sandwich no longer freezes FairCore. Skips when the RPC is down.
contract FairCoreAnchorGriefFork is Test {
    address constant PM = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant QUOTER = 0x8Dc178eFB8111BB0973Dd9d722ebeFF267c98F94;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant WIF = 0x5173b8eA6923c2d40267890D45C46a3480954773;
    address constant WIF_HOOK = 0xE5e702641Ea86F4ae6cC3cDaeD2B886f976Be044;
    address constant USDG_HOOK = 0x06a889870C8f83640D6816319f72e2aA579b6080;
    PoolKey usdgPool = PoolKey(address(0), USDG, 0x800000, 10, USDG_HOOK);
    PoolKey wifPool = PoolKey(address(0), WIF, 0, 200, WIF_HOOK);
    address owner = makeAddr("ownerSafe");
    address keeper = makeAddr("keeper");
    address vault = makeAddr("vault");
    FairCore core;
    bool forked;

    function setUp() public {
        try vm.createSelectFork("robinhood") returns (uint256) {
            forked = true;
        } catch {
            return;
        }
        GameConfig config = new GameConfig(
            owner, USDG, 7 days, Tokens(WIF, 5_000e18, WIF), Split(6000, 2000, 1750, 1750, 2500, 2500, 2500)
        );
        FairPass pass = new FairPass(IGameConfig(address(config)), owner);
        core = new FairCore(IERC20(USDG), IGameConfig(address(config)), pass, owner, 48 hours);
        StubBooth booth = new StubBooth(IFairCore(address(core)));
        BuyRouteV4 routeA = new BuyRouteV4(PM, address(core), usdgPool, wifPool);
        uint64 t = uint64(vm.getBlockTimestamp());
        vm.startPrank(owner);
        core.setupSet(FairCore.Op.AddBooth, 0, address(booth));
        core.setupSet(FairCore.Op.SetKeeper, 0, keeper);
        core.setupSet(FairCore.Op.SetVault, 0, vault);
        core.setupSet(FairCore.Op.SetRoute, 0, address(routeA));
        core.finishSetup();
        core.setFair(0, t + 1, t + 30 days);
        config.bindCore(address(core));
        vm.stopPrank();
        vm.warp(t + 1);

        // 10,000 USDG of shots -> Bonfire 700, enough for the windfall buy and the follow-up.
        address ana = makeAddr("ana");
        deal(USDG, ana, 10_000e6);
        vm.startPrank(ana);
        IERC20(USDG).approve(address(core), type(uint256).max);
        booth.shot(ana, 1, 10_000e6);
        vm.stopPrank();

        uint256 seed = quoteA(50e6) * 1e18 / 50e6; // read first: an external call would consume the prank
        // A1-12: after setup a seed goes through the timelock (no live anchor yet, so unbounded).
        vm.startPrank(owner);
        core.queue(FairCore.Op.ResetRatchet, seed, address(0));
        vm.warp(vm.getBlockTimestamp() + core.timelockDelay());
        core.execute(FairCore.Op.ResetRatchet, seed, address(0));
        vm.stopPrank();
    }

    function quoteA(uint256 usdgIn) internal returns (uint256 wifOut) {
        (uint256 eth,) =
            IV4Quoter(QUOTER).quoteExactInputSingle(QuoteExactSingleParams(usdgPool, false, uint128(usdgIn), ""));
        (wifOut,) = IV4Quoter(QUOTER).quoteExactInputSingle(QuoteExactSingleParams(wifPool, true, uint128(eth), ""));
    }

    /// An outsider dumps $wif in front of the keeper. The fill beats the quote, but the anchor stays on minOut,
    /// so the next honest buy is not frozen.
    function test_reverseSandwich_windfallDoesNotFreeze() public {
        if (!forked) {
            vm.skip(true, "robinhood RPC unavailable");
            return;
        }
        uint256 q = quoteA(50e6);
        uint256 minOut = q * 99 / 100;
        address att = makeAddr("attacker");
        AnchorSwapper s = new AnchorSwapper(PM, wifPool);
        uint256 dumpWif = vm.envOr("DUMP_WIF", uint256(10_000_000e18));
        deal(WIF, att, dumpWif);
        vm.startPrank(att);
        IERC20(WIF).approve(address(s), type(uint256).max);
        uint256 ethGot = s.swap(false, dumpWif);
        vm.stopPrank();

        uint256 anchorBefore = core.anchorRate();
        vm.prank(keeper);
        uint256 out = core.burnBuyToken(FairCore.BurnSource.Bonfire, 0, 50e6, minOut);
        assertGt(out, minOut, "the dump makes the fill a windfall");
        assertGt(out * 1e18 / 50e6, anchorBefore, "the fill is a better price than the anchor");
        assertEq(core.anchorRate(), anchorBefore, "anchor stays on the quote, not the fill");

        vm.deal(att, ethGot);
        vm.prank(att);
        s.swap{value: ethGot}(true, ethGot);

        uint256 frozenHours;
        for (uint256 h; h < 40; ++h) {
            vm.warp(vm.getBlockTimestamp() + 1 hours);
            uint256 live = quoteA(50e6);
            vm.prank(keeper);
            try core.burnBuyToken(FairCore.BurnSource.Bonfire, 0, 50e6, live) {
                break;
            } catch {
                ++frozenHours;
            }
        }
        assertEq(frozenHours, 0, "buys are not frozen");
    }
}
