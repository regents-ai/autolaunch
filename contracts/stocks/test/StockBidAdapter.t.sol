// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {IContinuousClearingAuction} from "continuous-clearing-auction/interfaces/IContinuousClearingAuction.sol";
import {IStepStorage} from "continuous-clearing-auction/interfaces/IStepStorage.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {StockBidAdapterV1} from "../src/StockBidAdapterV1.sol";
import {StocksBindings} from "../src/StocksBindings.sol";
import {FixtureStockToken} from "../src/fixtures/FixtureStockToken.sol";
import {IStockBidAdapterV1} from "../src/interfaces/IStockBidAdapterV1.sol";
import {FixtureStockRoute} from "../src/routes/FixtureStockRoute.sol";
import {StocksFixture} from "./StocksFixture.sol";

/// @notice Rule 7: the adapter measures by invocation deltas only, restores every allowance to zero and
///         bids as `owner = msg.sender`, against the real pinned CCA and the real Permit2 bytecode.
contract StockBidAdapterTest is StocksFixture {
    address internal buyer = makeAddr("buyer");

    function setUp() public {
        _deployStocks();
    }

    function _armBuyer(uint256 usdcAmount) private {
        usdc.mint(buyer, usdcAmount);
        vm.prank(buyer);
        usdc.approve(address(adapter), usdcAmount);
    }

    function test_bidWithUsdc_places_a_bid_owned_by_the_caller() public {
        Launched memory l = _launch(STOCK_LOW);
        _rollToStart(l);
        uint256 usdcAmount = 2_300e6; // 10 shares at the fixture price
        _armBuyer(usdcAmount);
        uint128 expectedStock = uint128(usdcAmount * 1e8 / USDC_PER_SHARE);
        uint256 price = _bidPrice(3);

        vm.expectEmit(true, true, true, true, address(adapter));
        emit IStockBidAdapterV1.StockBidPlaced(address(l.auction), buyer, 0, usdcAmount, expectedStock, price);
        vm.prank(buyer);
        (uint256 bidId, uint128 committed) =
            adapter.bidWithUsdc(address(l.auction), usdcAmount, expectedStock, price, FLOOR_PRICE_Q96, block.timestamp);

        assertEq(committed, expectedStock);
        assertEq(l.auction.bids(bidId).owner, buyer, "owner = msg.sender");
        assertEq(l.auction.bids(bidId).amountQ96, uint256(expectedStock) << 96);
        assertEq(l.auction.bids(bidId).maxPrice, price);
        assertEq(FixtureStockToken(l.stock).balanceOf(address(l.auction)), expectedStock, "STOCK in the auction");

        // Nothing stays behind and nothing stays approved.
        assertEq(usdc.balanceOf(address(adapter)), 0);
        assertEq(FixtureStockToken(l.stock).balanceOf(address(adapter)), 0);
        assertEq(usdc.balanceOf(buyer), 0);
        assertEq(usdc.allowance(buyer, address(adapter)), 0);
        assertEq(FixtureStockToken(l.stock).allowance(address(adapter), StocksBindings.PERMIT2), 0);
        (uint160 permit2Allowance,,) = IAllowanceTransfer(StocksBindings.PERMIT2).allowance(address(adapter), l.stock, address(l.auction));
        assertEq(permit2Allowance, 0);
        assertEq(adapter.launchpad(), address(launchpad));
        assertEq(adapter.usdc(), StocksBindings.USDC);
        assertEq(adapter.permit2(), StocksBindings.PERMIT2);
    }

    function test_the_bid_settles_through_the_cca_for_the_caller_alone() public {
        Launched memory l = _launch(STOCK_HIGH);
        _rollToStart(l);
        // 500 shares: fully filled at the floor, so it exits through the plain `exitBid` path.
        _armBuyer(115_000e6);
        vm.prank(buyer);
        (uint256 bidId,) = adapter.bidWithUsdc(address(l.auction), 115_000e6, 1, _bidPrice(10), FLOOR_PRICE_Q96, block.timestamp);
        _rollToMigration(l);
        launchpad.migrate(l.launchId);

        vm.prank(buyer);
        l.auction.exitBid(bidId);
        vm.prank(buyer);
        l.auction.claimTokens(bidId);
        assertGt(FixtureStockToken(l.newToken).balanceOf(buyer), 0, "the caller claims the NEW");
    }

    function test_two_invocations_are_independent_bids() public {
        Launched memory l = _launch(STOCK_LOW);
        _rollToStart(l);
        _armBuyer(4_600e6);
        vm.startPrank(buyer);
        (uint256 first,) = adapter.bidWithUsdc(address(l.auction), 2_300e6, 1, _bidPrice(2), FLOOR_PRICE_Q96, block.timestamp);
        (uint256 second,) = adapter.bidWithUsdc(address(l.auction), 2_300e6, 1, _bidPrice(2), FLOOR_PRICE_Q96, block.timestamp);
        vm.stopPrank();
        assertNotEq(first, second);
        assertEq(l.auction.bids(first).owner, buyer);
        assertEq(l.auction.bids(second).owner, buyer);
    }

    function test_each_auction_resolves_its_own_stock_and_route() public {
        Launched memory low = _launch(STOCK_LOW);
        Launched memory high = _launch(STOCK_HIGH);
        _rollToStart(low);
        _armBuyer(4_600e6);
        vm.startPrank(buyer);
        adapter.bidWithUsdc(address(low.auction), 2_300e6, 1, _bidPrice(2), FLOOR_PRICE_Q96, block.timestamp);
        adapter.bidWithUsdc(address(high.auction), 2_300e6, 1, _bidPrice(2), FLOOR_PRICE_Q96, block.timestamp);
        vm.stopPrank();
        assertEq(stockLow.balanceOf(address(low.auction)), 10e8);
        assertEq(stockHigh.balanceOf(address(high.auction)), 10e8);
        assertEq(stockLow.balanceOf(address(high.auction)), 0);
    }

    function test_foreign_auction_is_refused() public {
        Launched memory l = _launch(STOCK_LOW);
        _rollToStart(l);
        _armBuyer(2_300e6);
        address foreign = makeAddr("foreign-auction");
        vm.expectRevert(abi.encodeWithSelector(StockBidAdapterV1.UnknownAuction.selector, foreign));
        vm.prank(buyer);
        adapter.bidWithUsdc(foreign, 2_300e6, 1, _bidPrice(2), FLOOR_PRICE_Q96, block.timestamp);
        assertEq(usdc.balanceOf(buyer), 2_300e6, "nothing pulled");
    }

    function test_deadline_zero_amount_and_allowance_guards() public {
        Launched memory l = _launch(STOCK_LOW);
        _rollToStart(l);

        vm.expectRevert(abi.encodeWithSelector(StockBidAdapterV1.Expired.selector, block.timestamp - 1, block.timestamp));
        vm.prank(buyer);
        adapter.bidWithUsdc(address(l.auction), 2_300e6, 1, _bidPrice(2), FLOOR_PRICE_Q96, block.timestamp - 1);

        vm.expectRevert(StockBidAdapterV1.ZeroAmount.selector);
        vm.prank(buyer);
        adapter.bidWithUsdc(address(l.auction), 0, 1, _bidPrice(2), FLOOR_PRICE_Q96, block.timestamp);

        usdc.mint(buyer, 2_300e6);
        vm.prank(buyer);
        usdc.approve(address(adapter), 2_299e6);
        vm.expectRevert(abi.encodeWithSelector(StockBidAdapterV1.InsufficientAllowance.selector, 2_300e6, 2_299e6));
        vm.prank(buyer);
        adapter.bidWithUsdc(address(l.auction), 2_300e6, 1, _bidPrice(2), FLOOR_PRICE_Q96, block.timestamp);
    }

    function test_larger_standing_allowance_is_consumed_exactly() public {
        Launched memory l = _launch(STOCK_LOW);
        _rollToStart(l);
        usdc.mint(buyer, 10_000e6);
        vm.prank(buyer);
        usdc.approve(address(adapter), 10_000e6);
        vm.prank(buyer);
        adapter.bidWithUsdc(address(l.auction), 2_300e6, 1, _bidPrice(2), FLOOR_PRICE_Q96, block.timestamp);
        assertEq(usdc.allowance(buyer, address(adapter)), 10_000e6 - 2_300e6, "only this amount of it was spent");
        assertEq(usdc.balanceOf(buyer), 10_000e6 - 2_300e6);
    }

    function test_min_stock_out_and_zero_output_are_refused() public {
        Launched memory l = _launch(STOCK_LOW);
        _rollToStart(l);
        _armBuyer(2_300e6);
        uint128 expectedStock = uint128(2_300e6 * 1e8 / USDC_PER_SHARE);

        vm.expectRevert(
            abi.encodeWithSelector(FixtureStockRoute.InsufficientOutput.selector, expectedStock + 1, expectedStock)
        );
        vm.prank(buyer);
        adapter.bidWithUsdc(address(l.auction), 2_300e6, expectedStock + 1, _bidPrice(2), FLOOR_PRICE_Q96, block.timestamp);

        // A route that pays nothing: refused even with `minStockOut == 0`.
        ZeroRoute zero = new ZeroRoute(l.stock);
        vm.prank(governance);
        launchpad.admitStock(l.stock, address(zero));
        vm.expectRevert(abi.encodeWithSelector(StockBidAdapterV1.InsufficientStockOut.selector, 0, 0));
        vm.prank(buyer);
        adapter.bidWithUsdc(address(l.auction), 2_300e6, 0, _bidPrice(2), FLOOR_PRICE_Q96, block.timestamp);
        assertEq(usdc.balanceOf(buyer), 2_300e6, "the whole call rolled back");
    }

    function test_preexisting_balances_are_never_committed_or_returned() public {
        Launched memory l = _launch(STOCK_LOW);
        _rollToStart(l);
        // Someone donates STOCK and USDC to the adapter beforehand.
        stockLow.mint(address(adapter), 5e8);
        usdc.mint(address(adapter), 999e6);
        _armBuyer(2_300e6);
        uint128 expectedStock = uint128(2_300e6 * 1e8 / USDC_PER_SHARE);

        vm.prank(buyer);
        (, uint128 committed) =
            adapter.bidWithUsdc(address(l.auction), 2_300e6, 1, _bidPrice(2), FLOOR_PRICE_Q96, block.timestamp);

        assertEq(committed, expectedStock, "only this invocation's STOCK was committed");
        assertEq(stockLow.balanceOf(address(adapter)), 5e8, "donated STOCK untouched");
        assertEq(usdc.balanceOf(address(adapter)), 999e6, "donated USDC untouched");
        assertEq(usdc.balanceOf(buyer), 0, "the caller got nothing that was not theirs");
    }

    function test_route_residue_returns_to_the_caller() public {
        Launched memory l = _launch(STOCK_LOW);
        _rollToStart(l);
        UsdcResidueRoute refunding = new UsdcResidueRoute(l.stock, 17e6);
        stockLow.mint(address(refunding), 1_000e8);
        vm.prank(governance);
        launchpad.admitStock(l.stock, address(refunding));
        _armBuyer(2_300e6);

        uint128 expectedStock = uint128((2_300e6 - 17e6) * 1e8 / USDC_PER_SHARE);
        vm.expectEmit(true, true, true, true, address(adapter));
        emit IStockBidAdapterV1.StockBidPlaced(address(l.auction), buyer, 0, 2_300e6 - 17e6, expectedStock, _bidPrice(2));
        vm.prank(buyer);
        adapter.bidWithUsdc(address(l.auction), 2_300e6, 1, _bidPrice(2), FLOOR_PRICE_Q96, block.timestamp);
        assertEq(usdc.balanceOf(buyer), 17e6, "unconsumed USDC came back");
        assertEq(usdc.balanceOf(address(adapter)), 0);
    }

    function test_bids_outside_the_auction_window_revert_atomically() public {
        Launched memory l = _launch(STOCK_LOW);
        _armBuyer(2_300e6);
        vm.expectRevert(IContinuousClearingAuction.AuctionNotStarted.selector);
        vm.prank(buyer);
        adapter.bidWithUsdc(address(l.auction), 2_300e6, 1, _bidPrice(2), FLOOR_PRICE_Q96, block.timestamp);
        assertEq(usdc.balanceOf(buyer), 2_300e6);
        assertEq(usdc.allowance(buyer, address(adapter)), 2_300e6);

        vm.roll(l.auction.endBlock());
        vm.expectRevert(IStepStorage.AuctionIsOver.selector);
        vm.prank(buyer);
        adapter.bidWithUsdc(address(l.auction), 2_300e6, 1, _bidPrice(2), FLOOR_PRICE_Q96, block.timestamp);
    }

    function test_off_grid_price_reverts_atomically() public {
        Launched memory l = _launch(STOCK_LOW);
        _rollToStart(l);
        _armBuyer(2_300e6);
        vm.expectRevert();
        vm.prank(buyer);
        adapter.bidWithUsdc(address(l.auction), 2_300e6, 1, _bidPrice(2) + 1, FLOOR_PRICE_Q96, block.timestamp);
        assertEq(usdc.balanceOf(buyer), 2_300e6);
        assertEq(stockLow.balanceOf(address(adapter)), 0);
    }
}

