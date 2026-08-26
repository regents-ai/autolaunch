// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {BaseBindings} from "../src/bindings/BaseBindings.sol";
import {IRegentRevenueStakingMinimal} from "../src/interfaces/IRegentRevenueStakingMinimal.sol";
import {RegentLBPStrategy} from "../src/strategy/RegentLBPStrategy.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {UERC20} from "uerc20-factory/tokens/UERC20.sol";
import {ForkAutolaunch} from "./ForkAutolaunch.sol";

/// @notice `DEP-045`, `DEP-046`, `DEP-048`, and `DEP-049` at the committed pinned header.
/// @dev These are the behaviour claims a hermetic double can never satisfy: the deployed live
///      staking contract, the deployed PoolManager and PositionManager, the deployed CCA and
///      Permit2, and both complete Regent terminal paths driven end to end against all of them.
///
///      All four are pinned-only. Each drives real launches, real bids and a real migration against
///      the shared Base singletons, and the fresh-head subset re-reads the deployed code identity of
///      every binding they depend on instead of repeating the whole portfolio. One consequence is
///      accepted explicitly rather than papered over: `DEP-045` reads the live staking contract's
///      mutable `paused()` and proves both the deposit and the owner-driven fail-closed path, and
///      the fresh-head subset does not re-read it. `docs/audit/fork-authority-and-state-inventory.md`
///      records that `paused()` must be checked immediately before any separately authorized
///      deployment.
contract ProtocolForkTest is ForkAutolaunch {
    using StateLibrary for IPoolManager;

    function setUp() public {
        _loadObservations();
    }

    // -------------------------------------------------------------------------
    // DEP-045 — live staking depositUSDC, including the mandatory paused failure
    // -------------------------------------------------------------------------

    function test_DEP_045_ForkPinnedLiveStakingDepositUsdcMatchesAssumedSemantics() public {
        _checkLiveStaking(Header.Pinned);
    }

    /// @dev Three halves, and none of them is optional.
    ///
    ///      The admitted getters come first: `owner()` and `paused()` are read from the deployed
    ///      contract and compared against the reviewed record, so a change of owner or a contract
    ///      that is already paused on Base is a failure here rather than a surprise later. The
    ///      splitter's skim assumes a live contract, so a deployed `paused() == true` is itself a
    ///      stop.
    ///
    ///      The deposit half is a real interaction with the deployed contract through the same call
    ///      shape the splitter uses, measured by the staking contract's own balance delta rather
    ///      than by its return value alone.
    ///
    ///      The paused half is mandatory. The deployed owner is impersonated to pause its own
    ///      contract — a call that owner can really make — and the skim must then fail closed. A
    ///      `setPaused(true)` that reverts or does not take effect is a failed claim, never a passing
    ///      alternative: the whole point is that the splitter cannot silently succeed against a
    ///      paused dependency. Every mutation is local fork state, and this claim runs in its own
    ///      freshly created fork per header, so nothing it pauses is visible to any other claim.
    function _checkLiveStaking(Header header) private {
        _selectFork(header);

        address staking = BaseBindings.LIVE_STAKING;
        address depositor = makeAddr("fork-usdc-depositor");
        uint256 amount = 1_000e6;

        address owner = _callAddress(staking, abi.encodeWithSignature("owner()"));
        assertEq(owner, _observedAddress(_bindingPath("live_staking", "owner")), "the live staking owner changed");
        bool pausedOnChain = _callBool(staking, abi.encodeWithSignature("paused()"));
        assertEq(
            pausedOnChain, _observedBool(_bindingPath("live_staking", "paused")), "the deployed paused state moved"
        );
        assertFalse(pausedOnChain, "the deployed live staking contract is paused; the splitter's skim cannot settle");

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

        // Fail-closed, required. The owner pauses its own contract in local fork state and the
        // deposit must then revert.
        vm.prank(owner);
        _mustCall(staking, abi.encodeWithSignature("setPaused(bool)", true));
        assertTrue(_callBool(staking, abi.encodeWithSignature("paused()")), "the owner's pause did not take effect");

        deal(BaseBindings.USDC, depositor, amount);
        vm.startPrank(depositor);
        _mustCall(BaseBindings.USDC, abi.encodeWithSignature("approve(address,uint256)", staking, amount));
        vm.expectRevert();
        IRegentRevenueStakingMinimal(staking).depositUSDC(amount, bytes32("fork-subject"), bytes32("fork-ref"));
        vm.stopPrank();

        _emitVerdict("DEP-045", header, "deposit-exact-and-owner-pause-fails-closed");
    }

    // -------------------------------------------------------------------------
    // DEP-046 — PoolManager and PositionManager semantics
    // -------------------------------------------------------------------------

    function test_DEP_046_ForkPinnedPoolAndPositionManagerGettersMatchAssumedSemantics() public {
        _checkManagers(Header.Pinned);
    }

    /// @dev The migration path relies on `nextTokenId` advancing by exactly one per minted position
    ///      and on the deployed PositionManager's settlement semantics matching what the strategy
    ///      now asks of it. `PositionPlanner.toPlan` closes every plan with
    ///      `SETTLE(currency0, CONTRACT_BALANCE)`, `SETTLE(currency1, CONTRACT_BALANCE)`,
    ///      `TAKE_PAIR(currency0, currency1, MSG_SENDER)`. That `CONTRACT_BALANCE` sentinel resolves
    ///      to the deployed PositionManager's *entire* balance of each pool currency, and the
    ///      PositionManager is shared with every other v4 user on Base, so honouring the sentinel
    ///      would settle inventory this launch never funded and hand the credit back through
    ///      `TAKE_PAIR` as if it were this launch's unspent budget. `C6-I8` replaces those two
    ///      settlement amounts with the exact two amounts the strategy transfers in, and this is that
    ///      claim measured against the real deployed contract rather than a double: both pool
    ///      currencies must be preserved to the unit across a real graduation, and so must a
    ///      different launch's SUBJECT, which is not a currency of this pool at all.
    ///
    ///      Every pre-seed arrives through a real production path: a third party who holds REGENT
    ///      sends some to the shared PositionManager, and a bidder who exited and claimed auction
    ///      tokens sends some of those. Nothing is written into storage.
    function _checkManagers(Header header) private {
        _selectFork(header);
        _deployOnFork();

        assertGt(BaseBindings.POOL_MANAGER.code.length, 0, "the PoolManager carries no code");
        assertGt(BaseBindings.POSITION_MANAGER.code.length, 0, "the PositionManager carries no code");
        assertGe(
            IPositionManager(BaseBindings.POSITION_MANAGER).nextTokenId(),
            _observedUint(_bindingPath("position_manager", "next_token_id")),
            "the PositionManager's token counter moved backwards"
        );

        // Two launches created in the same block, so they share one schedule. Both are bid on, both
        // graduate at the auction level, and both bidders claim — which is where the pre-seed
        // inventory comes from.
        (ForkLaunch memory subjectLaunch,,) = _launchAsWallet(_worstCaseParams(1_000e18));
        (ForkLaunch memory otherLaunch,,) = _launchAsWallet(_worstCaseParams(1_000e18));

        vm.roll(subjectLaunch.auction.startBlock());
        uint256 subjectBidId = _bid(subjectLaunch, 4_000e18, 10);
        uint256 otherBidId = _bid(otherLaunch, 4_000e18, 10);

        vm.roll(uint256(subjectLaunch.auction.claimBlock()));
        uint256 ownSeed = _claimAndSeedPositionManager(subjectLaunch, subjectBidId);
        uint256 crossSeed = _claimAndSeedPositionManager(otherLaunch, otherBidId);
        assertGt(ownSeed, 0, "the bidder claimed nothing to pre-seed this pool's own SUBJECT with");
        assertGt(crossSeed, 0, "the bidder claimed nothing to pre-seed another launch's SUBJECT with");

        // Third-party REGENT at the shared PositionManager, sent by an ordinary holder.
        address stranger = makeAddr("fork-position-manager-stranger");
        deal(BaseBindings.REGENT, stranger, 1_000e18);
        vm.prank(stranger);
        _mustCall(
            BaseBindings.REGENT,
            abi.encodeWithSignature("transfer(address,uint256)", BaseBindings.POSITION_MANAGER, uint256(1_000e18))
        );

        uint256 seededRegent = _balanceOf(BaseBindings.REGENT, BaseBindings.POSITION_MANAGER);
        uint256 seededSubject = _balanceOf(address(subjectLaunch.subject), BaseBindings.POSITION_MANAGER);
        uint256 seededCross = _balanceOf(address(otherLaunch.subject), BaseBindings.POSITION_MANAGER);
        assertGt(seededRegent, 0, "the PositionManager holds no REGENT inventory to dispose of");
        assertGt(seededSubject, 0, "the PositionManager holds none of this launch's SUBJECT to dispose of");

        uint256 treasuryRegentBefore = _balanceOf(BaseBindings.REGENT, treasury);
        uint256 escrowSubjectBefore = _balanceOf(address(subjectLaunch.subject), address(subjectLaunch.escrow));
        uint256 auctionSubjectBefore = _balanceOf(address(subjectLaunch.subject), address(subjectLaunch.auction));
        uint256 auctionRegentBefore = _balanceOf(BaseBindings.REGENT, address(subjectLaunch.auction));

        vm.roll(uint256(subjectLaunch.auction.endBlock()) + strategy.MIGRATION_DELAY_BLOCKS());
        strategy.migrate(address(subjectLaunch.auction));
        RegentLBPStrategy.Distribution memory d = strategy.distribution(address(subjectLaunch.auction));

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
        (uint160 sqrtPriceX96,,,) = IPoolManager(BaseBindings.POOL_MANAGER).getSlot0(d.poolId);
        assertEq(sqrtPriceX96, d.finalSqrtPriceX96, "the pool did not open at the recorded final price");

        // The exact-funding disposition: both pool currencies preserved to the unit, on the real
        // deployed PositionManager.
        assertEq(
            _balanceOf(BaseBindings.REGENT, BaseBindings.POSITION_MANAGER),
            seededRegent,
            "graduation settled REGENT this launch never funded"
        );
        assertEq(
            _balanceOf(address(subjectLaunch.subject), BaseBindings.POSITION_MANAGER),
            seededSubject,
            "graduation settled SUBJECT this launch never funded"
        );

        // And nothing foreign reached this launch's two value destinations: the treasury received
        // exactly its own unused raise, the escrow exactly its own unused reserve.
        uint256 swept = auctionRegentBefore - _balanceOf(BaseBindings.REGENT, address(subjectLaunch.auction));
        assertEq(
            _balanceOf(BaseBindings.REGENT, treasury) - treasuryRegentBefore,
            swept - d.lpRegentUsed,
            "the seeded REGENT reached this launch's treasury"
        );
        uint256 escrowFromStrategy =
            (_balanceOf(address(subjectLaunch.subject), address(subjectLaunch.escrow)) - escrowSubjectBefore)
                - (auctionSubjectBefore - _balanceOf(address(subjectLaunch.subject), address(subjectLaunch.auction)));
        assertEq(
            escrowFromStrategy,
            strategy.RESERVE_ALLOCATION() - d.lpSubjectUsed,
            "the seeded SUBJECT reached this launch's escrow"
        );

        // Cross-launch inventory is not a currency of this pool and is untouched, to the unit.
        assertEq(
            _balanceOf(address(otherLaunch.subject), BaseBindings.POSITION_MANAGER),
            seededCross,
            "another launch's SUBJECT at the shared PositionManager was consumed"
        );

        _emitVerdict("DEP-046", header, "exact-funding-preserves-foreign-position-manager-balances");
    }

    // -------------------------------------------------------------------------
    // DEP-048 — the real CCA and the real Permit2
    // -------------------------------------------------------------------------

    function test_DEP_048_ForkPinnedCcaAndPermit2BehaveAsAssumed() public {
        _checkCcaAndPermit2(Header.Pinned);
    }

    /// @dev The bidder path exactly as the product will drive it, and every required path is driven
    ///      rather than left to whichever outcome one auction happened to reach.
    ///
    ///      Three launches created in the same block carry three bidders through three different
    ///      endings: a full exit before the auction closes, an applicable partial exit, and a
    ///      graduated claim. Every one of them starts from the same real allowance sequence — an
    ///      ERC20 approval to the canonical Permit2, a Permit2 `approve` allowance to the auction
    ///      with a bounded expiration, and the five-argument `submitBid` — and every one of them is
    ///      signed by the bidder's own account through `prank`. No backend holds custody at any
    ///      point, and the Permit2 allowance is proved consumed and cleaned up rather than assumed.
    function _checkCcaAndPermit2(Header header) private {
        _selectFork(header);
        _deployOnFork();

        // The refunding launch's raise is far beyond anything one bid can meet, so it ends
        // ungraduated and its bidder is entitled to the whole amount back.
        (ForkLaunch memory refunding,,) = _launchAsWallet(_worstCaseParams(50_000_000e18));
        (ForkLaunch memory partialExit,,) = _launchAsWallet(_worstCaseParams(1e18));
        (ForkLaunch memory claiming,,) = _launchAsWallet(_worstCaseParams(1_000e18));

        vm.roll(refunding.auction.startBlock());

        // --- the allowance flow, proved exactly, on the launch that will refund in full --------
        uint128 amount = 2_000e18;
        uint48 expiration = uint48(block.timestamp + 1 days);
        uint256 priceQ96 = _priceAboveClearing(refunding, 1);
        deal(BaseBindings.REGENT, bidder, amount);

        vm.startPrank(bidder);
        _mustCall(BaseBindings.REGENT, abi.encodeWithSignature("approve(address,uint256)", PERMIT2, uint256(amount)));
        assertEq(_allowance(BaseBindings.REGENT, bidder, PERMIT2), amount, "the ERC20 approval to Permit2 is inexact");

        IAllowanceTransfer(PERMIT2)
            .approve(BaseBindings.REGENT, address(refunding.auction), uint160(amount), expiration);
        (uint160 allowed, uint48 recordedExpiration,) =
            IAllowanceTransfer(PERMIT2).allowance(bidder, BaseBindings.REGENT, address(refunding.auction));
        assertEq(allowed, amount, "Permit2 did not record the exact bidder allowance");
        assertEq(recordedExpiration, expiration, "Permit2 did not record the bounded expiration");

        uint256 refundBidId = refunding.auction.submitBid(priceQ96, amount, bidder, strategy.FLOOR_PRICE_Q96(), "");
        vm.stopPrank();

        assertEq(_balanceOf(BaseBindings.REGENT, bidder), 0, "the bid did not pull the exact amount through Permit2");
        assertEq(
            _balanceOf(BaseBindings.REGENT, address(refunding.auction)), amount, "the auction received an inexact bid"
        );
        (uint160 remaining,,) =
            IAllowanceTransfer(PERMIT2).allowance(bidder, BaseBindings.REGENT, address(refunding.auction));
        assertEq(remaining, 0, "Permit2 did not consume the exact allowance the bid used");
        assertEq(_allowance(BaseBindings.REGENT, bidder, PERMIT2), 0, "the bidder's ERC20 approval to Permit2 survived");

        // --- an applicable partial exit, inside the auction's own open window ------------------
        _exitPartiallyFilled(partialExit);

        // --- the bid that will graduate and be claimed -----------------------------------------
        uint256 claimBidId = _bid(claiming, 4_000e18, 10);

        // --- past the end: a full refund on the launch no single bid could carry ---------------
        vm.roll(uint256(claiming.auction.endBlock()) + strategy.MIGRATION_DELAY_BLOCKS());
        refunding.auction.checkpoint();
        assertFalse(refunding.auction.isGraduated(), "the unreachable raise graduated anyway");
        uint256 refundBefore = _balanceOf(BaseBindings.REGENT, bidder);
        vm.prank(bidder);
        refunding.auction.exitBid(refundBidId);
        assertEq(
            _balanceOf(BaseBindings.REGENT, bidder) - refundBefore, amount, "a failed bidder was not fully refunded"
        );

        // --- a graduated claim: exit first, exactly as the pinned CCA requires -----------------
        claiming.auction.checkpoint();
        assertTrue(claiming.auction.isGraduated(), "the bid-on launch did not graduate");
        assertGt(_exitAndClaim(claiming, claimBidId), 0, "a graduated bidder claimed nothing");

        _emitVerdict("DEP-048", header, "permit2-allowance-bid-full-refund-partial-exit-and-claim");
    }

    // -------------------------------------------------------------------------
    // DEP-049 — every terminal path end to end
    // -------------------------------------------------------------------------

    function test_DEP_049_ForkPinnedBothTerminalPathsExecuteEndToEnd() public {
        _checkBothTerminalPaths(Header.Pinned);
    }

    /// @dev Three terminal outcomes against the real dependencies: a graduation, a zero-bid
    ///      retirement, and a partially bid retirement that misses its raise. Each is then proved
    ///      terminal — a repeated call reverts and moves nothing — which is the exact-rollback half
    ///      of the claim.
    function _checkBothTerminalPaths(Header header) private {
        _selectFork(header);
        _deployOnFork();

        (ForkLaunch memory graduating,,) = _launchAsWallet(_worstCaseParams(1_000e18));
        (ForkLaunch memory unbid,,) = _launchAsWallet(_worstCaseParams(1_000e18));
        (ForkLaunch memory underfunded,,) = _launchAsWallet(_worstCaseParams(50_000_000e18));

        vm.roll(graduating.auction.startBlock());
        _bid(graduating, 4_000e18, 10);
        _bid(underfunded, 4_000e18, 10);
        vm.roll(uint256(graduating.auction.endBlock()) + strategy.MIGRATION_DELAY_BLOCKS());

        strategy.migrate(address(graduating.auction));
        RegentLBPStrategy.Distribution memory good = strategy.distribution(address(graduating.auction));
        assertEq(uint8(good.lifecycle), uint8(RegentLBPStrategy.Lifecycle.Graduated), "the launch did not graduate");
        assertTrue(good.splitter != address(0), "graduation created no splitter");
        assertTrue(good.receiver != address(0), "graduation created no canonical receiver");
        assertGt(graduating.escrow.vestingStart(), 0, "graduation never started vesting");

        _assertRetires(unbid, "zero-bid");
        _assertRetires(underfunded, "partially bid");

        // Terminal means terminal, on every one of the three.
        _assertTerminalAndUnchanged(graduating);
        _assertTerminalAndUnchanged(unbid);
        _assertTerminalAndUnchanged(underfunded);

        _emitVerdict("DEP-049", header, "graduated-zero-bid-and-partially-bid-all-terminal");
    }

    // -------------------------------------------------------------------------
    // helpers
    // -------------------------------------------------------------------------

    function _assertRetires(ForkLaunch memory launched, string memory what) private {
        strategy.migrate(address(launched.auction));
        RegentLBPStrategy.Distribution memory bad = strategy.distribution(address(launched.auction));
        assertEq(
            uint8(bad.lifecycle),
            uint8(RegentLBPStrategy.Lifecycle.Failed),
            string.concat("the ", what, " launch did not fail")
        );
        assertEq(
            launched.subject.balanceOf(BaseBindings.DEAD_ADDRESS),
            100_000_000_000e18,
            string.concat("the ", what, " launch did not retire exactly one hundred billion")
        );
        assertEq(bad.splitter, address(0), string.concat("the ", what, " launch created a splitter"));
    }

    /// @dev A terminal launch refuses every further finalization and moves nothing when it does.
    function _assertTerminalAndUnchanged(ForkLaunch memory launched) private {
        RegentLBPStrategy.Distribution memory before = strategy.distribution(address(launched.auction));
        uint256 escrowBefore = launched.subject.balanceOf(address(launched.escrow));
        uint256 deadBefore = launched.subject.balanceOf(BaseBindings.DEAD_ADDRESS);

        vm.expectRevert();
        strategy.migrate(address(launched.auction));

        RegentLBPStrategy.Distribution memory found = strategy.distribution(address(launched.auction));
        assertEq(uint8(found.lifecycle), uint8(before.lifecycle), "a terminal launch changed lifecycle");
        assertEq(found.splitter, before.splitter, "a terminal launch changed its splitter");
        assertEq(found.lpTokenId, before.lpTokenId, "a terminal launch changed its position");
        assertEq(
            launched.subject.balanceOf(address(launched.escrow)), escrowBefore, "a repeated call moved escrow SUBJECT"
        );
        assertEq(
            launched.subject.balanceOf(BaseBindings.DEAD_ADDRESS), deadBefore, "a repeated call retired more SUBJECT"
        );
    }

    /// @dev A bidder claims their filled tokens and sends part of them to the shared PositionManager,
    ///      which is the ordinary way third-party inventory arrives there.
    function _claimAndSeedPositionManager(ForkLaunch memory launched, uint256 bidId) private returns (uint256 seeded) {
        uint256 claimed = _exitAndClaim(launched, bidId);
        assertGt(claimed, 0, "a graduated bidder claimed nothing to seed the shared PositionManager with");

        seeded = claimed / 4;
        assertGt(seeded, 0, "the claim was too small to seed the shared PositionManager with");

        vm.prank(bidder);
        UERC20(address(launched.subject)).transfer(BaseBindings.POSITION_MANAGER, seeded);
    }

    /// @dev The applicable partial-exit shape, constructed rather than hoped for.
    ///
    ///      The pinned CCA admits `exitPartiallyFilledBid` only for a bid that was filled for a
    ///      while and then outbid: it needs the last checkpoint whose clearing price was strictly
    ///      below the bid's maximum, and the next checkpoint, whose clearing price is at or above
    ///      it. A submitted bid first checkpoints the state before adding its own demand, so the
    ///      outbid is visible only in the following block's checkpoint. Those two exact checkpoints
    ///      are supplied as hints rather than guessed.
    ///
    ///      A low bid is placed first, then a much larger one a few blocks later at a far higher
    ///      tick, which raises the clearing price past the low bid's maximum and both graduates the
    ///      auction and partially fills that first bid. If this shape ever stops being reachable
    ///      against the pinned CCA, this fails rather than quietly degrading to a full exit.
    function _exitPartiallyFilled(ForkLaunch memory launched) private {
        uint64 lowBlock = uint64(block.number);
        uint256 lowPriceQ96 = _priceAboveClearing(launched, 1);
        uint256 lowBidId = _bidAs(launched, outbidBidder, 500e18, 1);

        uint64 lastFullyFilledBlock = lowBlock + 64;
        vm.roll(lastFullyFilledBlock);
        _bid(launched, 20_000_000e18, 40);

        uint64 outbidBlock = lastFullyFilledBlock + 1;
        vm.roll(outbidBlock);
        launched.auction.checkpoint();
        assertTrue(launched.auction.isGraduated(), "the outbidding bid did not graduate the auction");
        assertGt(
            launched.auction.clearingPrice(), lowPriceQ96, "the clearing price never rose above the low bid's maximum"
        );

        uint256 before = _balanceOf(BaseBindings.REGENT, outbidBidder);
        vm.prank(outbidBidder);
        launched.auction.exitPartiallyFilledBid(lowBidId, lastFullyFilledBlock, outbidBlock);
        uint256 refunded = _balanceOf(BaseBindings.REGENT, outbidBidder) - before;
        assertGt(refunded, 0, "a partial exit refunded nothing");
        assertLt(refunded, 500e18, "a partial exit refunded the whole bid, so nothing was partially filled");
    }
}
