// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {IContinuousClearingAuction} from "continuous-clearing-auction/interfaces/IContinuousClearingAuction.sol";
import {ConstantsLib} from "continuous-clearing-auction/libraries/ConstantsLib.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {BaseBindings} from "../../src/bindings/BaseBindings.sol";
import {ConditionalVestingEscrowV2} from "../../src/escrow/ConditionalVestingEscrowV2.sol";
import {RegentsAutolaunchFactoryV3} from "../../src/factory/RegentsAutolaunchFactoryV3.sol";
import {RegentFeeHook} from "../../src/hook/RegentFeeHook.sol";
import {RegentLBPStrategyV3} from "../../src/strategy/RegentLBPStrategyV3.sol";
import {V2Schedule} from "../strategy/V2Schedule.sol";

/// @notice Version 3 on a local copy of Base mainnet, which has made a block every 0.2 seconds since
///         Denim (block 53,556,127, 5 November 2026 18:00:01 UTC). Everything is the real thing: the
///         pinned CCA factory, Permit2, PoolManager, PositionManager, REGENT and version 2's deployed
///         UERC20 factory, escrow, splitter and payment receiver implementations, which version 3
///         binds unchanged. The factory is built here exactly as the deployment builds it and the
///         Governance and Regent Safe's own call opens it. Nothing is sent to Base: the copy is local
///         to Forge.
contract AutolaunchBaseCopyTest is Test {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    uint256 internal constant DENIM_BLOCK = 53_556_127;
    uint256 internal constant BLOCKS_PER_SECOND = 5;
    /// @dev Version 2's deployed implementations, read from
    ///      `contracts/revstake-v2/deployments/base-mainnet/deployed-manifest.json`.
    address internal constant UERC20_FACTORY = 0x4c003500c6a28826d15A6E4cF023C1f1ecd41E08;
    address internal constant ESCROW_IMPLEMENTATION = 0x8F511153393429468C3861E7cC5341Abb3310871;
    address internal constant SPLITTER_IMPLEMENTATION = 0x0886e34742B5E5ab8e07B0A6C3fC66A7912DE942;
    address internal constant RECEIVER_IMPLEMENTATION = 0xb58f2AF6A588414C6ad44280143db9aE7927d5fc;
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    uint160 internal constant HOOK_FLAGS =
        uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG);
    uint256 internal constant DEFAULT_TICK_Q96 = 42_949_673;
    /// @dev The widest gap, in mps, between version 3 and version 2 at the same wall-clock time.
    uint256 internal constant WIDEST_GAP_MPS = 26_144;

    RegentsAutolaunchFactoryV3 internal factory;
    RegentLBPStrategyV3 internal strategy;
    RegentFeeHook internal hook;
    IERC20 internal regent = IERC20(BaseBindings.REGENT);

    address internal treasury = makeAddr("treasury");
    address internal launcher = makeAddr("launcher");
    address internal bidder = makeAddr("bidder");
    uint256 internal forkBlock;

    function setUp() public {
        assertEq(block.chainid, BaseBindings.BASE_CHAIN_ID, "a copy of Base mainnet");
        assertGt(block.number, DENIM_BLOCK, "after Denim");
        assertEq(BaseBindings.CCA_FACTORY.codehash, BaseBindings.CCA_FACTORY_RUNTIME_CODE_HASH, "the pinned CCA");
        forkBlock = block.number;

        address predictedFactory = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        (, bytes32 salt) = HookMiner.find(
            predictedFactory,
            HOOK_FLAGS,
            type(RegentFeeHook).creationCode,
            abi.encode(BaseBindings.POOL_MANAGER, vm.computeCreateAddress(predictedFactory, 1))
        );
        factory = new RegentsAutolaunchFactoryV3(
            UERC20_FACTORY, ESCROW_IMPLEMENTATION, SPLITTER_IMPLEMENTATION, RECEIVER_IMPLEMENTATION, salt
        );
        strategy = factory.strategy();
        hook = factory.hook();
        assertTrue(factory.launchesPaused(), "born paused");

        vm.prank(BaseBindings.GOVERNANCE_AND_REGENT_SAFE);
        factory.unpauseLaunches();
    }

    /// @dev The copy's own history: 1,000 blocks span 200 seconds.
    function test_base_makes_five_blocks_a_second() public {
        vm.rollFork(forkBlock - 1000);
        uint256 earlier = vm.getBlockTimestamp();
        vm.rollFork(forkBlock);
        assertApproxEqAbs(vm.getBlockTimestamp() - earlier, 200, 1, "1,000 blocks in 200 seconds");
    }

    /// @dev A launch at five blocks a second: ten minutes to the opening, two days of auction, claims
    ///      128 seconds and the pool 256 seconds after the end, and a year of treasury vesting.
    function test_base_launch_runs_its_two_days_on_the_base_clock() public {
        (address subject, IContinuousClearingAuction auction, ConditionalVestingEscrowV2 escrow) = _launch();
        RegentLBPStrategyV3.Distribution memory d = strategy.distribution(address(auction));
        uint64 startBlock = auction.startBlock();
        uint64 endBlock = auction.endBlock();
        assertEq(startBlock, forkBlock + strategy.START_DELAY_BLOCKS(), "opens 3,000 blocks after the launch");
        assertEq(endBlock - startBlock, strategy.AUCTION_DURATION_BLOCKS());
        assertEq(auction.claimBlock(), endBlock + strategy.CLAIM_DELAY_BLOCKS());

        _elapse(600);
        assertEq(vm.getBlockNumber(), startBlock, "ten minutes to the opening block");
        uint256 openedAt = vm.getBlockTimestamp();
        uint256 bidId = _bid(auction, strategy.REQUIRED_REGENT_RAISED(), 10);

        _elapse(24 hours);
        uint256 released = auction.checkpoint().cumulativeMps;
        assertEq(released, V2Schedule.released(strategy.AUCTION_STEPS(), 24 hours * 5), "the schedule at 24 h");
        assertApproxEqAbs(
            released, V2Schedule.released(V2Schedule.AUCTION_STEPS, 24 hours / 2), WIDEST_GAP_MPS, "version 2 at 24 h"
        );

        _elapse(24 hours);
        vm.roll(vm.getBlockNumber() + 1);
        assertEq(vm.getBlockNumber(), endBlock, "the end block");
        assertApproxEqAbs(vm.getBlockTimestamp() - openedAt, 2 days, 1, "two days of wall-clock time");
        assertEq(auction.checkpoint().cumulativeMps, ConstantsLib.MPS, "everything released by the end");

        _elapse(128);
        assertEq(vm.getBlockNumber(), auction.claimBlock(), "claims open 128 seconds after the end");
        _elapse(127);
        vm.roll(vm.getBlockNumber() + 4);
        vm.expectRevert();
        strategy.migrate(address(auction));
        vm.roll(vm.getBlockNumber() + 1);
        assertEq(vm.getBlockNumber(), d.migrationBlock, "the pool 256 seconds after the end");
        strategy.migrate(address(auction));
        assertEq(
            uint8(strategy.distribution(address(auction)).lifecycle), uint8(RegentLBPStrategyV3.Lifecycle.Graduated)
        );
        PoolId poolId = strategy.poolKeyOf(subject).toId();
        (uint160 sqrtPriceX96,,,) = IPoolManager(BaseBindings.POOL_MANAGER).getSlot0(poolId);
        assertGt(sqrtPriceX96, 0, "the real PoolManager holds the official pool");
        assertGt(IPoolManager(BaseBindings.POOL_MANAGER).getLiquidity(poolId), 0, "with locked liquidity");
        assertEq(escrow.vestingStart(), vm.getBlockTimestamp(), "vesting starts at the graduation timestamp");

        vm.startPrank(bidder);
        auction.exitBid(bidId);
        auction.claimTokens(bidId);
        vm.stopPrank();
        assertGt(IERC20(subject).balanceOf(bidder), 0, "the bidder holds SUBJECT");

        uint256 held = IERC20(subject).balanceOf(address(escrow));
        _elapse(365 days / 2);
        escrow.release();
        assertApproxEqAbs(IERC20(subject).balanceOf(treasury), held / 2, 1, "half the escrow at half a year");
        _elapse(365 days / 2);
        escrow.release();
        assertEq(IERC20(subject).balanceOf(treasury), held, "all of it at a year");
    }

    /// @dev A raise one unit short fails through the real CCA; the bidder is refunded in full.
    function test_base_a_raise_one_unit_short_fails_and_refunds() public {
        (address subject, IContinuousClearingAuction auction, ConditionalVestingEscrowV2 escrow) = _launch();
        vm.roll(auction.startBlock());
        uint128 short = strategy.REQUIRED_REGENT_RAISED() - 1;
        uint256 bidId = _bid(auction, short, 10);
        vm.roll(uint256(auction.endBlock()) + strategy.MIGRATION_DELAY_BLOCKS());

        strategy.migrate(address(auction));
        assertEq(uint8(strategy.distribution(address(auction)).lifecycle), uint8(RegentLBPStrategyV3.Lifecycle.Failed));
        assertEq(uint8(escrow.lifecycle()), uint8(ConditionalVestingEscrowV2.Lifecycle.Failed));
        assertEq(IERC20(subject).balanceOf(BaseBindings.DEAD_ADDRESS), 100_000_000_000e18, "the supply is retired");

        vm.prank(bidder);
        auction.exitBid(bidId);
        assertEq(regent.balanceOf(bidder), short, "full refund through the CCA");
    }

    /// @dev The step loop's worst case: an auction nobody touched, checkpointed once after its end,
    ///      walks all nineteen steps in one call.
    function test_base_a_checkpoint_across_every_step_is_cheap() public {
        (, IContinuousClearingAuction auction,) = _launch();
        vm.roll(auction.endBlock());
        uint256 before = gasleft();
        auction.checkpoint();
        uint256 used = before - gasleft();
        emit log_named_uint("gas for one checkpoint across all nineteen steps", used);
        assertEq(auction.checkpoint().cumulativeMps, ConstantsLib.MPS);
        assertLt(used, 500_000, "far inside one Base block");
    }

    function _launch()
        private
        returns (address subject, IContinuousClearingAuction auction, ConditionalVestingEscrowV2 escrow)
    {
        vm.prank(launcher);
        (, address subject_, address auction_, address escrow_) = factory.launch(
            RegentsAutolaunchFactoryV3.LaunchParams({
                name: "Base Copy One",
                symbol: "BCOPY",
                description: "Base copy launch",
                website: "https://regents.sh",
                image: "ipfs://image",
                treasury: treasury
            })
        );
        return (subject_, IContinuousClearingAuction(auction_), ConditionalVestingEscrowV2(escrow_));
    }

    /// @dev A REGENT bid through the real Permit2, `ticks` above the one floor.
    function _bid(IContinuousClearingAuction auction, uint128 amount, uint256 ticks) private returns (uint256 bidId) {
        deal(BaseBindings.REGENT, bidder, amount);
        vm.startPrank(bidder);
        regent.approve(PERMIT2, amount);
        IAllowanceTransfer(PERMIT2).approve(BaseBindings.REGENT, address(auction), uint160(amount), type(uint48).max);
        bidId = auction.submitBid(
            auction.floorPrice() + ticks * DEFAULT_TICK_Q96, amount, bidder, auction.floorPrice(), ""
        );
        vm.stopPrank();
    }

    /// @dev Five blocks to each second, as Base makes them.
    function _elapse(uint256 seconds_) private {
        vm.roll(vm.getBlockNumber() + BLOCKS_PER_SECOND * seconds_);
        vm.warp(vm.getBlockTimestamp() + seconds_);
    }
}
