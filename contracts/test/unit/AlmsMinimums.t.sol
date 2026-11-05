// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {AlmsVote} from "../../src/AlmsVote.sol";
import {IFairCore} from "../../src/interfaces/IFair.sol";
import {Chapter0Dates} from "../../script/Chapter0Dates.sol";

/// Just enough FairCore for AlmsVote's constructor and window checks.
contract MinCore {
    mapping(uint256 => uint64[2]) internal f;

    function fairPass() external pure returns (address) {
        return address(0xFA55);
    }

    function setFair(uint256 id, uint64 s, uint64 e) external {
        f[id] = [s, e];
    }

    function fairs(uint256 id) external view returns (uint64, uint64) {
        return (f[id][0], f[id][1]);
    }
}

/// MIN_NOTICE and MIN_WINDOW are constructor immutables: 24h minimum on Robinhood Chain mainnet (4663), shorter allowed
/// on testnet so a whole Fair and Alms loop can be rehearsed in hours.
contract AlmsMinimumsTest is Test {
    MinCore core;
    address owner = makeAddr("owner");
    uint64 constant T0 = 1_793_000_000;

    function setUp() public {
        core = new MinCore();
        vm.warp(T0);
    }

    function _alms(uint64 n, uint64 w) internal returns (AlmsVote) {
        return new AlmsVote(IFairCore(address(core)), owner, n, w);
    }

    // ------------------------------------------------------------ constructor

    function test_mainnet_24hAccepted() public {
        vm.chainId(4663);
        AlmsVote a = _alms(24 hours, 24 hours);
        assertEq(a.MIN_NOTICE(), 24 hours);
        assertEq(a.MIN_WINDOW(), 24 hours);
    }

    function test_mainnet_rejectsShortNotice() public {
        vm.chainId(4663);
        vm.expectRevert(AlmsVote.BadMinimums.selector);
        _alms(24 hours - 1, 24 hours);
    }

    function test_mainnet_rejectsShortWindow() public {
        vm.chainId(4663);
        vm.expectRevert(AlmsVote.BadMinimums.selector);
        _alms(24 hours, 24 hours - 1);
    }

    function test_mainnet_rejectsTestnetValues() public {
        vm.chainId(4663);
        vm.expectRevert(AlmsVote.BadMinimums.selector);
        _alms(1 hours, 2 hours);
    }

    function testFuzz_mainnet_rejectsAnythingUnder24h(uint64 n, uint64 w) public {
        vm.chainId(4663);
        n = uint64(bound(n, 0, 7 days));
        w = uint64(bound(w, 0, 7 days));
        vm.assume(n < 24 hours || w < 24 hours);
        vm.expectRevert(AlmsVote.BadMinimums.selector);
        _alms(n, w);
    }

    function testFuzz_mainnet_accepts24hTo7d(uint64 n, uint64 w) public {
        vm.chainId(4663);
        n = uint64(bound(n, 24 hours, 7 days));
        w = uint64(bound(w, 24 hours, 7 days));
        AlmsVote a = _alms(n, w);
        assertEq(a.MIN_NOTICE(), n);
        assertEq(a.MIN_WINDOW(), w);
    }

    function test_testnet_acceptsShort() public {
        vm.chainId(46630);
        AlmsVote a = _alms(1 hours, 2 hours);
        assertEq(a.MIN_NOTICE(), 1 hours);
        assertEq(a.MIN_WINDOW(), 2 hours);
    }

    function test_anyChain_rejectsZeroAndOverCap() public {
        uint256[2] memory chains = [uint256(46630), 4663];
        for (uint256 i; i < 2; ++i) {
            vm.chainId(chains[i]);
            vm.expectRevert(AlmsVote.BadMinimums.selector);
            _alms(0, 24 hours);
            vm.expectRevert(AlmsVote.BadMinimums.selector);
            _alms(24 hours, 0);
            vm.expectRevert(AlmsVote.BadMinimums.selector);
            _alms(7 days + 1, 24 hours);
            vm.expectRevert(AlmsVote.BadMinimums.selector);
            _alms(24 hours, 7 days + 1);
        }
    }

    // ------------------------------------------------------------ window checks use the immutables

    /// The planned testnet schedule: Fair G..G+6h, suggest G+6h, vote G+8h, end G+10h, deployed 1h+ before suggest.
    function test_testnet_plannedSchedule() public {
        vm.chainId(46630);
        AlmsVote a = _alms(1 hours, 2 hours);
        uint64 g = T0 + 2 hours;
        core.setFair(0, g, g + 6 hours);
        vm.prank(owner);
        a.setAlmsWindows(0, g + 6 hours, g + 8 hours, g + 10 hours);
        (uint64 s, uint64 v, uint64 e) = a.windows(0);
        assertEq(s, g + 6 hours);
        assertEq(v, g + 8 hours);
        assertEq(e, g + 10 hours);
    }

    /// The same schedule is refused by a 24h/24h contract (what mainnet gets).
    function test_24h_refusesTestnetSchedule() public {
        AlmsVote a = _alms(24 hours, 24 hours);
        uint64 g = T0 + 2 hours;
        core.setFair(0, g, g + 6 hours);
        vm.prank(owner);
        vm.expectRevert(AlmsVote.BadWindows.selector);
        a.setAlmsWindows(0, g + 6 hours, g + 8 hours, g + 10 hours);
    }

    /// The mainnet Chapter 0 schedule on a 24h/24h contract: accepted up to 24h before suggestions open, refused one
    /// second later. Times from script/Chapter0Dates.sol.
    function test_mainnetChapter0_deadline() public {
        vm.chainId(4663);
        AlmsVote a = _alms(24 hours, 24 hours);
        core.setFair(0, Chapter0Dates.FAIR_START, Chapter0Dates.FAIR_END);
        vm.warp(Chapter0Dates.ALMS_SUGGEST - 24 hours + 1);
        vm.prank(owner);
        vm.expectRevert(AlmsVote.BadWindows.selector);
        a.setAlmsWindows(0, Chapter0Dates.ALMS_SUGGEST, Chapter0Dates.ALMS_VOTE, Chapter0Dates.ALMS_END);
        vm.warp(Chapter0Dates.ALMS_SUGGEST - 24 hours);
        vm.prank(owner);
        a.setAlmsWindows(0, Chapter0Dates.ALMS_SUGGEST, Chapter0Dates.ALMS_VOTE, Chapter0Dates.ALMS_END);
    }

    /// Exact boundaries for any minimums: each check passes at its limit and fails one second past it.
    function testFuzz_windowBoundaries(uint64 n, uint64 w, uint64 lead, uint64 fairLen) public {
        n = uint64(bound(n, 1, 7 days));
        w = uint64(bound(w, 1, 7 days));
        // fair end + 14 days always leaves room for notice plus both windows, so every negative case below
        // fails only because of the rule it targets, never because of the 14-day cap
        fairLen = uint64(bound(fairLen, 8 days, 35 days));
        uint64 maxEnd = T0 + fairLen + 14 days;
        lead = uint64(bound(lead, 0, maxEnd - T0 - n - 2 * w)); // how far past now + n the suggest window opens
        AlmsVote a = _alms(n, w);
        core.setFair(0, T0, T0 + fairLen);
        uint64 s = T0 + n + lead;
        uint64 v = s + w;
        uint64 e = v + w;
        assertLe(e, maxEnd);

        vm.startPrank(owner);
        // notice: suggest one second before now + MIN_NOTICE
        uint64 s0 = T0 + n - 1;
        vm.expectRevert(AlmsVote.BadWindows.selector);
        a.setAlmsWindows(0, s0, s0 + w, s0 + 2 * w);
        // suggest window one second short, vote window one second short
        vm.expectRevert(AlmsVote.BadWindows.selector);
        a.setAlmsWindows(0, s, v - 1, e);
        vm.expectRevert(AlmsVote.BadWindows.selector);
        a.setAlmsWindows(0, s, v, e - 1);

        // at the limits it passes, then a longer vote up to fair end + 14 days is still fine
        a.setAlmsWindows(0, s, v, e);
        (uint64 s2, uint64 v2, uint64 e2) = a.windows(0);
        assertEq(s2, s);
        assertEq(v2, v);
        assertEq(e2, e);
        a.setAlmsWindows(0, s, v, maxEnd);
        vm.expectRevert(AlmsVote.BadWindows.selector);
        a.setAlmsWindows(0, s, v, maxEnd + 1);
        vm.stopPrank();
    }

    /// Testnet-length minimums still let the Safe clear and re-set a Fair's windows before suggestions open.
    function test_testnetClearAndReset() public {
        vm.chainId(46630);
        AlmsVote a = _alms(1 hours, 2 hours);
        core.setFair(0, T0 + 2 hours, T0 + 8 hours);
        vm.startPrank(owner);
        a.setAlmsWindows(0, T0 + 8 hours, T0 + 10 hours, T0 + 12 hours);
        a.clearWindows(0);
        (uint64 s0,,) = a.windows(0);
        assertEq(s0, 0);
        a.setAlmsWindows(0, T0 + 2 hours, T0 + 4 hours, T0 + 6 hours);
        (uint64 s1, uint64 v1, uint64 e1) = a.windows(0);
        assertEq(s1, T0 + 2 hours);
        assertEq(v1, T0 + 4 hours);
        assertEq(e1, T0 + 6 hours);
        vm.stopPrank();
        // once suggestions open the windows are locked
        vm.warp(T0 + 2 hours);
        vm.prank(owner);
        vm.expectRevert(AlmsVote.WindowsLocked.selector);
        a.clearWindows(0);
    }

    /// Suggestions can't open before the Fair starts, whatever the minimums.
    function testFuzz_suggestNotBeforeFair(uint64 n, uint64 w, uint64 gap) public {
        n = uint64(bound(n, 1, 7 days));
        w = uint64(bound(w, 1, 7 days));
        gap = uint64(bound(gap, 1, 30 days));
        AlmsVote a = _alms(n, w);
        uint64 fStart = T0 + n + gap;
        core.setFair(0, fStart, fStart + 35 days);
        vm.startPrank(owner);
        vm.expectRevert(AlmsVote.BadWindows.selector);
        a.setAlmsWindows(0, fStart - 1, fStart - 1 + w, fStart - 1 + 2 * w);
        a.setAlmsWindows(0, fStart, fStart + w, fStart + 2 * w);
        vm.stopPrank();
    }
}
