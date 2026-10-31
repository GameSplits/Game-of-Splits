// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {FeeSplitter} from "../../src/FeeSplitter.sol";
import {Base} from "../Base.t.sol";
import {LocksleyVault, ICoreVaultUsdg} from "../../src/LocksleyVault.sol";
import {FairCore} from "../../src/FairCore.sol";

contract FeeSplitterTest is Test {
    uint16 constant PURSE = 4000;
    uint16 constant VAULT = 2500;
    uint16 constant REBATE = 1500;
    uint16 constant BURN = 1000;
    uint16 constant OPS = 1000;

    FeeSplitter splitter;
    ERC20Harness fee;
    ERC20Harness wif;

    address owner = makeAddr("ownerSafe");
    address purses = makeAddr("purses");
    address vault = makeAddr("vault");
    address rebate = makeAddr("rebate");
    address burnBuyer = makeAddr("burnBuyer");
    address ops = makeAddr("ops");
    address stranger = makeAddr("stranger");

    function setUp() public {
        fee = new ERC20Harness("Fee", "FEE");
        wif = new ERC20Harness("World is Flat", "WIF");
        splitter = _deploy(owner, _recipients(purses, vault, rebate, burnBuyer, ops), _launch(), address(wif));
    }

    // ---------------------------------------------------------------- constructor

    function test_constructor_setsImmutablesRecipientsAndSplit() public view {
        assertEq(splitter.owner(), owner);
        assertEq(splitter.wif(), address(wif));
        assertEq(splitter.purses(), purses);
        assertEq(splitter.vault(), vault);
        assertEq(splitter.rebate(), rebate);
        assertEq(splitter.burnBuyer(), burnBuyer);
        assertEq(splitter.ops(), ops);
        assertEq(splitter.pursesBps(), PURSE);
        assertEq(splitter.vaultBps(), VAULT);
        assertEq(splitter.rebateBps(), REBATE);
        assertEq(splitter.burnBps(), BURN);
        assertEq(splitter.opsBps(), OPS);
        assertEq(splitter.TIMELOCK(), 7 days);
        assertEq(splitter.DEAD(), 0x000000000000000000000000000000000000dEaD);
    }

    function test_constructor_rejectsZeroWif() public {
        vm.expectRevert(FeeSplitter.ZeroAddress.selector);
        _deploy(owner, _recipients(purses, vault, rebate, burnBuyer, ops), _launch(), address(0));
    }

    function test_constructor_rejectsZeroOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        _deploy(address(0), _recipients(purses, vault, rebate, burnBuyer, ops), _launch(), address(wif));
    }

    function test_constructor_rejectsZeroRecipient(uint8 which) public {
        which = uint8(bound(which, 0, 4));
        FeeSplitter.Recipients memory r = _recipients(purses, vault, rebate, burnBuyer, ops);
        if (which == 0) r.purses = address(0);
        else if (which == 1) r.vault = address(0);
        else if (which == 2) r.rebate = address(0);
        else if (which == 3) r.burnBuyer = address(0);
        else r.ops = address(0);
        vm.expectRevert(FeeSplitter.ZeroAddress.selector);
        _deploy(owner, r, _launch(), address(wif));
    }

    function test_constructor_rejectsSelfRecipient() public {
        FeeSplitter.Recipients memory r = _recipients(purses, vault, rebate, burnBuyer, ops);
        SplitterFactory factory = new SplitterFactory();
        // The first CREATE from the factory is the splitter, so a recipient can be set to its own address.
        r.ops = vm.computeCreateAddress(address(factory), vm.getNonce(address(factory)));
        vm.expectRevert(FeeSplitter.BadRecipient.selector);
        factory.deploy(address(wif), owner, r, _launch());
    }

    function test_constructor_rejectsBadSplit() public {
        FeeSplitter.FeeSplit memory s = _launch();
        s.opsBps = 999;
        vm.expectRevert(FeeSplitter.BadSplit.selector);
        _deploy(owner, _recipients(purses, vault, rebate, burnBuyer, ops), s, address(wif));
        s = _launch();
        s.opsBps = 1001;
        vm.expectRevert(FeeSplitter.BadSplit.selector);
        _deploy(owner, _recipients(purses, vault, rebate, burnBuyer, ops), s, address(wif));
    }

    function testFuzz_constructor_rejectsSplitNot10000(uint16 a, uint16 b, uint16 c, uint16 d, uint16 e) public {
        vm.assume(uint256(a) + b + c + d + e != 10_000);
        vm.expectRevert(FeeSplitter.BadSplit.selector);
        _deploy(
            owner, _recipients(purses, vault, rebate, burnBuyer, ops), FeeSplitter.FeeSplit(a, b, c, d, e), address(wif)
        );
    }

    // ---------------------------------------------------------------- receive and distribute

    function test_receive_acceptsEth_calldataIsRejected_distributeIsNotPayable() public {
        vm.deal(address(this), 2 ether);
        (bool ok,) = address(splitter).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(address(splitter).balance, 1 ether);

        (ok,) = address(splitter).call{value: 0}(hex"1234");
        assertFalse(ok);

        (ok,) = address(splitter).call{value: 1 ether}(abi.encodeCall(splitter.distribute, (address(0))));
        assertFalse(ok, "value on distribute must revert, so the fee and the call stay separate");
        assertEq(address(splitter).balance, 1 ether);
    }

    function test_distribute_erc20_launchSplit_exactAndEvent() public {
        uint256 amount = 1_000_000e18;
        fee.mint(address(splitter), amount);
        (uint256 p, uint256 v, uint256 r, uint256 b, uint256 o) = _legs(amount, PURSE, VAULT, REBATE, BURN);
        vm.expectEmit(true, true, false, true, address(splitter));
        emit FeeSplitter.Distributed(address(fee), burnBuyer, p, v, r, b, o);
        splitter.distribute(address(fee));
        _assertLegs(fee, address(0), p, v, r, b, o, burnBuyer);
        assertEq(fee.balanceOf(address(splitter)), 0);
        assertEq(p + v + r + b + o, amount);
        assertEq(fee.balanceOf(splitter.DEAD()), 0);
    }

    function test_distribute_eth_launchSplit_burnGoesToBurnBuyer() public {
        uint256 amount = 5 ether;
        vm.deal(address(splitter), amount);
        uint256 deadBefore = splitter.DEAD().balance;
        (uint256 p, uint256 v, uint256 r, uint256 b, uint256 o) = _legs(amount, PURSE, VAULT, REBATE, BURN);
        (uint256 gp, uint256 gv, uint256 gr, uint256 gb, uint256 go, address burnTo) = splitter.quote(address(0));
        assertEq(burnTo, burnBuyer);
        assertEq(gp, p);
        assertEq(gv, v);
        assertEq(gr, r);
        assertEq(gb, b);
        assertEq(go, o);
        splitter.distribute(address(0));
        assertEq(purses.balance, p);
        assertEq(vault.balance, v);
        assertEq(rebate.balance, r);
        assertEq(burnBuyer.balance, b);
        assertEq(ops.balance, o);
        assertEq(address(splitter).balance, 0);
        assertEq(splitter.DEAD().balance, deadBefore);
        assertEq(p + v + r + b + o, amount);
    }

    function test_distribute_wifBurnsToDead_notBurnBuyer() public {
        uint256 amount = 10_000e18;
        wif.mint(address(splitter), amount);
        (uint256 p, uint256 v, uint256 r, uint256 b, uint256 o, address burnTo) = splitter.quote(address(wif));
        assertEq(burnTo, splitter.DEAD());
        splitter.distribute(address(wif));
        assertEq(wif.balanceOf(purses), p);
        assertEq(wif.balanceOf(vault), v);
        assertEq(wif.balanceOf(rebate), r);
        assertEq(wif.balanceOf(splitter.DEAD()), b);
        assertEq(wif.balanceOf(burnBuyer), 0);
        assertEq(wif.balanceOf(ops), o);
        assertEq(wif.balanceOf(address(splitter)), 0);
        assertEq(b, amount * BURN / 10_000);
    }

    function test_distribute_dustGoesToOps_andTinyBalanceDoesToo() public {
        fee.mint(address(splitter), 9999);
        splitter.distribute(address(fee));
        // 9999 * bps floors leave 4 wei, all of it on top of the ops floor (999).
        assertEq(fee.balanceOf(purses), 3999);
        assertEq(fee.balanceOf(vault), 2499);
        assertEq(fee.balanceOf(rebate), 1499);
        assertEq(fee.balanceOf(splitter.DEAD()), 0);
        assertEq(fee.balanceOf(burnBuyer), 999);
        assertEq(fee.balanceOf(ops), 1003);
        assertEq(fee.balanceOf(address(splitter)), 0);
        assertEq(
            fee.balanceOf(purses) + fee.balanceOf(vault) + fee.balanceOf(rebate) + fee.balanceOf(burnBuyer)
                + fee.balanceOf(ops),
            9999
        );

        fee.mint(address(splitter), 1);
        splitter.distribute(address(fee));
        assertEq(fee.balanceOf(ops), 1004, "1 wei is entirely dust, paid to ops");
        assertEq(fee.balanceOf(purses), 3999);
    }

    function test_distribute_zeroOpsBps_stillPaysDustToOps() public {
        FeeSplitter s = _deploy(
            owner,
            _recipients(purses, vault, rebate, burnBuyer, ops),
            FeeSplitter.FeeSplit(2500, 2500, 2500, 2500, 0),
            address(wif)
        );
        fee.mint(address(s), 3);
        s.distribute(address(fee));
        assertEq(fee.balanceOf(address(s)), 0);
        assertEq(fee.balanceOf(purses), 0);
        assertEq(fee.balanceOf(ops), 3, "every floor is 0, so ops receives the whole dust balance");
    }

    function test_distribute_oneTokenLeavesTheOther() public {
        fee.mint(address(splitter), 10_000);
        wif.mint(address(splitter), 10_000);
        vm.deal(address(splitter), 10_000);
        splitter.distribute(address(fee));
        assertEq(fee.balanceOf(address(splitter)), 0);
        assertEq(wif.balanceOf(address(splitter)), 10_000);
        assertEq(address(splitter).balance, 10_000);
        splitter.distribute(address(wif));
        assertEq(address(splitter).balance, 10_000);
        assertEq(wif.balanceOf(splitter.DEAD()), 1000);
        splitter.distribute(address(0));
        assertEq(address(splitter).balance, 0);
    }

    function test_distribute_sameRecipientGetsEachLegOnce() public {
        address all = makeAddr("all");
        FeeSplitter s = _deploy(owner, _recipients(all, all, all, all, all), _launch(), address(wif));
        fee.mint(address(s), 123_456);
        s.distribute(address(fee));
        assertEq(fee.balanceOf(all), 123_456);
        assertEq(fee.balanceOf(address(s)), 0);
    }

    function test_distribute_zeroBalanceReverts_secondCallReverts() public {
        vm.expectRevert(FeeSplitter.ZeroAmount.selector);
        splitter.distribute(address(fee));
        vm.expectRevert(FeeSplitter.ZeroAmount.selector);
        splitter.distribute(address(0));
        fee.mint(address(splitter), 10_000);
        splitter.distribute(address(fee));
        vm.expectRevert(FeeSplitter.ZeroAmount.selector);
        splitter.distribute(address(fee));
    }

    /// A3-09: a token whose transfer returns false escrows every leg; nothing is split twice.
    function test_distribute_transferReturnsFalse_escrowsLegs_notSplitAgain() public {
        FalseToken bad = new FalseToken();
        splitter.distribute(address(bad));
        assertEq(splitter.escrowTotal(address(bad)), 100);
        assertEq(splitter.owed(address(bad), purses), 40);
        assertEq(splitter.owed(address(bad), ops), 10);
        vm.expectRevert(FeeSplitter.ZeroAmount.selector);
        splitter.distribute(address(bad));
    }

    /// A3-09: an ETH-rejecting recipient no longer blocks the other four legs; its leg waits in escrow.
    function test_distribute_rejectingEthRecipient_escrowsOnlyThatLeg() public {
        RejectEth reject = new RejectEth();
        FeeSplitter s =
            _deploy(owner, _recipients(address(reject), vault, rebate, burnBuyer, ops), _launch(), address(wif));
        vm.deal(address(s), 1 ether);
        s.distribute(address(0));
        assertEq(address(s).balance, 0.4 ether, "purses leg stays");
        assertEq(s.owed(address(0), address(reject)), 0.4 ether);
        assertEq(vault.balance, 0.25 ether);
        assertEq(ops.balance, 0.1 ether);
        vm.expectRevert(FeeSplitter.EthTransferFailed.selector);
        s.claimEscrow(address(0), address(reject));
        assertEq(s.owed(address(0), address(reject)), 0.4 ether, "failed claim keeps the escrow");
    }

    function test_distribute_reentrancyEthAndErc20Revert() public {
        ReenterEth attacker = new ReenterEth();
        FeeSplitter s =
            _deploy(owner, _recipients(address(attacker), vault, rebate, burnBuyer, ops), _launch(), address(wif));
        attacker.setSplitter(s);
        vm.deal(address(s), 1 ether);
        s.distribute(address(0)); // the reentering leg fails (ReentrancyGuard) and is escrowed; nothing pays twice
        assertEq(address(s).balance, 0.4 ether, "only the attacker's leg stays");
        assertEq(s.escrowTotal(address(0)), 0.4 ether);
        assertEq(vault.balance, 0.25 ether);

        ReenterToken hook = new ReenterToken();
        FeeSplitter s2 = _deploy(owner, _recipients(purses, vault, rebate, burnBuyer, ops), _launch(), address(wif));
        hook.mint(address(s2), 10_000e18);
        hook.arm(s2);
        s2.distribute(address(hook)); // every transfer reenters and reverts: all five legs escrowed
        assertEq(hook.balanceOf(address(s2)), 10_000e18);
        assertEq(s2.escrowTotal(address(hook)), 10_000e18);
        vm.expectRevert(FeeSplitter.ZeroAmount.selector);
        s2.distribute(address(hook));
    }

    function test_distribute_gas() public {
        fee.mint(address(splitter), 1_000_000e18);
        splitter.distribute(address(fee));
        uint256 coldErc20 = _lastGas();
        fee.mint(address(splitter), 1_000_000e18);
        splitter.distribute(address(fee));
        uint256 warmErc20 = _lastGas();

        vm.deal(address(splitter), 1 ether);
        splitter.distribute(address(0));
        uint256 coldEth = _lastGas();
        vm.deal(address(splitter), 1 ether);
        splitter.distribute(address(0));
        uint256 warmEth = _lastGas();

        console2.log("distribute ERC20 cold", coldErc20);
        console2.log("distribute ERC20 warm", warmErc20);
        console2.log("distribute ETH cold", coldEth);
        console2.log("distribute ETH warm", warmEth);
        assertGt(coldErc20, warmErc20);
        assertGt(coldEth, 0);
        assertGt(warmEth, 0);
    }

    function testFuzz_erc20_sumPaidEqualsBalance(uint256 amt, uint16 a, uint16 b, uint16 c, uint16 d) public {
        amt = bound(amt, 1, type(uint256).max / 10_000);
        (uint16 pa, uint16 va, uint16 ra, uint16 ba, uint16 oa) = _boundedSplit(a, b, c, d);
        FeeSplitter s = _deploy(
            owner,
            _recipients(purses, vault, rebate, burnBuyer, ops),
            FeeSplitter.FeeSplit(pa, va, ra, ba, oa),
            address(wif)
        );
        fee.mint(address(s), amt);
        uint256 p0 = fee.balanceOf(purses);
        uint256 v0 = fee.balanceOf(vault);
        uint256 r0 = fee.balanceOf(rebate);
        uint256 b0 = fee.balanceOf(burnBuyer);
        uint256 o0 = fee.balanceOf(ops);
        uint256 before = fee.balanceOf(address(s));
        s.distribute(address(fee));
        (uint256 p, uint256 v, uint256 r, uint256 burn, uint256 o) = _legs(before, pa, va, ra, ba);
        assertEq(p + v + r + burn + o, before, "sum paid == balance before");
        assertEq(fee.balanceOf(address(s)), 0);
        assertEq(fee.balanceOf(purses) - p0, p);
        assertEq(fee.balanceOf(vault) - v0, v);
        assertEq(fee.balanceOf(rebate) - r0, r);
        assertEq(fee.balanceOf(burnBuyer) - b0, burn);
        assertEq(fee.balanceOf(ops) - o0, o);
        uint256 opsFloor = before * oa / 10_000;
        assertGe(o, opsFloor);
        assertLe(o - opsFloor, 4);
    }

    function testFuzz_eth_sumPaidEqualsBalance(uint256 amt, uint16 a, uint16 b, uint16 c, uint16 d) public {
        amt = bound(amt, 1, type(uint256).max / 10_000);
        (uint16 pa, uint16 va, uint16 ra, uint16 ba, uint16 oa) = _boundedSplit(a, b, c, d);
        FeeSplitter s = _deploy(
            owner,
            _recipients(purses, vault, rebate, burnBuyer, ops),
            FeeSplitter.FeeSplit(pa, va, ra, ba, oa),
            address(wif)
        );
        vm.deal(address(s), amt);
        uint256 p0 = purses.balance;
        uint256 v0 = vault.balance;
        uint256 r0 = rebate.balance;
        uint256 b0 = burnBuyer.balance;
        uint256 o0 = ops.balance;
        s.distribute(address(0));
        (uint256 p, uint256 v, uint256 r, uint256 burn, uint256 o) = _legs(amt, pa, va, ra, ba);
        assertEq(p + v + r + burn + o, amt, "sum paid == balance before");
        assertEq(address(s).balance, 0);
        assertEq(purses.balance - p0, p);
        assertEq(vault.balance - v0, v);
        assertEq(rebate.balance - r0, r);
        assertEq(burnBuyer.balance - b0, burn);
        assertEq(ops.balance - o0, o);
        assertLe(o - (amt * oa / 10_000), 4);
    }

    function testFuzz_wif_burnReachesDead(uint256 amt) public {
        amt = bound(amt, 1, type(uint96).max);
        wif.mint(address(splitter), amt);
        uint256 deadBefore = wif.balanceOf(splitter.DEAD());
        uint256 buyerBefore = wif.balanceOf(burnBuyer);
        splitter.distribute(address(wif));
        uint256 burn = amt * BURN / 10_000;
        // Ops holds the dust, so the dead transfer is the exact floor, not the remainder.
        assertEq(wif.balanceOf(splitter.DEAD()) - deadBefore, burn);
        assertEq(wif.balanceOf(burnBuyer), buyerBefore);
        assertEq(wif.balanceOf(address(splitter)), 0);
    }

    // ---------------------------------------------------------------- timelock

    function test_timelock_queueExecuteRecipient_andEvents() public {
        address next = makeAddr("nextPurses");
        bytes32 id = splitter.opId(FeeSplitter.Op.SetPurses, 0, next);
        uint256 eta = block.timestamp + 7 days;
        vm.expectEmit(true, false, false, true, address(splitter));
        emit FeeSplitter.ChangeQueued(id, FeeSplitter.Op.SetPurses, 0, next, eta);
        vm.prank(owner);
        assertEq(splitter.queue(FeeSplitter.Op.SetPurses, 0, next), id);
        assertEq(splitter.queuedAt(id), eta);

        fee.mint(address(splitter), 10_000);
        splitter.distribute(address(fee));
        assertEq(fee.balanceOf(purses), 4000, "queued change does not apply early");
        assertEq(fee.balanceOf(next), 0);

        vm.warp(eta);
        vm.expectEmit(true, true, false, true, address(splitter));
        emit FeeSplitter.RecipientUpdated(FeeSplitter.Op.SetPurses, next);
        vm.expectEmit(true, false, false, true, address(splitter));
        emit FeeSplitter.ChangeExecuted(id, FeeSplitter.Op.SetPurses, 0, next);
        vm.prank(owner);
        splitter.execute(FeeSplitter.Op.SetPurses, 0, next);
        assertEq(splitter.purses(), next);
        assertEq(splitter.queuedAt(id), 0);

        fee.mint(address(splitter), 10_000);
        splitter.distribute(address(fee));
        assertEq(fee.balanceOf(next), 4000);
        assertEq(fee.balanceOf(purses), 4000);
    }

    function test_timelock_tooEarly_exactEta_andCancel() public {
        address next = makeAddr("nextVault");
        vm.prank(owner);
        bytes32 id = splitter.queue(FeeSplitter.Op.SetVault, 0, next);
        uint256 eta = splitter.queuedAt(id);

        vm.warp(eta - 1);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(FeeSplitter.TooEarly.selector, eta));
        splitter.execute(FeeSplitter.Op.SetVault, 0, next);
        assertEq(splitter.vault(), vault);

        vm.warp(eta);
        vm.prank(owner);
        splitter.execute(FeeSplitter.Op.SetVault, 0, next);
        assertEq(splitter.vault(), next);

        vm.prank(owner);
        vm.expectRevert(FeeSplitter.NotQueued.selector);
        splitter.execute(FeeSplitter.Op.SetVault, 0, next);
        vm.prank(owner);
        vm.expectRevert(FeeSplitter.NotQueued.selector);
        splitter.cancel(id);
    }

    function test_timelock_cancel_thenCannotExecute() public {
        address next = makeAddr("nextRebate");
        vm.prank(owner);
        bytes32 id = splitter.queue(FeeSplitter.Op.SetRebate, 0, next);
        vm.expectEmit(true, false, false, true, address(splitter));
        emit FeeSplitter.ChangeCancelled(id);
        vm.prank(owner);
        splitter.cancel(id);
        assertEq(splitter.queuedAt(id), 0);
        vm.warp(block.timestamp + 8 days);
        vm.prank(owner);
        vm.expectRevert(FeeSplitter.NotQueued.selector);
        splitter.execute(FeeSplitter.Op.SetRebate, 0, next);
        assertEq(splitter.rebate(), rebate);
    }

    function test_timelock_requeueResetsEta() public {
        address next = makeAddr("nextOps");
        vm.prank(owner);
        bytes32 id = splitter.queue(FeeSplitter.Op.SetOps, 0, next);
        uint256 first = splitter.queuedAt(id);
        vm.warp(block.timestamp + 6 days);
        vm.prank(owner);
        splitter.queue(FeeSplitter.Op.SetOps, 0, next);
        uint256 second = splitter.queuedAt(id);
        assertEq(second, block.timestamp + 7 days);
        assertGt(second, first);
        vm.warp(second - 1);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(FeeSplitter.TooEarly.selector, second));
        splitter.execute(FeeSplitter.Op.SetOps, 0, next);
        vm.warp(second);
        vm.prank(owner);
        splitter.execute(FeeSplitter.Op.SetOps, 0, next);
        assertEq(splitter.ops(), next);
    }

    function test_timelock_twoOpsStayIndependent() public {
        address nextP = makeAddr("p2");
        address nextB = makeAddr("b2");
        vm.startPrank(owner);
        bytes32 pursesId = splitter.queue(FeeSplitter.Op.SetPurses, 0, nextP);
        bytes32 burnId = splitter.queue(FeeSplitter.Op.SetBurnBuyer, 0, nextB);
        splitter.cancel(pursesId);
        vm.warp(block.timestamp + 7 days);
        splitter.execute(FeeSplitter.Op.SetBurnBuyer, 0, nextB);
        vm.stopPrank();
        assertEq(splitter.purses(), purses);
        assertEq(splitter.burnBuyer(), nextB);
        assertEq(splitter.queuedAt(burnId), 0);

        // $wif still burns to dead after the buyer changes. The other token follows the new buyer.
        wif.mint(address(splitter), 10_000);
        fee.mint(address(splitter), 10_000);
        splitter.distribute(address(wif));
        splitter.distribute(address(fee));
        assertEq(wif.balanceOf(splitter.DEAD()), 1000);
        assertEq(wif.balanceOf(nextB), 0);
        assertEq(fee.balanceOf(nextB), 1000);
        assertEq(fee.balanceOf(burnBuyer), 0);
    }

    function test_timelock_splitAppliesOnlyAfterExecute() public {
        FeeSplitter.FeeSplit memory s = FeeSplitter.FeeSplit(5000, 2000, 1500, 1000, 500);
        uint256 key = splitter.packSplit(s.pursesBps, s.vaultBps, s.rebateBps, s.burnBps, s.opsBps);
        vm.prank(owner);
        bytes32 id = splitter.queue(FeeSplitter.Op.SetSplit, key, address(0));

        fee.mint(address(splitter), 10_000);
        splitter.distribute(address(fee));
        assertEq(fee.balanceOf(purses), 4000, "still the launch split");

        vm.warp(splitter.queuedAt(id));
        vm.expectEmit(false, false, false, true, address(splitter));
        emit FeeSplitter.SplitUpdated(5000, 2000, 1500, 1000, 500);
        vm.prank(owner);
        splitter.execute(FeeSplitter.Op.SetSplit, key, address(0));
        assertEq(splitter.pursesBps(), 5000);
        assertEq(splitter.opsBps(), 500);

        fee.mint(address(splitter), 10_000);
        splitter.distribute(address(fee));
        assertEq(fee.balanceOf(purses), 4000 + 5000);
        assertEq(fee.balanceOf(ops), 1000 + 500);
    }

    function test_timelock_rejectsBadChanges() public {
        uint256 good = splitter.packSplit(4000, 2500, 1500, 1000, 1000);
        uint256 short = splitter.packSplit(4000, 2500, 1500, 1000, 999);
        uint256 high = good | (uint256(1) << 80);
        vm.startPrank(owner);
        vm.expectRevert(FeeSplitter.ZeroAddress.selector);
        splitter.queue(FeeSplitter.Op.SetPurses, 0, address(0));
        vm.expectRevert(FeeSplitter.BadRecipient.selector);
        splitter.queue(FeeSplitter.Op.SetVault, 0, address(splitter));
        vm.expectRevert(FeeSplitter.BadValue.selector);
        splitter.queue(FeeSplitter.Op.SetRebate, 1, rebate);
        vm.expectRevert(FeeSplitter.BadValue.selector);
        splitter.queue(FeeSplitter.Op.SetSplit, good, ops);
        vm.expectRevert(FeeSplitter.BadSplit.selector);
        splitter.queue(FeeSplitter.Op.SetSplit, short, address(0));
        vm.expectRevert(FeeSplitter.BadSplit.selector);
        splitter.queue(FeeSplitter.Op.SetSplit, high, address(0));
        vm.expectRevert(FeeSplitter.NotQueued.selector);
        splitter.execute(FeeSplitter.Op.SetSplit, good, address(0));
        vm.expectRevert(FeeSplitter.NotQueued.selector);
        splitter.cancel(bytes32(uint256(1)));
        vm.stopPrank();
    }

    function test_timelock_notOwner() public {
        vm.startPrank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        splitter.queue(FeeSplitter.Op.SetOps, 0, stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        splitter.cancel(bytes32(uint256(1)));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        splitter.execute(FeeSplitter.Op.SetOps, 0, stranger);
        vm.stopPrank();
    }

    function test_renounceDisabled_andOwnershipIsTwoStep() public {
        vm.prank(owner);
        vm.expectRevert(FeeSplitter.RenounceDisabled.selector);
        splitter.renounceOwnership();
        assertEq(splitter.owner(), owner);

        vm.prank(owner);
        splitter.transferOwnership(stranger);
        assertEq(splitter.owner(), owner);
        assertEq(splitter.pendingOwner(), stranger);
        vm.prank(stranger);
        splitter.acceptOwnership();
        assertEq(splitter.owner(), stranger);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        splitter.queue(FeeSplitter.Op.SetOps, 0, owner);
    }

    // ---------------------------------------------------------------- helpers

    function _deploy(address owner_, FeeSplitter.Recipients memory r, FeeSplitter.FeeSplit memory s, address wif_)
        internal
        returns (FeeSplitter)
    {
        return new FeeSplitter(wif_, owner_, r, s, address(0xC0FE), address(0xBEEF));
    }

    function _recipients(address p, address v, address r, address b, address o)
        internal
        pure
        returns (FeeSplitter.Recipients memory)
    {
        return FeeSplitter.Recipients(p, v, r, b, o);
    }

    function _launch() internal pure returns (FeeSplitter.FeeSplit memory) {
        return FeeSplitter.FeeSplit(PURSE, VAULT, REBATE, BURN, OPS);
    }

    function _boundedSplit(uint16 a, uint16 b, uint16 c, uint16 d)
        internal
        pure
        returns (uint16 pa, uint16 va, uint16 ra, uint16 ba, uint16 oa)
    {
        pa = uint16(bound(a, 0, 10_000));
        va = uint16(bound(b, 0, 10_000 - pa));
        ra = uint16(bound(c, 0, 10_000 - pa - va));
        ba = uint16(bound(d, 0, 10_000 - pa - va - ra));
        oa = uint16(10_000 - pa - va - ra - ba);
    }

    /// @dev Callee gas of the previous call, via the forge-std v1.11.0 Vm interface. Forge 1.8.x warns that
    ///      `lastCallGas` is deprecated for `lastFrameGas`, but older forge (CI 'stable' is 1.5.1) lacks the new one.
    function _lastGas() internal view returns (uint256) {
        return vm.lastCallGas().gasTotalUsed;
    }

    function _legs(uint256 bal, uint16 pa, uint16 va, uint16 ra, uint16 ba)
        internal
        pure
        returns (uint256 p, uint256 v, uint256 r, uint256 b, uint256 o)
    {
        p = bal * pa / 10_000;
        v = bal * va / 10_000;
        r = bal * ra / 10_000;
        b = bal * ba / 10_000;
        o = bal - p - v - r - b;
    }

    function _assertLegs(
        ERC20Harness token,
        address,
        uint256 p,
        uint256 v,
        uint256 r,
        uint256 b,
        uint256 o,
        address burnTo
    ) internal view {
        assertEq(token.balanceOf(purses), p);
        assertEq(token.balanceOf(vault), v);
        assertEq(token.balanceOf(rebate), r);
        assertEq(token.balanceOf(burnTo), b);
        assertEq(token.balanceOf(ops), o);
    }
}

