// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {FairPass} from "../src/FairPass.sol";
import {GameConfig} from "../src/GameConfig.sol";
import {FairCore} from "../src/FairCore.sol";
import {RakeBuyer} from "../src/RakeBuyer.sol";
import {IFairCore, IGameConfig, Tokens, Split} from "../src/interfaces/IFair.sol";
import {MockToken, MockRoute, StubBooth} from "./mocks/Mocks.sol";

abstract contract Base is Test {
    MockToken usdg;
    MockToken wif;
    GameConfig config;
    FairPass pass;
    FairCore core;
    MockRoute route;
    MockToken tokenB; // a second 18-dp game token, with its own route at index 1
    MockRoute routeB;
    StubBooth booth;

    address owner = makeAddr("ownerSafe");
    address keeper = makeAddr("keeper");
    address toll = makeAddr("toll");
    address almsSafe = makeAddr("almsSafe");
    address almsVoteAddr = makeAddr("almsVote");
    address vaultAddr = makeAddr("vault");
    address ana = makeAddr("ana");
    address bob = makeAddr("bob");
    address cat = makeAddr("cat");

    uint64 constant T0 = 1_800_000_000;
    uint256 constant PASS_LOCK = 5_000e18;
    uint256 constant CONFIG_DELAY = 7 days;

    function setUp() public virtual {
        vm.warp(T0);
        usdg = new MockToken("Global Dollar", "USDG", 6);
        wif = new MockToken("World is Flat", "WIF", 18);
        config = new GameConfig(owner, address(usdg), CONFIG_DELAY, Tokens(address(wif), PASS_LOCK, address(wif)), launchSplit());
        pass = new FairPass(IGameConfig(address(config)), owner);
        core = new FairCore(usdg, IGameConfig(address(config)), pass, owner, 48 hours);
        vm.prank(owner);
        config.bindCore(address(core));
        route = new MockRoute(wif, usdg);
        tokenB = new MockToken("Token B", "TKB", 18);
        routeB = new MockRoute(tokenB, usdg);
        routeB.setRate(100e12); // 100 TKB per USDG
        booth = new StubBooth(IFairCore(address(core)));

        vm.startPrank(owner);
        core.setupSet(FairCore.Op.AddBooth, 0, address(booth));
        core.setupSet(FairCore.Op.SetKeeper, 0, keeper);
        core.setupSet(FairCore.Op.SetTollRecipient, 0, toll);
        core.setupSet(FairCore.Op.SetAlmsSafe, 0, almsSafe);
        core.setupSet(FairCore.Op.SetAlmsVote, 0, almsVoteAddr);
        core.setupSet(FairCore.Op.SetVault, 0, vaultAddr);
        core.setupSet(FairCore.Op.SetRoute, 0, address(route));
        core.setupSet(FairCore.Op.SetRoute, 1, address(routeB));
        wireBooths();
        // v3.6: buybacks need a seeded anchor. Seed at the mock route's rate before finishSetup, as the deploy does (A1-12).
        core.resetRatchet(route.rate() * 1e18);
        core.finishSetup();
        core.setFair(0, T0 + 1 hours, T0 + 6 days);
        vm.stopPrank();

        address[3] memory people = [ana, bob, cat];
        for (uint256 i; i < 3; ++i) fund(people[i]);
    }

    function launchSplit() internal pure returns (Split memory) {
        return Split({purseBps: 6000, almsBps: 2000, bonfireBps: 1750, tollBps: 1750, vBuyBps: 2500, vLiqBps: 2500, vBurnBps: 2500});
    }

    /// A1-12: after setup the anchor is re-seeded only through the timelock: queue, wait timelockDelay, execute.
    function reseed(uint256 newAnchor) internal {
        reseedCore(core, newAnchor);
    }

    function reseedCore(FairCore c, uint256 newAnchor) internal {
        vm.startPrank(owner);
        c.queue(FairCore.Op.ResetRatchet, newAnchor, address(0));
        vm.warp(vm.getBlockTimestamp() + c.timelockDelay());
        c.execute(FairCore.Op.ResetRatchet, newAnchor, address(0));
        vm.stopPrank();
    }

    /// A1-12: the same for a RakeBuyer owned by `owner`.
    function reseedRb(RakeBuyer rb_, uint256 newAnchor) internal {
        vm.startPrank(owner);
        rb_.queue(RakeBuyer.Op.ResetRatchet, newAnchor, address(0));
        vm.warp(vm.getBlockTimestamp() + rb_.timelockDelay());
        rb_.execute(RakeBuyer.Op.ResetRatchet, newAnchor, address(0));
        vm.stopPrank();
    }

    /// Lock a pass in the current play token, as the site does (expected token and amount from GameConfig).
    function lockPass(address who) internal {
        (address t, uint256 amt,) = config.tokens();
        vm.prank(who);
        pass.lock(t, amt);
    }

    /// Queue a GameConfig token update, wait out the delay and execute it (the caller makes sure no Fair is running at
    /// the ETA). Returns the new epoch.
    function applyTokens(address play, uint256 amt, address buy) internal returns (uint64) {
        vm.startPrank(owner);
        config.queueTokens(Tokens(play, amt, buy));
        vm.warp(config.tokensEta());
        config.executeTokens();
        vm.stopPrank();
        return config.epoch();
    }

    /// Override to add booths during setup (called while pranked as owner).
    function wireBooths() internal virtual {}

    function fund(address who) internal {
        usdg.mint(who, 1_000_000e6);
        wif.mint(who, 100_000e18);
        tokenB.mint(who, 100_000e18);
        vm.startPrank(who);
        usdg.approve(address(core), type(uint256).max);
        wif.approve(address(pass), type(uint256).max);
        tokenB.approve(address(pass), type(uint256).max);
        vm.stopPrank();
    }

    function openFair() internal {
        vm.warp(T0 + 1 hours);
    }

    function shot(address who, uint256 key, uint256 gross) internal {
        vm.prank(who);
        booth.shot(who, key, gross);
    }

    /// Sum of every ledger, as FairCore's invariant I1 lists them (pots/rollovers per booth summed by the caller).
    function ledgers() internal view returns (uint256) {
        return core.bonfirePending() + core.tollPending() + core.vaultLiqUsdg() + core.vaultBuyPending()
            + core.vaultBurnPending() + core.vaultFairsBurnUsdg() + core.almsByFair(0) + core.almsEscrow();
    }

    function assertSolvent() internal view {
        assertGe(usdg.balanceOf(address(core)), core.accounted(), "insolvent");
    }
}
