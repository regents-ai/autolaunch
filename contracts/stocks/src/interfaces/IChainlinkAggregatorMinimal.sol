// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

/// @title IChainlinkAggregatorMinimal
/// @notice The slice of a Chainlink AggregatorV3 proxy the stock route reads.
interface IChainlinkAggregatorMinimal {
    function decimals() external view returns (uint8);

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}
