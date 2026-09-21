// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {ReentrancyGuardTransient} from "solady/utils/ReentrancyGuardTransient.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {IERC20Views} from "autolaunch-stocks/interfaces/IERC20Views.sol";
import {IRobinhoodBridgeAdapterV1} from "./interfaces/IRobinhoodBridgeAdapterV1.sol";
import {IRobinhoodProtocolRevenueInboxV1} from "./interfaces/IRobinhoodProtocolRevenueInboxV1.sol";
import {RobinhoodPreset} from "./RobinhoodPreset.sol";

/// @title RobinhoodProtocolRevenueInboxV1
/// @notice Collects every USDG protocol revenue stream on the Robinhood chain and bridges it to Base
///         in Safe-reviewed batches. See `IRobinhoodProtocolRevenueInboxV1`.
/// @dev Authority is exactly one account, the Robinhood Safe, checked as `msg.sender` (never
///      `tx.origin`, never a Safe owner). It may change the Base destination, replace the reviewed
///      adapter and initiate batches; it can never take USDG anywhere but the current destination
///      through the current adapter, and never USDC. Deposits are permissionless and exact. Every
///      state change emits. The USDG binding, the Safe and the whole recognized-revenue policy are
///      fixed at construction.
contract RobinhoodProtocolRevenueInboxV1 is ReentrancyGuardTransient, IRobinhoodProtocolRevenueInboxV1 {
    using SafeTransferLib for address;

    address public immutable override usdg;
    address public immutable override adminSafe;

    address public override baseDestination;
    uint64 public override destinationVersion;
    address public override bridgeAdapter;
    uint256 public override nextBatchId = 1;
    uint256 public override totalCollected;
    uint256 public override totalBridged;

    mapping(uint256 batchId => Batch) private _batches;

    error ZeroAddress();
    error SelfAddress();
    error NoCode(address account);
    error UnexpectedDecimals(uint8 expected, uint8 found);
    error NotSafe(address caller);
    error ZeroAmount();
    error InexactTransfer(uint256 expected, uint256 found);
    error NoDestination();
    error NoAdapter();
    error AdapterBindingMismatch(address expected, address found);
    error AdapterChainMismatch(uint256 expected, uint256 found);
    error StaleDestinationVersion(uint64 current, uint64 expected);
    error StaleAdapter(address current, address reviewed);
    error Expired(uint64 deadline, uint256 currentTimestamp);
    error ZeroMinimumOut();
    error InsufficientAvailable(uint256 available, uint256 requested);
    error AllowanceNotConsumed(address spender, uint256 remaining);
    error ProtectedToken(address token);

    constructor(address usdg_, address adminSafe_) {
        _requireBindable(usdg_);
        _requireBindable(adminSafe_);
        if (usdg_.code.length == 0) revert NoCode(usdg_);
        uint8 decimals = IERC20Views(usdg_).decimals();
        if (decimals != RobinhoodPreset.USDG_DECIMALS) {
            revert UnexpectedDecimals(RobinhoodPreset.USDG_DECIMALS, decimals);
        }
        usdg = usdg_;
        adminSafe = adminSafe_;
    }

    modifier onlySafe() {
        if (msg.sender != adminSafe) revert NotSafe(msg.sender);
        _;
    }

    // -------------------------------------------------------------------------
    // collection
    // -------------------------------------------------------------------------

    /// @inheritdoc IRobinhoodProtocolRevenueInboxV1
    function deposit(uint256 amount, bytes32 sourceTag, bytes32 sourceRef)
        external
        override
        nonReentrant
        returns (uint256 received)
    {
        if (amount == 0) revert ZeroAmount();

        totalCollected += amount;
        emit RevenueCollected(msg.sender, sourceTag, sourceRef, amount);

        uint256 before = usdg.balanceOf(address(this));
        usdg.safeTransferFrom(msg.sender, address(this), amount);
        received = usdg.balanceOf(address(this)) - before;
        if (received != amount) revert InexactTransfer(amount, received);
    }

    // -------------------------------------------------------------------------
    // Safe surface
    // -------------------------------------------------------------------------

    /// @inheritdoc IRobinhoodProtocolRevenueInboxV1
    /// @dev Batches already initiated keep the destination they captured. USDG still here, refunds
    ///      included, goes to the new destination from the next batch on.
    function setBaseDestination(address newDestination) external override onlySafe {
        if (newDestination == address(0)) revert ZeroAddress();
        address previous = baseDestination;
        uint64 version = destinationVersion + 1;
        baseDestination = newDestination;
        destinationVersion = version;
        emit BaseDestinationSet(previous, newDestination, version);
    }

    /// @inheritdoc IRobinhoodProtocolRevenueInboxV1
    /// @dev A nonzero adapter must be deployed code bound to this USDG and to Base. The review of what
    ///      the adapter does with the funds is the Safe's; the inbox only proves the binding.
    function setBridgeAdapter(address adapter) external override onlySafe {
        if (adapter != address(0)) {
            if (adapter == address(this)) revert SelfAddress();
            if (adapter.code.length == 0) revert NoCode(adapter);
            address adapterUsdg = IRobinhoodBridgeAdapterV1(adapter).usdg();
            if (adapterUsdg != usdg) revert AdapterBindingMismatch(usdg, adapterUsdg);
            uint256 chainId = IRobinhoodBridgeAdapterV1(adapter).destinationChainId();
            if (chainId != RobinhoodPreset.BASE_CHAIN_ID) {
                revert AdapterChainMismatch(RobinhoodPreset.BASE_CHAIN_ID, chainId);
            }
        }
        address previous = bridgeAdapter;
        bridgeAdapter = adapter;
        emit BridgeAdapterSet(previous, adapter);
    }

    /// @inheritdoc IRobinhoodProtocolRevenueInboxV1
    /// @dev Checks, then the batch record, then exactly one adapter call with an exact allowance,
    ///      then proof that exactly `amountUsdg` left and no allowance remains. The destination,
    ///      amount, output asset (the adapter's fixed Base USDC), minimum output, deadline and refund
    ///      destination (this inbox) are all bound before the adapter runs.
    // slither-disable-next-line reentrancy-no-eth,reentrancy-benign
    function bridgeRevenue(
        uint256 amountUsdg,
        uint256 minimumUsdcOut,
        uint64 deadline,
        uint64 expectedDestinationVersion,
        address reviewedAdapter
    ) external override onlySafe nonReentrant returns (uint256 batchId) {
        if (amountUsdg == 0) revert ZeroAmount();
        if (minimumUsdcOut == 0) revert ZeroMinimumOut();
        address destination = baseDestination;
        if (destination == address(0)) revert NoDestination();
        uint64 version = destinationVersion;
        if (version != expectedDestinationVersion) revert StaleDestinationVersion(version, expectedDestinationVersion);
        address adapter = bridgeAdapter;
        if (adapter == address(0)) revert NoAdapter();
        if (reviewedAdapter != adapter) revert StaleAdapter(adapter, reviewedAdapter);
        // The Safe's own deadline; block time is the only clock a proposal can reason about.
        // slither-disable-next-line timestamp
        if (block.timestamp > deadline) revert Expired(deadline, block.timestamp);
        uint256 held = usdg.balanceOf(address(this));
        if (amountUsdg > held) revert InsufficientAvailable(held, amountUsdg);

        batchId = nextBatchId;
        nextBatchId = batchId + 1;
        totalBridged += amountUsdg;
        Batch storage batch = _batches[batchId];
        batch.amountUsdg = amountUsdg;
        batch.baseDestination = destination;
        batch.destinationVersion = version;
        batch.deadline = deadline;
        batch.adapter = adapter;
        batch.minimumUsdcOut = minimumUsdcOut;

        usdg.safeApprove(adapter, amountUsdg);
        bytes32 transferRef =
            IRobinhoodBridgeAdapterV1(adapter).bridge(amountUsdg, destination, minimumUsdcOut, deadline, batchId);
        batch.transferRef = transferRef;

        uint256 sent = held - usdg.balanceOf(address(this));
        if (sent != amountUsdg) revert InexactTransfer(amountUsdg, sent);
        uint256 remaining = IERC20Views(usdg).allowance(address(this), adapter);
        if (remaining != 0) revert AllowanceNotConsumed(adapter, remaining);

        emit RevenueBridgeInitiated(
            batchId, destination, version, adapter, amountUsdg, minimumUsdcOut, deadline, transferRef
        );
    }

    // -------------------------------------------------------------------------
    // recovery
    // -------------------------------------------------------------------------

    /// @inheritdoc IRobinhoodProtocolRevenueInboxV1
    /// @dev Permissionless because it decides nothing: the whole balance, always to the Safe, USDG
    ///      refused. One guarded transfer and nothing else, so a hostile token can fail only its own call.
    function recoverUnsupportedToken(address token) external override nonReentrant {
        if (token == usdg) revert ProtectedToken(token);
        uint256 amount = token.balanceOf(address(this));
        if (amount == 0) revert ZeroAmount();
        emit UnsupportedTokenRecovered(token, adminSafe, amount);
        token.safeTransfer(adminSafe, amount);
    }

    // -------------------------------------------------------------------------
    // reads
    // -------------------------------------------------------------------------

    /// @inheritdoc IRobinhoodProtocolRevenueInboxV1
    function available() external view override returns (uint256) {
        return usdg.balanceOf(address(this));
    }

    /// @inheritdoc IRobinhoodProtocolRevenueInboxV1
    function batches(uint256 batchId) external view override returns (Batch memory) {
        return _batches[batchId];
    }

    function _requireBindable(address value) private view {
        if (value == address(0)) revert ZeroAddress();
        if (value == address(this)) revert SelfAddress();
    }
}
