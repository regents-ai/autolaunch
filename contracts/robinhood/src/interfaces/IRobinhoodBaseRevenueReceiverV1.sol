// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

/// @title IRobinhoodBaseRevenueReceiverV1
/// @notice The Base-side destination of every Robinhood protocol revenue batch. Bridged native Base
///         USDC lands here; each delivery is attributed to its inbox batch by the Base Safe from the
///         route's delivery evidence; anyone may then deposit an attributed delivery into live REGENT
///         staking with `depositUSDC`, and retry as often as needed until it succeeds.
/// @dev Deployed on Base, bound to Base USDC and the live staking contract. It holds no authority over
///      subject rewards, refunds or LP principal: the only USDC it ever sees is what a bridge delivers
///      to it, and the only place it can send USDC is the staking deposit.
interface IRobinhoodBaseRevenueReceiverV1 {
    event DeliveryAttested(uint256 indexed batchId, uint256 amount, uint256 pendingAfter);
    event RevenueDeposited(uint256 indexed batchId, address indexed staking, uint256 amount);
    event SurplusDeposited(address indexed staking, uint256 amount);

    function usdc() external view returns (address);
    function liveStaking() external view returns (address);
    function baseSafe() external view returns (address);
    /// @notice USDC attributed to a batch and not yet deposited.
    function pendingOf(uint256 batchId) external view returns (uint256);
    /// @notice The sum of every batch's pending amount.
    function totalPending() external view returns (uint256);
    function totalDeposited() external view returns (uint256);

    /// @notice Safe only. Attribute `amount` of delivered USDC to `batchId`. The attested total may
    ///         never exceed the USDC actually held here beyond what is already pending.
    function attestDelivery(uint256 batchId, uint256 amount) external;

    /// @notice Deposit one batch's whole pending amount into live staking. Permissionless; a
    ///         failed deposit reverts and leaves the batch pending for a later retry.
    function depositRevenue(uint256 batchId) external;

    /// @notice Deposit USDC held here that no batch claims. Permissionless.
    function depositSurplus() external;
}
