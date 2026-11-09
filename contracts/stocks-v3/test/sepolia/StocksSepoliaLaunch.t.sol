// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {ConstantsLib} from "continuous-clearing-auction/libraries/ConstantsLib.sol";
import {UERC20} from "uerc20-factory/tokens/UERC20.sol";
import {StocksBindings} from "../../src/StocksBindings.sol";
import {StocksPreset} from "../../src/StocksPreset.sol";
import {StocksFixture} from "../StocksFixture.sol";
import {V2Schedule} from "../V2Schedule.sol";

/// @notice A version 3 launch on Base Sepolia, which has run 0.2 s blocks since 21 Oct 2026, driven
///         through the real pinned CCA factory and Permit2 there at five blocks a second. The pool
///         pieces, USDC, REGENT staking and the stock are built fresh at their Base mainnet addresses,
///         which hold nothing usable on Sepolia.
contract StocksSepoliaLaunchTest is StocksFixture {
    /// @dev The pinned factory's runtime code hash, the same on Base mainnet.
    bytes32 internal constant CCA_FACTORY_CODEHASH = 0xa1d2a90564f4f63580b25de42efaff92505c254b00fc666f65ab38126cce5cfa;
    uint256 internal constant BASE_SEPOLIA_CHAIN_ID = 84_532;

    uint256 internal forkBlock;
    uint256 internal forkTime;

    function setUp() public {
        vm.createSelectFork("base_sepolia");
        assertEq(block.chainid, BASE_SEPOLIA_CHAIN_ID);
        forkBlock = block.number;
        forkTime = block.timestamp;

        _deployStocks();
        // Sepolia has an unrelated contract at the mainnet staking address; the mock starts clean.
        for (uint256 slot; slot < 6; ++slot) {
            vm.store(StocksBindings.LIVE_STAKING, bytes32(slot), bytes32(0));
        }
        vm.roll(forkBlock);
        vm.warp(forkTime);
    }

    /// @dev The real factory and Permit2 stay in place; only their presence is checked.
    function _placeAuctionPieces() internal view override {
        assertEq(StocksBindings.CCA_FACTORY.codehash, CCA_FACTORY_CODEHASH, "the pinned CCA factory");
        assertGt(StocksBindings.PERMIT2.code.length, 0, "Permit2");
    }

    /// @dev 1,000 blocks span 200 seconds, and every whole second holds five blocks.
    function test_sepolia_runs_five_blocks_a_second() public {
        uint256 latest = forkBlock;
        vm.rollFork(latest - 1000);
        uint256 earlier = vm.getBlockTimestamp();
        vm.rollFork(latest);
        assertApproxEqAbs(vm.getBlockTimestamp() - earlier, 200, 1, "1,000 blocks in 200 seconds");

        // Walk 31 blocks second by second. The first and last seconds may run past the window; every
        // second between them is whole and holds exactly five blocks.
        vm.rollFork(latest - 30);
        uint256 second = vm.getBlockTimestamp();
        uint256 run = 1;
        uint256 seconds_;
        uint256 wholeSeconds;
        for (uint256 n = latest - 29; n <= latest; ++n) {
            vm.rollFork(n);
            uint256 timestamp = vm.getBlockTimestamp();
            if (timestamp == second) {
                ++run;
                continue;
            }
            assertEq(timestamp, second + 1, "consecutive seconds");
            if (seconds_ > 0) {
                assertEq(run, 5, "five blocks share each second");
                ++wholeSeconds;
            }
            ++seconds_;
            second = timestamp;
            run = 1;
        }
        assertGe(wholeSeconds, 4, "at least four whole seconds checked");
    }

    function test_launch_runs_its_day_on_the_sepolia_clock() public {
        Launched memory l = _launch(STOCK_LOW);
        uint64 startBlock = l.auction.startBlock();
        uint64 endBlock = l.auction.endBlock();
        assertEq(startBlock, forkBlock + StocksPreset.START_LEAD_BLOCKS, "opens 3,000 blocks after creation");
        assertEq(endBlock - startBlock, StocksPreset.AUCTION_DURATION_BLOCKS);

        _elapse(600);
        assertEq(vm.getBlockNumber(), startBlock, "ten minutes to the opening block");
        uint256 openedAt = vm.getBlockTimestamp();
        uint256 bidId = _bidDirect(l, bidder, 500e8, _bidPrice(GRADUATING_TICKS));

        _elapse(12 hours);
        uint256 released = l.auction.checkpoint().cumulativeMps;
        assertEq(released, V2Schedule.released(StocksPreset.AUCTION_STEPS, 12 hours * 5), "the schedule at 12 h");
        assertApproxEqAbs(
            released, V2Schedule.released(V2Schedule.AUCTION_STEPS, 12 hours / 2), 10_218, "version 2's 12 h amount"
        );

        _elapse(12 hours - 2);
        vm.roll(vm.getBlockNumber() + 1);
        assertEq(vm.getBlockNumber(), endBlock, "the end block");
        assertApproxEqAbs(vm.getBlockTimestamp() - openedAt, 1 days, 2, "the auction runs a day of wall-clock time");
        assertEq(l.auction.checkpoint().cumulativeMps, ConstantsLib.MPS, "everything released by the end");

        _elapse(128);
        assertEq(vm.getBlockNumber(), l.auction.claimBlock(), "claims open 128 seconds after the end");
        _elapse(127);
        vm.roll(vm.getBlockNumber() + 4);
        vm.expectRevert();
        launchpad.migrate(l.launchId);
        vm.roll(vm.getBlockNumber() + 1);
        assertEq(vm.getBlockNumber(), _record(l).migrationBlock, "the pool opens 256 seconds after the end");
        launchpad.migrate(l.launchId);
        assertEq(_record(l).vestingStart, vm.getBlockTimestamp(), "vesting starts at the graduation timestamp");

        vm.startPrank(bidder);
        l.auction.exitBid(bidId);
        l.auction.claimTokens(bidId);
        vm.stopPrank();
        assertGt(UERC20(l.newToken).balanceOf(bidder), 0, "the bidder holds NEW");

        _elapse(15 days);
        assertEq(
            launchpad.releaseCreatorVesting(l.launchId), uint256(StocksPreset.CREATOR_VESTING) / 2, "half at 15 days"
        );
        _elapse(15 days);
        launchpad.releaseCreatorVesting(l.launchId);
        assertEq(UERC20(l.newToken).balanceOf(launcher), StocksPreset.CREATOR_VESTING, "all of it at 30 days");
    }
}
