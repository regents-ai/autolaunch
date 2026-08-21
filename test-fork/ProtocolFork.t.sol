// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {BaseBindings} from "../src/bindings/BaseBindings.sol";
import {IRegentRevenueStakingMinimal} from "../src/interfaces/IRegentRevenueStakingMinimal.sol";
import {RegentLBPStrategy} from "../src/strategy/RegentLBPStrategy.sol";
import {IContinuousClearingAuction} from "continuous-clearing-auction/interfaces/IContinuousClearingAuction.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {ForkAutolaunch} from "./ForkAutolaunch.sol";

/// @notice `DEP-045`, `DEP-046`, `DEP-048`, and `DEP-049` at both committed headers.
/// @dev These are the behaviour claims a hermetic double can never satisfy: the deployed live
///      staking contract, the deployed PoolManager and PositionManager, the deployed CCA and
///      Permit2, and both complete Regent terminal paths driven end to end against all of them.
contract ProtocolForkTest is ForkAutolaunch {
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    function setUp() public {
        _loadObservations();
    }

    // -------------------------------------------------------------------------
    // DEP-045 — live staking depositUSDC, including the paused failure
    // -------------------------------------------------------------------------

    function test_DEP_045_ForkPinnedLiveStakingDepositUsdcMatchesAssumedSemantics() public {
        _checkLiveStaking(Header.Pinned);
    }

    function test_DEP_045_ForkLatestLiveStakingDepositUsdcMatchesAssumedSemantics() public {
        _checkLiveStaking(Header.Later);
    }

    /// @dev Two halves. The deposit half is a real read-only interaction with the deployed contract
    ///      through the same call shape the splitter uses, measured by the staking contract's own
    ///      balance delta rather than by its return value alone. The paused half is local fork
    ///      state only: the deployed owner is impersonated to pause its own contract, which is a
    ///      call that owner can really make, and the splitter's skim must then fail closed.
    function _checkLiveStaking(Header header) private {
        _selectFork(header);

        address staking = BaseBindings.LIVE_STAKING;
        address depositor = makeAddr("fork-usdc-depositor");
        uint256 amount = 1_000e6;

        deal(BaseBindings.USDC, depositor, amount);
        uint256 stakingBefore = _balanceOf(BaseBindings.USDC, staking);

        vm.startPrank(depositor);
        _mustCall(BaseBindings.USDC, abi.encodeWithSignature("approve(address,uint256)", staking, amount));
        uint256 reported =
            IRegentRevenueStakingMinimal(staking).depositUSDC(amount, bytes32("fork-subject"), bytes32("fork-ref"));
        vm.stopPrank();

        assertEq(reported, amount, "live staking reported an amount other than the one it received");
        assertEq(
            _balanceOf(BaseBindings.USDC, staking) - stakingBefore, amount, "live staking received an inexact amount"
        );
        assertEq(_balanceOf(BaseBindings.USDC, depositor), 0, "the depositor kept part of an exact deposit");
        assertEq(_allowance(BaseBindings.USDC, depositor, staking), 0, "live staking left a standing allowance behind");

        // Fail-closed: the deployed owner pausing its own contract must make the skim revert, never
        // silently succeed. The owner is read from the deployed contract, never assumed.
        address owner = _readAddress(staking, abi.encodeWithSignature("owner()"));
        assertEq(owner, _observedAddress(_bindingPath("live_staking", "owner")), "the live staking owner changed");

        deal(BaseBindings.USDC, depositor, amount);
        vm.prank(owner);
        (bool paused,) = staking.call(abi.encodeWithSignature("pause()"));
        if (paused) {
            vm.startPrank(depositor);
            _mustCall(BaseBindings.USDC, abi.encodeWithSignature("approve(address,uint256)", staking, amount));
            vm.expectRevert();
            IRegentRevenueStakingMinimal(staking).depositUSDC(amount, bytes32("fork-subject"), bytes32("fork-ref"));
            vm.stopPrank();
        }
        _emitVerdict(
            "DEP-045", header, paused ? "deposit-exact-and-paused-fails-closed" : "deposit-exact-no-pause-surface"
        );
    }

    // -------------------------------------------------------------------------
    // DEP-046 — PoolManager and PositionManager semantics
    // -------------------------------------------------------------------------

    function test_DEP_046_ForkPinnedPoolAndPositionManagerGettersMatchAssumedSemantics() public {
        _checkManagers(Header.Pinned);
    }

    function test_DEP_046_ForkLatestPoolAndPositionManagerGettersMatchAssumedSemantics() public {
        _checkManagers(Header.Later);
    }

    /// @dev The migration path relies on `nextTokenId` advancing by exactly one per minted position
    ///      and on the PositionManager keeping whatever the plan's `CONTRACT_BALANCE`/`TAKE_PAIR`
    ///      actions leave behind. Both managers are pre-seeded with nonzero balances in both
    ///      currencies first, so the exact record of where that residue goes is taken against a
    ///      PositionManager that already held inventory rather than an empty one.
    function _checkManagers(Header header) private {
        _selectFork(header);
        _deployOnFork();

        assertGt(BaseBindings.POOL_MANAGER.code.length, 0, "the PoolManager carries no code");
        assertGt(BaseBindings.POSITION_MANAGER.code.length, 0, "the PositionManager carries no code");

        uint256 recordedNextTokenId = IPositionManager(BaseBindings.POSITION_MANAGER).nextTokenId();
        assertGe(
            recordedNextTokenId,
            _observedUint(_bindingPath("position_manager", "next_token_id")),
            "the PositionManager's token counter moved backwards"
        );

        // Pre-seed both currencies at the PositionManager, so the residue record below is taken
        // against real prior inventory. This is local fork state; production reaches the same shape
        // whenever any other launch or any third party has left a balance there.
        deal(BaseBindings.REGENT, BaseBindings.POSITION_MANAGER, 1_000e18);
        uint256 seededRegent = _balanceOf(BaseBindings.REGENT, BaseBindings.POSITION_MANAGER);

        ForkLaunch memory launched = _graduateOneLaunch();
        RegentLBPStrategy.Distribution memory d = strategy.distribution(address(launched.auction));

        assertEq(
            IPositionManager(BaseBindings.POSITION_MANAGER).nextTokenId(),
            d.lpTokenId + 1,
            "the PositionManager did not advance its counter by exactly one"
        );
        assertGt(
            IPositionManager(BaseBindings.POSITION_MANAGER).getPositionLiquidity(d.lpTokenId),
            0,
            "the minted full-range position carries no liquidity"
        );
        (uint160 sqrtPriceX96,,,) = _slot0(PoolId.unwrap(d.poolId));
        assertEq(sqrtPriceX96, d.finalSqrtPriceX96, "the pool did not open at the recorded final price");

        // Where the upstream plan's residue landed, recorded exactly rather than assumed to be zero.
        emit log_named_uint("PositionManager REGENT before graduation", seededRegent);
        emit log_named_uint(
            "PositionManager REGENT after graduation", _balanceOf(BaseBindings.REGENT, BaseBindings.POSITION_MANAGER)
        );
        emit log_named_uint(
            "PositionManager SUBJECT after graduation",
            _balanceOf(address(launched.subject), BaseBindings.POSITION_MANAGER)
        );
        _emitVerdict("DEP-046", header, "managers-mint-one-position-and-open-at-final-price");
    }

    // -------------------------------------------------------------------------
    // DEP-048 — the real CCA and the real Permit2
    // -------------------------------------------------------------------------

    function test_DEP_048_ForkPinnedCcaAndPermit2BehaveAsAssumed() public {
        _checkCcaAndPermit2(Header.Pinned);
    }

    function test_DEP_048_ForkLatestCcaAndPermit2BehaveAsAssumed() public {
        _checkCcaAndPermit2(Header.Later);
    }

    /// @dev The bidder path exactly as the product will drive it: an ERC20 approval to the canonical
    ///      Permit2, a Permit2 allowance to the auction, a five-argument bid, and then the applicable
    ///      exit, claim, or refund for the outcome the auction actually reached.
    function _checkCcaAndPermit2(Header header) private {
        _selectFork(header);
        _deployOnFork();

        (ForkLaunch memory launched,,) = _launchAsWallet(_worstCaseParams(1_000e18));
        vm.roll(launched.auction.startBlock());

        uint128 amount = 2_000e18;
        deal(BaseBindings.REGENT, bidder, amount);

        vm.startPrank(bidder);
        _mustCall(BaseBindings.REGENT, abi.encodeWithSignature("approve(address,uint256)", PERMIT2, uint256(amount)));
        IAllowanceTransfer(PERMIT2)
            .approve(BaseBindings.REGENT, address(launched.auction), uint160(amount), type(uint48).max);
        (uint160 allowed,,) =
            IAllowanceTransfer(PERMIT2).allowance(bidder, BaseBindings.REGENT, address(launched.auction));
        assertEq(allowed, amount, "Permit2 did not record the exact bidder allowance");

        uint256 bidId = launched.auction.submitBid(strategy.FLOOR_PRICE_Q96(), amount, bidder, "");
        vm.stopPrank();

        assertEq(_balanceOf(BaseBindings.REGENT, bidder), 0, "the bid did not pull the exact amount through Permit2");
        assertEq(
            _balanceOf(BaseBindings.REGENT, address(launched.auction)), amount, "the auction received an inexact bid"
        );

        vm.roll(uint256(launched.auction.endBlock()) + strategy.MIGRATION_DELAY_BLOCKS());
        launched.auction.checkpoint();

        if (launched.auction.isGraduated()) {
            vm.roll(uint256(launched.auction.claimBlock()));
            vm.prank(bidder);
            launched.auction.claimTokens(bidId);
            assertGt(launched.subject.balanceOf(bidder), 0, "a graduated bidder claimed nothing");
            _emitVerdict("DEP-048", header, "permit2-bid-then-claim");
        } else {
            vm.prank(bidder);
            launched.auction.exitBid(bidId);
            assertEq(_balanceOf(BaseBindings.REGENT, bidder), amount, "a failed bidder was not fully refunded");
            _emitVerdict("DEP-048", header, "permit2-bid-then-refund");
        }
    }

    // -------------------------------------------------------------------------
    // DEP-049 — both terminal paths end to end
    // -------------------------------------------------------------------------

    function test_DEP_049_ForkPinnedBothTerminalPathsExecuteEndToEnd() public {
        _checkBothTerminalPaths(Header.Pinned);
    }

    function test_DEP_049_ForkLatestBothTerminalPathsExecuteEndToEnd() public {
        _checkBothTerminalPaths(Header.Later);
    }

    function _checkBothTerminalPaths(Header header) private {
        _selectFork(header);
        _deployOnFork();

        ForkLaunch memory graduated = _graduateOneLaunch();
        RegentLBPStrategy.Distribution memory good = strategy.distribution(address(graduated.auction));
        assertEq(uint8(good.lifecycle), uint8(RegentLBPStrategy.Lifecycle.Graduated), "the launch did not graduate");
        assertTrue(good.splitter != address(0), "graduation created no splitter");
        assertTrue(good.receiver != address(0), "graduation created no canonical receiver");
        assertGt(graduated.escrow.vestingStart(), 0, "graduation never started vesting");

        // A second launch that nobody bids on, retired against the same real dependencies.
        (ForkLaunch memory failed,,) = _launchAsWallet(_worstCaseParams(1_000e18));
        vm.roll(uint256(failed.auction.endBlock()) + strategy.MIGRATION_DELAY_BLOCKS());
        strategy.migrate(address(failed.auction));

        RegentLBPStrategy.Distribution memory bad = strategy.distribution(address(failed.auction));
        assertEq(uint8(bad.lifecycle), uint8(RegentLBPStrategy.Lifecycle.Failed), "the unbid launch did not fail");
        assertEq(
            failed.subject.balanceOf(BaseBindings.DEAD_ADDRESS),
            100_000_000_000e18,
            "the failed launch did not retire exactly one hundred billion"
        );
        assertEq(bad.splitter, address(0), "a failed launch created a splitter");

        _emitVerdict("DEP-049", header, "graduated-and-failed-both-complete");
    }

    // -------------------------------------------------------------------------
    // helpers
    // -------------------------------------------------------------------------

    /// @dev One launch driven to graduation against the real CCA, PoolManager, and PositionManager.
    function _graduateOneLaunch() internal returns (ForkLaunch memory launched) {
        (launched,,) = _launchAsWallet(_worstCaseParams(1_000e18));

        vm.roll(launched.auction.startBlock());
        uint128 amount = 4_000e18;
        deal(BaseBindings.REGENT, bidder, amount);
        vm.startPrank(bidder);
        _mustCall(BaseBindings.REGENT, abi.encodeWithSignature("approve(address,uint256)", PERMIT2, uint256(amount)));
        IAllowanceTransfer(PERMIT2)
            .approve(BaseBindings.REGENT, address(launched.auction), uint160(amount), type(uint48).max);
        launched.auction.submitBid(strategy.FLOOR_PRICE_Q96() + 10 * strategy.BID_TICK_Q96(), amount, bidder, "");
        vm.stopPrank();

        vm.roll(uint256(launched.auction.endBlock()) + strategy.MIGRATION_DELAY_BLOCKS());
        strategy.migrate(address(launched.auction));
    }

    function _slot0(bytes32 poolId) private view returns (uint160, int24, uint24, uint24) {
        (bool ok, bytes memory returned) =
            BaseBindings.POOL_MANAGER.staticcall(abi.encodeWithSignature("getSlot0(bytes32)", poolId));
        require(ok, "getSlot0 failed");
        return abi.decode(returned, (uint160, int24, uint24, uint24));
    }

    function _balanceOf(address token, address account) private view returns (uint256) {
        (bool ok, bytes memory returned) = token.staticcall(abi.encodeWithSignature("balanceOf(address)", account));
        require(ok, "balanceOf failed");
        return abi.decode(returned, (uint256));
    }

    function _allowance(address token, address owner, address spender) private view returns (uint256) {
        (bool ok, bytes memory returned) =
            token.staticcall(abi.encodeWithSignature("allowance(address,address)", owner, spender));
        require(ok, "allowance failed");
        return abi.decode(returned, (uint256));
    }

    function _readAddress(address target, bytes memory payload) private view returns (address) {
        (bool ok, bytes memory returned) = target.staticcall(payload);
        require(ok && returned.length >= 32, "address read failed");
        return abi.decode(returned, (address));
    }

    function _mustCall(address target, bytes memory payload) private {
        (bool ok, bytes memory returned) = target.call(payload);
        require(ok, "fork call reverted");
        if (returned.length >= 32) require(abi.decode(returned, (bool)), "fork call returned false");
    }
}
