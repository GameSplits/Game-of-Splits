// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FeeSplitter} from "../../src/FeeSplitter.sol";

/// @notice Robinhood Chain fork: real $wif is dealt to the splitter and the burn leg lands on 0x...dEaD.
///         Skips when the robinhood RPC in foundry.toml is unreachable. Read-only against mainnet.
contract FeeSplitterForkTest is Test {
    address constant WIF = 0x5173b8eA6923c2d40267890D45C46a3480954773;
    uint256 constant AMOUNT = 1_000e18;

    FeeSplitter splitter;
    bool forked;
    address purses = makeAddr("purses");
    address vault = makeAddr("vault");
    address rebate = makeAddr("rebate");
    address burnBuyer = makeAddr("burnBuyer");
    address ops = makeAddr("ops");

    function setUp() public {
        try vm.createSelectFork("robinhood") returns (uint256) {
            forked = true;
        } catch {
            return;
        }
        splitter = new FeeSplitter(
            WIF,
            makeAddr("ownerSafe"),
            FeeSplitter.Recipients(purses, vault, rebate, burnBuyer, ops),
            FeeSplitter.FeeSplit(4000, 2500, 1500, 1000, 1000),
            makeAddr("fairCore"),
            makeAddr("rakeBuyer")
        );
    }

    function test_fork_wifDistribute_burnReachesDead() public {
        if (!forked) {
            vm.skip(true, "robinhood RPC unavailable");
            return;
        }
        assertEq(block.chainid, 4663);
        uint256 deadBefore = IERC20(WIF).balanceOf(splitter.DEAD());
        uint256 buyerBefore = IERC20(WIF).balanceOf(burnBuyer);

        deal(WIF, address(splitter), AMOUNT);
        if (IERC20(WIF).balanceOf(address(splitter)) != AMOUNT) {
            vm.skip(true, "deal() did not credit real $wif");
            return;
        }

        splitter.distribute(WIF);

        assertEq(IERC20(WIF).balanceOf(address(splitter)), 0, "full balance clears");
        assertEq(IERC20(WIF).balanceOf(splitter.DEAD()) - deadBefore, AMOUNT * 1000 / 10_000);
        assertEq(IERC20(WIF).balanceOf(burnBuyer), buyerBefore, "non-dead burn buyer gets no $wif");
        assertEq(IERC20(WIF).balanceOf(purses), AMOUNT * 4000 / 10_000);
        assertEq(IERC20(WIF).balanceOf(vault), AMOUNT * 2500 / 10_000);
        assertEq(IERC20(WIF).balanceOf(rebate), AMOUNT * 1500 / 10_000);
        assertEq(IERC20(WIF).balanceOf(ops), AMOUNT - (AMOUNT * 9000 / 10_000));
    }
}