/// @notice Confirms the purse and vault legs have nowhere to land inside the existing contracts.
contract FeeSplitterAccountingTest is Base {
    function test_purse_plainTransferIsUncounted_collectIsNotATopUp() public {
        openFair();
        uint256 gross = 100e6;
        shot(ana, 1, gross);
        uint256 purseBps = config.split().purseBps;
        uint256 purse = core.pot(address(booth), 1);
        assertEq(purse, gross * purseBps / 10_000);
        assertLt(purse, gross, "collect keeps purseBps only; the rest is Greenwood");
        uint256 accounted = core.accounted();
        assertEq(accounted, gross);
        uint256 vaultLedgers = _vaultLedgers();
        assertGt(vaultLedgers, 0, "the shot's Greenwood share did reach the vault ledgers");

        usdg.mint(address(core), 40e6);
        wif.mint(address(core), 7e18);
        assertEq(core.pot(address(booth), 1), purse, "a plain transfer does not credit the purse");
        assertEq(core.accounted(), accounted, "a plain transfer is uncounted");
        assertEq(_vaultLedgers(), vaultLedgers, "a plain transfer does not credit the vault ledgers");

        vm.prank(ana);
        vm.expectRevert(FairCore.NotBooth.selector);
        core.collect(ana, ana, 1, 1);

        vm.startPrank(owner);
        core.sweepExcess(usdg, owner);
        core.sweepExcess(wif, owner);
        vm.stopPrank();
        assertEq(usdg.balanceOf(address(core)), accounted, "sweep takes the donation, not the purse");
        assertEq(wif.balanceOf(address(core)), 0, "a non-USDG donation is swept in full");
        assertEq(core.pot(address(booth), 1), purse);
        assertEq(core.claimable(ana), 0, "nothing donated became claimable");
    }

    function test_vault_plainErc20IsHeldAndPullable_ethIsRejected() public {
        LocksleyVault locksley = new LocksleyVault(ICoreVaultUsdg(address(core)), owner);
        wif.mint(address(locksley), 10e18);
        usdg.mint(address(locksley), 5e6);
        assertEq(locksley.heldOf(wif), 10e18, "heldOf is balanceOf; no top-up function");
        assertEq(locksley.heldOf(usdg), 5e6);
        assertEq(core.vaultLiqUsdg(), 0, "tokens sent to the vault are not the FairCore USDG ledger");
        assertEq(core.vaultFairsBurnUsdg(), 0);

        vm.deal(address(this), 1 ether);
        (bool ok,) = address(locksley).call{value: 1 ether}("");
        assertFalse(ok, "LocksleyVault has no receive");
        assertEq(address(locksley).balance, 0);
        (ok,) = address(core).call{value: 1 ether}("");
        assertFalse(ok, "FairCore has no receive");
        assertEq(address(core).balance, 0);

        address launcher = makeAddr("launcher");
        vm.startPrank(owner);
        locksley.queueLauncher(launcher);
        vm.warp(block.timestamp + 7 days);
        locksley.attachLauncher();
        vm.stopPrank();

        IERC20[] memory tokens = new IERC20[](2);
        tokens[0] = wif;
        tokens[1] = usdg;
        vm.prank(launcher);
        locksley.pull(tokens);
        assertEq(wif.balanceOf(launcher), 10e18);
        assertEq(usdg.balanceOf(launcher), 5e6);
        assertEq(locksley.heldOf(wif), 0);
    }

    function _vaultLedgers() internal view returns (uint256) {
        return core.vaultLiqUsdg() + core.vaultBuyPending() + core.vaultBurnPending() + core.vaultFairsBurnUsdg();
    }
}

