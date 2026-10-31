// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {RobinAmongThieves} from "../../src/RobinAmongThieves.sol";
import {RakeBuyer} from "../../src/RakeBuyer.sol";
import {BuyRouteV4} from "../../src/routes/BuyRouteV4.sol";
import {GameConfig} from "../../src/GameConfig.sol";
import {FairPass} from "../../src/FairPass.sol";
import {FairCore} from "../../src/FairCore.sol";
import {IArbSys, IFairCore, IGameConfig, Tokens, Split} from "../../src/interfaces/IFair.sol";
import {IIdentityRegistry, IReputationRegistry} from "../../src/interfaces/I8004.sol";
import {PoolKey, IV4Quoter, QuoteExactSingleParams} from "../../src/interfaces/IV4Minimal.sol";
import {MockArbSys} from "../mocks/Mocks.sol";

interface IReputationRead {
    function getSummary(uint256 agentId, address[] calldata clients, string calldata tag1, string calldata tag2)
        external
        view
        returns (uint64 count, int128 summaryValue, uint8 summaryValueDecimals);
}

/// Read-only against Robinhood Chain mainnet (4663): the real ERC-8004 registries and USDG, on a local fork.
/// Skips when the `robinhood` RPC endpoint isn't configured.
contract Rat8004ForkTest is Test {
    address constant IDENTITY = 0x8004A169FB4a3325136EB29fA0ceB6D2e539a432;
    address constant REPUTATION = 0x8004BAa17C55a88189AE136b182e5fdA19dE9b63;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant WIF = 0x5173b8eA6923c2d40267890D45C46a3480954773;
    address constant PM = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant QUOTER = 0x8Dc178eFB8111BB0973Dd9d722ebeFF267c98F94;
    address constant WIF_HOOK = 0xE5e702641Ea86F4ae6cC3cDaeD2B886f976Be044;
    address constant USDG_HOOK = 0x06a889870C8f83640D6816319f72e2aA579b6080;

    address owner = makeAddr("ownerSafe");
    address keeper = makeAddr("keeper");
    address ana = makeAddr("ana");
    address bob = makeAddr("bob");

    function setUp() public {
        string memory url;
        try vm.rpcUrl("robinhood") returns (string memory u) {
            url = u;
        } catch {}
        if (bytes(url).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(url);
        vm.etch(address(0x64), address(new MockArbSys()).code);
        MockArbSys(address(0x64)).set(1_000_000);
    }

    function test_usdg_has6Decimals() public view {
        assertEq(IERC20Metadata(USDG).decimals(), 6);
    }

    /// Register, feedback and getSummary directly on the real proxies, including the self-feedback refusal.
    function test_registry_register_feedback_summary() public {
        vm.prank(ana);
        uint256 id = IIdentityRegistry(IDENTITY).register("ipfs://fork-test");
        assertEq(IIdentityRegistry(IDENTITY).ownerOf(id), ana);
        assertEq(IIdentityRegistry(IDENTITY).getAgentWallet(id), ana);
        vm.prank(ana);
        vm.expectRevert(bytes("Self-feedback not allowed"));
        IReputationRegistry(REPUTATION).giveFeedback(id, 100, 0, "robinamongthieves", "share", "", "", bytes32(0));
        vm.prank(bob);
        IReputationRegistry(REPUTATION).giveFeedback(id, 100, 0, "robinamongthieves", "share", "", "", bytes32(0));
        address[] memory clients = new address[](1);
        clients[0] = bob;
        (uint64 n, int128 v,) = IReputationRead(REPUTATION).getSummary(id, clients, "robinamongthieves", "");
        assertEq(n, 1);
        assertEq(v, 100);
    }

    /// One full round through Robin Among Thieves against the real registries: one-transaction onboarding leaves the
    /// player owning the identity, and settle writes an honesty record that getSummary reads back.
    function test_rat_roundWritesRealReputation() public {
        GameConfig config = new GameConfig(
            owner, USDG, 7 days, Tokens(WIF, 5_000e18, WIF), Split(6000, 2000, 1750, 1750, 2500, 2500, 2500)
        );
        FairPass pass = new FairPass(IGameConfig(address(config)), owner);
        FairCore core = new FairCore(IERC20(USDG), IGameConfig(address(config)), pass, owner, 48 hours);
        uint256 genesis = (block.timestamp / 30 minutes) * 30 minutes;
        RobinAmongThieves rat = new RobinAmongThieves(
            RobinAmongThieves.Params({
                usdg: IERC20(USDG),
                config: IGameConfig(address(config)),
                core: IFairCore(address(core)),
                identity: IIdentityRegistry(IDENTITY),
                reputation: IReputationRegistry(REPUTATION),
                owner: owner,
                timelockDelay: 48 hours,
                bondDelay: 7 days,
                genesis: genesis,
                keeper: keeper,
                rakeSink: makeAddr("rakeSink"),
                houseSink: makeAddr("houseSink")
            })
        );
        bytes32 s2 = keccak256("fork chain 2");
        bytes32 s1 = keccak256(abi.encode(s2));
        uint64 first = uint64(rat.currentRound() + 2);
        vm.prank(keeper);
        rat.commitSeedChain(keccak256(abi.encode(s1)), first);

        address[2] memory who = [ana, bob];
        uint256[2] memory id;
        for (uint256 i; i < 2; ++i) {
            deal(USDG, who[i], 100e6);
            deal(WIF, who[i], 11_000e18);
            vm.startPrank(who[i]);
            IERC20(USDG).approve(address(rat), type(uint256).max);
            IERC20(WIF).approve(address(rat), type(uint256).max);
            IERC20(WIF).approve(address(pass), type(uint256).max);
            pass.lock(WIF, 5_000e18);
            id[i] = rat.registerOutlawNew("ipfs://fork-outlaw", address(0), WIF, 1000e18);
            rat.deposit(id[i], 10e6);
            vm.stopPrank();
            assertEq(IIdentityRegistry(IDENTITY).ownerOf(id[i]), who[i]);
            assertFalse(IIdentityRegistry(IDENTITY).isAuthorizedOrOwner(address(rat), id[i]));
        }
        uint256 t = rat.closeTime(first);
        vm.warp(t - 30 minutes);
        for (uint256 i; i < 2; ++i) {
            vm.prank(who[i]);
            rat.enter(id[i], first, keccak256(abi.encode(id[i], first)));
        }
        vm.warp(t);
        rat.revealSeed(first, s1);
        // Foundry serves the real ArbSys precompile on this fork. `vm.roll` does not move
        // `arbBlockNumber`, so step that view and supply the reveal block's hash.
        uint256 revealedArb = IArbSys(address(0x64)).arbBlockNumber();
        vm.mockCall(address(0x64), abi.encodeWithSelector(IArbSys.arbBlockNumber.selector), abi.encode(revealedArb + 1));
        vm.mockCall(
            address(0x64),
            abi.encodeWithSelector(IArbSys.arbBlockHash.selector, revealedArb),
            abi.encode(keccak256("fork-reveal-hash"))
        );
        rat.pair(first, 10);
        RobinAmongThieves.Choice[2] memory c = [RobinAmongThieves.Choice.Share, RobinAmongThieves.Choice.Steal];
        for (uint256 i; i < 2; ++i) {
            bytes32 h = rat.commitHash(c[i], bytes32(i + 7), first, id[i]);
            vm.prank(who[i]);
            rat.commit(first, id[i], h);
        }
        vm.warp(t + 14 minutes);
        for (uint256 i; i < 2; ++i) {
            vm.prank(who[i]);
            rat.reveal(first, id[i], c[i], bytes32(i + 7));
        }
        vm.warp(t + 24 minutes);
        vm.recordLogs();
        rat.settle(first, 10);
        assertEq(vm.getRecordedLogs().length > 0, true);
        address[] memory clients = new address[](1);
        clients[0] = address(rat);
        (uint64 n0, int128 v0,) = IReputationRead(REPUTATION).getSummary(id[0], clients, "robinamongthieves", "");
        (uint64 n1, int128 v1,) = IReputationRead(REPUTATION).getSummary(id[1], clients, "robinamongthieves", "");
        assertEq(n0, 1);
        assertEq(v0, 100, "the sharer's honesty");
        assertEq(n1, 1);
        assertEq(v1, 0, "the thief's");
    }

    /// RakeBuyer buys the buy token through a real route (route A, the v4 pools) with the ratchet seeded.
    function test_rakeBuyer_realRoute() public {
        GameConfig config = new GameConfig(
            owner, USDG, 7 days, Tokens(WIF, 5_000e18, WIF), Split(6000, 2000, 1750, 1750, 2500, 2500, 2500)
        );
        address vault = makeAddr("vault");
        RakeBuyer rb = new RakeBuyer(IERC20(USDG), IGameConfig(address(config)), vault, owner, 48 hours, makeAddr("fairCore"));
        PoolKey memory usdgPool = PoolKey(address(0), USDG, 0x800000, 10, USDG_HOOK);
        PoolKey memory wifPool = PoolKey(address(0), WIF, 0, 200, WIF_HOOK);
        BuyRouteV4 route = new BuyRouteV4(PM, address(rb), usdgPool, wifPool);
        (uint256 eth,) = IV4Quoter(QUOTER).quoteExactInputSingle(QuoteExactSingleParams(usdgPool, false, 10e6, ""));
        (uint256 q,) = IV4Quoter(QUOTER).quoteExactInputSingle(QuoteExactSingleParams(wifPool, true, uint128(eth), ""));
        vm.startPrank(owner);
        rb.setupSet(RakeBuyer.Op.SetKeeper, 0, keeper);
        rb.setupSet(RakeBuyer.Op.SetRoute, 0, address(route));
        rb.resetRatchet(q * 1e18 / 10e6);
        rb.finishSetup();
        vm.stopPrank();
        deal(USDG, address(rb), 20e6);
        vm.prank(keeper);
        uint256 out = rb.buy(0, 10e6, q * 99 / 100);
        assertGe(out, q * 99 / 100);
        rb.forward();
        assertEq(IERC20(WIF).balanceOf(vault), out);
        assertEq(IERC20(USDG).balanceOf(vault), 10e6);
    }
}
