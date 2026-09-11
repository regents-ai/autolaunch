// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

/// @title IRobinhoodFeeHookV1
/// @notice The official-pool hook of one Robinhood launchpad. Every registered pool pairs NEW with its
///         fee currency: USDG for a revenue-share launch, the admitted STOCK for a stock-pair launch.
///         The hook charges fee-currency lanes on every swap and only accrues them: 100 bps to the
///         mandatory protocol bucket and, when a subject splitter is active for the pool at that
///         moment, 100 bps to that splitter's bucket. Deposits happen outside swaps through `settle`:
///         a USDG bucket is deposited as it is, a STOCK bucket is first converted to USDG through the
///         launchpad's admitted route.
/// @dev Fee base: the realized fee-currency amount of the swap, floored per lane. Every accrual is
///      attributed to the destination in effect when it accrued; later administration never
///      redirects an existing bucket.
interface IRobinhoodFeeHookV1 {
    /// @notice A bucket is (poolId, destination). The protocol lane's destination is the inbox
    ///         (`PROTOCOL_DESTINATION`); a subject lane's destination is the splitter that was active.
    event HookFeeAccrued(
        bytes32 indexed poolId, address indexed destination, uint256 feeBase, uint256 protocolLane, uint256 subjectLane
    );
    /// @notice Fee currency from one bucket was converted (STOCK) or taken as is (USDG) and deposited.
    event BucketSettled(
        bytes32 indexed poolId,
        address indexed destination,
        uint256 feeTokenConsumed,
        uint256 usdgDeposited,
        bytes32 sourceRef
    );

    function PROTOCOL_DESTINATION() external view returns (address);
    function launchpad() external view returns (address);
    function usdg() external view returns (address);
    function inbox() external view returns (address);
    function accrued(bytes32 poolId, address destination) external view returns (uint256);
    function settled(bytes32 poolId, address destination)
        external
        view
        returns (uint256 feeTokenConsumed, uint256 usdgDeposited);

    /// @notice Deposit `amount` of one bucket. USDG buckets: anyone may call, the amount is deposited
    ///         unchanged. STOCK buckets: executor only, the amount is converted through the admitted
    ///         route and at least `minUsdgOut` must come out. Protocol bucket -> inbox `deposit`,
    ///         subject bucket -> that splitter's `depositRecognizedRevenue(USDG, ...)`. A failure here
    ///         reverts only this call; swaps and other buckets are unaffected.
    function settle(bytes32 poolId, address destination, uint256 amount, uint256 minUsdgOut) external;
}
