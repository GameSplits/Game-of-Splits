// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Base} from "./Base.t.sol";
import {RobinAmongThieves} from "../src/RobinAmongThieves.sol";
import {RakeBuyer} from "../src/RakeBuyer.sol";
import {IFairCore, IGameConfig} from "../src/interfaces/IFair.sol";
import {IIdentityRegistry, IReputationRegistry} from "../src/interfaces/I8004.sol";
import {MockIdentity, MockReputation, MockArbSys} from "./mocks/Mocks.sol";

/// @dev Test-only hooks: set an outlaw's R4 opponent counter, and pre-fund the Sharing Pot (backed by real USDG).
contract RatHarness is RobinAmongThieves {
    constructor(Params memory p) RobinAmongThieves(p) {}

    function setOpponents(uint256 id, uint16 n) external {
        outlaws[id].distinctOpponents = n;
    }

    function entriesByControllerOf(uint256 r, address c) external view returns (uint8) {
        return entriesByController[r][c];
    }

    function fundPot(uint256 amt) external {
        require(usdg.transferFrom(msg.sender, address(this), amt));
        sharingPot += amt;
    }
}

abstract contract RatBase is Base {
    MockIdentity idr;
    MockReputation rep;
    RatHarness rat;
    RakeBuyer buyer;
    address houseSink = makeAddr("houseSink");
    address opr = makeAddr("oneClickOperator");
    address dan = makeAddr("dan");
    address eve = makeAddr("eve");
    address fay = makeAddr("fay");
    address house = makeAddr("houseWallet");

    uint256 constant LIC = 1000e18;
    uint256 constant FIRST = 3; // the first round the seed chain covers
    uint256 constant CHAIN = 600;
    bytes32[] chain;
    uint256 nextLink = 1;
    uint256 saltNonce;

    function setUp() public virtual override {
        super.setUp();
        vm.etch(address(0x64), address(new MockArbSys()).code);
        MockArbSys(address(0x64)).set(1_000_000);
        idr = new MockIdentity();
        rep = new MockReputation(idr);
        buyer = new RakeBuyer(usdg, IGameConfig(address(config)), vaultAddr, owner, 48 hours, address(core));
        rat = new RatHarness(_params());
        chain = new bytes32[](CHAIN);
        chain[CHAIN - 1] = keccak256("keeper secret");
        for (uint256 i = CHAIN - 1; i > 0; --i) {
            chain[i - 1] = keccak256(abi.encode(chain[i]));
        }
        vm.prank(keeper);
        rat.commitSeedChain(chain[0], uint64(FIRST));
        address[9] memory people = [ana, bob, cat, dan, eve, fay, house, opr, owner];
        for (uint256 i; i < people.length; ++i) ratFund(people[i]);
    }

    function _params() internal view returns (RobinAmongThieves.Params memory) {
        return RobinAmongThieves.Params({
            usdg: usdg,
            config: IGameConfig(address(config)),
            core: IFairCore(address(core)),
            identity: IIdentityRegistry(address(idr)),
            reputation: IReputationRegistry(address(rep)),
            owner: owner,
            timelockDelay: 48 hours,
            bondDelay: 7 days,
            genesis: T0,
            keeper: keeper,
            rakeSink: address(buyer),
            houseSink: houseSink
        });
    }

    function ratFund(address who) internal {
        usdg.mint(who, 1_000_000e6);
        wif.mint(who, 100_000e18);
        tokenB.mint(who, 100_000e18);
        vm.startPrank(who);
        usdg.approve(address(rat), type(uint256).max);
        wif.approve(address(rat), type(uint256).max);
        tokenB.approve(address(rat), type(uint256).max);
        wif.approve(address(pass), type(uint256).max);
        tokenB.approve(address(pass), type(uint256).max);
        vm.stopPrank();
        if (!pass.hasPass(who)) lockPass(who);
    }

    // ---------------------------------------------------------------- helpers

    function reg(address who) internal returns (uint256 id) {
        vm.prank(who);
        id = rat.registerOutlawNew("ipfs://outlaw", address(0), address(wif), LIC);
    }

    function regFunded(address who, uint256 amt) internal returns (uint256 id) {
        id = reg(who);
        vm.prank(who);
        rat.deposit(id, amt);
    }

    function regHouse(uint256 amt) internal returns (uint256 id) {
        id = regFunded(house, amt);
        vm.prank(house);
        rat.requestHouse(id);
        vm.prank(owner);
        rat.setHouse(id, true);
    }

    function windowStart(uint256 r) internal view returns (uint256) {
        return rat.closeTime(r) - 30 minutes;
    }

    /// Warp into round r's entry window (to its start if we're before it).
    function toEntries(uint256 r) internal {
        if (vm.getBlockTimestamp() < windowStart(r)) vm.warp(windowStart(r));
    }

    function enterAs(address who, uint256 id, uint256 r) internal {
        vm.prank(who);
        rat.enter(id, r, keccak256(abi.encode(id, r)));
    }

    function seedPair(uint256 r) internal {
        if (vm.getBlockTimestamp() < rat.closeTime(r)) vm.warp(rat.closeTime(r));
        rat.revealSeed(r, chain[nextLink++]);
        advanceL2();
        rat.pair(r, 1000);
    }

    /// The reveal block's hash is only available from the next L2 block.
    function advanceL2() internal {
        MockArbSys arb = MockArbSys(address(0x64));
        arb.set(arb.n() + 1);
    }

    function salt(uint256 id, uint256 r) internal pure returns (bytes32) {
        return keccak256(abi.encode("salt", id, r));
    }

    function commitAs(address who, uint256 id, uint256 r, RobinAmongThieves.Choice c) internal {
        bytes32 h = rat.commitHash(c, salt(id, r), r, id);
        vm.prank(who);
        rat.commit(r, id, h);
    }

    function toReveal(uint256 r) internal {
        uint256 t = rat.closeTime(r) + 13 minutes + 1;
        if (vm.getBlockTimestamp() < t) vm.warp(t);
    }

    function revealAs(address who, uint256 id, uint256 r, RobinAmongThieves.Choice c) internal {
        toReveal(r);
        vm.prank(who);
        rat.reveal(r, id, c, salt(id, r));
    }

    function toSettle(uint256 r) internal {
        uint256 t = rat.closeTime(r) + 23 minutes + 1;
        if (vm.getBlockTimestamp() < t) vm.warp(t);
    }

    function settleAll(uint256 r) internal {
        toSettle(r);
        rat.settle(r, 1000);
        rat.finalize(r, 1000);
    }

    /// One match between two entered outlaws: enter, pair, commit, reveal, settle, finalize. None = don't commit.
    function playMatch(
        uint256 r,
        address wa,
        uint256 a,
        RobinAmongThieves.Choice ca,
        address wb,
        uint256 b,
        RobinAmongThieves.Choice cb
    ) internal {
        toEntries(r);
        enterAs(wa, a, r);
        enterAs(wb, b, r);
        seedPair(r);
        if (ca != RobinAmongThieves.Choice.None) commitAs(wa, a, r, ca);
        if (cb != RobinAmongThieves.Choice.None) commitAs(wb, b, r, cb);
        if (ca != RobinAmongThieves.Choice.None) revealAs(wa, a, r, ca);
        if (cb != RobinAmongThieves.Choice.None) revealAs(wb, b, r, cb);
        settleAll(r);
    }

    function bal(uint256 id) internal view returns (uint256 b) {
        (,,,,,,,,,,, b,,,) = rat.outlaws(id);
    }

    function openRoundOf(uint256 id) internal view returns (uint256 r) {
        (,,, r,,,,,,,,,,,) = rat.outlaws(id);
    }

    function ledgersOk() internal view {
        assertEq(
            usdg.balanceOf(address(rat)),
            rat.freeBalances() + rat.reservedStakes() + rat.sharingPot() + rat.rakePending(),
            "I1: USDG conservation"
        );
    }
}
