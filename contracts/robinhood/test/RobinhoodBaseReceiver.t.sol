// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "autolaunch-stocks-test/mocks/MockERC20.sol";
import {MockLiveStaking} from "autolaunch-stocks-test/mocks/MockLiveStaking.sol";
import {RobinhoodBaseRevenueReceiverV1} from "../src/RobinhoodBaseRevenueReceiverV1.sol";

/// @notice The Base receiver: Safe-attested attribution, deposits of the actual delivered amount,
///         retries independent per batch, and a surplus sweep that never touches attested amounts.
contract RobinhoodBaseReceiverTest is Test {
    RobinhoodBaseRevenueReceiverV1 internal receiver;
    MockERC20 internal usdc;
    MockLiveStaking internal staking;

    address internal baseSafe = makeAddr("base-safe");
    address internal outsider = makeAddr("outsider");

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        staking = new MockLiveStaking(address(usdc), address(usdc));
        receiver = new RobinhoodBaseRevenueReceiverV1(address(usdc), address(staking), baseSafe);
    }

    function test_attestation_is_safe_only_and_bounded_by_what_arrived() public {
        usdc.mint(address(receiver), 99e6);
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(RobinhoodBaseRevenueReceiverV1.NotSafe.selector, outsider));
        receiver.attestDelivery(1, 99e6);
        vm.startPrank(baseSafe);
        vm.expectRevert(
            abi.encodeWithSelector(RobinhoodBaseRevenueReceiverV1.AttestationExceedsHeld.selector, 99e6, 100e6)
        );
        receiver.attestDelivery(1, 100e6);
        receiver.attestDelivery(1, 99e6);
        vm.stopPrank();
        assertEq(receiver.pendingOf(1), 99e6);
        assertEq(receiver.totalPending(), 99e6);
    }

    function test_deposit_uses_the_delivered_amount_and_retries_after_a_failure() public {
        usdc.mint(address(receiver), 99e6);
        vm.prank(baseSafe);
        receiver.attestDelivery(7, 99e6);

        staking.setPaused(true);
        vm.expectRevert(MockLiveStaking.Paused.selector);
        receiver.depositRevenue(7);
        assertEq(receiver.pendingOf(7), 99e6);

        staking.setPaused(false);
        vm.prank(outsider);
        receiver.depositRevenue(7);
        assertEq(staking.lastAmount(), 99e6);
        assertEq(staking.lastSourceRef(), bytes32(uint256(7)));
        assertEq(staking.lastSourceTag(), receiver.SOURCE_TAG());
        assertEq(receiver.pendingOf(7), 0);
        assertEq(receiver.totalDeposited(), 99e6);
        assertEq(usdc.allowance(address(receiver), address(staking)), 0);

        vm.expectRevert(abi.encodeWithSelector(RobinhoodBaseRevenueReceiverV1.NothingPending.selector, 7));
        receiver.depositRevenue(7);
    }

    function test_batches_deposit_independently_and_surplus_excludes_attested_amounts() public {
        usdc.mint(address(receiver), 150e6);
        vm.startPrank(baseSafe);
        receiver.attestDelivery(1, 40e6);
        receiver.attestDelivery(2, 60e6);
        vm.stopPrank();

        receiver.depositRevenue(2);
        assertEq(receiver.pendingOf(1), 40e6);
        assertEq(receiver.totalPending(), 40e6);

        receiver.depositSurplus();
        assertEq(usdc.balanceOf(address(receiver)), 40e6);
        assertEq(receiver.totalDeposited(), 110e6);

        vm.expectRevert(RobinhoodBaseRevenueReceiverV1.ZeroAmount.selector);
        receiver.depositSurplus();
        receiver.depositRevenue(1);
        assertEq(receiver.totalDeposited(), 150e6);
    }

    function test_a_short_or_misreported_deposit_reverts() public {
        usdc.mint(address(receiver), 10e6);
        vm.prank(baseSafe);
        receiver.attestDelivery(1, 10e6);
        staking.setReportsWrongAmount(true);
        vm.expectRevert(abi.encodeWithSelector(RobinhoodBaseRevenueReceiverV1.DepositMismatch.selector, 10e6, 10e6 + 1));
        receiver.depositRevenue(1);
        staking.setReportsWrongAmount(false);
        staking.setPullsPartially(true);
        vm.expectRevert(abi.encodeWithSelector(RobinhoodBaseRevenueReceiverV1.DepositMismatch.selector, 10e6, 5e6));
        receiver.depositRevenue(1);
    }
}
