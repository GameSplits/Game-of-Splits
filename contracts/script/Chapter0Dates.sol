// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

/// The one place that holds the Chapter 0 and Alms times for the mainnet deploy. DeployMainnet, SafeAcceptVerify,
/// the Fair0 fork sim, the Alms minimums test and e2e/run.mjs all read these values. To change the dates, edit the
/// five times below and nothing else.
///
/// Dates set by the owner on 5 Nov 2026:
///   Chapter 0 runs 12 Nov 2026 00:00 UTC to 14 Nov 2026 00:00 UTC.
///   Alms suggestions open 12 Nov 00:00 UTC (option a, 5 Nov), voting opens 13 Nov 00:00 UTC, and Alms end 14 Nov 12:00 UTC.
///
/// Rules checked in test/unit/Chapter0Dates.t.sol and again in DeployMainnet: start and end on 00:00 UTC (SEAT-01),
/// start before end, suggest at or after start, each Alms window at least 24h (AlmsVote.MAINNET_MIN), Alms end after
/// the chapter ends and within 14 days of it, and DEPLOY_BY = SUGGEST - 25h (24h Alms notice plus an hour for the
/// broadcast to land).
library Chapter0Dates {
    uint64 internal constant FAIR_START = 1794441600; // 12 Nov 2026 00:00 UTC
    uint64 internal constant FAIR_END = 1794614400; // 14 Nov 2026 00:00 UTC
    uint64 internal constant ALMS_SUGGEST = 1794441600; // 12 Nov 2026 00:00 UTC
    uint64 internal constant ALMS_VOTE = 1794528000; // 13 Nov 2026 00:00 UTC
    uint64 internal constant ALMS_END = 1794657600; // 14 Nov 2026 12:00 UTC

    /// Latest start of the deploy run. Derived, never edited by hand.
    uint64 internal constant DEPLOY_BY = ALMS_SUGGEST - 25 hours;

    /// "deploy by 10 Nov 2026 23:00 UTC", built from DEPLOY_BY so the text can never drift from the check.
    function deployByText() internal pure returns (string memory) {
        return string.concat("deploy by ", utc(DEPLOY_BY), " (Alms need 24h notice)");
    }

    /// Formats a unix time as "D Mon YYYY HH:MM UTC" (days to civil date, proleptic Gregorian).
    function utc(uint256 t) internal pure returns (string memory) {
        uint256 z = t / 1 days + 719468;
        uint256 era = z / 146097;
        uint256 doe = z - era * 146097;
        uint256 yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
        uint256 doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
        uint256 mp = (5 * doy + 2) / 153;
        uint256 d = doy - (153 * mp + 2) / 5 + 1;
        uint256 m = mp < 10 ? mp + 3 : mp - 9;
        uint256 y = yoe + era * 400 + (m <= 2 ? 1 : 0);
        uint256 sod = t % 1 days;
        return string.concat(
            _u(d), " ", _month(m), " ", _u(y), " ", _two(sod / 3600), ":", _two((sod % 3600) / 60), " UTC"
        );
    }

    function _month(uint256 m) private pure returns (string memory) {
        bytes memory all = "JanFebMarAprMayJunJulAugSepOctNovDec";
        bytes memory out = new bytes(3);
        for (uint256 i; i < 3; ++i) {
            out[i] = all[(m - 1) * 3 + i];
        }
        return string(out);
    }

    function _two(uint256 v) private pure returns (string memory) {
        return v < 10 ? string.concat("0", _u(v)) : _u(v);
    }

    function _u(uint256 v) private pure returns (string memory) {
        if (v == 0) return "0";
        uint256 len;
        for (uint256 x = v; x != 0; x /= 10) {
            ++len;
        }
        bytes memory b = new bytes(len);
        for (; v != 0; v /= 10) {
            b[--len] = bytes1(uint8(48 + v % 10));
        }
        return string(b);
    }
}