contract ZeroRoute {
    address public immutable stock;
    address public immutable usdc = StocksBindings.USDC;

    constructor(address stock_) {
        stock = stock_;
    }

    function swapExactIn(address, address, uint256, uint256, address) external pure returns (uint256) {
        return 0;
    }

    function quoteExactIn(address, address, uint256) external pure returns (uint256) {
        return 0;
    }
}

/// @dev Pays the fixture price on all but `residue` USDC and hands the residue back to the recipient.
contract UsdcResidueRoute {
    address public immutable stock;
    address public immutable usdc = StocksBindings.USDC;
    uint256 public immutable residue;

    constructor(address stock_, uint256 residue_) {
        stock = stock_;
        residue = residue_;
    }

    function swapExactIn(address tokenIn, address tokenOut, uint256 amountIn, uint256, address recipient)
        external
        returns (uint256 amountOut)
    {
        require(tokenIn == usdc && tokenOut == stock, "pair");
        amountOut = (amountIn - residue) * 1e8 / 230_000000;
        FixtureStockToken(usdc).transfer(recipient, residue);
        FixtureStockToken(stock).transfer(recipient, amountOut);
    }

    function quoteExactIn(address, address, uint256 amountIn) external view returns (uint256) {
        return (amountIn - residue) * 1e8 / 230_000000;
    }
}
