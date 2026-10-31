// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Base} from "../Base.t.sol";
import {FairCore} from "../../src/FairCore.sol";
import {GameConfig} from "../../src/GameConfig.sol";
import {BuyRouteV4} from "../../src/routes/BuyRouteV4.sol";
import {BuyRouteV3V4} from "../../src/routes/BuyRouteV3V4.sol";
import {IBuyRoute, IFairCore, IGameConfig, Tokens} from "../../src/interfaces/IFair.sol";
import {IUniswapV3Pool} from "../../src/routes/BuyRouteV3V4.sol";
import {PoolKey, SwapParams, IPoolManager, IUnlockCallback} from "../../src/interfaces/IV4Minimal.sol";
import {StubBooth} from "../mocks/Mocks.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface ISwapCb {
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external;
}

/// @dev PoolManager that returns fixed v4 deltas and `take`s the buy token to whoever the route names.
contract MockPoolManager is IPoolManager {
    uint256 public usdgIn;
    uint256 public ethOut;
    uint256 public tokenOutAmt;
    bool public singleLeg;
    uint256 public swaps;
    address public lastTo;
    uint256 public lastAmt;
    address public lastCurrency;

    function configure(uint256 usdgIn_, uint256 ethOut_, uint256 tokenOutAmt_, bool single) external {
        (usdgIn, ethOut, tokenOutAmt, singleLeg) = (usdgIn_, ethOut_, tokenOutAmt_, single);
    }

    function unlock(bytes calldata data) external returns (bytes memory) {
        swaps = 0;
        return IUnlockCallback(msg.sender).unlockCallback(data);
    }

    function swap(PoolKey memory, SwapParams memory, bytes calldata) external returns (int256) {
        swaps++;
        int128 eth = int128(uint128(ethOut));
        if (!singleLeg && swaps == 1) return _pack(eth, -int128(uint128(usdgIn)));
        return _pack(-eth, int128(uint128(tokenOutAmt)));
    }

    function sync(address) external {}

    function settle() external payable returns (uint256 paid) {
        return msg.value;
    }

    function take(address currency, address to, uint256 amount) external {
        lastCurrency = currency;
        lastTo = to;
        lastAmt = amount;
        require(IERC20(currency).transfer(to, amount), "take");
    }

    function _pack(int128 a0, int128 a1) internal pure returns (int256 d) {
        assembly {
            d := or(shl(128, a0), and(a1, 0xffffffffffffffffffffffffffffffff))
        }
    }
}

/// @dev WETH the v3 leg unwraps. ETH is dealt to this contract in the test.
contract MockWeth is ERC20 {
    error EthSendFailed();

    constructor() ERC20("Wrapped Ether", "WETH") {}

    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }

    function withdraw(uint256 amt) external {
        _burn(msg.sender, amt);
        (bool ok,) = msg.sender.call{value: amt}("");
        if (!ok) revert EthSendFailed();
    }

    receive() external payable {}
}

/// @dev v3 USDG/WETH pool. Pays WETH to the route, then pulls USDG in the callback.
contract MockV3Pool {
    address public immutable token0;
    address public immutable token1;
    MockWeth public immutable weth;
    uint256 public wethOut;

    constructor(address usdg_, MockWeth weth_) {
        token0 = usdg_;
        token1 = address(weth_);
        weth = weth_;
    }

    function setWethOut(uint256 amt) external {
        wethOut = amt;
    }

    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160, bytes calldata)
        external
        returns (int256 amount0, int256 amount1)
    {
        require(zeroForOne, "dir");
        weth.transfer(recipient, wethOut);
        amount0 = amountSpecified;
        amount1 = -int256(wethOut);
        ISwapCb(msg.sender).uniswapV3SwapCallback(amount0, amount1, "");
    }
}

