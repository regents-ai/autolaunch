// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

/// @dev How long after a boundary before its price is applied. The factory turns the week over at
///      the same moment, so the series and the factory read this one value.
uint256 constant BOUNDARY_SETTLE_DELAY = 1 hours;

/// @notice Everything a weekly series is made from, fixed when it opens.
struct SeriesConfig {
    address asset;
    /// The Chainlink aggregator proxy the prices come from.
    address feed;
    /// The proxy phase (one fixed aggregator) every price of the series is read from.
    uint16 phase;
    uint8 feedDecimals;
    /// Most raw stock the series may hold for outstanding pairs at once.
    uint256 depositCap;
    /// keccak256 of the published terms.
    bytes32 termsHash;
    /// The initial close, then each trading day's open and close, ending on a close. UTC seconds.
    uint64[] boundaries;
    string overnightName;
    string overnightSymbol;
    string sessionName;
    string sessionSymbol;
}

/// @notice What a series reads from the factory that creates it, once, in its constructor.
interface ISeriesConfigSource {
    function seriesConfig(uint256 week) external view returns (SeriesConfig memory);
}

/// @notice The parts of a Chainlink `EACAggregatorProxy` the series and factory use. Rounds of any
///         phase are read through the proxy as `getRoundData(phase << 64 | round)`: the aggregators
///         behind it only answer the proxy.
interface IAggregatorProxy {
    function phaseId() external view returns (uint16);
    function phaseAggregators(uint16 phase) external view returns (address);
    function getRoundData(uint80 roundId)
        external
        view
        returns (uint80, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

interface IAggregatorDecimals {
    function decimals() external view returns (uint8);
}
