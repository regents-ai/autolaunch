// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {BaseBindings} from "../../src/bindings/BaseBindings.sol";
import {PaymentReceiverV1} from "../../src/revenue/PaymentReceiverV1.sol";
import {RegentsAutolaunchFactoryV1} from "../../src/factory/RegentsAutolaunchFactoryV1.sol";
import {SubjectSplitterV1} from "../../src/revenue/SubjectSplitterV1.sol";
import {RegentLBPStrategy} from "../../src/strategy/RegentLBPStrategy.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {AutolaunchFixture} from "./AutolaunchFixture.sol";
import {SimpleSwapRouter} from "../mocks/SimpleSwapRouter.sol";
import {StagedERC20} from "../strategy/doubles/StagedERC20.sol";

/// @notice `C4-I1`: the launch pause gates exactly one thing — creating a new launch. Every existing
///         launch keeps running: bidding, finalization, refunds, staking, claims, swaps, payments,
///         vesting and recovery all continue untouched, and the launch fee a completed launch paid is
///         never returned by a later economic failure.
contract AutolaunchPauseScopeTest is AutolaunchFixture {
    SimpleSwapRouter internal router;

    function setUp() public {
        _deployAutolaunch();
        router = new SimpleSwapRouter(IPoolManager(BaseBindings.POOL_MANAGER));
    }

    /// @notice `FAC-018`: the launch fee buys the launch, not its outcome. A launch that later fails
    ///         economically returns no REGENT to its launcher.
    function test_FAC_018_FailedAuctionDoesNotRefundTheLaunchFee() public {
        Launched memory launched = _defaultLaunch();

        uint256 safeAfterLaunch = regent.balanceOf(BaseBindings.GOVERNANCE_AND_REGENT_SAFE);
        assertEq(regent.balanceOf(launcher), 0, "the launcher kept fee REGENT");

        _rollToMigration(launched);
        strategy.migrate(address(launched.auction));
        assertEq(
            uint8(_distribution(launched).lifecycle),
            uint8(RegentLBPStrategy.Lifecycle.Failed),
            "this launch was supposed to fail"
        );

        assertEq(regent.balanceOf(launcher), 0, "the failed launch refunded its fee");
        assertEq(
            regent.balanceOf(BaseBindings.GOVERNANCE_AND_REGENT_SAFE),
            safeAfterLaunch,
            "the Regent Safe gave the fee back"
        );
        assertEq(regent.balanceOf(address(factory)), 0, "the factory holds refundable fee REGENT");

        // And there is no surface that could ever return it.
        bytes memory runtime = address(factory).code;
        string[3] memory forbidden = ["refundLaunchFee(uint256)", "refund(uint256)", "withdraw(address,uint256)"];
        for (uint256 i; i < forbidden.length; ++i) {
            assertFalse(
                _carriesSelector(runtime, bytes4(keccak256(bytes(forbidden[i])))),
                string.concat("the factory can return a fee: ", forbidden[i])
            );
        }
    }

    /// @notice `FAC-019`: with new launches paused, every existing lifecycle operation still works.
    function test_FAC_019_PauseNeverBlocksExistingLifecycleOperations() public {
        Launched memory winner = _defaultLaunch();
        Launched memory loser = _launchAs(launcher, _params());

        _rollToStart(winner);
        _bid(winner, bidder, 2_000e18, _bidPrice(10));

        vm.prank(governance);
        factory.pauseLaunches();
        assertTrue(factory.launchesPaused(), "the factory is not paused");

        // 1. bidding on an existing auction
        uint256 loserBid = _bid(loser, outsider, 100e18, _bidPrice(10));
        uint256 extraBid = _bid(winner, outsider, 1_000e18, _bidPrice(11));
        assertGt(extraBid, 0, "a paused factory blocked a bid");

        // 2. finalization of both outcomes
        _rollToMigration(winner);
        strategy.migrate(address(winner.auction));
        strategy.migrate(address(loser.auction));
        RegentLBPStrategy.Distribution memory d = _distribution(winner);
        assertEq(
            uint8(d.lifecycle), uint8(RegentLBPStrategy.Lifecycle.Graduated), "a paused factory blocked graduation"
        );
        assertEq(
            uint8(_distribution(loser).lifecycle),
            uint8(RegentLBPStrategy.Lifecycle.Failed),
            "a paused factory blocked retirement"
        );

        // 3. refunds from the failed auction
        vm.prank(outsider);
        loser.auction.exitBid(loserBid);
        assertEq(regent.balanceOf(outsider), 100e18, "a paused factory blocked a refund");

        // 4. vesting release from the graduated escrow
        vm.warp(block.timestamp + 365 days);
        winner.escrow.release();
        uint256 vested = winner.subject.balanceOf(treasury);
        assertGt(vested, 0, "a paused factory blocked vesting");

        // 5. staking and 6. claims through the launch splitter
        // A tenth of the fixed supply, so the staker's coverage really does earn a share of the net.
        SubjectSplitterV1 splitter = SubjectSplitterV1(d.splitter);
        vm.startPrank(treasury);
        winner.subject.transfer(outsider, 10_000_000_000e18);
        vm.stopPrank();
        vm.startPrank(outsider);
        winner.subject.approve(address(splitter), 10_000_000_000e18);
        splitter.stake(10_000_000_000e18);
        vm.stopPrank();

        regent.mint(launcher, 10_000e18);
        vm.startPrank(launcher);
        regent.approve(address(splitter), 10_000e18);
        splitter.depositRecognizedRevenue(address(regent), 10_000e18, bytes32("rev"));
        vm.stopPrank();

        uint256 claimable = splitter.claimable(address(regent), outsider);
        assertGt(claimable, 0, "a paused factory blocked revenue recognition");
        vm.roll(vm.getBlockNumber() + 1);
        vm.prank(outsider);
        splitter.claim(address(regent));
        assertEq(regent.balanceOf(outsider), 100e18 + claimable, "a paused factory blocked a claim");

        // 7. swaps through the official pool and its hook
        uint256 safeSubjectBefore = winner.subject.balanceOf(BaseBindings.GOVERNANCE_AND_REGENT_SAFE);
        _swap(winner, 1_000e18);
        assertGt(
            winner.subject.balanceOf(BaseBindings.GOVERNANCE_AND_REGENT_SAFE),
            safeSubjectBefore,
            "a paused factory blocked a swap"
        );

        // 8. payments through the canonical receiver
        PaymentReceiverV1 canonical = PaymentReceiverV1(payable(d.receiver));
        regent.mint(launcher, 1_000e18);
        vm.startPrank(launcher);
        regent.approve(address(canonical), 1_000e18);
        canonical.pay(address(regent), 1_000e18, bytes32("pay"));
        vm.stopPrank();
        assertEq(regent.balanceOf(address(canonical)), 0, "a paused factory blocked a payment");

        // 9. permissionless recovery of an unsupported token
        StagedERC20 stray = new StagedERC20();
        stray.mint(address(canonical), 5e18);
        vm.prank(outsider);
        canonical.recoverUnsupportedToken(address(stray));
        assertEq(stray.balanceOf(treasury), 5e18, "a paused factory blocked recovery");

        // 10. custom receiver creation
        vm.prank(outsider);
        address custom = factory.createPaymentReceiver(winner.launchId, outsider, 100);
        assertTrue(custom != address(0), "a paused factory blocked custom receiver creation");

        // Only the one thing the pause is for is actually blocked.
        assertTrue(factory.launchesPaused(), "the factory unpaused itself somewhere above");
        RegentsAutolaunchFactoryV1.LaunchParams memory params = _params();
        _fundFee(launcher, params.expectedLaunchFee);
        vm.expectRevert(RegentsAutolaunchFactoryV1.LaunchesArePaused.selector);
        vm.prank(launcher);
        factory.launch(params);
    }

    /// @notice `SPL-010`: staking, unstaking and claiming are the staker's own operations and the
    ///         factory pause has no reach into them at all.
    function test_SPL_010_ClaimsAndUnstakingIgnoreTheLaunchPause() public {
        Launched memory launched = _defaultLaunch();
        _bidToGraduation(launched, 2_000e18);
        strategy.migrate(address(launched.auction));
        SubjectSplitterV1 splitter = SubjectSplitterV1(_distribution(launched).splitter);

        vm.warp(block.timestamp + 365 days);
        launched.escrow.release();
        vm.prank(treasury);
        launched.subject.transfer(outsider, 10_000_000_000e18);

        // Stake while the factory is open, then pause and do everything else under the pause. Two
        // stakes of 5% of the supply each, so the staker's coverage earns a real share of both nets.
        vm.startPrank(outsider);
        launched.subject.approve(address(splitter), 10_000_000_000e18);
        splitter.stake(5_000_000_000e18);
        vm.stopPrank();

        vm.prank(governance);
        factory.pauseLaunches();

        vm.startPrank(outsider);
        splitter.stake(5_000_000_000e18);
        vm.stopPrank();

        regent.mint(launcher, 10_000e18);
        usdc.mint(launcher, 10_000e6);
        vm.startPrank(launcher);
        regent.approve(address(splitter), 10_000e18);
        splitter.depositRecognizedRevenue(address(regent), 10_000e18, bytes32("rev"));
        usdc.approve(address(splitter), 10_000e6);
        splitter.depositRecognizedRevenue(address(usdc), 10_000e6, bytes32("usdc"));
        vm.stopPrank();

        uint256 regentClaimable = splitter.claimable(address(regent), outsider);
        uint256 usdcClaimable = splitter.claimable(address(usdc), outsider);
        assertGt(regentClaimable, 0, "no REGENT revenue accrued");
        assertGt(usdcClaimable, 0, "no USDC revenue accrued");

        // Accrual is immediate; every value exit needs a later block than the staker's own latest
        // stake, and the pause has no reach into the refusal or the exit.
        vm.prank(outsider);
        vm.expectRevert(
            abi.encodeWithSelector(SubjectSplitterV1.SameBlockStakeExit.selector, outsider, vm.getBlockNumber())
        );
        splitter.unstake(10_000_000_000e18);

        vm.roll(vm.getBlockNumber() + 1);
        vm.startPrank(outsider);
        splitter.claimAll();
        splitter.unstake(10_000_000_000e18);
        vm.stopPrank();

        assertEq(regent.balanceOf(outsider), regentClaimable, "a paused factory blocked a REGENT claim");
        assertEq(usdc.balanceOf(outsider), usdcClaimable, "a paused factory blocked a USDC claim");
        assertEq(launched.subject.balanceOf(outsider), 10_000_000_000e18, "a paused factory blocked unstaking");
        assertTrue(factory.launchesPaused(), "the factory was not paused for this test");
    }

    // -------------------------------------------------------------------------
    // helpers
    // -------------------------------------------------------------------------

    /// @dev One ordinary REGENT-in swap through an unprivileged router, so the hook's two lanes run.
    function _swap(Launched memory launched, uint256 amountIn) private {
        PoolKey memory key = strategy.poolKeyOf(address(launched.subject));
        bool regentIsCurrency0 = Currency.unwrap(key.currency0) == BaseBindings.REGENT;

        regent.mint(bidder, amountIn);
        vm.startPrank(bidder);
        regent.approve(address(router), type(uint256).max);
        launched.subject.approve(address(router), type(uint256).max);
        router.swap(
            key,
            SwapParams({
                zeroForOne: regentIsCurrency0,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: regentIsCurrency0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            })
        );
        vm.stopPrank();
    }
}
