// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

/// @title IStocksFeeHookV1
/// @notice The official NEW/STOCK pool hook. It charges STOCK-side hook fees on every swap of a
///         registered pool and only accrues them: 100 bps to the mandatory REGENT bucket and, when
///         enabled for the pool at that moment, 100 bps to the subject bucket of the splitter then
///         active. Conversion to USDC and downstream deposits happen outside swaps through
///         `settle`. Nothing in a swap calls a splitter, a route or REGENT staking.
/// @dev Fee base: the realized STOCK amount of the swap (the trader's STOCK debit for STOCK-input
///      swaps, the pool's STOCK output before hook charges for STOCK-output swaps), floored per lane.
///      Every accrual is attributed to the destination in effect when it accrued; later
///      administration never redirects an existing bucket.
interface IStocksFeeHookV1 {
    /// @notice A bucket is (poolId, destination). The REGENT lane's destination is the constant
    ///         `REGENT_DESTINATION` sentinel; a subject lane's destination is the splitter that was
    ///         active when the fee accrued.
    event HookFeeAccrued(
        bytes32 indexed poolId, address indexed destination, uint256 feeBase, uint256 regentLane, uint256 subjectLane
    );
    /// @notice STOCK from one bucket was converted and the resulting USDC deposited.
    event BucketSettled(
        bytes32 indexed poolId, address indexed destination, uint256 stockConverted, uint256 usdcDeposited, bytes32 sourceRef
    );

    function REGENT_DESTINATION() external pure returns (address);
    function launchpad() external view returns (address);
    /// @notice STOCK accrued and not yet settled for one bucket.
    function accrued(bytes32 poolId, address destination) external view returns (uint256);
    /// @notice Lifetime STOCK converted and USDC deposited for one bucket.
    function settled(bytes32 poolId, address destination) external view returns (uint256 stockConverted, uint256 usdcDeposited);

    /// @notice Convert `stockAmount` of one bucket through the launchpad's admitted route for that
    ///         STOCK and deposit the USDC: REGENT bucket -> REGENT staking `depositUSDC`, subject
    ///         bucket -> that splitter's `depositRecognizedRevenue(USDC, ...)`. Executor only.
    ///         A failure here reverts only this call; swaps and other buckets are unaffected.
    function settle(bytes32 poolId, address destination, uint256 stockAmount, uint256 minUsdcOut) external;
}