/// @notice BuyRouteV4 and BuyRouteV3V4 pay FairCore. FairCore forwards its own balance delta.
contract RealRoutePaysCoreTest is Base {
    uint256 constant RATE = 781_250e12;
    uint256 constant ETH_OUT = 1e15;
    uint256 constant V4 = 2;
    uint256 constant V3V4 = 3;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    MockPoolManager pm;
    MockWeth weth;
    MockV3Pool v3;
    BuyRouteV4 routeV4;
    BuyRouteV3V4 routeV3;

    function setUp() public override {
        super.setUp();
        pm = new MockPoolManager();
        weth = new MockWeth();
        vm.deal(address(weth), 100 ether);
        v3 = new MockV3Pool(address(usdg), weth);

        PoolKey memory usdgPool =
            PoolKey({currency0: address(0), currency1: address(usdg), fee: 100, tickSpacing: 1, hooks: address(0)});
        PoolKey memory outPool =
            PoolKey({currency0: address(0), currency1: address(wif), fee: 3000, tickSpacing: 60, hooks: address(0)});
        routeV4 = new BuyRouteV4(address(pm), address(core), usdgPool, outPool);
        routeV3 = new BuyRouteV3V4(address(pm), address(core), IUniswapV3Pool(address(v3)), address(usdg), address(weth), outPool);

        openFair();
        shot(ana, 1, 5_000e6);

        vm.startPrank(owner);
        core.queue(FairCore.Op.SetRoute, V4, address(routeV4));
        core.queue(FairCore.Op.SetRoute, V3V4, address(routeV3));
        vm.warp(vm.getBlockTimestamp() + core.timelockDelay());
        core.execute(FairCore.Op.SetRoute, V4, address(routeV4));
        core.execute(FairCore.Op.SetRoute, V3V4, address(routeV3));
        vm.stopPrank();
        reseed(RATE * 1e18);
    }

    function test_buyRouteV4_paysFairCore_thenForwards() public {
        uint256 usdgIn = 50e6;
        uint256 outAmt = usdgIn * RATE;
        pm.configure(usdgIn, ETH_OUT, outAmt, false);
        wif.mint(address(pm), outAmt * 2);

        uint256 v0 = wif.balanceOf(vaultAddr);
        vm.expectEmit(true, false, false, true, address(core));
        emit FairCore.BoughtForVault(address(wif), V4, usdgIn, outAmt, outAmt);
        vm.prank(keeper);
        uint256 out = core.buyForVault(V4, usdgIn, outAmt);
        assertEq(out, outAmt);
        assertEq(pm.lastTo(), address(core), "the route paid FairCore");
        assertEq(pm.lastCurrency(), address(wif));
        assertEq(pm.lastAmt(), outAmt);
        assertEq(wif.balanceOf(vaultAddr) - v0, outAmt, "FairCore forwarded the delta");
        assertEq(wif.balanceOf(address(core)), 0);
        assertEq(usdg.balanceOf(address(pm)), usdgIn);

        uint256 d0 = wif.balanceOf(DEAD);
        vm.prank(keeper);
        uint256 burned = core.burnBuyToken(FairCore.BurnSource.Vault, V4, usdgIn, outAmt);
        assertEq(burned, outAmt);
        assertEq(pm.lastTo(), address(core));
        assertEq(wif.balanceOf(DEAD) - d0, outAmt);
        assertEq(wif.balanceOf(address(core)), 0);
    }

    function test_buyRouteV3V4_paysFairCore_thenForwards() public {
        uint256 usdgIn = 50e6;
        uint256 outAmt = usdgIn * RATE;
        pm.configure(usdgIn, ETH_OUT, outAmt, true);
        v3.setWethOut(ETH_OUT);
        weth.mint(address(v3), ETH_OUT);
        wif.mint(address(pm), outAmt);

        uint256 d0 = wif.balanceOf(DEAD);
        vm.expectEmit(true, false, false, true, address(core));
        emit FairCore.Burned(address(wif), uint8(FairCore.BurnSource.Bonfire), V3V4, usdgIn, outAmt, outAmt);
        vm.prank(keeper);
        uint256 out = core.burnBuyToken(FairCore.BurnSource.Bonfire, V3V4, usdgIn, outAmt);
        assertEq(out, outAmt);
        assertEq(pm.lastTo(), address(core), "the route paid FairCore");
        assertEq(pm.lastAmt(), outAmt);
        assertEq(wif.balanceOf(DEAD) - d0, outAmt);
        assertEq(wif.balanceOf(address(core)), 0);
        assertEq(usdg.balanceOf(address(v3)), usdgIn);
        assertEq(address(routeV3).balance, 0, "the route holds no ETH");
    }
}

