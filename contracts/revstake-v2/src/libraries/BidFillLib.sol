// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {IContinuousClearingAuction} from "continuous-clearing-auction/interfaces/IContinuousClearingAuction.sol";
import {Bid} from "continuous-clearing-auction/libraries/BidLib.sol";
import {CheckpointAccountingLib} from "continuous-clearing-auction/libraries/CheckpointAccountingLib.sol";
import {Checkpoint} from "continuous-clearing-auction/libraries/CheckpointLib.sol";

/// @title BidFillLib
/// @notice The tokens one bid won in an ended, graduated auction, derived from the auction's own
///         permanent records with the pinned accounting its exits use.
/// @dev A bid's stored `tokensFilled` is zeroed by `claimTokens`, which anyone may call for any bid,
///      so it cannot be what a later share-out reads. Everything read here is fixed once the end block
///      is checkpointed: the bid itself, the checkpoints and the tick demand at the bid's price (no bid
///      can join a tick at or below the clearing price). The hints are validated exactly as
///      `exitPartiallyFilledBid` validates them, which admits one hint pair per bid, so the result
///      equals the `tokensFilled` the bid's exit records.
library BidFillLib {
    error InvalidLastFullyFilledCheckpointHint();
    error InvalidOutbidBlockCheckpointHint();
    error BidNotAtFinalClearingPrice();

    /// @param lastFullyFilledCheckpointBlock Ignored for a bid priced above the final clearing price;
    ///        otherwise the last checkpoint whose clearing price is below the bid's price.
    /// @param outbidBlock Ignored for a bid priced above the final clearing price; otherwise the first
    ///        checkpoint whose clearing price is above the bid's price, or zero when the auction ended
    ///        at exactly the bid's price.
    function tokensFilled(
        IContinuousClearingAuction auction,
        uint256 bidId,
        uint64 lastFullyFilledCheckpointBlock,
        uint64 outbidBlock
    ) internal view returns (address owner, uint256 filled) {
        Bid memory bid = auction.bids(bidId);
        owner = bid.owner;
        Checkpoint memory finalCheckpoint = auction.checkpoints(auction.endBlock());
        Checkpoint memory startCheckpoint = auction.checkpoints(bid.startBlock);

        // `exitBid`: filled at every checkpoint to the end.
        if (bid.maxPrice > finalCheckpoint.clearingPrice) {
            // slither-disable-next-line unused-return
            (filled,) = CheckpointAccountingLib.accountFullyFilledCheckpoints(finalCheckpoint, startCheckpoint, bid);
            return (owner, filled);
        }

        // `exitPartiallyFilledBid`: fully filled up to the hinted checkpoint, then partially filled
        // while the clearing price sat at the bid's price.
        Checkpoint memory lastFullyFilled = auction.checkpoints(lastFullyFilledCheckpointBlock);
        if (
            lastFullyFilled.clearingPrice >= bid.maxPrice
                || auction.checkpoints(lastFullyFilled.next).clearingPrice < bid.maxPrice
                || lastFullyFilledCheckpointBlock < bid.startBlock
        ) {
            revert InvalidLastFullyFilledCheckpointHint();
        }
        // slither-disable-next-line unused-return
        (filled,) = CheckpointAccountingLib.accountFullyFilledCheckpoints(lastFullyFilled, startCheckpoint, bid);

        Checkpoint memory upper;
        if (outbidBlock != 0) {
            Checkpoint memory outbid = auction.checkpoints(outbidBlock);
            upper = auction.checkpoints(outbid.prev);
            if (outbid.clearingPrice <= bid.maxPrice || upper.clearingPrice > bid.maxPrice) {
                revert InvalidOutbidBlockCheckpointHint();
            }
        } else {
            upper = finalCheckpoint;
            if (upper.clearingPrice != bid.maxPrice) revert BidNotAtFinalClearingPrice();
        }

        if (upper.clearingPrice == bid.maxPrice) {
            // slither-disable-next-line unused-return
            (uint256 partiallyFilled,) = CheckpointAccountingLib.accountPartiallyFilledCheckpoints(
                bid, auction.ticks(bid.maxPrice).currencyDemandQ96, upper.currencyRaisedAtClearingPriceQ96X7
            );
            filled += partiallyFilled;
        }
    }
}
