// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {IFinalizedPrintOracle} from "./interfaces/IFinalizedPrintOracle.sol";

interface IAggregatorProxy {
    function decimals() external view returns (uint8);
    function phaseId() external view returns (uint16);
    function getRoundData(uint80 roundId)
        external
        view
        returns (uint80, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @title ChainlinkPrintOracleV2
/// @notice Open and close prints for one stock token from its Chainlink feed on Base, read from one
///         fixed feed phase: the phase the proxy pointed at when this oracle was deployed. The print
///         for a scheduled time is that phase's value in force at the moment, i.e. its last round
///         updated at or before it, provided that round is at most `MAX_STALENESS` old. Anyone records
///         a print once the moment is an hour past, by naming the round; the oracle checks it and
///         keeps the value, and the round it came from, for good. No owner, no reporters.
/// @dev Pinning the phase makes every print a pure function of that phase's history. Chainlink runs
///      old and new aggregators side by side when it migrates a feed, and the proxy switches between
///      them at a time that is not recorded on chain, so following the proxy would let the record
///      time decide which aggregator's value counts. The underlying aggregators only answer the
///      proxy, so rounds are read through the proxy by their phase id. When Chainlink retires the
///      pinned aggregator it stops updating: for up to `MAX_STALENESS` its frozen last value is still
///      used (moves in that time are not counted), after which prints are refused and series end at
///      their last applied values through the series' own missing-print rule. Later series use a new
///      oracle on the new phase.
///
///      Base's Coinbase stock feeds report the token's total-return value (equity price times the
///      token's multiplier), so a split or dividend needs no adjustment. They update on a 0.5% move
///      or a 24-hour heartbeat while the market trades, and hold their value over weekends, holidays
///      and corporate-action freezes. A print is the feed's value at the moment, not the exchange's
///      auction price.
contract ChainlinkPrintOracleV2 is IFinalizedPrintOracle {
    /// @notice How long after a scheduled time before its print may be recorded, so every round
    ///         stamped at or before it has landed.
    uint256 public constant RECORD_DELAY = 1 hours;
    /// @notice The oldest a round may be at the moment it prices: 84 hours. The longest normal gap in
    ///         the AMZN feed's history is 75.9 hours (Friday evening to Tuesday after Labor Day); anything
    ///         older means the feed has stopped, been retired or is paused for longer than a weekend.
    uint256 public constant MAX_STALENESS = 84 hours;

    IAggregatorProxy public immutable feed;
    uint16 public immutable phase;
    /// @notice The only feed id this oracle answers for: keccak256(abi.encode(chainid, feed, phase)).
    bytes32 public immutable feedId;
    uint256 internal immutable _scale;

    struct Source {
        uint80 roundId;
        uint64 updatedAt;
    }

    mapping(bytes32 key => Print) internal _prints;
    mapping(bytes32 key => Source) internal _sources;

    event PrintRecorded(uint64 indexed scheduledAt, bool isOpen, uint80 roundId, uint256 updatedAt, uint256 priceWad);

    error ZeroAddress();
    error TooEarly(uint256 recordableAt);
    error AlreadyRecorded();
    error RoundNotInForce(uint64 round);
    error RoundTooOld(uint256 updatedAt);
    error BadAnswer(int256 answer);

    constructor(address feed_) {
        if (feed_ == address(0)) revert ZeroAddress();
        feed = IAggregatorProxy(feed_);
        phase = IAggregatorProxy(feed_).phaseId();
        feedId = keccak256(abi.encode(block.chainid, feed_, phase));
        _scale = 10 ** (18 - IAggregatorProxy(feed_).decimals());
    }

    /// @notice Records the print for the open (`isOpen`) or close at `scheduledAt`: the answer of
    ///         round `round` of the pinned phase, which must be the round in force at that moment.
    function record(uint64 scheduledAt, bool isOpen, uint64 round) external {
        uint256 recordableAt = uint256(scheduledAt) + RECORD_DELAY;
        if (block.timestamp < recordableAt) revert TooEarly(recordableAt);
        bytes32 key = printKey(scheduledAt, isOpen);
        if (_prints[key].finalizedAt != 0) revert AlreadyRecorded();

        uint80 roundId = roundIdOf(round);
        (, int256 answer,, uint256 updatedAt,) = feed.getRoundData(roundId);
        (,,, uint256 nextUpdatedAt,) = feed.getRoundData(roundIdOf(round + 1));
        // In force: updated at or before the moment, and the next round (if any yet) came after it.
        if (updatedAt == 0 || updatedAt > scheduledAt || (nextUpdatedAt != 0 && nextUpdatedAt <= scheduledAt)) {
            revert RoundNotInForce(round);
        }
        if (scheduledAt - updatedAt > MAX_STALENESS) revert RoundTooOld(updatedAt);
        // forge-lint: disable-next-line(unsafe-typecast)
        if (answer <= 0 || uint256(answer) > type(uint128).max / _scale) revert BadAnswer(answer); // positive first
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 priceWad = uint256(answer) * _scale; // answer is positive

        // forge-lint: disable-next-line(unsafe-typecast)
        uint128 price = uint128(priceWad); // capped above
        // forge-lint: disable-next-line(unsafe-typecast)
        _prints[key] = Print({priceWad: price, observedAt: scheduledAt, finalizedAt: uint64(block.timestamp)});
        // forge-lint: disable-next-line(unsafe-typecast)
        _sources[key] = Source({roundId: roundId, updatedAt: uint64(updatedAt)}); // updatedAt <= scheduledAt
        emit PrintRecorded(scheduledAt, isOpen, roundId, updatedAt, priceWad);
    }

    function getPrint(bytes32 feedId_, uint64 scheduledAt, bool isOpen) external view returns (Print memory p) {
        if (feedId_ == feedId) p = _prints[printKey(scheduledAt, isOpen)];
    }

    /// @notice The feed round a recorded print came from and when that round was updated.
    function sourceOf(uint64 scheduledAt, bool isOpen) external view returns (Source memory) {
        return _sources[printKey(scheduledAt, isOpen)];
    }

    /// @notice The proxy round id of round `round` of the pinned phase.
    function roundIdOf(uint64 round) public view returns (uint80) {
        return (uint80(phase) << 64) | round;
    }

    function printKey(uint64 scheduledAt, bool isOpen) public pure returns (bytes32) {
        // forge-lint: disable-next-line(asm-keccak256)
        return keccak256(abi.encode(scheduledAt, isOpen));
    }
}
