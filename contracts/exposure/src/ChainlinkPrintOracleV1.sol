// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {IFinalizedPrintOracle} from "./interfaces/IFinalizedPrintOracle.sol";

interface IAggregatorV3 {
    function decimals() external view returns (uint8);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
    function getRoundData(uint80 roundId)
        external
        view
        returns (uint80, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @title ChainlinkPrintOracleV1
/// @notice Open and close prints for one stock token, taken from its Chainlink feed on Base: the print
///         for a scheduled time is the feed's value in force at that moment, i.e. the last round
///         updated at or before it. Anyone records a print once the moment is an hour past, by naming
///         that round; the oracle checks the round was in force (the next round came later, or there
///         is none yet) and keeps the value for good. No owner, no reporters.
/// @dev Base's Coinbase stock feeds report the token's total-return value (equity price times the
///      token's multiplier), so a split or dividend needs no adjustment here. They run 24/5 and
///      update on a 0.5% move or a 24-hour heartbeat, so a print can differ from the exchange's
///      official auction price by up to the deviation threshold. On weekends, holidays and
///      corporate-action freezes the feed holds its last value, so those windows record no move.
contract ChainlinkPrintOracleV1 is IFinalizedPrintOracle {
    /// @notice How long after a scheduled time before its print may be recorded, so every round
    ///         stamped at or before it has landed.
    uint256 public constant RECORD_DELAY = 1 hours;

    IAggregatorV3 public immutable feed;
    /// @notice The only feed id this oracle answers for: keccak256(abi.encode(chainid, feed)).
    bytes32 public immutable feedId;
    uint256 internal immutable _scale;

    mapping(bytes32 key => Print) internal _prints;

    event PrintRecorded(uint64 indexed scheduledAt, bool isOpen, uint80 roundId, uint256 priceWad);

    error ZeroAddress();
    error TooEarly(uint256 recordableAt);
    error AlreadyRecorded();
    error RoundNotInForce(uint80 roundId);
    error BadAnswer(int256 answer);

    constructor(address feed_) {
        if (feed_ == address(0)) revert ZeroAddress();
        feed = IAggregatorV3(feed_);
        feedId = keccak256(abi.encode(block.chainid, feed_));
        _scale = 10 ** (18 - IAggregatorV3(feed_).decimals());
    }

    /// @notice Records the print for the open (`isOpen`) or close at `scheduledAt`: the answer of
    ///         `roundId`, which must be the round in force at that moment.
    function record(uint64 scheduledAt, bool isOpen, uint80 roundId) external {
        uint256 recordableAt = uint256(scheduledAt) + RECORD_DELAY;
        if (block.timestamp < recordableAt) revert TooEarly(recordableAt);
        bytes32 key = printKey(scheduledAt, isOpen);
        if (_prints[key].finalizedAt != 0) revert AlreadyRecorded();

        (bool found, int256 answer, uint256 updatedAt) = _round(roundId);
        if (!found || updatedAt > scheduledAt || !_nextRoundLater(roundId, scheduledAt)) {
            revert RoundNotInForce(roundId);
        }
        // forge-lint: disable-next-line(unsafe-typecast)
        if (answer <= 0 || uint256(answer) > type(uint128).max / _scale) revert BadAnswer(answer); // positive first
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 priceWad = uint256(answer) * _scale; // answer is positive

        // forge-lint: disable-next-line(unsafe-typecast)
        uint128 price = uint128(priceWad); // capped above
        // forge-lint: disable-next-line(unsafe-typecast)
        _prints[key] = Print({priceWad: price, observedAt: scheduledAt, finalizedAt: uint64(block.timestamp)});
        emit PrintRecorded(scheduledAt, isOpen, roundId, priceWad);
    }

    function getPrint(bytes32 feedId_, uint64 scheduledAt, bool isOpen) external view returns (Print memory p) {
        if (feedId_ == feedId) p = _prints[printKey(scheduledAt, isOpen)];
    }

    function printKey(uint64 scheduledAt, bool isOpen) public pure returns (bytes32) {
        // forge-lint: disable-next-line(asm-keccak256)
        return keccak256(abi.encode(scheduledAt, isOpen));
    }

    /// @dev True when nothing replaced `roundId` by `at`: no newer feed phase had reported by then,
    ///      and the next round of its own phase (if any) came later. Round ids are
    ///      (phase << 64 | n). While Chainlink runs an old and a new feed side by side, only the
    ///      newest phase that had reported by `at` counts, so a moment has exactly one print.
    function _nextRoundLater(uint80 roundId, uint256 at) internal view returns (bool) {
        (uint80 latest,,,,) = feed.latestRoundData();
        uint256 phase = roundId >> 64;
        uint256 latestPhase = latest >> 64;
        if (phase > latestPhase || (phase == latestPhase && roundId > latest)) return false;
        for (uint256 later = phase + 1; later <= latestPhase; ++later) {
            (bool reported,, uint256 firstUpdatedAt) = _round(uint80((later << 64) | 1));
            if (reported && firstUpdatedAt <= at) return false;
        }
        if (roundId == latest) return true;
        (bool found,, uint256 nextUpdatedAt) = _round(roundId + 1);
        // No next round in its phase: it was its phase's last, and no newer phase had reported.
        return found ? nextUpdatedAt > at : phase < latestPhase;
    }

    /// @dev A round that does not exist reverts on some aggregators and reads as zeros on others.
    function _round(uint80 roundId) internal view returns (bool found, int256 answer, uint256 updatedAt) {
        try feed.getRoundData(roundId) returns (uint80, int256 answer_, uint256, uint256 updatedAt_, uint80) {
            return (updatedAt_ != 0, answer_, updatedAt_);
        } catch {
            return (false, 0, 0);
        }
    }
}
