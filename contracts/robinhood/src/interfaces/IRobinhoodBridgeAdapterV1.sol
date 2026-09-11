// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

/// @title IRobinhoodBridgeAdapterV1
/// @notice The one reviewed bridge execution path the protocol revenue inbox may use. An adapter
///         wraps exactly one bridge route (Robinhood USDG -> Base USDC) and builds every byte of
///         that route's calldata itself from the five arguments below. The inbox never supplies
///         calldata, never names a router, and never sends to a route whose destination a caller
///         could override.
/// @dev Explicit ERC-20 deposit path: the inbox grants the adapter an exact USDG allowance for
///      `amountUsdg` immediately before calling `bridge` and proves afterwards that exactly that
///      amount left and the allowance is back at zero. The adapter must deliver at least
///      `minimumUsdcOut` native Base USDC to `baseDestination` on Base or fail; on a failed or
///      refunded transfer the route's refund address must be the inbox (`msg.sender`), so refunded
///      USDG becomes available for a later batch. Slippage, fees and finality are the adapter's
///      review scope, not the inbox's.
interface IRobinhoodBridgeAdapterV1 {
    /// @notice The USDG this adapter bridges. Must equal the inbox's USDG.
    function usdg() external view returns (address);

    /// @notice The chain this adapter delivers to. Must be Base mainnet.
    function destinationChainId() external view returns (uint256);

    /// @notice Pull exactly `amountUsdg` from the caller and initiate one transfer to
    ///         `baseDestination` on Base.
    /// @param amountUsdg Exact USDG to bridge, already approved by the caller.
    /// @param baseDestination The Base address that must receive the USDC.
    /// @param minimumUsdcOut The least native Base USDC the destination may receive.
    /// @param deadline Latest acceptable `block.timestamp` for initiating the transfer.
    /// @param batchId The inbox batch this transfer settles, for off-chain attribution.
    /// @return transferRef The route's own identifier for the initiated transfer, or zero if the
    ///         route has none.
    function bridge(
        uint256 amountUsdg,
        address baseDestination,
        uint256 minimumUsdcOut,
        uint256 deadline,
        uint256 batchId
    ) external returns (bytes32 transferRef);
}
