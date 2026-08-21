// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

/// @title ForkHeaders
/// @notice The one place the two committed fork headers' fixed relationship is written down.
/// @dev Constants only. Both fork phases need this number and neither may learn it from the other:
///      the discovery pass uses it to choose the pinned header behind the head it opened, and the
///      check pass uses it to prove the two committed records really are that far apart. Discovery
///      deliberately cannot read `reports/frozen/fork-observations.json` at all, so the value lives
///      here rather than in the record or in `ForkFixture`, and one literal serves both sides.
library ForkHeaders {
    /// @notice How far behind the later header the pinned header sits, in blocks.
    /// @dev At Base's two-second block time this is roughly ten minutes, comfortably past reorg
    ///      depth, which is what makes the pinned header a settled one. `DEP-052` asserts the two
    ///      committed records are separated by exactly this distance, so a record whose headers
    ///      were chosen some other way fails before any claim runs against them.
    uint256 internal constant PINNED_TO_LATER_DISTANCE = 300;
}
