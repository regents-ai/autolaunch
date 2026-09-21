// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

/// @title IRobinhoodProtocolRevenueInboxV1
/// @notice The one USDG destination of every protocol revenue stream on the Robinhood chain: hook
///         protocol lanes and splitter skims. It collects, it records provenance, and
///         the Robinhood Safe bridges collected USDG to a Base destination in reviewed batches.
///         The inbox takes no skim of its own.
/// @dev Everything that can change is Safe-only and versioned. `baseDestination` carries a version
///      counter so a bridge proposal reviewed against one destination can never execute against
///      another; every batch captures the destination and version it was initiated with, and a
///      later change never touches an initiated batch. Delivered USDC on Base stays where it was
///      delivered; refunded USDG lands back here and is simply available again.
interface IRobinhoodProtocolRevenueInboxV1 {
    struct Batch {
        uint256 amountUsdg;
        address baseDestination;
        uint64 destinationVersion;
        uint64 deadline;
        address adapter;
        uint256 minimumUsdcOut;
        bytes32 transferRef;
    }

    /// @notice `source` is the depositing contract; `sourceTag` names its kind (hook, splitter);
    ///         `sourceRef` is that source's own reference (pool id, revenue ref).
    event RevenueCollected(
        address indexed source, bytes32 indexed sourceTag, bytes32 indexed sourceRef, uint256 amount
    );
    event BaseDestinationSet(address indexed previous, address indexed current, uint64 indexed version);
    event BridgeAdapterSet(address indexed previous, address indexed current);
    event RevenueBridgeInitiated(
        uint256 indexed batchId,
        address indexed baseDestination,
        uint64 indexed destinationVersion,
        address adapter,
        uint256 amountUsdg,
        uint256 minimumUsdcOut,
        uint64 deadline,
        bytes32 transferRef
    );
    event UnsupportedTokenRecovered(address indexed token, address indexed safe, uint256 amount);

    function usdg() external view returns (address);
    function adminSafe() external view returns (address);
    function baseDestination() external view returns (address);
    function destinationVersion() external view returns (uint64);
    function bridgeAdapter() external view returns (address);
    function nextBatchId() external view returns (uint256);
    function totalCollected() external view returns (uint256);
    function totalBridged() external view returns (uint256);
    /// @notice USDG held here right now and not yet bridged: every collected deposit plus every refund.
    function available() external view returns (uint256);
    function batches(uint256 batchId) external view returns (Batch memory);

    /// @notice Recognize exactly `amount` USDG as protocol revenue, pulled from the caller in this call.
    /// @return received The amount that arrived, always equal to `amount`.
    function deposit(uint256 amount, bytes32 sourceTag, bytes32 sourceRef) external returns (uint256 received);

    /// @notice Safe only. Point future batches at a new Base destination and bump the version.
    function setBaseDestination(address newDestination) external;

    /// @notice Safe only. Replace the reviewed bridge adapter. Zero disables bridging.
    function setBridgeAdapter(address adapter) external;

    /// @notice Safe only. Bridge `amountUsdg` of the available balance to the current destination
    ///         through the reviewed adapter. Every argument was reviewed in the Safe proposal:
    ///         `expectedDestinationVersion` must be the current version and `reviewedAdapter` the
    ///         current adapter, or the proposal is stale and refused.
    function bridgeRevenue(
        uint256 amountUsdg,
        uint256 minimumUsdcOut,
        uint64 deadline,
        uint64 expectedDestinationVersion,
        address reviewedAdapter
    ) external returns (uint256 batchId);

    /// @notice Send this inbox's whole balance of a token other than USDG to the Safe. Permissionless.
    function recoverUnsupportedToken(address token) external;
}
