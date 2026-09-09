// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {IContinuousClearingAuction} from "continuous-clearing-auction/interfaces/IContinuousClearingAuction.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {ReentrancyGuardTransient} from "solady/utils/ReentrancyGuardTransient.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {IERC20Minimal} from "./interfaces/IERC20Minimal.sol";
import {IStockBidAdapterV1} from "./interfaces/IStockBidAdapterV1.sol";
import {IStockRoute} from "./interfaces/IStockRoute.sol";
import {IStocksLaunchpadV1} from "./interfaces/IStocksLaunchpadV1.sol";
import {StocksBindings} from "./StocksBindings.sol";

/// @title StockBidAdapterV1
/// @notice Atomic USDC -> STOCK -> CCA bid for one launchpad-created Stocks auction, owned by the caller.
/// @dev Invocation balance deltas are the only measurement. Exactly `usdcAmount` is pulled, the
///      launchpad's admitted route for the auction's STOCK converts it, the STOCK this call received is
///      committed through an exact Permit2 allowance to the five-argument `submitBid` with
///      `owner = msg.sender`, and every allowance is proved back at zero. Any USDC or STOCK the call did
///      not commit returns to the caller inside the call; balances that were already here stay here.
///      Any failure reverts the whole transaction. The adapter never owns a bid.
contract StockBidAdapterV1 is ReentrancyGuardTransient, IStockBidAdapterV1 {
    using SafeTransferLib for address;

    address public immutable override launchpad;
    address public immutable override usdc;
    address public immutable override permit2;

    error ZeroAddress();
    error NoCode(address account);
    error Expired(uint256 deadline, uint256 currentTimestamp);
    error ZeroAmount();
    error UnknownAuction(address auction);
    error NoRoute(address stock);
    error InsufficientAllowance(uint256 required, uint256 found);
    error AllowanceNotConsumedExactly(uint256 expected, uint256 found);
    error InexactTransfer(uint256 expected, uint256 found);
    error InsufficientStockOut(uint128 minimum, uint256 found);
    error AllowanceNotRestored(address spender, uint256 remaining);
    error Permit2AllowanceNotRestored(uint160 remaining);

    constructor(address launchpad_) {
        if (launchpad_ == address(0)) revert ZeroAddress();
        if (launchpad_.code.length == 0) revert NoCode(launchpad_);
        launchpad = launchpad_;
        usdc = StocksBindings.USDC;
        permit2 = StocksBindings.PERMIT2;
    }

    /// @inheritdoc IStockBidAdapterV1
    // slither-disable-next-line reentrancy-no-eth,reentrancy-benign
    function bidWithUsdc(
        address auction,
        uint256 usdcAmount,
        uint128 minStockOut,
        uint256 maxPriceQ96,
        uint256 prevTickPriceQ96,
        uint256 deadline
    ) external override nonReentrant returns (uint256 bidId, uint128 stockCommitted) {
        // The caller's own deadline; block time is the only clock a wallet can reason about.
        // slither-disable-next-line timestamp
        if (block.timestamp > deadline) revert Expired(deadline, block.timestamp);
        if (usdcAmount == 0) revert ZeroAmount();

        uint256 launchId = IStocksLaunchpadV1(launchpad).launchIdOfAuction(auction);
        if (launchId == 0) revert UnknownAuction(auction);
        address stock = IStocksLaunchpadV1(launchpad).launches(launchId).stock;
        // slither-disable-next-line unused-return
        (,, address route) = IStocksLaunchpadV1(launchpad).stockAdmission(stock);
        if (route == address(0)) revert NoRoute(stock);

        uint256 usdcBefore = usdc.balanceOf(address(this));
        uint256 stockBefore = stock.balanceOf(address(this));

        _pullExactUsdc(usdcAmount, usdcBefore);

        usdc.safeTransfer(route, usdcAmount);
        // slither-disable-next-line unused-return
        IStockRoute(route).swapExactIn(usdc, stock, usdcAmount, minStockOut, address(this));

        uint256 stockOut = stock.balanceOf(address(this)) - stockBefore;
        if (stockOut == 0 || stockOut < minStockOut) revert InsufficientStockOut(minStockOut, stockOut);
        stockCommitted = SafeCastLib.toUint128(stockOut);

        // Exact Permit2 path: ERC-20 allowance to Permit2, Permit2 allowance to the auction, then the
        // auction pulls exactly `stockCommitted` from this contract and both allowances are proved zero.
        stock.safeApprove(permit2, stockCommitted);
        IAllowanceTransfer(permit2).approve(stock, auction, uint160(stockCommitted), uint48(block.timestamp));
        bidId = IContinuousClearingAuction(auction).submitBid(maxPriceQ96, stockCommitted, msg.sender, prevTickPriceQ96, "");

        uint256 erc20Remaining = IERC20Minimal(stock).allowance(address(this), permit2);
        if (erc20Remaining != 0) revert AllowanceNotRestored(permit2, erc20Remaining);
        // slither-disable-next-line unused-return
        (uint160 permit2Remaining,,) = IAllowanceTransfer(permit2).allowance(address(this), stock, auction);
        if (permit2Remaining != 0) revert Permit2AllowanceNotRestored(permit2Remaining);

        uint256 stockResidue = stock.balanceOf(address(this)) - stockBefore;
        if (stockResidue != 0) stock.safeTransfer(msg.sender, stockResidue);
        uint256 usdcResidue = usdc.balanceOf(address(this)) - usdcBefore;
        if (usdcResidue != 0) usdc.safeTransfer(msg.sender, usdcResidue);

        emit StockBidPlaced(auction, msg.sender, bidId, usdcAmount - usdcResidue, stockCommitted, maxPriceQ96);
    }

    /// @dev Pull exactly `usdcAmount` from the caller and prove it by the balance delta and by the exact
    ///      allowance consumption; a caller's larger standing allowance is admitted but only this
    ///      amount of it is ever spent.
    function _pullExactUsdc(uint256 usdcAmount, uint256 usdcBefore) private {
        uint256 allowed = IERC20Minimal(usdc).allowance(msg.sender, address(this));
        if (allowed < usdcAmount) revert InsufficientAllowance(usdcAmount, allowed);

        usdc.safeTransferFrom(msg.sender, address(this), usdcAmount);

        uint256 received = usdc.balanceOf(address(this)) - usdcBefore;
        if (received != usdcAmount) revert InexactTransfer(usdcAmount, received);
        uint256 remaining = IERC20Minimal(usdc).allowance(msg.sender, address(this));
        if (remaining != allowed - usdcAmount) revert AllowanceNotConsumedExactly(allowed - usdcAmount, remaining);
    }
}
