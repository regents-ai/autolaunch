// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {ReentrancyGuardTransient} from "solady/utils/ReentrancyGuardTransient.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {IERC20Minimal} from "autolaunch-stocks/interfaces/IERC20Minimal.sol";
import {IRegentRevenueStakingMinimal} from "autolaunch-stocks/interfaces/IRegentRevenueStakingMinimal.sol";
import {IRobinhoodBaseRevenueReceiverV1} from "./interfaces/IRobinhoodBaseRevenueReceiverV1.sol";

/// @title RobinhoodBaseRevenueReceiverV1
/// @notice The Base address Robinhood protocol revenue is bridged to. See the interface.
/// @dev Deposit amounts are what actually arrived, never what a batch promised: attribution is a
///      Safe-recorded bookkeeping of delivered USDC and every deposit is proved by balance delta and
///      by the staking contract's own report. A deposit that fails (staking paused, allowance not
///      consumed, short pull) reverts in full and leaves the batch pending, so nothing is ever lost
///      to a partial deposit and no second bridge is needed to retry.
contract RobinhoodBaseRevenueReceiverV1 is ReentrancyGuardTransient, IRobinhoodBaseRevenueReceiverV1 {
    using SafeTransferLib for address;

    /// @notice The `sourceTag` every deposit carries into live staking.
    // forge-lint: disable-next-line(unsafe-typecast)
    bytes32 public constant SOURCE_TAG = bytes32("autolaunch-robinhood");

    address public immutable override usdc;
    address public immutable override liveStaking;
    address public immutable override baseSafe;

    uint256 public override totalPending;
    uint256 public override totalDeposited;
    mapping(uint256 batchId => uint256 amount) private _pending;

    error ZeroAddress();
    error SelfAddress();
    error NoCode(address account);
    error NotSafe(address caller);
    error ZeroAmount();
    error AttestationExceedsHeld(uint256 held, uint256 pendingAfter);
    error NothingPending(uint256 batchId);
    error DepositMismatch(uint256 expected, uint256 reported);
    error InexactTransfer(uint256 expected, uint256 found);
    error AllowanceNotConsumed(address spender, uint256 remaining);

    constructor(address usdc_, address liveStaking_, address baseSafe_) {
        _requireBindable(usdc_);
        _requireBindable(liveStaking_);
        _requireBindable(baseSafe_);
        if (usdc_.code.length == 0) revert NoCode(usdc_);
        if (liveStaking_.code.length == 0) revert NoCode(liveStaking_);
        usdc = usdc_;
        liveStaking = liveStaking_;
        baseSafe = baseSafe_;
    }

    /// @inheritdoc IRobinhoodBaseRevenueReceiverV1
    function attestDelivery(uint256 batchId, uint256 amount) external override {
        if (msg.sender != baseSafe) revert NotSafe(msg.sender);
        if (amount == 0) revert ZeroAmount();
        uint256 pendingAfter = totalPending + amount;
        uint256 held = usdc.balanceOf(address(this));
        if (pendingAfter > held) revert AttestationExceedsHeld(held, pendingAfter);
        totalPending = pendingAfter;
        uint256 batchPending = _pending[batchId] + amount;
        _pending[batchId] = batchPending;
        emit DeliveryAttested(batchId, amount, batchPending);
    }

    /// @inheritdoc IRobinhoodBaseRevenueReceiverV1
    function depositRevenue(uint256 batchId) external override nonReentrant {
        uint256 amount = _pending[batchId];
        if (amount == 0) revert NothingPending(batchId);
        _pending[batchId] = 0;
        totalPending -= amount;
        emit RevenueDeposited(batchId, liveStaking, amount);
        _deposit(amount, bytes32(batchId));
    }

    /// @inheritdoc IRobinhoodBaseRevenueReceiverV1
    function depositSurplus() external override nonReentrant {
        uint256 amount = usdc.balanceOf(address(this)) - totalPending;
        if (amount == 0) revert ZeroAmount();
        emit SurplusDeposited(liveStaking, amount);
        _deposit(amount, bytes32(0));
    }

    /// @inheritdoc IRobinhoodBaseRevenueReceiverV1
    function pendingOf(uint256 batchId) external view override returns (uint256) {
        return _pending[batchId];
    }

    /// @dev Exact approval, the pinned deposit, the reported amount, the balance delta and the
    ///      allowance all checked; any mismatch reverts the whole call.
    function _deposit(uint256 amount, bytes32 sourceRef) private {
        address staking = liveStaking;
        uint256 before = usdc.balanceOf(address(this));
        usdc.safeApprove(staking, amount);
        uint256 reported = IRegentRevenueStakingMinimal(staking).depositUSDC(amount, SOURCE_TAG, sourceRef);
        if (reported != amount) revert DepositMismatch(amount, reported);
        uint256 sent = before - usdc.balanceOf(address(this));
        if (sent != amount) revert InexactTransfer(amount, sent);
        uint256 remaining = IERC20Minimal(usdc).allowance(address(this), staking);
        if (remaining != 0) revert AllowanceNotConsumed(staking, remaining);
        totalDeposited += amount;
    }

    function _requireBindable(address value) private view {
        if (value == address(0)) revert ZeroAddress();
        if (value == address(this)) revert SelfAddress();
    }
}
