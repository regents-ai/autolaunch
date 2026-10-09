// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {IContinuousClearingAuction} from "continuous-clearing-auction/interfaces/IContinuousClearingAuction.sol";
import {Bid} from "continuous-clearing-auction/libraries/BidLib.sol";
import {Checkpoint} from "continuous-clearing-auction/libraries/CheckpointLib.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {UERC20} from "uerc20-factory/tokens/UERC20.sol";
import {StocksPreset} from "autolaunch-stocks/StocksPreset.sol";
import {MockERC20} from "autolaunch-stocks-test/mocks/MockERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IRobinhoodLaunchpadBase} from "../src/interfaces/IRobinhoodLaunchpadBase.sol";
import {RobinhoodPreset} from "../src/RobinhoodPreset.sol";
import {RobinhoodFixture} from "./RobinhoodFixture.sol";

/// @notice AL-03 sweep for Memestake on Robinhood Chain, as the Base sweep: several bidders with fuzzed amounts (down to one STOCK base
///         unit), prices and blocks. A launch graduates exactly when the auction's own raise meets the
///         minimum; a graduated launch opens its pool and its bids receive the whole sale allocation
///         but for crumbs; a failed launch opens no pool and refunds every bid in full. Bids adding up
///         to the minimum are not graduation: the auction's rounding comes off first.
contract RobinhoodSelloutSweepTest is RobinhoodFixture {
    using StateLibrary for IPoolManager;

    uint256 private constant MAX_BIDDERS = 6;

    struct Sweep {
        uint256[] bidIds;
        uint256 placed;
        uint256 bidTotal;
    }

    function setUp() public {
        _deployRobinhood();
    }

    function testFuzz_AL03_GraduationIsExactlyTheMinimumAndAGraduatedSaleSellsOut(
        uint256[MAX_BIDDERS] memory seeds,
        uint8 count,
        uint8 scale,
        bool low
    ) public {
        Launched memory l = _launchStock(low ? STOCK_LOW : STOCK_HIGH);
        uint256 n = bound(count, 2, MAX_BIDDERS);
        uint256 maxAmount =
            scale % 3 == 0 ? REQUIRED_RAISE : scale % 3 == 1 ? 4 * uint256(REQUIRED_RAISE) : 1_000_000e18;
        Sweep memory s;
        s.bidIds = new uint256[](n);
        uint256 blockNumber = l.auction.startBlock();
        for (uint256 i; i < n; ++i) {
            uint256 seed = seeds[i];
            blockNumber = _nextBlock(l, blockNumber, seed);
            uint256 clearing = l.auction.checkpoint().clearingPrice;
            uint256 ticks = bound(seed >> 32, 1, 2_000);
            uint256 minTicks = (clearing - FLOOR_PRICE_Q96) / StocksPreset.BID_TICK_SPACING_Q96 + 1;
            if (ticks < minTicks) ticks = minTicks + ticks % 50;
            _tryBid(l, s, i, uint128(bound(seed, 1, maxAmount)), _bidPrice(ticks));
        }
        _assertOutcome(l, s);
    }

    function testFuzz_AL03_BidsAddingUpToTheMinimumGraduateOnlyOnTheCountedRaise(
        uint256[MAX_BIDDERS] memory seeds,
        uint8 count,
        uint8 extra,
        bool low
    ) public {
        Launched memory l = _launchStock(low ? STOCK_LOW : STOCK_HIGH);
        uint256 n = bound(count, 2, 4);
        uint256 remaining = uint256(REQUIRED_RAISE) + extra % (n + 1);
        Sweep memory s;
        s.bidIds = new uint256[](n);
        uint256 blockNumber = l.auction.startBlock();
        for (uint256 i; i < n; ++i) {
            uint256 seed = seeds[i];
            blockNumber = _nextBlock(l, blockNumber, seed);
            uint128 amount = uint128(i == n - 1 ? remaining : bound(seed >> 8, 1, remaining - (n - 1 - i)));
            remaining -= amount;
            uint256 bidId = _bidDirect(l, address(uint160(0xA103 + i)), amount, _bidPrice(bound(seed >> 32, 1, 10_000)));
            s.bidIds[s.placed++] = bidId;
            s.bidTotal += amount;
        }
        _assertOutcome(l, s);
    }

    function _nextBlock(Launched memory l, uint256 blockNumber, uint256 seed) private returns (uint256) {
        blockNumber += seed % 2 == 0 ? 0 : bound(seed >> 64, 1, 200_000);
        uint256 lastBidBlock = uint256(l.auction.endBlock()) - 1;
        if (blockNumber > lastBidBlock) blockNumber = lastBidBlock;
        vm.roll(blockNumber);
        return blockNumber;
    }

    function _tryBid(Launched memory l, Sweep memory s, uint256 i, uint128 amount, uint256 priceQ96) private {
        address account = address(uint160(uint256(keccak256(abi.encode("sweep", i)))));
        MockERC20(l.currency).mint(account, amount);
        vm.startPrank(account);
        MockERC20(l.currency).approve(PERMIT2, amount);
        IAllowanceTransfer(PERMIT2).approve(l.currency, address(l.auction), uint160(amount), type(uint48).max);
        try l.auction.submitBid(priceQ96, amount, account, FLOOR_PRICE_Q96, "") returns (uint256 bidId) {
            s.bidIds[s.placed++] = bidId;
            s.bidTotal += amount;
        } catch {}
        vm.stopPrank();
    }

    function _assertOutcome(Launched memory l, Sweep memory s) private {
        _rollToMigration(l);
        l.auction.checkpoint();
        bool minimumMet = l.auction.currencyRaised() >= REQUIRED_RAISE;
        assertEq(l.auction.isGraduated(), minimumMet, "the auction's own graduation is the minimum");

        stocks.migrate(l.launchId);
        IRobinhoodLaunchpadBase.Launch memory record = _record(l);

        if (minimumMet) {
            assertEq(
                uint8(record.lifecycle), uint8(IRobinhoodLaunchpadBase.Lifecycle.Graduated), "met but not graduated"
            );
            assertNotEq(_poolPrice(l), 0, "graduated but no pool");
            uint256 received;
            for (uint256 i; i < s.placed; ++i) {
                received += _settleGraduated(l, s.bidIds[i]);
            }
            uint256 crumbs = StocksPreset.INITIAL_SUPPLY / l.auction.floorPrice();
            assertLe(received, StocksPreset.AUCTION_INVENTORY, "bids received more than the sale allocation");
            assertGe(received, StocksPreset.AUCTION_INVENTORY - crumbs, "graduated without selling out");
        } else {
            assertEq(uint8(record.lifecycle), uint8(IRobinhoodLaunchpadBase.Lifecycle.Failed), "short but not failed");
            assertEq(_poolPrice(l), 0, "failed but a pool opened");
            uint256 refunded;
            for (uint256 i; i < s.placed; ++i) {
                Bid memory placed = l.auction.bids(s.bidIds[i]);
                uint256 before = MockERC20(l.currency).balanceOf(placed.owner);
                l.auction.exitBid(s.bidIds[i]);
                refunded += MockERC20(l.currency).balanceOf(placed.owner) - before;
            }
            assertEq(refunded, s.bidTotal, "a failed launch did not refund every bid in full");
        }
    }

    function _poolPrice(Launched memory l) private view returns (uint160 sqrtPriceX96) {
        (sqrtPriceX96,,,) = IPoolManager(address(poolManager)).getSlot0(PoolId.wrap(_poolId(l, address(stocksHook))));
    }

    function _settleGraduated(Launched memory l, uint256 bidId) private returns (uint256 received) {
        Bid memory placed = l.auction.bids(bidId);
        uint256 startBalance = UERC20(l.newToken).balanceOf(placed.owner);
        if (placed.maxPrice > l.auction.checkpoints(l.auction.endBlock()).clearingPrice) {
            l.auction.exitBid(bidId);
        } else {
            (uint64 lastFullyFilled, uint64 outbid) = _hints(l.auction, bidId);
            l.auction.exitPartiallyFilledBid(bidId, lastFullyFilled, outbid);
        }
        l.auction.claimTokens(bidId);
        received = UERC20(l.newToken).balanceOf(placed.owner) - startBalance;
    }

    function _hints(IContinuousClearingAuction auction, uint256 bidId)
        private
        view
        returns (uint64 lastFullyFilled, uint64 outbid)
    {
        Bid memory placed = auction.bids(bidId);
        uint64 blockNumber = placed.startBlock;
        while (blockNumber != type(uint64).max) {
            Checkpoint memory checkpoint = auction.checkpoints(blockNumber);
            if (checkpoint.clearingPrice < placed.maxPrice) lastFullyFilled = blockNumber;
            if (checkpoint.clearingPrice > placed.maxPrice && outbid == 0) outbid = blockNumber;
            blockNumber = checkpoint.next;
        }
    }
}
