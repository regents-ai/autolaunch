// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {MockERC20} from "autolaunch-stocks-test/mocks/MockERC20.sol";
import {RobinhoodStockBidAdapterV1} from "../src/RobinhoodStockBidAdapterV1.sol";
import {RobinhoodFixture} from "./RobinhoodFixture.sol";

/// @notice USDG in, STOCK bid out, in one transaction, owned by the caller, nothing left behind.
contract RobinhoodStockBidAdapterTest is RobinhoodFixture {
    function setUp() public {
        _deployRobinhood();
    }

    function test_bid_with_usdg_converts_and_commits_exactly_for_the_caller() public {
        Launched memory l = _launchStock(STOCK_HIGH);
        _rollToStart(l);
        uint256 usdgAmount = 2_300e6;
        uint128 expectedStock = uint128(usdgAmount * 1e8 / USDG_PER_SHARE);
        uint256 auctionStockBefore = stockHigh.balanceOf(address(l.auction));

        usdg.mint(bidder, usdgAmount);
        vm.startPrank(bidder);
        usdg.approve(address(adapter), usdgAmount);
        (uint256 bidId, uint128 committed) = adapter.bidWithUsdg(
            address(l.auction), usdgAmount, expectedStock, _bidPrice(10), FLOOR_PRICE_Q96, block.timestamp
        );
        vm.stopPrank();

        assertEq(committed, expectedStock);
        assertEq(stockHigh.balanceOf(address(l.auction)), auctionStockBefore + expectedStock);
        assertEq(usdg.balanceOf(bidder), 0);
        assertEq(usdg.balanceOf(address(adapter)), 0);
        assertEq(stockHigh.balanceOf(address(adapter)), 0);
        assertEq(usdg.allowance(bidder, address(adapter)), 0);

        // The bid is the bidder's: after graduation only the bidder can settle it.
        _rollToMigration(l);
        stocks.migrate(l.launchId);
        vm.prank(bidder);
        l.auction.exitBid(bidId);
        vm.prank(bidder);
        l.auction.claimTokens(bidId);
        assertGt(MockERC20(l.newToken).balanceOf(bidder), 0);
    }

    function test_unknown_auction_and_short_output_are_refused() public {
        Launched memory l = _launchStock(STOCK_LOW);
        _rollToStart(l);
        usdg.mint(bidder, 230e6);
        vm.startPrank(bidder);
        usdg.approve(address(adapter), 230e6);
        vm.expectRevert(abi.encodeWithSelector(RobinhoodStockBidAdapterV1.UnknownAuction.selector, outsider));
        adapter.bidWithUsdg(outsider, 230e6, 1, _bidPrice(10), FLOOR_PRICE_Q96, block.timestamp);
        vm.expectRevert();
        adapter.bidWithUsdg(address(l.auction), 230e6, 1e8 + 1, _bidPrice(10), FLOOR_PRICE_Q96, block.timestamp);
        vm.stopPrank();
    }
}
