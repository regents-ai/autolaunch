// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {LibBit} from "solady/utils/LibBit.sol";

import {IFinalizedPrintOracle} from "./interfaces/IFinalizedPrintOracle.sol";

/// @title PrintOracleV1
/// @notice Append-only official prints, made final when `threshold` of a fixed set of reporters
///         submit the same price for the same scheduled open or close. The reporter set and threshold
///         are fixed at deployment; there is no owner, so a print can never be added, changed or
///         removed any other way. `finalizedAt` is the block time the last needed report landed.
/// @dev The reporters are trusted to publish the official print: this contract proves agreement, not
///      the market fact. Their independence (separate keys and separate market data) is what the
///      threshold buys, and a deployment review must establish it. A reporter may change its vote
///      until the print is final (to fix a typo or match the published rounding), never after.
contract PrintOracleV1 is IFinalizedPrintOracle {
    uint256 public constant MAX_REPORTERS = 8;

    uint256 public immutable threshold;
    uint256 public immutable reporterCount;

    /// @notice A reporter's bit in the vote masks, or zero for anyone else.
    mapping(address reporter => uint256 bit) public reporterBit;
    mapping(bytes32 key => Print) internal _prints;
    /// @notice Each reporter's current vote on a print, or zero.
    mapping(bytes32 key => mapping(address reporter => uint128 priceWad)) public voteOf;
    /// @notice Reporters who have voted for each price, as a bit mask.
    mapping(bytes32 key => mapping(uint128 priceWad => uint256 mask)) public votesFor;

    event Reported(
        bytes32 indexed key,
        address indexed reporter,
        bytes32 feedId,
        uint64 scheduledAt,
        bool isOpen,
        uint128 priceWad,
        bytes32 evidence
    );
    event PrintFinalized(bytes32 indexed key, bytes32 feedId, uint64 scheduledAt, bool isOpen, uint128 priceWad);

    error BadReporters();
    error BadThreshold();
    error NotReporter();
    error ZeroPrice();
    error NotYetHappened(uint64 scheduledAt);
    error AlreadyFinal();
    error AlreadyVoted();

    constructor(address[] memory reporters, uint256 threshold_) {
        uint256 count = reporters.length;
        if (count == 0 || count > MAX_REPORTERS) revert BadReporters();
        // A strict majority, so no minority can make a print final.
        if (threshold_ == 0 || threshold_ > count || threshold_ * 2 <= count) revert BadThreshold();
        for (uint256 i; i < count; ++i) {
            address reporter = reporters[i];
            if (reporter == address(0) || reporterBit[reporter] != 0) revert BadReporters();
            // forge-lint: disable-next-line(incorrect-shift)
            reporterBit[reporter] = 1 << i; // reporter i's bit
        }
        threshold = threshold_;
        reporterCount = count;
    }

    /// @notice Votes `priceWad` (USD per whole raw token, 18 decimals) for the open or close at
    ///         `scheduledAt`. `evidence` commits to the source data and is only logged.
    function report(bytes32 feedId, uint64 scheduledAt, bool isOpen, uint128 priceWad, bytes32 evidence) external {
        uint256 bit = reporterBit[msg.sender];
        if (bit == 0) revert NotReporter();
        if (priceWad == 0) revert ZeroPrice();
        if (scheduledAt > block.timestamp) revert NotYetHappened(scheduledAt);
        bytes32 key = printKey(feedId, scheduledAt, isOpen);
        if (_prints[key].finalizedAt != 0) revert AlreadyFinal();
        uint128 previous = voteOf[key][msg.sender];
        if (previous == priceWad) revert AlreadyVoted();
        if (previous != 0) votesFor[key][previous] &= ~bit;

        voteOf[key][msg.sender] = priceWad;
        uint256 agreeing = votesFor[key][priceWad] | bit;
        votesFor[key][priceWad] = agreeing;
        emit Reported(key, msg.sender, feedId, scheduledAt, isOpen, priceWad, evidence);

        if (LibBit.popCount(agreeing) >= threshold) {
            _prints[key] = Print({priceWad: priceWad, observedAt: scheduledAt, finalizedAt: uint64(block.timestamp)});
            emit PrintFinalized(key, feedId, scheduledAt, isOpen, priceWad);
        }
    }

    function getPrint(bytes32 feedId, uint64 scheduledAt, bool isOpen) external view returns (Print memory) {
        return _prints[printKey(feedId, scheduledAt, isOpen)];
    }

    function printKey(bytes32 feedId, uint64 scheduledAt, bool isOpen) public pure returns (bytes32) {
        // forge-lint: disable-next-line(asm-keccak256)
        return keccak256(abi.encode(feedId, scheduledAt, isOpen));
    }
}
