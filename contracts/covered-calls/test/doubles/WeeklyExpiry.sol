// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

/// @notice Expiries the contract accepts: Fridays at 21:00 UTC.
library WeeklyExpiry {
    uint256 internal constant OFFSET = 1 days + 21 hours;

    /// The first Friday close strictly after `t`, plus `weeksAhead` weeks.
    function next(uint256 t, uint256 weeksAhead) internal pure returns (uint64) {
        uint256 first = t - t % 1 weeks + OFFSET;
        if (first <= t) first += 1 weeks;
        return uint64(first + weeksAhead * 1 weeks);
    }
}
