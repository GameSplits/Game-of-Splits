// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {RakeBuyer} from "../../src/RakeBuyer.sol";
import {BuyRouteV4} from "../../src/routes/BuyRouteV4.sol";
import {GameConfig} from "../../src/GameConfig.sol";
import {IGameConfig, Tokens, Split} from "../../src/interfaces/IFair.sol";
import {
    PoolKey,
    SwapParams,
    IPoolManager,
    IUnlockCallback,
    IV4Quoter,
    QuoteExactSingleParams
} from "../../src/interfaces/IV4Minimal.sol";

/// Swaps on one v4 pool in either direction (exact input). Pays and receives from the caller.
contract AnchorSwapper is IUnlockCallback {
    IPoolManager pm;
    PoolKey key;

    constructor(address pm_, PoolKey memory k) {
        pm = IPoolManager(pm_);
        key = k;
    }

    receive() external payable {}

    function swap(bool zeroForOne, uint256 amtIn) external payable returns (uint256 out) {
        out = abi.decode(pm.unlock(abi.encode(zeroForOne, amtIn, msg.sender)), (uint256));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (bool z, uint256 amtIn, address who) = abi.decode(data, (bool, uint256, address));
        int256 d = pm.swap(
            key, SwapParams(z, -int256(amtIn), z ? 4295128740 : 1461446703485210103287273052203988822378723970341), ""
        );
        int128 a0;
        int128 a1;
        assembly {
            a0 := sar(128, d)
            a1 := signextend(15, d)
        }
        if (z) {
            pm.settle{value: amtIn}();
            pm.take(key.currency1, who, uint256(int256(a1)));
            return abi.encode(uint256(int256(a1)));
        } else {
            pm.sync(key.currency1);
            IERC20(key.currency1).transferFrom(who, address(pm), amtIn);
            pm.settle();
            pm.take(address(0), who, uint256(int256(a0)));
            return abi.encode(uint256(int256(a0)));
        }
    }
}

/// Mainnet-fork check that a reverse sandwich no longer freezes RakeBuyer. Skips when the RPC is down.
contract RakeAnchorGriefFork is Test {
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
    RakeBuyer rb;
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
        rb = new RakeBuyer(IERC20(USDG), IGameConfig(address(config)), vault, owner, 48 hours, makeAddr("fairCore"));
        BuyRouteV4 routeA = new BuyRouteV4(PM, address(rb), usdgPool, wifPool);
        vm.startPrank(owner);
        rb.setupSet(RakeBuyer.Op.SetKeeper, 0, keeper);
        rb.setupSet(RakeBuyer.Op.SetRoute, 0, address(routeA));
        rb.resetRatchet(quoteA(50e6) * 1e18 / 50e6);
        rb.finishSetup();
        vm.stopPrank();
        deal(USDG, address(rb), 2_000e6);
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

        uint256 anchorBefore = rb.anchorRate();
        vm.prank(keeper);
        uint256 out = rb.buy(0, 50e6, minOut);
        assertGt(out, minOut, "the dump makes the fill a windfall");
        assertGt(out * 1e18 / 50e6, anchorBefore, "the fill is a better price than the anchor");
        assertEq(rb.anchorRate(), anchorBefore, "anchor stays on the quote, not the fill");

        vm.deal(att, ethGot);
        vm.prank(att);
        s.swap{value: ethGot}(true, ethGot);

        uint256 frozenHours;
        for (uint256 h; h < 40; ++h) {
            vm.warp(vm.getBlockTimestamp() + 1 hours);
            uint256 live = quoteA(50e6);
            vm.prank(keeper);
            try rb.buy(0, 50e6, live) {
                break;
            } catch {
                ++frozenHours;
            }
        }
        assertEq(frozenHours, 0, "buys are not frozen");
    }
}