contract ERC20Harness is ERC20 {
    constructor(string memory n, string memory s) ERC20(n, s) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract FalseToken {
    function balanceOf(address) external pure returns (uint256) {
        return 100;
    }

    function transfer(address, uint256) external pure returns (bool) {
        return false;
    }
}

contract RejectEth {
    receive() external payable {
        revert();
    }
}

contract ReenterEth {
    FeeSplitter splitter;
    bool armed = true;

    function setSplitter(FeeSplitter s) external {
        splitter = s;
    }

    receive() external payable {
        if (armed) {
            armed = false;
            splitter.distribute(address(0));
        }
    }
}

contract ReenterToken is ERC20 {
    FeeSplitter splitter;
    bool armed;

    constructor() ERC20("Hook", "HOOK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function arm(FeeSplitter s) external {
        splitter = s;
        armed = true;
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        if (armed) {
            armed = false;
            splitter.distribute(address(this));
        }
        return super.transfer(to, value);
    }
}

/// @dev Deploys a splitter so a test can name that splitter as its own recipient.
contract SplitterFactory {
    function deploy(address wif_, address owner_, FeeSplitter.Recipients memory r, FeeSplitter.FeeSplit memory s)
        external
        returns (FeeSplitter)
    {
        return new FeeSplitter(wif_, owner_, r, s, address(0xC0FE), address(0xBEEF));
    }
}
