// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
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
/// An outlaw that approves RAT on its identity can't hide a steal from reputation. Skips when the `robinhood` RPC
/// endpoint isn't configured.
contract Rat8004SelfApprovalFork is Test {
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

    RobinAmongThieves rat;
    uint256[2] id;
    uint256 first;

    /// Same round as test_rat_roundWritesRealReputation (ana shares, bob steals), stopped right before settle.
    function _round() internal {
        GameConfig config = new GameConfig(
            owner, USDG, 7 days, Tokens(WIF, 5_000e18, WIF), Split(6000, 2000, 1750, 1750, 2500, 2500, 2500)
        );
        FairPass pass = new FairPass(IGameConfig(address(config)), owner);
        FairCore core = new FairCore(IERC20(USDG), IGameConfig(address(config)), pass, owner, 48 hours);
        uint256 genesis = (block.timestamp / 30 minutes) * 30 minutes;
        rat = new RobinAmongThieves(
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
        first = uint64(rat.currentRound() + 2);
        vm.prank(keeper);
        rat.commitSeedChain(keccak256(abi.encode(s1)), uint64(first));

        address[2] memory who = [ana, bob];
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
    }

    function _summary(uint256 i) internal view returns (uint64 n) {
        address[] memory clients = new address[](1);
        clients[0] = address(rat);
        (n,,) = IReputationRead(REPUTATION).getSummary(id[i], clients, "robinamongthieves", "");
    }

    function _bal(uint256 i) internal view returns (uint256 b) {
        (,,,,,,,,,,, b,,,) = rat.outlaws(id[i]);
    }

    /// Real 8004 proxies: the thief approves RAT after reveal; sweep the settle gas limit.
    /// Escape = settle succeeds, no record, thief paid.
    function test_fork_gasSweep_cannotEscape() public {
        _round();
        vm.prank(bob);
        IERC721(IDENTITY).approve(address(rat), id[1]);
        uint256 b0 = _bal(1);
        uint256 snap = vm.snapshotState();
        uint256 succ;
        uint256 escaped;
        uint256 minOk;
        for (uint256 g = 300_000; g <= 1_200_000; g += 500) {
            (bool ok,) = address(rat).call{gas: g}(abi.encodeCall(rat.settle, (first, 10)));
            if (ok) {
                succ++;
                if (minOk == 0) minOk = g;
                if (_summary(1) == 0 && _bal(1) > b0) escaped++;
            }
            vm.revertToState(snap);
        }
        emit log_named_uint("successful gas limits", succ);
        emit log_named_uint("min successful gas", minOk);
        assertGt(succ, 0);
        assertEq(escaped, 0, "gas limit let the thief escape on the real registries");
        rat.settle(first, 10);
        assertEq(_summary(1), 0, "steal refused by real registry");
        assertEq(_bal(1), b0, "thief forfeits FULL");
        assertEq(_summary(0), 1, "sharer recorded");
    }

    /// Real proxies: the reputation registry reverts every write (an outage) while bob has approved RAT.
    function test_fork_registryRevertsWhileApproved() public {
        _round();
        vm.prank(bob);
        IERC721(IDENTITY).approve(address(rat), id[1]);
        vm.mockCallRevert(REPUTATION, abi.encodeWithSelector(IReputationRegistry.giveFeedback.selector), "down");
        uint256 b0 = _bal(0);
        uint256 b1 = _bal(1);
        rat.settle(first, 10);
        assertEq(_bal(1), b1, "approved thief forfeits during outage");
        assertEq(_bal(0), b0, "victim gets 0 as in a normal steal");
    }

    /// Outage, nobody approved: no forfeit.
    function test_fork_registryRevertsUnapproved() public {
        _round();
        vm.mockCallRevert(REPUTATION, abi.encodeWithSelector(IReputationRegistry.giveFeedback.selector), "down");
        uint256 b1 = _bal(1);
        rat.settle(first, 10);
        assertEq(_bal(1) - b1, 9_500_000);
    }
}
