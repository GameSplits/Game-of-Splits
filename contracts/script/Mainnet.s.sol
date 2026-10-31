// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Script, console2} from "forge-std/Script.sol";
import {PoolKey, IV4Quoter, QuoteExactSingleParams} from "../src/interfaces/IV4Minimal.sol";
import {L2Head} from "./L2.s.sol";

/// Robinhood Chain mainnet (4663) addresses and the anchor price helpers shared by the deploy, quote and Safe scripts.
abstract contract MainnetAddrs is L2Head {
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168; // 6 dp. NEVER 0x8218d73C...BB5b4 (18 dp)
    address constant WIF = 0x5173b8eA6923c2d40267890D45C46a3480954773;
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant PM = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant QUOTER = 0x8Dc178eFB8111BB0973Dd9d722ebeFF267c98F94; // V4Quoter
    address constant V3_POOL = 0x52e65B17fB6E5BA00Ed806f37Afcd2DaA50271Ca; // USDG/WETH 0.01%
    address constant WIF_HOOK = 0xE5e702641Ea86F4ae6cC3cDaeD2B886f976Be044; // PonsV2MemeHook
    address constant USDG_HOOK = 0x06a889870C8f83640D6816319f72e2aA579b6080; // FablesRampETH

    /// How far the seed may sit from the live quote. The seed itself must come from a 30-minute average.
    uint256 constant SEED_TOLERANCE_BPS = 2000; // ±20%
    uint256 constant QUOTE_USDG = 100e6;

    function _usdgPool() internal pure returns (PoolKey memory) {
        return PoolKey(address(0), USDG, 0x800000, 10, USDG_HOOK);
    }

    function _wifPool() internal pure returns (PoolKey memory) {
        return PoolKey(address(0), WIF, 0, 200, WIF_HOOK);
    }

    /// Route A's live rate for 100 USDG through an ETH/token v4 pool, in the anchor's units (token wei per USDG unit,
    /// x1e18). Simulation only: call it outside vm.startBroadcast so it never becomes a transaction.
    function _liveRateFor(PoolKey memory outPool) internal returns (uint256) {
        (uint256 eth,) =
            IV4Quoter(QUOTER).quoteExactInputSingle(QuoteExactSingleParams(_usdgPool(), false, uint128(QUOTE_USDG), ""));
        (uint256 out,) =
            IV4Quoter(QUOTER).quoteExactInputSingle(QuoteExactSingleParams(outPool, true, uint128(eth), ""));
        return out * 1e18 / QUOTE_USDG;
    }

    function _liveRate() internal returns (uint256) {
        return _liveRateFor(_wifPool());
    }

    /// The seed must be non-zero and within ±20% of the live quote; anything else is a typo or a bad average.
    function _checkSeed(uint256 seed) internal returns (uint256 live) {
        require(seed != 0, "ANCHOR_SEED missing");
        live = _liveRate();
        uint256 lo = live * (10_000 - SEED_TOLERANCE_BPS) / 10_000;
        uint256 hi = live * (10_000 + SEED_TOLERANCE_BPS) / 10_000;
        console2.log("anchor seed      ", seed);
        console2.log("live quote (A)   ", live);
        require(seed >= lo && seed <= hi, "ANCHOR_SEED more than 20% from the live quote");
    }
}

/// Read-only. Prints route A's live rate in the anchor's units. Run it every 5 minutes for 30 minutes and average the
/// six readings to get ANCHOR_SEED (never seed from a single reading). No key, no `--account`, no hardware wallet.
///   forge script script/Mainnet.s.sol:QuoteAnchor --rpc-url robinhood
/// For another ETH/token v4 pool set POOL_TOKEN, POOL_FEE, POOL_TICK_SPACING and POOL_HOOK.
contract QuoteAnchor is MainnetAddrs {
    function run() external {
        require(block.chainid == 4663, "mainnet only");
        address t = vm.envOr("POOL_TOKEN", address(0));
        uint256 r = t == address(0)
            ? _liveRate()
            : _liveRateFor(
                PoolKey(
                    address(0),
                    t,
                    uint24(vm.envUint("POOL_FEE")),
                    int24(vm.envInt("POOL_TICK_SPACING")),
                    vm.envAddress("POOL_HOOK")
                )
            );
        console2.log("block timestamp", block.timestamp);
        console2.log("route A rate, token wei per USDG unit x1e18:", r);
        console2.log("i.e. tokens per USDG:", r / 1e30);
    }
}