/// @dev 1% fee-on-transfer buy token. `InAmount` takes the fee out of the transfer. `OnTop` charges it extra.
contract FeeBuy is ERC20 {
    enum Mode {
        InAmount,
        OnTop
    }

    Mode public mode;
    /// @notice Fee in bps of the transferred amount. 100 is 1%.
    uint256 public feeBps = 100;

    error FeeOnTop();

    constructor() ERC20("Fee Buy", "FBUY") {}

    function decimals() public pure override returns (uint8) {
        return 18;
    }

    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }

    function setMode(Mode m) external {
        mode = m;
    }

    function setFeeBps(uint256 bps) external {
        require(bps <= 10_000);
        feeBps = bps;
    }

    function _update(address from, address to, uint256 value) internal override {
        // The fee sink is excluded so the fee transfer is not charged again.
        if (from != address(0) && to != address(0) && to != address(0xFEE)) {
            uint256 fee = value * feeBps / 10_000;
            if (fee != 0) {
                if (mode == Mode.OnTop) {
                    if (balanceOf(from) < value + fee) revert FeeOnTop();
                    super._update(from, address(0xFEE), fee);
                } else {
                    super._update(from, address(0xFEE), fee);
                    value -= fee;
                }
            }
        }
        super._update(from, to, value);
    }
}

/// @dev Pays `deliver` of the fee token to the recipient, by transfer or by mint.
contract FoTRoute is IBuyRoute {
    FeeBuy public immutable token;
    IERC20 public immutable usdg;
    uint256 public deliver;
    bool public mintIn;

    constructor(FeeBuy t, IERC20 u) {
        token = t;
        usdg = u;
    }

    function tokenOut() external view returns (address) {
        return address(token);
    }

    function set(uint256 deliver_, bool mintIn_) external {
        (deliver, mintIn) = (deliver_, mintIn_);
    }

    function swapToToken(uint256 usdgIn, uint256, address recipient) external returns (uint256) {
        require(usdg.balanceOf(address(this)) >= usdgIn, "not funded");
        if (mintIn) token.mint(recipient, deliver);
        else token.transfer(recipient, deliver);
        return deliver;
    }
}

