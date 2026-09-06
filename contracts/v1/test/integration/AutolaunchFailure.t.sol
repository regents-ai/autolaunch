// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {BaseBindings} from "../../src/bindings/BaseBindings.sol";
import {ConditionalVestingEscrowV1} from "../../src/escrow/ConditionalVestingEscrowV1.sol";
import {RegentsAutolaunchFactoryV1} from "../../src/factory/RegentsAutolaunchFactoryV1.sol";
import {RegentLBPStrategy} from "../../src/strategy/RegentLBPStrategy.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {AutolaunchFixture} from "./AutolaunchFixture.sol";
import {Vm} from "forge-std/Vm.sol";

/// @notice `C4-I6`: an economically failed launch retires its whole supply, preserves every bidder's
///         refund, and commits none of the graduated infrastructure — once, and only once.
contract AutolaunchFailureTest is AutolaunchFixture {
    using StateLibrary for IPoolManager;

    function setUp() public {
        _deployAutolaunch();
    }

    /// @notice `FAIL-001`: an auction that raises less than its required raise fails.
    function test_FAIL_001_UnmetRaiseResolvesAsFailed() public {
        RegentsAutolaunchFactoryV1.LaunchParams memory params = _params();
        params.requiredRegentRaised = 10_000e18;
        Launched memory launched = _launchAs(launcher, params);

        _rollToStart(launched);
        _bid(launched, bidder, 9_999e18, _bidPrice(10));
        _rollToMigration(launched);

        strategy.migrate(address(launched.auction));

        assertFalse(launched.auction.isGraduated(), "an under-raised auction graduated");
        assertEq(
            uint8(_distribution(launched).lifecycle),
            uint8(RegentLBPStrategy.Lifecycle.Failed),
            "the under-raised launch is not failed"
        );
        assertEq(
            uint8(launched.escrow.lifecycle()),
            uint8(ConditionalVestingEscrowV1.Lifecycle.Failed),
            "the escrow is not failed"
        );
    }

    /// @notice `FAIL-002`: an auction nobody bid on fails.
    function test_FAIL_002_ZeroBidsResolveAsFailed() public {
        Launched memory launched = _defaultLaunch();
        _rollToMigration(launched);

        strategy.migrate(address(launched.auction));

        assertEq(uint256(launched.auction.currencyRaised()), 0, "an unbid auction raised REGENT");
        assertEq(
            uint8(_distribution(launched).lifecycle),
            uint8(RegentLBPStrategy.Lifecycle.Failed),
            "the unbid launch is not failed"
        );
        assertEq(
            launched.subject.balanceOf(BaseBindings.DEAD_ADDRESS), TOTAL_SUPPLY, "the unbid launch was not retired"
        );
    }

    /// @notice `FAIL-003`: several genuine bids that together fall short still fail.
    function test_FAIL_003_PartialBidsBelowTheRaiseResolveAsFailed() public {
        RegentsAutolaunchFactoryV1.LaunchParams memory params = _params();
        params.requiredRegentRaised = 30_000e18;
        Launched memory launched = _launchAs(launcher, params);

        _rollToStart(launched);
        _bid(launched, bidder, 9_000e18, _bidPrice(10));
        _bid(launched, outsider, 9_000e18, _bidPrice(11));
        _bid(launched, launcher, 9_000e18, _bidPrice(12));
        _rollToMigration(launched);

        strategy.migrate(address(launched.auction));

        assertEq(uint256(launched.auction.currencyRaised()), 27_000e18, "the partial raise is not the sum of the bids");
        assertEq(
            uint8(_distribution(launched).lifecycle),
            uint8(RegentLBPStrategy.Lifecycle.Failed),
            "a partially filled auction below its raise did not fail"
        );
    }

    /// @notice `FAIL-004`: retirement proves it holds the whole supply before it retires anything.
    /// @dev The escrow announces the retirement only after its own exact-inventory check passes, so
    ///      the announcement appearing before the transfer in the real log stream is the proof that
    ///      the inventory was proved first.
    function test_FAIL_004_RetirementProvesFullInventoryFirst() public {
        Launched memory launched = _defaultLaunch();
        _rollToMigration(launched);

        vm.recordLogs();
        strategy.migrate(address(launched.auction));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 announced = type(uint256).max;
        uint256 retired = type(uint256).max;
        bytes32 failedTopic = keccak256("LaunchFailed(address,uint256)");
        bytes32 transferTopic = keccak256("Transfer(address,address,uint256)");
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(launched.escrow) && logs[i].topics[0] == failedTopic) {
                assertEq(abi.decode(logs[i].data, (uint256)), TOTAL_SUPPLY, "the retirement is not the whole supply");
                if (announced == type(uint256).max) announced = i;
            }
            if (
                logs[i].emitter == address(launched.subject) && logs[i].topics[0] == transferTopic
                    && address(uint160(uint256(logs[i].topics[1]))) == address(launched.escrow)
                    && address(uint160(uint256(logs[i].topics[2]))) == BaseBindings.DEAD_ADDRESS
            ) {
                if (retired == type(uint256).max) retired = i;
            }
        }
        assertLt(announced, type(uint256).max, "the escrow never announced the retirement");
        assertLt(retired, type(uint256).max, "nothing was retired");
        assertLt(announced, retired, "the retirement happened before the inventory was proved");

        assertEq(launched.subject.balanceOf(address(launched.escrow)), 0, "the escrow kept retired SUBJECT");
        assertEq(launched.subject.balanceOf(address(strategy)), 0, "the strategy kept the reserve");
        assertEq(launched.subject.balanceOf(address(launched.auction)), 0, "the auction kept its inventory");
    }

    /// @notice `FAIL-005`: the dead address gains exactly the whole retired supply and nothing else
    ///         holds any of it.
    function test_FAIL_005_DeadAddressDeltaEqualsTheRetiredSupply() public {
        Launched memory launched = _defaultLaunch();
        uint256 deadBefore = launched.subject.balanceOf(BaseBindings.DEAD_ADDRESS);
        _rollToMigration(launched);

        strategy.migrate(address(launched.auction));

        assertEq(
            launched.subject.balanceOf(BaseBindings.DEAD_ADDRESS) - deadBefore,
            TOTAL_SUPPLY,
            "the dead-address delta is not the whole supply"
        );
        assertEq(launched.subject.totalSupply(), TOTAL_SUPPLY, "retirement changed the supply");
        assertEq(launched.subject.balanceOf(address(factory)), 0, "the factory holds retired SUBJECT");
        assertEq(launched.subject.balanceOf(treasury), 0, "the treasury holds retired SUBJECT");
    }

    /// @notice `FAIL-006`: retirement never touches bidder REGENT — every bidder can still exit and
    ///         be made whole from the CCA afterwards.
    function test_FAIL_006_BidderRefundsSurviveRetirement() public {
        RegentsAutolaunchFactoryV1.LaunchParams memory params = _params();
        params.requiredRegentRaised = 100_000e18;
        Launched memory launched = _launchAs(launcher, params);

        _rollToStart(launched);
        uint256 firstBid = _bid(launched, bidder, 4_000e18, _bidPrice(10));
        uint256 secondBid = _bid(launched, outsider, 6_000e18, _bidPrice(11));
        _rollToMigration(launched);

        uint256 auctionRegent = regent.balanceOf(address(launched.auction));
        assertEq(auctionRegent, 10_000e18, "the auction is not holding both bids");

        strategy.migrate(address(launched.auction));

        assertEq(
            regent.balanceOf(address(launched.auction)), auctionRegent, "retirement moved bidder REGENT out of the CCA"
        );

        vm.prank(bidder);
        launched.auction.exitBid(firstBid);
        vm.prank(outsider);
        launched.auction.exitBid(secondBid);

        assertEq(regent.balanceOf(bidder), 4_000e18, "the first bidder was not fully refunded");
        assertEq(regent.balanceOf(outsider), 6_000e18, "the second bidder was not fully refunded");
        assertEq(regent.balanceOf(address(launched.auction)), 0, "the auction kept bidder REGENT");
        assertEq(launched.subject.balanceOf(bidder), 0, "a failed auction delivered SUBJECT");
    }

    /// @notice `FAIL-007`: failure creates no pool, splitter, receiver, hook registration or vesting.
    function test_FAIL_007_FailureCommitsNoDownstreamInfrastructure() public {
        Launched memory launched = _defaultLaunch();
        _rollToMigration(launched);

        uint64 strategyNonceBefore = vm.getNonce(address(strategy));
        uint256 nextTokenIdBefore = positionManager.nextTokenId();

        strategy.migrate(address(launched.auction));

        RegentLBPStrategy.Distribution memory d = _distribution(launched);
        assertEq(d.splitter, address(0), "failure deployed a splitter");
        assertEq(d.receiver, address(0), "failure deployed a receiver");
        assertEq(d.lpTokenId, 0, "failure minted a position");
        assertEq(d.finalSqrtPriceX96, 0, "failure recorded a price");
        assertEq(vm.getNonce(address(strategy)), strategyNonceBefore, "failure created a clone");
        assertEq(positionManager.nextTokenId(), nextTokenIdBefore, "failure minted an NFT");
        assertEq(hook.splitterOf(_poolId(launched)), address(0), "failure registered a pool");

        (uint160 sqrtPrice,,,) = IPoolManager(BaseBindings.POOL_MANAGER).getSlot0(_poolId(launched));
        assertEq(sqrtPrice, 0, "failure initialized a pool");

        assertEq(launched.escrow.vestingStart(), 0, "failure started vesting");
        assertFalse(launched.escrow.graduatedSweepDone(), "failure ran the graduated sweep");
        vm.expectRevert(
            abi.encodeWithSelector(
                ConditionalVestingEscrowV1.NotGraduated.selector, ConditionalVestingEscrowV1.Lifecycle.Failed
            )
        );
        launched.escrow.release();

        vm.expectRevert(
            abi.encodeWithSelector(RegentsAutolaunchFactoryV1.LaunchNotGraduated.selector, launched.launchId)
        );
        factory.createPaymentReceiver(launched.launchId, outsider, 0);
    }

    /// @notice `FAIL-008`: a failed launch is terminal. A second attempt reverts and moves nothing.
    function test_FAIL_008_RepeatedFailureResolutionMovesNoValue() public {
        Launched memory launched = _defaultLaunch();
        _rollToMigration(launched);
        strategy.migrate(address(launched.auction));

        Ledger memory before = _ledger(launched);

        vm.expectRevert(
            abi.encodeWithSelector(RegentLBPStrategy.LaunchNotActive.selector, RegentLBPStrategy.Lifecycle.Failed)
        );
        strategy.migrate(address(launched.auction));

        vm.expectRevert(
            abi.encodeWithSelector(
                ConditionalVestingEscrowV1.NotPending.selector, ConditionalVestingEscrowV1.Lifecycle.Failed
            )
        );
        vm.prank(address(strategy));
        launched.escrow.resolveFailure(address(launched.auction));

        vm.expectRevert(abi.encodeWithSelector(ConditionalVestingEscrowV1.NotStrategy.selector, outsider));
        vm.prank(outsider);
        launched.escrow.resolveFailure(address(launched.auction));

        _assertLedgerUnchanged(before, _ledger(launched), "repeated failure resolution");

        // A late-arriving unit is retirable and still only ever reaches the dead address.
        vm.prank(BaseBindings.DEAD_ADDRESS);
        launched.subject.transfer(address(launched.escrow), 1);
        launched.escrow.retireLateFailedSubject();
        assertEq(
            launched.subject.balanceOf(BaseBindings.DEAD_ADDRESS), TOTAL_SUPPLY, "the late unit did not return to dead"
        );
        assertEq(launched.subject.balanceOf(address(launched.escrow)), 0, "the escrow kept the late unit");
    }
}
