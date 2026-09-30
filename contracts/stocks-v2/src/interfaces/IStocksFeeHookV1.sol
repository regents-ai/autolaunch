// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

/// @title IStocksFeeHookV1
/// @notice The official NEW/STOCK pool hook. It charges STOCK-side hook fees on every swap of a
///         registered pool and only accrues them: 30 bps to the launch's creator, 100 bps to the REGENT
///         lane and 300 bps to the staker lane of the pool's memestock splitter. All three lanes are
///         always on and the creator and splitter are fixed when the pool is registered. Conversion and
///         payouts happen outside swaps. Nothing in a swap calls a splitter, a route, REGENT staking or
///         the creator.
/// @dev Fee base: the realized STOCK amount of the swap (the trader's STOCK debit for STOCK-input
///      swaps, the pool's STOCK output before hook charges for STOCK-output swaps). The whole fee is
///      430 bps of it, floored once; the creator and REGENT lanes are each floored and the staker lane
///      is the rest.
interface IStocksFeeHookV1 {
    event HookFeeAccrued(
        bytes32 indexed poolId, uint256 feeBase, uint256 creatorLane, uint256 regentLane, uint256 stakerLane
    );
    /// @notice The whole creator lane was paid, in STOCK, to the launch's creator.
    event CreatorLaneSettled(bytes32 indexed poolId, address indexed creator, uint256 stockPaid);
    /// @notice STOCK from the REGENT lane was converted and the resulting USDC deposited into REGENT staking.
    event RegentLaneSettled(bytes32 indexed poolId, uint256 stockConverted, uint256 usdcDeposited);
    /// @notice The whole staker lane was deposited, in STOCK, into the pool's memestock splitter.
    event StakerLaneSettled(bytes32 indexed poolId, address indexed splitter, uint256 stockDeposited);

    function launchpad() external view returns (address);
    /// @notice STOCK accrued and not yet settled for one pool, per lane.
    function accrued(bytes32 poolId) external view returns (uint256 creatorLane, uint256 regentLane, uint256 stakerLane);
    /// @notice Lifetime totals for one pool: STOCK paid to the creator, REGENT-lane STOCK converted and
    ///         USDC deposited, and STOCK deposited into the splitter.
    function settled(bytes32 poolId)
        external
        view
        returns (
            uint256 stockPaidToCreator,
            uint256 stockConverted,
            uint256 usdcDeposited,
            uint256 stockDepositedToStakers
        );

    /// @notice Pay the whole creator lane, in STOCK, to the launch's creator. Anyone may call.
    function settleCreatorLane(bytes32 poolId) external returns (uint256 stockPaid);

    /// @notice Convert `stockAmount` of the REGENT lane through the launchpad's admitted route for that
    ///         STOCK and deposit the USDC into REGENT staking (`depositUSDC`). Executor only. A failure
    ///         here reverts only this call; swaps and the other lanes are unaffected.
    function settleRegentLane(bytes32 poolId, uint256 stockAmount, uint256 minUsdcOut) external;

    /// @notice Deposit the whole staker lane, in STOCK, into the pool's memestock splitter
    ///         (`depositRecognizedRevenue`). Anyone may call.
    function settleStakerLane(bytes32 poolId) external returns (uint256 stockDeposited);
}
