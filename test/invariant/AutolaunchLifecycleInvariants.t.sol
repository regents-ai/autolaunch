// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {BaseBindings} from "../../src/bindings/BaseBindings.sol";
import {ConditionalVestingEscrowV1} from "../../src/escrow/ConditionalVestingEscrowV1.sol";
import {RegentsAutolaunchFactoryV1} from "../../src/factory/RegentsAutolaunchFactoryV1.sol";
import {RegentLBPStrategy} from "../../src/strategy/RegentLBPStrategy.sol";
import {UERC20} from "uerc20-factory/tokens/UERC20.sol";
import {AutolaunchFixture} from "../integration/AutolaunchFixture.sol";
import {LifecycleHandler} from "./handlers/LifecycleHandler.sol";

/// @notice `INV-001`, `INV-006`, `INV-007`, `INV-009`, and `INV-010`: five separate accounting
///         models over three simultaneous launches sharing one factory, one strategy, and one hook.
/// @dev Each model answers a different question and none of them is a restatement of another.
///
///      `INV-001` is *supply*: every unit of a launch's SUBJECT is somewhere reachable, always.
///      `INV-006` is *one launch's reserve*: this launch's 5% against this launch's own destinations.
///      `INV-007` is *lifecycle*: exactly one state, terminal once reached, escrow agreeing.
///      `INV-009` is *isolation across launches*: no launch's reserve is credited to, consumed by, or
///      reachable from another, over reachable interleavings rather than in one operation.
///      `INV-010` is *attribution*: the shared contracts hold no balance and no allowance beyond
///      what a specified flow needs, and an explained external gift is never protocol inventory.
///
///      The timeline the handler produces is monotone and every call goes through a real production
///      entry point, so no state here is one a real chain could not reach.
contract AutolaunchLifecycleInvariantsTest is AutolaunchFixture {
    uint256 internal constant LAUNCHES = 3;

    LifecycleHandler internal handler;
    Launched[LAUNCHES] internal launches;

    function setUp() public {
        _deployAutolaunch();

        // Three launches created in the same block, on both sides of REGENT, at required raises
        // spanning the admitted interval: one that a single small bid clears, one that needs real
        // demand, and one no reachable bid sequence in this portfolio can meet.
        uint128[LAUNCHES] memory raises = [uint128(1), 1_000e18, 50_000_000e18];
        bool[LAUNCHES] memory below = [true, false, true];

        address[LAUNCHES] memory auctions;
        address[LAUNCHES] memory subjects;
        address[LAUNCHES] memory escrows;
        for (uint256 i; i < LAUNCHES; ++i) {
            launches[i] = _launchSorted(below[i], _paramsWithRaise(raises[i]));
            auctions[i] = address(launches[i].auction);
            subjects[i] = address(launches[i].subject);
            escrows[i] = address(launches[i].escrow);
        }

        handler = new LifecycleHandler(
            factory, strategy, address(hook), regent, usdc, bidder, treasury, auctions, subjects, escrows
        );

        targetContract(address(handler));
    }

    // -------------------------------------------------------------------------
    // INV-001 — supply
    // -------------------------------------------------------------------------

    /// @notice `INV-001`: each launch's SUBJECT supply is exactly one hundred billion and every unit
    ///         of it sits in one of the reachable custody or terminal destinations.
    function invariant_INV_001_SubjectSupplyIsConserved() public view {
        for (uint256 i; i < LAUNCHES; ++i) {
            UERC20 subject = launches[i].subject;
            assertEq(subject.totalSupply(), TOTAL_SUPPLY, "a launch's SUBJECT supply changed");

            RegentLBPStrategy.Distribution memory d = strategy.distribution(address(launches[i].auction));
            uint256 accounted = subject.balanceOf(address(launches[i].escrow))
                + subject.balanceOf(address(launches[i].auction)) + subject.balanceOf(address(strategy))
                + subject.balanceOf(address(factory)) + subject.balanceOf(address(hook))
                + subject.balanceOf(BaseBindings.DEAD_ADDRESS) + subject.balanceOf(treasury)
                + subject.balanceOf(BaseBindings.POSITION_MANAGER) + subject.balanceOf(BaseBindings.POOL_MANAGER)
                + subject.balanceOf(bidder) + subject.balanceOf(address(handler));
            if (d.splitter != address(0)) accounted += subject.balanceOf(d.splitter);
            if (d.receiver != address(0)) accounted += subject.balanceOf(d.receiver);

            assertEq(accounted, TOTAL_SUPPLY, "a launch's SUBJECT is not all in a reachable destination");
        }
    }

    // -------------------------------------------------------------------------
    // INV-006 — one launch's reserve
    // -------------------------------------------------------------------------

    /// @notice `INV-006`: while a launch is active the strategy custodies exactly its 5% reserve,
    ///         and after a terminal outcome the reserve has been consumed only by that launch's own
    ///         specified destination, with nothing stranded and nothing created.
    function invariant_INV_006_IsolatedReserveIsConserved() public view {
        for (uint256 i; i < LAUNCHES; ++i) {
            UERC20 subject = launches[i].subject;
            RegentLBPStrategy.Distribution memory d = strategy.distribution(address(launches[i].auction));

            assertEq(uint256(d.reserve), RESERVE_ALLOCATION, "the recorded reserve is not the fixed 5%");

            // Whatever the strategy holds of this SUBJECT, minus explained gifts, is the reserve.
            uint256 attributable = subject.balanceOf(address(strategy)) - handler.strategySubjectGifts(i);

            if (d.lifecycle == RegentLBPStrategy.Lifecycle.Active) {
                assertEq(attributable, RESERVE_ALLOCATION, "an active launch's reserve is not in custody");
            } else if (d.lifecycle == RegentLBPStrategy.Lifecycle.Graduated) {
                assertEq(attributable, 0, "a graduated launch left reserve stranded at the strategy");
                assertGt(uint256(d.lpSubjectUsed), 0, "graduation consumed none of the reserve");
                assertLe(uint256(d.lpSubjectUsed), RESERVE_ALLOCATION, "graduation consumed more than the reserve");
            } else {
                assertEq(attributable, 0, "a failed launch left reserve stranded at the strategy");
                assertEq(
                    subject.balanceOf(BaseBindings.DEAD_ADDRESS),
                    TOTAL_SUPPLY,
                    "a failed launch did not retire its whole supply, reserve included"
                );
            }
        }
    }

    // -------------------------------------------------------------------------
    // INV-007 — lifecycle
    // -------------------------------------------------------------------------

    /// @notice `INV-007`: every launch occupies exactly one lifecycle state, graduation and failure
    ///         are mutually exclusive and terminal, and the escrow always agrees with the strategy.
    function invariant_INV_007_LifecycleStatesAreExclusiveAndTerminal() public view {
        for (uint256 i; i < LAUNCHES; ++i) {
            RegentLBPStrategy.Distribution memory d = strategy.distribution(address(launches[i].auction));
            ConditionalVestingEscrowV1.Lifecycle escrowState = launches[i].escrow.lifecycle();

            assertTrue(d.lifecycle != RegentLBPStrategy.Lifecycle.None, "a created launch fell back to None");

            uint8 firstTerminal = handler.firstTerminalLifecycle(i);
            if (firstTerminal != 0) {
                assertEq(uint8(d.lifecycle), firstTerminal, "a terminal launch changed state afterwards");
            }

            if (d.lifecycle == RegentLBPStrategy.Lifecycle.Active) {
                assertEq(
                    uint8(escrowState),
                    uint8(ConditionalVestingEscrowV1.Lifecycle.Pending),
                    "an active launch's escrow is not pending"
                );
                assertEq(d.splitter, address(0), "an active launch has a splitter");
                assertEq(d.receiver, address(0), "an active launch has a receiver");
                assertEq(hook.splitterOf(_poolId(launches[i])), address(0), "an active launch registered a pool");
            } else if (d.lifecycle == RegentLBPStrategy.Lifecycle.Graduated) {
                assertEq(
                    uint8(escrowState),
                    uint8(ConditionalVestingEscrowV1.Lifecycle.Graduated),
                    "a graduated launch's escrow disagrees"
                );
                assertTrue(d.splitter != address(0), "a graduated launch has no splitter");
                assertTrue(d.receiver != address(0), "a graduated launch has no receiver");
                assertEq(hook.splitterOf(_poolId(launches[i])), d.splitter, "the hook registered a different splitter");
                assertGt(launches[i].escrow.vestingStart(), 0, "a graduated launch never started vesting");
            } else {
                assertEq(
                    uint8(escrowState),
                    uint8(ConditionalVestingEscrowV1.Lifecycle.Failed),
                    "a failed launch's escrow disagrees"
                );
                assertEq(d.splitter, address(0), "a failed launch created a splitter");
                assertEq(d.receiver, address(0), "a failed launch created a receiver");
                assertEq(hook.splitterOf(_poolId(launches[i])), address(0), "a failed launch registered a pool");
                assertEq(launches[i].escrow.vestingStart(), 0, "a failed launch started vesting");
            }
        }
    }

    // -------------------------------------------------------------------------
    // INV-009 — isolation across launches
    // -------------------------------------------------------------------------

    /// @notice `INV-009`: over reachable interleavings, no launch's reserve is ever credited to,
    ///         consumed by, or reachable from another launch.
    /// @dev A different model from `INV-006`. That one conserves one launch against its own
    ///      destinations; this one is about the boundary *between* launches: one SUBJECT maps to one
    ///      auction forever, each SUBJECT's dead-address balance is nonzero only for its own
    ///      failure, and no launch's SUBJECT ever appears in another launch's escrow or auction.
    function invariant_INV_009_ReservesAreNeverUsedAcrossLaunches() public view {
        for (uint256 i; i < LAUNCHES; ++i) {
            UERC20 subject = launches[i].subject;

            assertEq(
                strategy.auctionOfSubject(address(subject)),
                address(launches[i].auction),
                "a SUBJECT no longer maps to its own auction"
            );

            RegentLBPStrategy.Distribution memory d = strategy.distribution(address(launches[i].auction));
            if (d.lifecycle != RegentLBPStrategy.Lifecycle.Failed) {
                assertEq(subject.balanceOf(BaseBindings.DEAD_ADDRESS), 0, "SUBJECT was retired without a failure");
            }

            for (uint256 j; j < LAUNCHES; ++j) {
                if (i == j) continue;
                assertEq(
                    subject.balanceOf(address(launches[j].escrow)),
                    0,
                    "one launch's SUBJECT reached another launch's escrow"
                );
                assertEq(
                    subject.balanceOf(address(launches[j].auction)),
                    0,
                    "one launch's SUBJECT reached another launch's auction"
                );
                assertTrue(address(launches[i].escrow) != address(launches[j].escrow), "two launches share one escrow");
                assertTrue(
                    address(launches[i].auction) != address(launches[j].auction), "two launches share one auction"
                );
            }
        }
    }

    // -------------------------------------------------------------------------
    // INV-010 — attribution
    // -------------------------------------------------------------------------

    /// @notice `INV-010`: the factory, the strategy, and the hook hold no attributable balance and
    ///         no standing allowance beyond a specified in-flight flow, and an explained external
    ///         gift is never counted as protocol inventory nor able to block another flow.
    function invariant_INV_010_NoUnexplainedFactoryStrategyOrHookBalances() public view {
        // Currency: neither the factory nor the strategy nor the hook keeps REGENT or USDC between
        // transactions, so whatever they hold is exactly what strangers gifted them.
        assertEq(regent.balanceOf(address(factory)), handler.factoryRegentGifts(), "unexplained factory REGENT");
        assertEq(regent.balanceOf(address(strategy)), handler.strategyRegentGifts(), "unexplained strategy REGENT");
        assertEq(regent.balanceOf(address(hook)), handler.hookRegentGifts(), "unexplained hook REGENT");
        assertEq(usdc.balanceOf(address(factory)), handler.factoryUsdcGifts(), "unexplained factory USDC");
        assertEq(usdc.balanceOf(address(strategy)), handler.strategyUsdcGifts(), "unexplained strategy USDC");
        assertEq(usdc.balanceOf(address(hook)), handler.hookUsdcGifts(), "unexplained hook USDC");

        for (uint256 i; i < LAUNCHES; ++i) {
            UERC20 subject = launches[i].subject;
            RegentLBPStrategy.Distribution memory d = strategy.distribution(address(launches[i].auction));

            // SUBJECT: the factory and the hook are never destinations, so they hold only gifts.
            assertEq(subject.balanceOf(address(factory)), handler.factorySubjectGifts(i), "unexplained factory SUBJECT");
            assertEq(subject.balanceOf(address(hook)), handler.hookSubjectGifts(i), "unexplained hook SUBJECT");

            // The strategy holds the reserve while active, and gifts it has not absorbed. Nothing else.
            uint256 expected = d.lifecycle == RegentLBPStrategy.Lifecycle.Active ? RESERVE_ALLOCATION : 0;
            assertEq(
                subject.balanceOf(address(strategy)),
                expected + handler.strategySubjectGifts(i),
                "the strategy holds SUBJECT no specified flow accounts for"
            );

            // No standing allowance survives a transaction anywhere in the shared graph.
            assertEq(subject.allowance(address(factory), address(strategy)), 0, "a factory allowance survived");
            assertEq(
                subject.allowance(address(factory), address(launches[i].escrow)), 0, "an escrow allowance survived"
            );
            assertEq(
                subject.allowance(address(strategy), BaseBindings.POSITION_MANAGER),
                0,
                "a PositionManager allowance survived"
            );
            if (d.splitter != address(0)) {
                assertEq(regent.allowance(address(hook), d.splitter), 0, "a hook splitter allowance survived");
            }
        }

        // A gift never blocks a flow: launches that have not reached a terminal state can still be
        // migrated, and those that have are still exactly where their outcome put them.
        assertEq(factory.launchesPaused(), false, "the shared factory became paused");
    }

    // -------------------------------------------------------------------------
    // helpers
    // -------------------------------------------------------------------------

    function _paramsWithRaise(uint128 raise) private view returns (RegentsAutolaunchFactoryV1.LaunchParams memory) {
        RegentsAutolaunchFactoryV1.LaunchParams memory params = _params();
        params.requiredRegentRaised = raise;
        return params;
    }
}
