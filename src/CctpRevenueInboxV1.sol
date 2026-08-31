// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "./interfaces/IERC20.sol";
import {ITokenMessengerV2} from "./interfaces/ITokenMessengerV2.sol";
import {SafeToken} from "./libraries/SafeToken.sol";

/// @notice Permissionlessly burns bounded source USDC for a fixed Base receiver through CCTP V2.
/// @dev Bindings are constructor-only storage rather than Solidity immutables so every instance has
///      one exact runtime code identity. The factory separately checks that identity and every
///      binding before returning an existing CREATE2 route.
contract CctpRevenueInboxV1 {
    uint32 public constant BASE_CCTP_DOMAIN = 6;
    uint32 public constant FINALITY_THRESHOLD = 2000;
    uint256 public constant BPS_DENOMINATOR = 10_000;

    // Constructor-only storage is intentional: it preserves one exact runtime code identity across
    // routes, while the factory verifies every binding before returning an existing route.
    // slither-disable-next-line immutable-states
    bytes32 public routeId;
    // slither-disable-next-line immutable-states
    IERC20 public usdc;
    // slither-disable-next-line immutable-states
    ITokenMessengerV2 public tokenMessenger;
    // slither-disable-next-line immutable-states
    uint32 public sourceDomain;
    // slither-disable-next-line immutable-states
    uint256 public sourceChainId;
    // slither-disable-next-line immutable-states
    bytes32 public sourceNamespace;
    // slither-disable-next-line immutable-states
    uint256 public minimumSweep;
    // slither-disable-next-line immutable-states
    uint256 public maxBurnPerMessage;
    // slither-disable-next-line immutable-states
    uint256 public maxFeeBps;
    // slither-disable-next-line immutable-states
    address public baseReceiver;
    // slither-disable-next-line immutable-states
    address public baseSplitter;

    uint256 private _sweepLock = 1;

    event RevenueBridgeInitiated(
        bytes32 indexed routeId,
        uint256 amount,
        uint256 maxFee,
        address indexed baseReceiver,
        address indexed baseSplitter
    );

    error ZeroBinding();
    error InvalidSweepBounds(uint256 minimumSweep, uint256 maxBurnPerMessage);
    error InvalidFeeCeiling(uint256 maxFeeBps);
    error BelowMinimumSweep(uint256 amount, uint256 minimumSweep);
    error ExcessiveFeeAuthorization(uint256 maxFee, uint256 feeCeiling);
    error FeeNotLessThanAmount(uint256 maxFee, uint256 amount);
    error InexactMessengerAllowance(uint256 expected, uint256 found);
    error InexactMessengerConsumption(uint256 expected, uint256 consumed);
    error ResidualMessengerAllowance(uint256 remaining);
    error ReentrantSweep();

    constructor(
        bytes32 routeId_,
        address usdc_,
        address tokenMessenger_,
        uint32 sourceDomain_,
        uint256 sourceChainId_,
        bytes32 sourceNamespace_,
        uint256 minimumSweep_,
        uint256 maxBurnPerMessage_,
        uint256 maxFeeBps_,
        address baseReceiver_,
        address baseSplitter_
    ) {
        if (
            routeId_ == bytes32(0) || usdc_ == address(0) || tokenMessenger_ == address(0) || sourceChainId_ == 0
                || sourceNamespace_ == bytes32(0) || baseReceiver_ == address(0) || baseSplitter_ == address(0)
        ) revert ZeroBinding();
        if (minimumSweep_ == 0 || minimumSweep_ > maxBurnPerMessage_) {
            revert InvalidSweepBounds(minimumSweep_, maxBurnPerMessage_);
        }
        if (maxFeeBps_ > BPS_DENOMINATOR) revert InvalidFeeCeiling(maxFeeBps_);

        routeId = routeId_;
        usdc = IERC20(usdc_);
        tokenMessenger = ITokenMessengerV2(tokenMessenger_);
        sourceDomain = sourceDomain_;
        sourceChainId = sourceChainId_;
        sourceNamespace = sourceNamespace_;
        minimumSweep = minimumSweep_;
        maxBurnPerMessage = maxBurnPerMessage_;
        maxFeeBps = maxFeeBps_;
        baseReceiver = baseReceiver_;
        baseSplitter = baseSplitter_;
    }

    /// @notice Burns a bounded amount of this inbox's exact source USDC into its fixed Base route.
    /// @param maxFee The most source USDC that CCTP may charge on destination.
    function sweep(uint256 maxFee) external returns (uint256 amount) {
        if (_sweepLock != 1) revert ReentrantSweep();
        _sweepLock = 2;

        IERC20 usdc_ = usdc;
        uint256 beforeBalance = SafeToken.balanceOf(usdc_, address(this));
        uint256 cap = maxBurnPerMessage;
        amount = beforeBalance < cap ? beforeBalance : cap;
        uint256 minimum = minimumSweep;
        if (amount < minimum) revert BelowMinimumSweep(amount, minimum);

        uint256 feeCeiling = _feeCeiling(amount, maxFeeBps);
        if (maxFee > feeCeiling) revert ExcessiveFeeAuthorization(maxFee, feeCeiling);
        if (maxFee >= amount) revert FeeNotLessThanAmount(maxFee, amount);

        // The lock is set before every interaction and a hostile callback test covers reentry.
        // slither-disable-next-line reentrancy-no-eth,reentrancy-events
        _authorizeAndBurn(usdc_, beforeBalance, amount, maxFee);

        _sweepLock = 1;
        emit RevenueBridgeInitiated(routeId, amount, maxFee, baseReceiver, baseSplitter);
    }

    function _authorizeAndBurn(IERC20 usdc_, uint256 beforeBalance, uint256 amount, uint256 maxFee) private {
        ITokenMessengerV2 tokenMessenger_ = tokenMessenger;
        address messenger = address(tokenMessenger_);
        SafeToken.approve(usdc_, messenger, amount);
        uint256 authorized = SafeToken.allowance(usdc_, address(this), messenger);
        if (authorized != amount) revert InexactMessengerAllowance(amount, authorized);

        tokenMessenger_.depositForBurn(
            amount,
            BASE_CCTP_DOMAIN,
            bytes32(uint256(uint160(baseReceiver))),
            address(usdc_),
            bytes32(0),
            maxFee,
            FINALITY_THRESHOLD
        );

        uint256 afterBalance = SafeToken.balanceOf(usdc_, address(this));
        uint256 consumed = beforeBalance >= afterBalance ? beforeBalance - afterBalance : 0;
        if (consumed != amount) revert InexactMessengerConsumption(amount, consumed);

        uint256 remaining = SafeToken.allowance(usdc_, address(this), messenger);
        if (remaining != 0) revert ResidualMessengerAllowance(remaining);
        SafeToken.approve(usdc_, messenger, 0);
    }

    function _feeCeiling(uint256 amount, uint256 feeBps) private pure returns (uint256) {
        // Quotient/remainder decomposition gives the exact floor without overflowing at uint256 max.
        // forge-lint: disable-next-line(divide-before-multiply)
        // slither-disable-next-line divide-before-multiply
        return (amount / BPS_DENOMINATOR) * feeBps + ((amount % BPS_DENOMINATOR) * feeBps) / BPS_DENOMINATOR;
    }
}
