// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {BaseBindings} from "../../src/bindings/BaseBindings.sol";
import {ConditionalVestingEscrowV2} from "../../src/escrow/ConditionalVestingEscrowV2.sol";
import {RegentLBPStrategyV3} from "../../src/strategy/RegentLBPStrategyV3.sol";
import {ConstantsLib} from "continuous-clearing-auction/libraries/ConstantsLib.sol";
import {AutolaunchFixture} from "../integration/AutolaunchFixture.sol";
import {V2Schedule} from "../strategy/V2Schedule.sol";

/// @notice A version 3 launch on Base Sepolia, which has run 0.2 s blocks since 21 Oct 2026, driven
///         through the real pinned CCA factory and Permit2 there at five blocks a second. The pool
///         pieces, REGENT, USDC and REGENT staking are built fresh at their Base mainnet addresses,
///         which hold nothing usable on Sepolia.
contract AutolaunchSepoliaLaunchTest is AutolaunchFixture {
    uint256 internal constant BASE_SEPOLIA_CHAIN_ID = 84_532;
    uint256 internal constant BLOCKS_PER_SECOND = 5;
    /// @dev The widest gap, in mps, between version 3 and version 2 at the same wall-clock time.
    uint256 internal constant WIDEST_GAP_MPS = 26_144;

    uint256 internal forkBlock;
    uint256 internal forkTime;

    function setUp() public {
        vm.createSelectFork("base_sepolia");
        assertEq(block.chainid, BASE_SEPOLIA_CHAIN_ID);
        forkBlock = block.number;
        forkTime = block.timestamp;

        _deployAutolaunch();
        // Sepolia has an unrelated contract at the mainnet staking address; the mock starts clean.
        for (uint256 slot; slot < 6; ++slot) {
            vm.store(BaseBindings.LIVE_STAKING, bytes32(slot), bytes32(0));
        }
        vm.roll(forkBlock);
        vm.warp(forkTime);
    }

    /// @dev The real factory and Permit2 stay in place; only their presence is checked.
    function _placeAuctionPieces() internal view override {
        assertEq(
            BaseBindings.CCA_FACTORY.codehash, BaseBindings.CCA_FACTORY_RUNTIME_CODE_HASH, "the pinned CCA factory"
        );
        assertGt(PERMIT2.code.length, 0, "Permit2");
    }

    /// @dev Five blocks to each second, as Base produces them.
    function _elapse(uint256 seconds_) internal {
        vm.roll(vm.getBlockNumber() + BLOCKS_PER_SECOND * seconds_);
        vm.warp(vm.getBlockTimestamp() + seconds_);
    }

    function test_launch_runs_its_two_days_on_the_sepolia_clock() public {
        Launched memory l = _defaultLaunch();
        RegentLBPStrategyV3.Distribution memory d = _distribution(l);
        uint64 startBlock = l.auction.startBlock();
        uint64 endBlock = l.auction.endBlock();
        assertEq(startBlock, forkBlock + strategy.START_DELAY_BLOCKS(), "opens 3,000 blocks after the launch");
        assertEq(endBlock - startBlock, strategy.AUCTION_DURATION_BLOCKS());

        _elapse(600);
        assertEq(vm.getBlockNumber(), startBlock, "ten minutes to the opening block");
        uint256 openedAt = vm.getBlockTimestamp();
        uint256 bidId = _bid(l, bidder, FLOOR_RAISE, _bidPrice(10));

        _elapse(24 hours);
        uint256 released = l.auction.checkpoint().cumulativeMps;
        assertEq(released, V2Schedule.released(strategy.AUCTION_STEPS(), 24 hours * 5), "the schedule at 24 h");
        assertApproxEqAbs(
            released,
            V2Schedule.released(V2Schedule.AUCTION_STEPS, 24 hours / 2),
            WIDEST_GAP_MPS,
            "version 2's 24 h amount"
        );

        _elapse(24 hours);
        vm.roll(vm.getBlockNumber() + 1);
        assertEq(vm.getBlockNumber(), endBlock, "the end block");
        assertApproxEqAbs(vm.getBlockTimestamp() - openedAt, 2 days, 1, "the auction runs two days of wall-clock time");
        assertEq(l.auction.checkpoint().cumulativeMps, ConstantsLib.MPS, "everything released by the end");

        _elapse(128);
        assertEq(vm.getBlockNumber(), l.auction.claimBlock(), "claims open 128 seconds after the end");
        _elapse(127);
        vm.roll(vm.getBlockNumber() + 4);
        vm.expectRevert();
        strategy.migrate(address(l.auction));
        vm.roll(vm.getBlockNumber() + 1);
        assertEq(vm.getBlockNumber(), d.migrationBlock, "the pool opens 256 seconds after the end");
        strategy.migrate(address(l.auction));
        assertEq(
            uint8(_distribution(l).lifecycle), uint8(RegentLBPStrategyV3.Lifecycle.Graduated), "the launch graduated"
        );
        assertEq(l.escrow.vestingStart(), vm.getBlockTimestamp(), "vesting starts at the graduation timestamp");
        assertEq(
            uint8(l.escrow.lifecycle()), uint8(ConditionalVestingEscrowV2.Lifecycle.Graduated), "the escrow graduated"
        );

        vm.startPrank(bidder);
        l.auction.exitBid(bidId);
        l.auction.claimTokens(bidId);
        vm.stopPrank();
        assertGt(l.subject.balanceOf(bidder), 0, "the bidder holds SUBJECT");

        uint256 held = l.subject.balanceOf(address(l.escrow));
        _elapse(365 days / 2);
        l.escrow.release();
        assertApproxEqAbs(l.subject.balanceOf(treasury), held / 2, 1, "half the escrow at half a year");
        _elapse(365 days / 2);
        l.escrow.release();
        assertEq(l.subject.balanceOf(treasury), held, "all of it at a year");
    }
}
