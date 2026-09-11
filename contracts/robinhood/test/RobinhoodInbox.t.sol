// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "autolaunch-stocks-test/mocks/MockERC20.sol";
import {IRobinhoodProtocolRevenueInboxV1} from "../src/interfaces/IRobinhoodProtocolRevenueInboxV1.sol";
import {RobinhoodProtocolRevenueInboxV1} from "../src/RobinhoodProtocolRevenueInboxV1.sol";
import {MockBridgeAdapter} from "./mocks/MockBridgeAdapter.sol";

/// @notice The protocol revenue inbox: USDG-only credits, Safe-only administration, destination changes
///         without redeploy, stale-version and stale-adapter refusal, and batches that keep the
///         destination they were sent to.
contract RobinhoodInboxTest is Test {
    RobinhoodProtocolRevenueInboxV1 internal inbox;
    MockERC20 internal usdg;
    MockERC20 internal other;
    MockBridgeAdapter internal adapter;

    address internal safe = makeAddr("safe");
    address internal outsider = makeAddr("outsider");
    address internal destinationA = makeAddr("base-destination-a");
    address internal destinationB = makeAddr("base-destination-b");

    function setUp() public {
        vm.warp(1_700_000_000);
        usdg = new MockERC20("Global Dollar", "USDG", 6);
        other = new MockERC20("Other", "OTH", 6);
        inbox = new RobinhoodProtocolRevenueInboxV1(address(usdg), safe);
        adapter = new MockBridgeAdapter(address(usdg), false);
    }

    function _deposit(address from, uint256 amount) internal {
        usdg.mint(from, amount);
        vm.startPrank(from);
        usdg.approve(address(inbox), amount);
        inbox.deposit(amount, bytes32("test"), bytes32(uint256(1)));
        vm.stopPrank();
    }

    function _armed() internal {
        vm.startPrank(safe);
        inbox.setBaseDestination(destinationA);
        inbox.setBridgeAdapter(address(adapter));
        vm.stopPrank();
    }

    function test_construction_refuses_a_non_six_decimal_dollar() public {
        MockERC20 wrong = new MockERC20("Wrong", "W", 18);
        vm.expectRevert(abi.encodeWithSelector(RobinhoodProtocolRevenueInboxV1.UnexpectedDecimals.selector, 6, 18));
        new RobinhoodProtocolRevenueInboxV1(address(wrong), safe);
    }

    function test_deposit_is_exact_and_counted() public {
        _deposit(outsider, 1_000e6);
        assertEq(inbox.totalCollected(), 1_000e6);
        assertEq(inbox.available(), 1_000e6);
        assertEq(usdg.balanceOf(address(inbox)), 1_000e6);
    }

    function test_safe_only_administration() public {
        vm.startPrank(outsider);
        vm.expectRevert(abi.encodeWithSelector(RobinhoodProtocolRevenueInboxV1.NotSafe.selector, outsider));
        inbox.setBaseDestination(destinationA);
        vm.expectRevert(abi.encodeWithSelector(RobinhoodProtocolRevenueInboxV1.NotSafe.selector, outsider));
        inbox.setBridgeAdapter(address(adapter));
        vm.expectRevert(abi.encodeWithSelector(RobinhoodProtocolRevenueInboxV1.NotSafe.selector, outsider));
        inbox.bridgeRevenue(1, 1, uint64(block.timestamp), 1, address(adapter));
        vm.stopPrank();
    }

    function test_destination_changes_bump_the_version_without_redeploy() public {
        vm.startPrank(safe);
        inbox.setBaseDestination(destinationA);
        assertEq(inbox.destinationVersion(), 1);
        inbox.setBaseDestination(destinationB);
        assertEq(inbox.destinationVersion(), 2);
        assertEq(inbox.baseDestination(), destinationB);
        vm.expectRevert(RobinhoodProtocolRevenueInboxV1.ZeroAddress.selector);
        inbox.setBaseDestination(address(0));
        vm.stopPrank();
    }

    function test_adapter_must_bind_usdg_and_base() public {
        MockBridgeAdapter wrongChain = new MockBridgeAdapter(address(usdg), true);
        MockBridgeAdapter wrongToken = new MockBridgeAdapter(address(other), false);
        vm.startPrank(safe);
        vm.expectRevert(abi.encodeWithSelector(RobinhoodProtocolRevenueInboxV1.AdapterChainMismatch.selector, 8453, 1));
        inbox.setBridgeAdapter(address(wrongChain));
        vm.expectRevert(
            abi.encodeWithSelector(
                RobinhoodProtocolRevenueInboxV1.AdapterBindingMismatch.selector, address(usdg), address(other)
            )
        );
        inbox.setBridgeAdapter(address(wrongToken));
        vm.stopPrank();
    }

    function test_bridge_records_a_batch_and_moves_exactly_the_amount() public {
        _armed();
        _deposit(outsider, 1_000e6);
        uint64 deadline = uint64(block.timestamp + 1 hours);

        vm.prank(safe);
        uint256 batchId = inbox.bridgeRevenue(400e6, 390e6, deadline, 1, address(adapter));

        IRobinhoodProtocolRevenueInboxV1.Batch memory batch = inbox.batches(batchId);
        assertEq(batch.amountUsdg, 400e6);
        assertEq(batch.baseDestination, destinationA);
        assertEq(batch.destinationVersion, 1);
        assertEq(batch.adapter, address(adapter));
        assertEq(batch.minimumUsdcOut, 390e6);
        assertEq(batch.transferRef, keccak256(abi.encode(batchId, 400e6, destinationA)));
        assertEq(adapter.lastDestination(), destinationA);
        assertEq(adapter.lastBatchId(), batchId);
        assertEq(usdg.balanceOf(address(inbox)), 600e6);
        assertEq(usdg.allowance(address(inbox), address(adapter)), 0);
        assertEq(inbox.totalBridged(), 400e6);
        assertEq(inbox.nextBatchId(), batchId + 1);
    }

    function test_bridge_refuses_stale_version_stale_adapter_expiry_and_overdraw() public {
        _armed();
        _deposit(outsider, 100e6);
        uint64 deadline = uint64(block.timestamp + 1 hours);
        MockBridgeAdapter another = new MockBridgeAdapter(address(usdg), false);

        vm.startPrank(safe);
        vm.expectRevert(abi.encodeWithSelector(RobinhoodProtocolRevenueInboxV1.StaleDestinationVersion.selector, 1, 2));
        inbox.bridgeRevenue(50e6, 1, deadline, 2, address(adapter));
        vm.expectRevert(
            abi.encodeWithSelector(
                RobinhoodProtocolRevenueInboxV1.StaleAdapter.selector, address(adapter), address(another)
            )
        );
        inbox.bridgeRevenue(50e6, 1, deadline, 1, address(another));
        vm.expectRevert(RobinhoodProtocolRevenueInboxV1.ZeroMinimumOut.selector);
        inbox.bridgeRevenue(50e6, 0, deadline, 1, address(adapter));
        vm.expectRevert(
            abi.encodeWithSelector(RobinhoodProtocolRevenueInboxV1.InsufficientAvailable.selector, 100e6, 101e6)
        );
        inbox.bridgeRevenue(101e6, 1, deadline, 1, address(adapter));
        vm.warp(deadline + 1);
        vm.expectRevert(
            abi.encodeWithSelector(RobinhoodProtocolRevenueInboxV1.Expired.selector, deadline, deadline + 1)
        );
        inbox.bridgeRevenue(50e6, 1, deadline, 1, address(adapter));
        vm.stopPrank();
    }

    function test_a_partial_pull_by_the_adapter_reverts_the_batch() public {
        _armed();
        _deposit(outsider, 100e6);
        adapter.setPullsPartially(true);
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(RobinhoodProtocolRevenueInboxV1.InexactTransfer.selector, 100e6, 50e6));
        inbox.bridgeRevenue(100e6, 1, uint64(block.timestamp + 1), 1, address(adapter));
        assertEq(inbox.nextBatchId(), 1);
        assertEq(inbox.totalBridged(), 0);
    }

    function test_a_sent_batch_keeps_its_destination_after_a_change() public {
        _armed();
        _deposit(outsider, 100e6);
        uint64 deadline = uint64(block.timestamp + 1 hours);
        vm.startPrank(safe);
        uint256 first = inbox.bridgeRevenue(40e6, 1, deadline, 1, address(adapter));
        inbox.setBaseDestination(destinationB);
        vm.expectRevert(abi.encodeWithSelector(RobinhoodProtocolRevenueInboxV1.StaleDestinationVersion.selector, 2, 1));
        inbox.bridgeRevenue(40e6, 1, deadline, 1, address(adapter));
        uint256 second = inbox.bridgeRevenue(40e6, 1, deadline, 2, address(adapter));
        vm.stopPrank();
        assertEq(inbox.batches(first).baseDestination, destinationA);
        assertEq(inbox.batches(second).baseDestination, destinationB);
    }

    function test_usdg_is_never_recoverable_and_other_tokens_go_to_the_safe() public {
        other.mint(address(inbox), 5e6);
        vm.expectRevert(abi.encodeWithSelector(RobinhoodProtocolRevenueInboxV1.ProtectedToken.selector, address(usdg)));
        inbox.recoverUnsupportedToken(address(usdg));
        vm.prank(outsider);
        inbox.recoverUnsupportedToken(address(other));
        assertEq(other.balanceOf(safe), 5e6);
    }
}
