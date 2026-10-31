// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {AcceptBase} from "../../script/SafeAccept.s.sol";
import {FeeSplitter} from "../../src/FeeSplitter.sol";
import {RakeBuyer} from "../../src/RakeBuyer.sol";
import {FairCore} from "../../src/FairCore.sol";
import {GameConfig} from "../../src/GameConfig.sol";
import {FairPass} from "../../src/FairPass.sol";
import {IGameConfig, Tokens, Split} from "../../src/interfaces/IFair.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockToken} from "../mocks/Mocks.sol";

/// @dev Has code, so a plain transfer here can be forwarded onward.
contract ForwarderPayee {
    function sweep(address token, address to) external {
        IERC20(token).transfer(to, IERC20(token).balanceOf(address(this)));
    }
}

contract PayeeCheckHarness is AcceptBase {
    function check(FeeSplitter fs, RakeBuyer b, FairCore core_, address[] calldata allow) external view {
        D memory d;
        d.feeSplitter = fs;
        d.rakeBuyer = b;
        d.core = core_;
        _assertSplitterAndForward(d, allow);
    }
}

contract PayeeAcceptTest is Test {
    address owner = makeAddr("owner");
    MockToken usdg;
    MockToken wif;
    GameConfig config;
    FairPass pass;
    FairCore core;
    RakeBuyer buyer;
    PayeeCheckHarness harness;
    address vaultEoa = makeAddr("vaultEoa");

    function setUp() public {
        usdg = new MockToken("USDG", "USDG", 6);
        wif = new MockToken("WIF", "WIF", 18);
        config = new GameConfig(
            owner, address(usdg), 0, Tokens(address(wif), 5_000e18, address(wif)), Split(6000, 2000, 1750, 1750, 2500, 2500, 2500)
        );
        pass = new FairPass(IGameConfig(address(config)), owner);
        core = new FairCore(usdg, IGameConfig(address(config)), pass, owner, 0);
        buyer = new RakeBuyer(usdg, IGameConfig(address(config)), vaultEoa, owner, 0, address(core));
        harness = new PayeeCheckHarness();
    }

    function _legs(address ops) internal returns (FeeSplitter.Recipients memory) {
        return FeeSplitter.Recipients({
            purses: makeAddr("purses"),
            vault: vaultEoa,
            rebate: makeAddr("rebate"),
            burnBuyer: makeAddr("burnBuyer"),
            ops: ops
        });
    }

    function _split() internal pure returns (FeeSplitter.FeeSplit memory) {
        return FeeSplitter.FeeSplit(4000, 2500, 1500, 1000, 1000);
    }

    /// A payee with code that is not the vault or DEAD fails acceptance. EOAs and a matching FeeSplitter pass.
    function test_safeAccept_rejectsForwarderPayee() public {
        address[] memory allow = new address[](1);
        allow[0] = 0x000000000000000000000000000000000000dEaD;
        FeeSplitter ok = new FeeSplitter(
            address(wif), owner, _legs(makeAddr("ops")), _split(), address(core), address(buyer)
        );
        harness.check(ok, buyer, core, allow);

        ForwarderPayee fwd = new ForwarderPayee();
        FeeSplitter bad = new FeeSplitter(address(wif), owner, _legs(address(fwd)), _split(), address(core), address(buyer));
        vm.expectRevert(bytes("feeSplitter ops: contract payee"));
        harness.check(bad, buyer, core, allow);

        vm.prank(owner);
        buyer.setupSet(RakeBuyer.Op.SetForwardTo, 0, address(fwd));
        vm.expectRevert(bytes("rakeBuyer forwardTo: contract payee"));
        harness.check(ok, buyer, core, allow);
    }

    function test_safeAccept_feeSplitterImmutables() public {
        address[] memory allow = new address[](1);
        allow[0] = 0x000000000000000000000000000000000000dEaD;
        FeeSplitter wrongCore =
            new FeeSplitter(address(wif), owner, _legs(makeAddr("ops2")), _split(), makeAddr("otherCore"), address(buyer));
        vm.expectRevert(bytes("feeSplitter fairCore"));
        harness.check(wrongCore, buyer, core, allow);
        FeeSplitter wrongBuyer =
            new FeeSplitter(address(wif), owner, _legs(makeAddr("ops3")), _split(), address(core), makeAddr("otherBuyer"));
        vm.expectRevert(bytes("feeSplitter rakeBuyer"));
        harness.check(wrongBuyer, buyer, core, allow);
    }
}
