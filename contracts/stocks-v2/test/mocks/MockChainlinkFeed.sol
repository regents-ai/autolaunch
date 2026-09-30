// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {IChainlinkAggregatorMinimal} from "../../src/interfaces/IChainlinkAggregatorMinimal.sol";

/// @notice A settable AggregatorV3 double for hermetic route tests. Not evidence about a live feed.
contract MockChainlinkFeed is IChainlinkAggregatorMinimal {
    uint8 public immutable override decimals;
    int256 public answer;
    uint256 public updatedAt;

    constructor(uint8 decimals_, int256 answer_, uint256 updatedAt_) {
        decimals = decimals_;
        answer = answer_;
        updatedAt = updatedAt_;
    }

    function set(int256 answer_, uint256 updatedAt_) external {
        answer = answer_;
        updatedAt = updatedAt_;
    }

    function latestRoundData() external view override returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, updatedAt, updatedAt, 1);
    }
}