/// @notice Documented fee-on-transfer behavior: the swap reverts, or the event overstates the amount forwarded.
contract FeeOnTransferBuyTest is Base {
    uint256 constant USDG_IN = 50e6;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    FeeBuy fot;
    FoTRoute fotRoute;
    FairCore c;

    function setUp() public override {
        super.setUp();
        fot = new FeeBuy();
        fotRoute = new FoTRoute(fot, usdg);
        fot.mint(address(fotRoute), 1_000e6);
        GameConfig cfg = new GameConfig(
            owner, address(usdg), 0, Tokens(address(wif), PASS_LOCK, address(fot)), launchSplit()
        );
        c = new FairCore(usdg, IGameConfig(address(cfg)), pass, owner, 0);
        StubBooth b = new StubBooth(IFairCore(address(c)));
        vm.startPrank(owner);
        c.setupSet(FairCore.Op.AddBooth, 0, address(b));
        c.setupSet(FairCore.Op.SetKeeper, 0, keeper);
        c.setupSet(FairCore.Op.SetVault, 0, vaultAddr);
        c.setupSet(FairCore.Op.SetRoute, 0, address(fotRoute));
        c.resetRatchet(1e18); // 1 buy-token wei per USDG unit; floor is 95% of that
        c.finishSetup();
        c.setFair(0, uint64(block.timestamp + 1 hours), uint64(block.timestamp + 6 days));
        vm.stopPrank();
        vm.warp(block.timestamp + 1 hours);
        vm.prank(ana);
        usdg.approve(address(c), type(uint256).max);
        vm.prank(ana);
        b.shot(ana, 1, 2_000e6);
    }

    /// A 1% fee on the way in leaves FairCore short of minOut. The swap reverts ShortFill.
    function test_feeOnTransfer_inboundFee_shortFill() public {
        fotRoute.set(USDG_IN, false);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(FairCore.ShortFill.selector, 49_500_000, USDG_IN));
        c.burnBuyToken(FairCore.BurnSource.Bonfire, 0, USDG_IN, USDG_IN);
        assertEq(fot.balanceOf(address(c)), 0);
        assertEq(fot.balanceOf(DEAD), 0);
    }

    /// The delta clears minOut, then the forward takes another 1%. The event reports the delta, which is more than
    /// DEAD received.
    function test_feeOnTransfer_outboundFee_eventOverstates() public {
        uint256 deliver = 100_000_000; // core receives 99_000_000; DEAD receives 98_010_000
        fotRoute.set(deliver, false);
        uint256 d0 = fot.balanceOf(DEAD);
        vm.expectEmit(true, false, false, true, address(c));
        emit FairCore.Burned(address(fot), uint8(FairCore.BurnSource.Bonfire), 0, USDG_IN, 99_000_000, USDG_IN);
        vm.prank(keeper);
        uint256 out = c.burnBuyToken(FairCore.BurnSource.Bonfire, 0, USDG_IN, USDG_IN);
        assertEq(out, 99_000_000, "return value is FairCore's delta");
        assertEq(fot.balanceOf(DEAD) - d0, 98_010_000, "DEAD received less than the event reports");
        assertEq(fot.balanceOf(address(c)), 0);
    }

    /// A fee charged on top of the outbound amount reverts: FairCore forwards exactly its delta and has no surplus.
    function test_feeOnTransfer_feeOnTop_forwardReverts() public {
        fot.setMode(FeeBuy.Mode.OnTop);
        fotRoute.set(USDG_IN, true); // mint: no fee on the way in, so the delta equals minOut
        vm.prank(keeper);
        vm.expectRevert(FeeBuy.FeeOnTop.selector);
        c.buyForVault(0, USDG_IN, USDG_IN);
        assertEq(fot.balanceOf(address(c)), 0);
        assertEq(fot.balanceOf(vaultAddr), 0);
        assertGe(c.vaultBuyPending(), USDG_IN);
    }

    /// Vary the delivered amount. Under minOut the swap reverts ShortFill with the post-fee delta. At or above it,
    /// the event reports that delta and DEAD receives one fee less.
    function testFuzz_feeOnTransfer_deliver(uint256 deliver) public {
        deliver = bound(deliver, 100, 500_000_000);
        fotRoute.set(deliver, false);
        uint256 got = deliver - deliver / 100;
        if (got < USDG_IN) {
            vm.prank(keeper);
            vm.expectRevert(abi.encodeWithSelector(FairCore.ShortFill.selector, got, USDG_IN));
            c.burnBuyToken(FairCore.BurnSource.Bonfire, 0, USDG_IN, USDG_IN);
            assertEq(fot.balanceOf(address(c)), 0);
            assertEq(fot.balanceOf(DEAD), 0);
        } else {
            vm.prank(keeper);
            uint256 out = c.burnBuyToken(FairCore.BurnSource.Bonfire, 0, USDG_IN, USDG_IN);
            assertEq(out, got);
            assertEq(fot.balanceOf(DEAD), got - got / 100);
            assertEq(fot.balanceOf(address(c)), 0);
        }
    }

    /// The fee rate is not fixed at 1%. `out` is the post-fee delta; DEAD receives that amount minus one more fee.
    function testFuzz_feeOnTransfer_rate(uint256 deliver, uint256 bps) public {
        bps = bound(bps, 1, 2_000);
        deliver = bound(deliver, 10_000, 400_000_000);
        fot.setFeeBps(bps);
        fotRoute.set(deliver, false);
        uint256 got = deliver - deliver * bps / 10_000;
        if (got < USDG_IN) {
            vm.prank(keeper);
            vm.expectRevert(abi.encodeWithSelector(FairCore.ShortFill.selector, got, USDG_IN));
            c.burnBuyToken(FairCore.BurnSource.Bonfire, 0, USDG_IN, USDG_IN);
            assertEq(fot.balanceOf(DEAD), 0);
        } else {
            vm.prank(keeper);
            uint256 out = c.burnBuyToken(FairCore.BurnSource.Bonfire, 0, USDG_IN, USDG_IN);
            uint256 onward = got * bps / 10_000;
            assertEq(out, got);
            assertEq(fot.balanceOf(DEAD), got - onward);
        }
    }
}
