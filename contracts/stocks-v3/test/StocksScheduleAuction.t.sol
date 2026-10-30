// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {
    AuctionParameters,
    IContinuousClearingAuction
} from "continuous-clearing-auction/interfaces/IContinuousClearingAuction.sol";
import {ConstantsLib} from "continuous-clearing-auction/libraries/ConstantsLib.sol";
import {StocksPreset} from "../src/StocksPreset.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {StocksFixture} from "./StocksFixture.sol";
import {V2Schedule} from "./V2Schedule.sol";

/// @notice The pinned auction itself, not arithmetic about it: a version 3 launch's auction releases
///         exactly what a version 2 auction released at every version 2 step boundary, at the same
///         wall-clock time on the new block clock, and all of it by the end block.
contract StocksScheduleAuctionTest is StocksFixture {
    function setUp() public {
        _deployStocks();
    }

    function test_the_launch_auction_releases_version_two_amounts_at_the_same_wall_clock_times() public {
        IContinuousClearingAuction former = _versionTwoAuction();
        Launched memory l = _launch(STOCK_LOW);
        IContinuousClearingAuction current = l.auction;
        assertEq(current.endBlock() - current.startBlock(), StocksPreset.AUCTION_DURATION_BLOCKS);

        // Version 2's checkpoints first, since the chain only moves forward and its auction ends sooner.
        bytes memory v2 = V2Schedule.AUCTION_STEPS;
        uint256 windows = v2.length / 8 - 1;
        uint64[] memory boundaries = new uint64[](windows);
        uint24[] memory released = new uint24[](windows);
        uint64 boundary;
        for (uint256 w; w < windows; ++w) {
            (, uint40 blockDelta) = V2Schedule.step(v2, 8 * w);
            boundary += uint64(blockDelta);
            boundaries[w] = boundary;
            vm.roll(former.startBlock() + boundary);
            released[w] = former.checkpoint().cumulativeMps;
        }
        vm.roll(former.endBlock());
        assertEq(former.checkpoint().cumulativeMps, ConstantsLib.MPS, "version 2 is whole at its end");

        for (uint256 w; w < windows; ++w) {
            vm.roll(current.startBlock() + 10 * boundaries[w]);
            assertEq(current.checkpoint().cumulativeMps, released[w], "the same amount at the same wall-clock time");
        }
        vm.roll(current.endBlock());
        assertEq(current.checkpoint().cumulativeMps, ConstantsLib.MPS, "version 3 is whole at its end");
    }

    /// @dev A version 2 auction with the same token amount, floor and tick, from the same pinned factory.
    function _versionTwoAuction() private returns (IContinuousClearingAuction auction) {
        MockERC20 token = new MockERC20("Reference", "REF", 18);
        uint64 startBlock = uint64(block.number) + 1;
        uint64 endBlock = startBlock + V2Schedule.AUCTION_DURATION_BLOCKS;
        auction = IContinuousClearingAuction(
            address(
                ccaFactory.create(
                    address(token),
                    StocksPreset.AUCTION_INVENTORY,
                    abi.encode(
                        AuctionParameters({
                            currency: STOCK_LOW,
                            tokensRecipient: address(this),
                            fundsRecipient: address(this),
                            startBlock: startBlock,
                            endBlock: endBlock,
                            claimBlock: endBlock + 64,
                            tickSpacing: StocksPreset.BID_TICK_SPACING_Q96,
                            validationHook: address(0),
                            floorPrice: StocksPreset.FLOOR_PRICE_Q96,
                            requiredCurrencyRaised: StocksPreset.REQUIRED_STOCK_RAISED,
                            auctionStepsData: V2Schedule.AUCTION_STEPS
                        })
                    ),
                    bytes32(0)
                )
            )
        );
        token.mint(address(auction), StocksPreset.AUCTION_INVENTORY);
        auction.onTokensReceived();
    }
}
