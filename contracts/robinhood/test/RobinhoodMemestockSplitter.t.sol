// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {MemestockSplitterCore} from "autolaunch-stocks/MemestockSplitterCore.sol";
import {MockERC20} from "autolaunch-stocks-test/mocks/MockERC20.sol";
import {IRobinhoodProtocolRevenueInboxV1} from "../src/interfaces/IRobinhoodProtocolRevenueInboxV1.sol";
import {RobinhoodMemestockSplitterV1} from "../src/RobinhoodMemestockSplitterV1.sol";
import {RobinhoodFixture} from "./RobinhoodFixture.sol";

/// @notice The Robinhood memestock splitter behind a real graduated launch: stakers divide USDG,
///         MEMESTOCK and STOCK pro rata after the 2% protocol share, whose USDG goes into the protocol
///         revenue inbox and whose MEMESTOCK and STOCK go to the Robinhood Safe. The staking
///         accounting itself is the shared core, proved in the Base Stocks suite.
contract RobinhoodMemestockSplitterTest is RobinhoodFixture {
    uint256 internal constant SKIM_BPS = 200;

    address internal payer = makeAddr("payer");
    address internal second = makeAddr("second-staker");

    Launched internal l;
    RobinhoodMemestockSplitterV1 internal splitter;
    uint256 internal staked;

    function setUp() public {
        _deployRobinhood();
        (l, staked) = _graduatedStakedMarket(STOCK_LOW);
        splitter = _splitter(l);
        vm.roll(block.number + 1);
    }

    /// @dev USDG and STOCK are mintable doubles; MEMESTOCK revenue is funded from a holder instead.
    function _deposit(address token, uint256 amount, bytes32 ref) internal {
        MockERC20(token).mint(payer, amount);
        vm.startPrank(payer);
        MockERC20(token).approve(address(splitter), amount);
        splitter.depositRecognizedRevenue(token, amount, ref);
        vm.stopPrank();
    }

    function test_the_implementation_refuses_zero_bindings_and_can_never_be_initialized() public {
        vm.expectRevert(MemestockSplitterCore.ZeroAddress.selector);
        new RobinhoodMemestockSplitterV1(address(0), address(inbox), safe);
        vm.expectRevert(MemestockSplitterCore.ZeroAddress.selector);
        new RobinhoodMemestockSplitterV1(USDG_ADDRESS, address(0), safe);
        vm.expectRevert(MemestockSplitterCore.ZeroAddress.selector);
        new RobinhoodMemestockSplitterV1(USDG_ADDRESS, address(inbox), address(0));

        RobinhoodMemestockSplitterV1 implementation = RobinhoodMemestockSplitterV1(stocks.splitterImplementation());
        vm.expectRevert();
        implementation.initialize(l.newToken, STOCK_LOW);
    }

    function test_usdg_protocol_share_goes_into_the_inbox_tagged_and_the_rest_to_stakers() public {
        uint256 inboxBefore = inbox.totalCollected();
        uint256 share = 1_000e6 * SKIM_BPS / 10_000;

        bytes32 tag = splitter.PROTOCOL_SOURCE_TAG();
        assertEq(tag, bytes32("robinhood-splitter"));

        usdg.mint(payer, 1_000e6);
        vm.startPrank(payer);
        usdg.approve(address(splitter), 1_000e6);
        vm.expectEmit(true, true, true, true, address(inbox));
        emit IRobinhoodProtocolRevenueInboxV1.RevenueCollected(address(splitter), tag, bytes32("ref-1"), share);
        splitter.depositRecognizedRevenue(USDG_ADDRESS, 1_000e6, bytes32("ref-1"));
        vm.stopPrank();

        assertEq(inbox.totalCollected(), inboxBefore + share);
        assertEq(usdg.balanceOf(safe), 0);
        assertEq(usdg.allowance(address(splitter), address(inbox)), 0);

        uint256 owed = splitter.claimable(USDG_ADDRESS, staker);
        assertApproxEqAbs(owed, 1_000e6 - share, 1);
        vm.prank(staker);
        splitter.claim(USDG_ADDRESS);
        assertEq(usdg.balanceOf(staker), owed);
    }

    function test_stock_and_memestock_protocol_shares_go_to_the_safe() public {
        uint256 stockShare = 50e18 * SKIM_BPS / 10_000;
        _deposit(STOCK_LOW, 50e18, bytes32("stock"));
        assertEq(stockLow.balanceOf(safe), stockShare);
        assertApproxEqAbs(splitter.claimable(STOCK_LOW, staker), 50e18 - stockShare, 1);

        // MEMESTOCK has a fixed supply, so the payer's MEMESTOCK comes out of the staker's own stake.
        vm.prank(staker);
        splitter.unstake(1_000e18);
        vm.prank(staker);
        MockERC20(l.newToken).transfer(payer, 1_000e18);
        vm.startPrank(payer);
        MockERC20(l.newToken).approve(address(splitter), 1_000e18);
        splitter.depositRecognizedRevenue(l.newToken, 1_000e18, bytes32("memestock"));
        vm.stopPrank();

        uint256 newShare = 1_000e18 * SKIM_BPS / 10_000;
        assertEq(MockERC20(l.newToken).balanceOf(safe), newShare);
        assertApproxEqAbs(splitter.claimable(l.newToken, staker), 1_000e18 - newShare, 1);
        // Staked principal is never paid out as revenue.
        assertEq(splitter.protectedBalance(l.newToken), MockERC20(l.newToken).balanceOf(address(splitter)));
    }

    function test_two_stakers_divide_pro_rata_and_nothing_is_held_back() public {
        vm.prank(staker);
        splitter.unstake(staked / 4);
        vm.prank(staker);
        MockERC20(l.newToken).transfer(second, staked / 4);
        vm.startPrank(second);
        MockERC20(l.newToken).approve(address(splitter), staked / 4);
        splitter.stake(staked / 4);
        vm.stopPrank();
        vm.roll(block.number + 1);

        _deposit(USDG_ADDRESS, 4_000e6, bytes32("split"));
        uint256 net = 4_000e6 - 4_000e6 * SKIM_BPS / 10_000;
        uint256 first = splitter.claimable(USDG_ADDRESS, staker);
        uint256 other = splitter.claimable(USDG_ADDRESS, second);
        assertApproxEqAbs(first, net * 3 / 4, 1);
        assertApproxEqAbs(other, net / 4, 1);
        assertApproxEqAbs(first + other, net, 2);
        assertEq(usdg.balanceOf(address(splitter)), net);
    }

    function test_revenue_with_nothing_staked_goes_whole_to_the_protocol_route() public {
        vm.prank(staker);
        splitter.unstake(staked);
        uint256 inboxBefore = inbox.totalCollected();

        _deposit(USDG_ADDRESS, 100e6, bytes32("idle-usdg"));
        _deposit(STOCK_LOW, 5e18, bytes32("idle-stock"));

        assertEq(inbox.totalCollected(), inboxBefore + 100e6);
        assertEq(stockLow.balanceOf(safe), 5e18);
        assertEq(usdg.balanceOf(address(splitter)), 0);
        assertEq(stockLow.balanceOf(address(splitter)), 0);
    }

    function test_unsupported_tokens_are_recovered_to_the_safe_and_the_three_assets_never_are() public {
        MockERC20 stray = new MockERC20("Stray", "STRAY", 18);
        stray.mint(address(splitter), 7e18);
        vm.prank(outsider);
        splitter.recoverUnsupportedToken(address(stray));
        assertEq(stray.balanceOf(safe), 7e18);

        vm.expectRevert(abi.encodeWithSelector(MemestockSplitterCore.ProtectedToken.selector, USDG_ADDRESS));
        splitter.recoverUnsupportedToken(USDG_ADDRESS);
        vm.expectRevert(abi.encodeWithSelector(MemestockSplitterCore.ProtectedToken.selector, STOCK_LOW));
        splitter.recoverUnsupportedToken(STOCK_LOW);
        vm.expectRevert(abi.encodeWithSelector(MemestockSplitterCore.ProtectedToken.selector, l.newToken));
        splitter.recoverUnsupportedToken(l.newToken);
    }

    function test_a_refusing_inbox_fails_only_usdg_recognition() public {
        vm.mockCallRevert(
            address(inbox), abi.encodeWithSelector(IRobinhoodProtocolRevenueInboxV1.deposit.selector), "inbox down"
        );
        usdg.mint(payer, 10e6);
        vm.startPrank(payer);
        usdg.approve(address(splitter), 10e6);
        vm.expectRevert();
        splitter.depositRecognizedRevenue(USDG_ADDRESS, 10e6, bytes32("down"));
        vm.stopPrank();

        _deposit(STOCK_LOW, 1e18, bytes32("still-up"));
        assertGt(splitter.claimable(STOCK_LOW, staker), 0);
    }

    function test_a_misreporting_inbox_is_refused() public {
        vm.mockCall(
            address(inbox), abi.encodeWithSelector(IRobinhoodProtocolRevenueInboxV1.deposit.selector), abi.encode(1)
        );
        usdg.mint(payer, 10e6);
        vm.startPrank(payer);
        usdg.approve(address(splitter), 10e6);
        vm.expectRevert(
            abi.encodeWithSelector(
                RobinhoodMemestockSplitterV1.InboxDepositMismatch.selector, 10e6 * SKIM_BPS / 10_000, 1
            )
        );
        splitter.depositRecognizedRevenue(USDG_ADDRESS, 10e6, bytes32("lie"));
        vm.stopPrank();
    }
}
