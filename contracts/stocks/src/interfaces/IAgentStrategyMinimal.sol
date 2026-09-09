// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

/// @title IAgentStrategyMinimal
/// @notice The two provenance reads this component makes on the deployed Agent `RegentLBPStrategy`.
/// @dev `Distribution` mirrors `RegentLBPStrategy.Distribution` field for field so the ABI decoding of
///      `distribution(address)` is exact. Only `.splitter` is consumed.
interface IAgentStrategyMinimal {
    enum Lifecycle {
        None,
        Active,
        Graduated,
        Failed
    }

    struct Distribution {
        Lifecycle lifecycle;
        uint64 startBlock;
        uint64 endBlock;
        uint64 claimBlock;
        uint64 migrationBlock;
        uint128 requiredRegentRaised;
        uint128 reserve;
        uint128 lpRegentUsed;
        uint128 lpSubjectUsed;
        uint160 finalSqrtPriceX96;
        uint256 launchId;
        address subject;
        address escrow;
        address treasury;
        address splitter;
        address receiver;
        bytes32 poolId;
        uint256 lpTokenId;
    }

    function auctionOfSubject(address subject) external view returns (address auction);
    function distribution(address auction) external view returns (Distribution memory);
}
