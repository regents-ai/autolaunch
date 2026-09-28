// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

/// @title IStocksFeeHookV1
/// @notice The official NEW/STOCK pool hook. It charges STOCK-side hook fees on every swap of a
///         registered pool and only accrues them: 100 bps to the REGENT lane and 100 bps to the staker
///         lane of the pool's memestock splitter. Both lanes are always on and the splitter is fixed
///         when the pool is registered. Conversion and downstream deposits happen outside swaps.
///         Nothing in a swap calls a splitter, a route or REGENT staking.
/// @dev Fee base: the realized STOCK amount of the swap (the trader's STOCK debit for STOCK-input
///      swaps, the pool's STOCK output before hook charges for STOCK-output swaps), floored per lane.
interface IStocksFeeHookV1 {
    event HookFeeAccrued(bytes32 indexed poolId, uint256 feeBase, uint256 regentLane, uint256 stakerLane);
    /// @notice STOCK from the REGENT lane was converted and the resulting USDC deposited into REGENT staking.
    event RegentLaneSettled(bytes32 indexed poolId, uint256 stockConverted, uint256 usdcDeposited);
    /// @notice The whole staker lane was deposited, in STOCK, into the pool's memestock splitter.
    event StakerLaneSettled(bytes32 indexed poolId, address indexed splitter, uint256 stockDeposited);

    function launchpad() external view returns (address);
    /// @notice STOCK accrued and not yet settled for one pool, per lane.
    function accrued(bytes32 poolId) external view returns (uint256 regentLane, uint256 stakerLane);
    /// @notice Lifetime totals for one pool: REGENT-lane STOCK converted and USDC deposited, and STOCK
    ///         deposited into the splitter.
    function settled(bytes32 poolId)
        external
        view
        returns (uint256 stockConverted, uint256 usdcDeposited, uint256 stockDepositedToStakers);

    /// @notice Convert `stockAmount` of the REGENT lane through the launchpad's admitted route for that
    ///         STOCK and deposit the USDC into REGENT staking (`depositUSDC`). Executor only. A failure
    ///         here reverts only this call; swaps and the staker lane are unaffected.
    function settleRegentLane(bytes32 poolId, uint256 stockAmount, uint256 minUsdcOut) external;

    /// @notice Deposit the whole staker lane, in STOCK, into the pool's memestock splitter
    ///         (`depositRecognizedRevenue`). Anyone may call.
    function settleStakerLane(bytes32 poolId) external returns (uint256 stockDeposited);
}
