// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {MockERC20} from "autolaunch-stocks-test/mocks/MockERC20.sol";
import {RobinhoodPreset} from "../src/RobinhoodPreset.sol";
import {RobinhoodSubjectSplitterV1} from "../src/RobinhoodSubjectSplitterV1.sol";
import {RobinhoodFixture} from "./RobinhoodFixture.sol";

/// @notice The per-launch splitter: 2% skim to the inbox exactly once, USDG the only revenue, stakers
///         paid pro rata on total supply, the treasury the default holder, principal never recoverable.
contract RobinhoodSplitterTest is RobinhoodFixture {
    RobinhoodSubjectSplitterV1 internal splitter;
    Launched internal l;
    uint256 internal staked;

    function setUp() public {
        _deployRobinhood();
        l = _launchRevshare();
        uint256 bidId = _graduateRevshare(l);
        splitter = RobinhoodSubjectSplitterV1(revshare.splitterOf(l.newToken));
        staked = _claimNewTo(l, bidId, trader);
        vm.startPrank(trader);
        MockERC20(l.newToken).approve(address(splitter), staked);
        splitter.stake(staked);
        vm.stopPrank();
        vm.roll(block.number + 1);
    }

    function _deposit(uint256 amount) internal {
        usdg.mint(outsider, amount);
        vm.startPrank(outsider);
        usdg.approve(address(splitter), amount);
        splitter.depositRecognizedRevenue(USDG_ADDRESS, amount, bytes32("sale"));
        vm.stopPrank();
    }

    function test_revenue_is_skimmed_once_and_split_pro_rata_on_total_supply() public {
        uint256 inboxBefore = inbox.totalCollected();
        uint256 treasuryBefore = usdg.balanceOf(treasury);
        _deposit(1_000e6);

        uint256 skim = 1_000e6 * RobinhoodPreset.PROTOCOL_SKIM_BPS / 10_000;
        uint256 net = 1_000e6 - skim;
        uint256 stakerShare = net * staked / RobinhoodPreset.REVSHARE_TOTAL_SUPPLY;
        assertEq(inbox.totalCollected(), inboxBefore + skim);
        assertEq(usdg.balanceOf(treasury), treasuryBefore + net - stakerShare);
        assertEq(splitter.unclaimedLiability(), stakerShare);
        assertEq(usdg.balanceOf(address(splitter)), stakerShare);
        assertEq(usdg.allowance(address(splitter), address(inbox)), 0);

        vm.prank(trader);
        splitter.claim();
        assertEq(usdg.balanceOf(trader), splitter.claimable(trader) + stakerShare - splitter.unclaimedLiability());
    }

    function test_only_usdg_is_revenue() public {
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(RobinhoodSubjectSplitterV1.UnsupportedToken.selector, STOCK_LOW));
        splitter.depositRecognizedRevenue(STOCK_LOW, 1e8, bytes32(0));
    }

    function test_principal_and_revenue_are_never_recoverable() public {
        vm.expectRevert(abi.encodeWithSelector(RobinhoodSubjectSplitterV1.ProtectedToken.selector, l.newToken));
        splitter.recoverUnsupportedToken(l.newToken);
        vm.expectRevert(abi.encodeWithSelector(RobinhoodSubjectSplitterV1.ProtectedToken.selector, USDG_ADDRESS));
        splitter.recoverUnsupportedToken(USDG_ADDRESS);
        stockLow.mint(address(splitter), 3e8);
        splitter.recoverUnsupportedToken(STOCK_LOW);
        assertEq(stockLow.balanceOf(treasury), 3e8);
    }

    function test_surplus_recognition_cannot_relabel_unclaimed_rewards() public {
        _deposit(1_000e6);
        vm.expectRevert(RobinhoodSubjectSplitterV1.ZeroAmount.selector);
        splitter.recognizeSurplusRevenue();
        usdg.mint(address(splitter), 500e6);
        uint256 inboxBefore = inbox.totalCollected();
        splitter.recognizeSurplusRevenue();
        assertEq(inbox.totalCollected(), inboxBefore + 500e6 * RobinhoodPreset.PROTOCOL_SKIM_BPS / 10_000);
    }
}
