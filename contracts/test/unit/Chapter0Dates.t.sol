// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {Chapter0Dates} from "../../script/Chapter0Dates.sol";

/// The rules every Chapter 0 schedule must meet, whatever dates are dropped into script/Chapter0Dates.sol.
contract Chapter0DatesTest is Test {
    function test_chapterStartsAndEndsOnUtcMidnight() public pure {
        // SEAT-01: Sheriff's Seat days are UTC days, so the chapter must line up with them.
        assertEq(Chapter0Dates.FAIR_START % 1 days, 0, "start on 00:00 UTC");
        assertEq(Chapter0Dates.FAIR_END % 1 days, 0, "end on 00:00 UTC");
        assertLt(Chapter0Dates.FAIR_START, Chapter0Dates.FAIR_END, "start before end");
    }

    function test_almsWindowsFitTheContractMinimums() public pure {
        assertGe(Chapter0Dates.ALMS_SUGGEST, Chapter0Dates.FAIR_START, "suggestions open once the chapter starts");
        assertGe(Chapter0Dates.ALMS_VOTE - Chapter0Dates.ALMS_SUGGEST, 24 hours, "suggest window at least 24h");
        assertGe(Chapter0Dates.ALMS_END - Chapter0Dates.ALMS_VOTE, 24 hours, "vote window at least 24h");
        assertGt(Chapter0Dates.ALMS_END, Chapter0Dates.FAIR_END, "Alms end after the chapter ends");
        assertLe(Chapter0Dates.ALMS_END, Chapter0Dates.FAIR_END + 14 days, "Alms end within 14 days of the chapter");
    }

    function test_deployByIsSuggestMinus25Hours() public pure {
        assertEq(Chapter0Dates.DEPLOY_BY, Chapter0Dates.ALMS_SUGGEST - 25 hours);
    }

    function test_datesAreOwnerPick() public pure {
        assertEq(Chapter0Dates.FAIR_START, 1794441600); // 12 Nov 2026 00:00 UTC
        assertEq(Chapter0Dates.FAIR_END, 1794614400); // 14 Nov 2026 00:00 UTC
        assertEq(Chapter0Dates.ALMS_SUGGEST, 1794441600); // 12 Nov 2026 00:00 UTC
        assertEq(Chapter0Dates.ALMS_VOTE, 1794528000); // 13 Nov 2026 00:00 UTC
        assertEq(Chapter0Dates.ALMS_END, 1794657600); // 14 Nov 2026 12:00 UTC
        assertEq(Chapter0Dates.deployByText(), "deploy by 10 Nov 2026 23:00 UTC (Alms need 24h notice)");
    }

    function test_utcFormatting() public pure {
        assertEq(Chapter0Dates.utc(0), "1 Jan 1970 00:00 UTC");
        assertEq(Chapter0Dates.utc(1793577600), "2 Nov 2026 00:00 UTC");
        assertEq(Chapter0Dates.utc(1709164800 + 9 hours + 5 minutes), "29 Feb 2024 09:05 UTC");
        assertEq(Chapter0Dates.utc(1798761599), "31 Dec 2026 23:59 UTC");
        assertEq(Chapter0Dates.utc(4102444800), "1 Jan 2100 00:00 UTC");
    }
}
