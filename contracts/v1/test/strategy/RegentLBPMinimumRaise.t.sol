// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {BaseBindings} from "../../src/bindings/BaseBindings.sol";
import {RegentLBPStrategy} from "../../src/strategy/RegentLBPStrategy.sol";
import {StrategyFixture} from "./StrategyFixture.sol";

/// @notice `STR-020`: governance authority over the raise floor, the inclusive floor at
///         initialization, and the terms an existing auction keeps across a change.
contract RegentLBPMinimumRaiseTest is StrategyFixture {
    function setUp() public {
        _deployC3();
    }

    function test_STR_020_MinimumIsGovernanceOnlyAndBounded() public {
        assertEq(strategy.minimumRegentRaised(), 10_000_000e18);
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(RegentLBPStrategy.NotGovernance.selector, outsider));
        strategy.setMinimumRegentRaised(1);

        vm.startPrank(BaseBindings.GOVERNANCE_AND_REGENT_SAFE);
        vm.expectRevert(abi.encodeWithSelector(RegentLBPStrategy.UnreachableRequiredRaise.selector, uint128(0)));
        strategy.setMinimumRegentRaised(0);
        uint128 excessive = strategy.MAX_REACHABLE_RAISE() + 1;
        vm.expectRevert(abi.encodeWithSelector(RegentLBPStrategy.UnreachableRequiredRaise.selector, excessive));
        strategy.setMinimumRegentRaised(excessive);
        vm.expectEmit(address(strategy));
        emit RegentLBPStrategy.MinimumRegentRaisedChanged(10_000_000e18, 5_000_000e18);
        strategy.setMinimumRegentRaised(5_000_000e18);
        vm.stopPrank();
        assertEq(strategy.minimumRegentRaised(), 5_000_000e18);
    }

    function test_STR_020_FloorIsInclusiveAndExistingAuctionsKeepTheirTerms() public {
        uint128 minimum = 10_000_000e18;
        // Stage custody before expectRevert so the next external call is initialization.
        _etchToken(SUBJECT_LOW).mint(address(factory), TOTAL_SUPPLY);
        address escrow = factory.fundedEscrow(SUBJECT_LOW, treasury);
        vm.expectRevert(
            abi.encodeWithSelector(RegentLBPStrategy.RequiredRaiseBelowMinimum.selector, minimum - 1, minimum)
        );
        factory.initialize(SUBJECT_LOW, escrow, 1, minimum - 1);
        address auction = factory.initialize(SUBJECT_LOW, escrow, 1, minimum);

        vm.prank(BaseBindings.GOVERNANCE_AND_REGENT_SAFE);
        strategy.setMinimumRegentRaised(20_000_000e18);
        assertEq(strategy.distribution(auction).requiredRegentRaised, minimum);
        assertEq(strategy.minimumRegentRaised(), 20_000_000e18);
    }
}
