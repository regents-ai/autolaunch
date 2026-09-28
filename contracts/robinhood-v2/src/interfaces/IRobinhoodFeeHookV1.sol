// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

/// @title IRobinhoodFeeHookV1
/// @notice The official NEW/STOCK pool hook of the Robinhood launchpad. It charges STOCK-side hook
///         fees on every swap of a registered pool and only accrues them: 100 bps to the protocol lane
///         and 100 bps to the staker lane of the pool's memestock splitter. Both lanes are always on
///         and the splitter is fixed when the pool is registered. Conversion and downstream deposits
///         happen outside swaps. Nothing in a swap calls a splitter, a route or the inbox.
/// @dev Fee base: the realized STOCK amount of the swap (the trader's STOCK debit for STOCK-input
///      swaps, the pool's STOCK output before hook charges for STOCK-output swaps), floored per lane.
interface IRobinhoodFeeHookV1 {
    event HookFeeAccrued(bytes32 indexed poolId, uint256 feeBase, uint256 protocolLane, uint256 stakerLane);
    /// @notice STOCK from the protocol lane was converted and the resulting USDG deposited into the inbox.
    event ProtocolLaneSettled(bytes32 indexed poolId, uint256 stockConverted, uint256 usdgDeposited);
    /// @notice The whole staker lane was deposited, in STOCK, into the pool's memestock splitter.
    event StakerLaneSettled(bytes32 indexed poolId, address indexed splitter, uint256 stockDeposited);

    function launchpad() external view returns (address);
    function usdg() external view returns (address);
    function inbox() external view returns (address);
    /// @notice STOCK accrued and not yet settled for one pool, per lane.
    function accrued(bytes32 poolId) external view returns (uint256 protocolLane, uint256 stakerLane);
    /// @notice Lifetime totals for one pool: protocol-lane STOCK converted and USDG deposited, and STOCK
    ///         deposited into the splitter.
    function settled(bytes32 poolId)
        external
        view
        returns (uint256 stockConverted, uint256 usdgDeposited, uint256 stockDepositedToStakers);

    /// @notice Convert `stockAmount` of the protocol lane through the launchpad's admitted route for that
    ///         STOCK and deposit the USDG into the protocol revenue inbox (`deposit`). Executor only. A failure
    ///         here reverts only this call; swaps and the staker lane are unaffected.
    function settleProtocolLane(bytes32 poolId, uint256 stockAmount, uint256 minUsdgOut) external;

    /// @notice Deposit the whole staker lane, in STOCK, into the pool's memestock splitter
    ///         (`depositRecognizedRevenue`). Anyone may call.
    function settleStakerLane(bytes32 poolId) external returns (uint256 stockDeposited);
}
