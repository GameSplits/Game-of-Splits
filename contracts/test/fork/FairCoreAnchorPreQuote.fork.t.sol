// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FairCore} from "../../src/FairCore.sol";
import {FairCoreAnchorGriefFork} from "./FairCoreAnchorGrief.fork.t.sol";
import {AnchorSwapper} from "./RakeAnchorGrief.fork.t.sol";

/// FC-01 regression on a Robinhood mainnet fork: a WIF dump before the keeper quotes must not
/// freeze later honest buys. Skips when the RPC is down.
contract FairCoreAnchorPreQuoteFork is FairCoreAnchorGriefFork {
    function _run(uint256 dumpWif) internal returns (uint256 frozenHours, uint256 anchorX1000) {
        uint256 market = quoteA(50e6);
        address att = makeAddr("attacker");
        AnchorSwapper s = new AnchorSwapper(PM, wifPool);
        deal(WIF, att, dumpWif);
        vm.startPrank(att);
        IERC20(WIF).approve(address(s), type(uint256).max);
        uint256 ethGot = s.swap(false, dumpWif);
        vm.stopPrank();

        uint256 q = quoteA(50e6);
        uint256 minOut = q * 9850 / 10_000;
        vm.prank(keeper);
        core.burnBuyToken(FairCore.BurnSource.Bonfire, 0, 50e6, minOut);
        anchorX1000 = core.anchorRate() * 1000 / (market * 1e18 / 50e6);

        vm.deal(att, ethGot);
        vm.prank(att);
        s.swap{value: ethGot}(true, ethGot);

        for (uint256 h; h < 48; ++h) {
            vm.warp(vm.getBlockTimestamp() + 1 hours);
            uint256 live = quoteA(50e6);
            uint256 floor = 50e6 * core.ratchetFloorRate() / 1e18;
            if (live >= floor) {
                uint256 mo = live * 9850 / 10_000;
                if (mo < floor) mo = floor;
                vm.prank(keeper);
                try core.burnBuyToken(FairCore.BurnSource.Bonfire, 0, 50e6, mo) {
                    break;
                } catch {}
            }
            ++frozenHours;
        }
    }

    function test_FC01_fork_preQuoteDump_capped() public {
        if (!forked) {
            vm.skip(true, "robinhood RPC unavailable");
            return;
        }
        uint256[5] memory sizes = [uint256(1_000_000e18), 5_000_000e18, 10_000_000e18, 20_000_000e18, 50_000_000e18];
        uint256 snap = vm.snapshotState();
        uint256 maxFrozen;
        for (uint256 i; i < sizes.length; ++i) {
            (uint256 fh, uint256 ax) = _run(sizes[i]);
            emit log_named_uint("dump WIF (whole)", sizes[i] / 1e18);
            emit log_named_uint("  anchor / market x1000", ax);
            emit log_named_uint("  frozen hours", fh);
            assertLe(ax, 1020, "anchor/market stays within the 2% cap");
            if (fh > maxFrozen) maxFrozen = fh;
            vm.revertToState(snap);
        }
        assertEq(maxFrozen, 0, "pre-quote dumps do not freeze honest buys");
    }
}
