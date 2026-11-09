// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {BaseBindings} from "../../src/bindings/BaseBindings.sol";
import {RegentLBPStrategyV3} from "../../src/strategy/RegentLBPStrategyV3.sol";
import {
    AuctionParameters,
    IContinuousClearingAuction
} from "continuous-clearing-auction/interfaces/IContinuousClearingAuction.sol";
import {ConstantsLib} from "continuous-clearing-auction/libraries/ConstantsLib.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {StrategyFixture} from "./StrategyFixture.sol";
import {V2Schedule} from "./V2Schedule.sol";

/// @notice Version 3's schedule against version 2's: ten version 3 blocks (0.2 s each) for every
///         version 2 block (2 s each), the same amount released at every version 2 step boundary, and
///         never far from version 2 in between. Proved on the arithmetic and on the pinned CCA itself.
contract RegentLBPStrategyScheduleTest is StrategyFixture {
    /// @dev The widest gap, in mps, between version 3 at block `10 t` and version 2 at block `t`.
    uint256 internal constant WIDEST_GAP_MPS = 26_144;

    function setUp() public {
        _deployC3();
    }

    /// @dev Each version 2 step boundary at block `t` is block `10 t` here, and the amount released by
    ///      then is identical, so each of the twelve windows releases what it did in version 2 at the
    ///      same wall-clock time.
    function test_schedule_matches_version_two_at_every_version_two_step_boundary() public view {
        bytes memory v2 = V2Schedule.AUCTION_STEPS;
        uint256 boundary;
        for (uint256 i; i < v2.length - 8; i += 8) {
            (, uint40 blockDelta) = V2Schedule.step(v2, i);
            boundary += blockDelta;
            assertEq(
                V2Schedule.released(strategy.AUCTION_STEPS(), 10 * boundary),
                V2Schedule.released(v2, boundary),
                "equal at a version 2 step boundary"
            );
        }
        assertEq(boundary, V2Schedule.AUCTION_DURATION_BLOCKS - 1, "twelve scheduled windows");
        assertEq(10 * boundary + 1, strategy.AUCTION_DURATION_BLOCKS(), "ten times the windows, one terminal block");
    }

    /// @dev At every 2-second mark of the auction (each version 2 block `t`, version 3 block `10 t`) the
    ///      two schedules differ by at most 26,144 mps, 0.26% of the sale. Every mark is checked.
    function test_schedule_tracks_version_two_at_every_two_second_mark() public view {
        uint256 widest = V2Schedule.widestGap(strategy.AUCTION_STEPS());
        assertEq(widest, WIDEST_GAP_MPS, "the widest gap between boundaries");
        assertLe(widest * 10_000, 27 * uint256(ConstantsLib.MPS), "never more than 0.27% of the sale");
    }

    /// @dev For any block of the version 3 auction, what it has released lies within the widest gap of
    ///      what version 2 released at the 2-second marks either side of it, and it is whole at the end.
    function testFuzz_schedule_tracks_version_two_at_any_block(uint256 blockNumber) public view {
        blockNumber = bound(blockNumber, 0, strategy.AUCTION_DURATION_BLOCKS() + 10);
        uint256 current = V2Schedule.released(strategy.AUCTION_STEPS(), blockNumber);
        uint256 before = V2Schedule.released(V2Schedule.AUCTION_STEPS, blockNumber / 10);
        uint256 later = V2Schedule.released(V2Schedule.AUCTION_STEPS, (blockNumber + 9) / 10);
        assertLe(current, later + WIDEST_GAP_MPS, "never far ahead of version 2");
        assertGe(current + WIDEST_GAP_MPS, before, "never far behind version 2");
        if (blockNumber >= strategy.AUCTION_DURATION_BLOCKS()) {
            assertEq(current, ConstantsLib.MPS, "whole");
        }
    }

    /// @dev The pinned auction itself: a version 3 launch's auction releases exactly what a version 2
    ///      auction released at every version 2 step boundary, ten times as many blocks in.
    function test_the_launch_auction_releases_version_two_amounts_at_the_same_wall_clock_times() public {
        IContinuousClearingAuction former = _versionTwoAuction();
        IContinuousClearingAuction current = _defaultLaunch().auction;
        assertEq(current.endBlock() - current.startBlock(), strategy.AUCTION_DURATION_BLOCKS());

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

    /// @dev A version 2 auction with the same sale, floor and tick, from the same pinned factory.
    function _versionTwoAuction() private returns (IContinuousClearingAuction auction) {
        MockERC20 token = new MockERC20("Reference", "REF", 18);
        uint64 startBlock = uint64(block.number) + 1;
        uint64 endBlock = startBlock + V2Schedule.AUCTION_DURATION_BLOCKS;
        auction = IContinuousClearingAuction(
            address(
                ccaFactory.create(
                    address(token),
                    AUCTION_ALLOCATION,
                    abi.encode(
                        AuctionParameters({
                            currency: BaseBindings.REGENT,
                            tokensRecipient: address(this),
                            fundsRecipient: address(this),
                            startBlock: startBlock,
                            endBlock: endBlock,
                            claimBlock: endBlock + 64,
                            tickSpacing: DEFAULT_TICK_Q96,
                            validationHook: address(0),
                            floorPrice: DEFAULT_FLOOR_Q96,
                            requiredCurrencyRaised: FLOOR_RAISE,
                            auctionStepsData: V2Schedule.AUCTION_STEPS
                        })
                    ),
                    bytes32(0)
                )
            )
        );
        token.mint(address(auction), AUCTION_ALLOCATION);
        auction.onTokensReceived();
    }
}
