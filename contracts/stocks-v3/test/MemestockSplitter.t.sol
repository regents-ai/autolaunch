// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Initializable} from "solady/utils/Initializable.sol";
import {LibClone} from "solady/utils/LibClone.sol";
import {UERC20} from "uerc20-factory/tokens/UERC20.sol";
import {MemestockSplitterCore} from "../src/MemestockSplitterCore.sol";
import {MemestockSplitterV1} from "../src/MemestockSplitterV1.sol";
import {StocksBindings} from "../src/StocksBindings.sol";
import {FixtureStockToken} from "../src/fixtures/FixtureStockToken.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockLiveStaking} from "./mocks/MockLiveStaking.sol";
import {StocksFixture} from "./StocksFixture.sol";

/// @notice The memestock splitter of a graduated launch: MEMESTOCK holders stake and divide, pro rata,
///         everything recognized in USDC, MEMESTOCK and STOCK after the 2% protocol share; nothing is
///         held back for any treasury; nobody administers it.
contract MemestockSplitterTest is StocksFixture {
    Launched internal l;
    MemestockSplitterV1 internal splitter;
    UERC20 internal memestock;
    FixtureStockToken internal stock;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal payer = makeAddr("payer");

    function setUp() public {
        _deployStocks();
        l = _graduatedMarket(STOCK_LOW);
        splitter = _splitter(l);
        memestock = UERC20(l.newToken);
        stock = FixtureStockToken(l.stock);

        // Alice and Bob hold MEMESTOCK three to one; the payer funds revenue in all three assets.
        vm.startPrank(trader);
        memestock.transfer(alice, 3_000e18);
        memestock.transfer(bob, 1_000e18);
        memestock.transfer(payer, 10_000e18);
        vm.stopPrank();
        usdc.mint(payer, 1_000_000e6);
        stock.mint(payer, 1_000_000e8);
        vm.startPrank(payer);
        usdc.approve(address(splitter), type(uint256).max);
        stock.approve(address(splitter), type(uint256).max);
        memestock.approve(address(splitter), type(uint256).max);
        vm.stopPrank();
    }

    // -------------------------------------------------------------------------
    // bindings
    // -------------------------------------------------------------------------

    function test_clone_is_bound_once_to_the_launch_and_has_no_administrator() public {
        assertEq(splitter.dollar(), StocksBindings.USDC);
        assertEq(splitter.memestock(), l.newToken);
        assertEq(splitter.stock(), l.stock);
        assertEq(splitter.protocolTreasury(), governance);
        assertEq(splitter.SKIM_BPS(), 200);

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        splitter.initialize(l.newToken, l.stock);

        MemestockSplitterV1 implementation = MemestockSplitterV1(launchpad.splitterImplementation());
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.initialize(l.newToken, l.stock);
    }

    function test_initialize_refuses_zero_self_and_aliased_tokens() public {
        address implementation = launchpad.splitterImplementation();

        MemestockSplitterV1 fresh = MemestockSplitterV1(LibClone.clone(implementation));
        vm.expectRevert(MemestockSplitterCore.ZeroAddress.selector);
        fresh.initialize(address(0), l.stock);
        vm.expectRevert(MemestockSplitterCore.ZeroAddress.selector);
        fresh.initialize(l.newToken, address(0));
        vm.expectRevert(MemestockSplitterCore.SelfAddress.selector);
        fresh.initialize(address(fresh), l.stock);
        vm.expectRevert(MemestockSplitterCore.DuplicateTokenBinding.selector);
        fresh.initialize(l.newToken, l.newToken);
        vm.expectRevert(MemestockSplitterCore.DuplicateTokenBinding.selector);
        fresh.initialize(StocksBindings.USDC, l.stock);
        vm.expectRevert(MemestockSplitterCore.DuplicateTokenBinding.selector);
        fresh.initialize(l.newToken, StocksBindings.USDC);
    }

    // -------------------------------------------------------------------------
    // the 2% protocol share, on all three assets
    // -------------------------------------------------------------------------

    function test_usdc_share_goes_straight_into_live_staking_and_the_rest_to_stakers() public {
        _stakeAs(alice, 1_000e18);
        uint256 stakingBefore = usdc.balanceOf(address(liveStaking));
        uint256 safeBefore = usdc.balanceOf(governance);

        vm.expectEmit(true, true, true, true, address(splitter));
        emit MemestockSplitterCore.RevenueRecognized(StocksBindings.USDC, payer, bytes32("ref"), 1_000e6, 20e6, 980e6);
        vm.prank(payer);
        splitter.depositRecognizedRevenue(StocksBindings.USDC, 1_000e6, bytes32("ref"));

        assertEq(usdc.balanceOf(address(liveStaking)) - stakingBefore, 20e6, "2% into REGENT staking");
        assertEq(usdc.balanceOf(governance), safeBefore, "no USDC to the Safe");
        assertEq(liveStaking.lastAmount(), 20e6);
        assertEq(liveStaking.lastSourceTag(), bytes32(uint256(uint160(l.newToken))), "tagged with the MEMESTOCK");
        assertEq(liveStaking.lastSourceRef(), bytes32("ref"));
        assertEq(liveStaking.lastCaller(), address(splitter));
        assertEq(usdc.allowance(address(splitter), address(liveStaking)), 0);
        assertEq(usdc.balanceOf(address(splitter)), 980e6);
        assertEq(splitter.unclaimedLiability(StocksBindings.USDC), 980e6, "the whole remainder is owed to stakers");
        assertEq(splitter.claimable(StocksBindings.USDC, alice), 980e6);
    }

    function test_stock_and_memestock_shares_go_to_the_safe_and_the_rest_to_stakers() public {
        _stakeAs(alice, 1_000e18);
        uint256 safeStock = stock.balanceOf(governance);
        uint256 safeMemestock = memestock.balanceOf(governance);

        vm.startPrank(payer);
        splitter.depositRecognizedRevenue(l.stock, 500e8, bytes32("s"));
        splitter.depositRecognizedRevenue(l.newToken, 2_000e18, bytes32("m"));
        vm.stopPrank();

        assertEq(stock.balanceOf(governance) - safeStock, 10e8, "2% of STOCK to the Safe");
        assertEq(memestock.balanceOf(governance) - safeMemestock, 40e18, "2% of MEMESTOCK to the Safe");
        assertEq(splitter.claimable(l.stock, alice), 490e8);
        assertEq(splitter.claimable(l.newToken, alice), 1_960e18);
        assertEq(liveStaking.depositCalls(), 0, "only USDC reaches REGENT staking");
        // Staked principal and owed MEMESTOCK sit side by side and never mix.
        assertEq(memestock.balanceOf(address(splitter)), 1_000e18 + 1_960e18);
        assertEq(splitter.protectedBalance(l.newToken), 1_000e18 + 1_960e18);
    }

    function test_revenue_is_divided_pro_rata_with_nothing_held_back() public {
        _stakeAs(alice, 3_000e18);
        _stakeAs(bob, 1_000e18);

        vm.startPrank(payer);
        splitter.depositRecognizedRevenue(StocksBindings.USDC, 1_000e6, 0);
        splitter.depositRecognizedRevenue(l.stock, 400e8, 0);
        splitter.depositRecognizedRevenue(l.newToken, 100e18, 0);
        vm.stopPrank();

        assertEq(splitter.claimable(StocksBindings.USDC, alice), 735e6);
        assertEq(splitter.claimable(StocksBindings.USDC, bob), 245e6);
        assertEq(splitter.claimable(l.stock, alice), 294e8);
        assertEq(splitter.claimable(l.stock, bob), 98e8);
        assertEq(splitter.claimable(l.newToken, alice), 73.5e18);
        assertEq(splitter.claimable(l.newToken, bob), 24.5e18);

        vm.roll(block.number + 1);
        uint256 aliceMemestock = memestock.balanceOf(alice);
        vm.prank(alice);
        splitter.claimAll();
        vm.prank(bob);
        splitter.claimAll();
        assertEq(usdc.balanceOf(alice), 735e6);
        assertEq(usdc.balanceOf(bob), 245e6);
        assertEq(stock.balanceOf(alice), 294e8);
        assertEq(stock.balanceOf(bob), 98e8);
        assertEq(memestock.balanceOf(alice) - aliceMemestock, 73.5e18);

        // Everything recognized has left: only staked principal remains, no residue for anyone else.
        assertEq(usdc.balanceOf(address(splitter)), 0);
        assertEq(stock.balanceOf(address(splitter)), 0);
        assertEq(memestock.balanceOf(address(splitter)), 4_000e18);
    }

    function test_a_later_staker_shares_only_in_later_revenue() public {
        _stakeAs(alice, 1_000e18);
        vm.prank(payer);
        splitter.depositRecognizedRevenue(l.stock, 100e8, 0);

        _stakeAs(bob, 1_000e18);
        assertEq(splitter.claimable(l.stock, bob), 0);
        vm.prank(payer);
        splitter.depositRecognizedRevenue(l.stock, 100e8, 0);

        assertEq(splitter.claimable(l.stock, alice), 98e8 + 49e8);
        assertEq(splitter.claimable(l.stock, bob), 49e8);
    }

    function test_unstaking_keeps_what_was_already_earned() public {
        _stakeAs(alice, 1_000e18);
        vm.prank(payer);
        splitter.depositRecognizedRevenue(l.stock, 100e8, 0);

        vm.roll(block.number + 1);
        vm.prank(alice);
        splitter.unstake(1_000e18);
        assertEq(memestock.balanceOf(alice), 3_000e18);
        assertEq(splitter.totalStaked(), 0);
        assertEq(splitter.claimable(l.stock, alice), 98e8);

        vm.prank(alice);
        splitter.claim(l.stock);
        assertEq(stock.balanceOf(alice), 98e8);
    }

    // -------------------------------------------------------------------------
    // nothing staked
    // -------------------------------------------------------------------------

    function test_with_nothing_staked_the_whole_inflow_is_the_protocols() public {
        uint256 stakingBefore = usdc.balanceOf(address(liveStaking));
        uint256 safeStock = stock.balanceOf(governance);
        uint256 safeMemestock = memestock.balanceOf(governance);

        vm.expectEmit(true, true, true, true, address(splitter));
        emit MemestockSplitterCore.RevenueRecognized(l.stock, payer, bytes32(0), 100e8, 100e8, 0);
        vm.startPrank(payer);
        splitter.depositRecognizedRevenue(l.stock, 100e8, 0);
        splitter.depositRecognizedRevenue(StocksBindings.USDC, 1_000e6, 0);
        splitter.depositRecognizedRevenue(l.newToken, 50e18, 0);
        vm.stopPrank();

        assertEq(usdc.balanceOf(address(liveStaking)) - stakingBefore, 1_000e6);
        assertEq(stock.balanceOf(governance) - safeStock, 100e8);
        assertEq(memestock.balanceOf(governance) - safeMemestock, 50e18);
        assertEq(splitter.unclaimedLiability(l.stock), 0);
        assertEq(stock.balanceOf(address(splitter)), 0);

        // The first staker inherits nothing from before it staked.
        _stakeAs(alice, 1_000e18);
        assertEq(splitter.claimable(l.stock, alice), 0);
        assertEq(splitter.claimable(StocksBindings.USDC, alice), 0);
    }

    // -------------------------------------------------------------------------
    // the one-block exit rule
    // -------------------------------------------------------------------------

    function test_nothing_leaves_an_account_in_its_own_stake_block() public {
        _stakeAs(alice, 1_000e18);
        vm.prank(payer);
        splitter.depositRecognizedRevenue(l.stock, 100e8, 0);

        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(MemestockSplitterCore.SameBlockStakeExit.selector, alice, block.number));
        splitter.unstake(1);
        vm.expectRevert(abi.encodeWithSelector(MemestockSplitterCore.SameBlockStakeExit.selector, alice, block.number));
        splitter.claim(l.stock);
        vm.expectRevert(abi.encodeWithSelector(MemestockSplitterCore.SameBlockStakeExit.selector, alice, block.number));
        splitter.claimAll();
        vm.stopPrank();

        vm.roll(block.number + 1);
        vm.prank(alice);
        splitter.claimAll();
        assertEq(stock.balanceOf(alice), 98e8);

        // A top-up restarts the rule for the whole position.
        _stakeAs(alice, 1);
        vm.expectRevert(abi.encodeWithSelector(MemestockSplitterCore.SameBlockStakeExit.selector, alice, block.number));
        vm.prank(alice);
        splitter.unstake(1_000e18);
    }

    function test_stake_and_unstake_guards() public {
        vm.startPrank(alice);
        vm.expectRevert(MemestockSplitterCore.ZeroAmount.selector);
        splitter.stake(0);
        vm.expectRevert(MemestockSplitterCore.ZeroAmount.selector);
        splitter.unstake(0);
        vm.expectRevert(abi.encodeWithSelector(MemestockSplitterCore.InsufficientStake.selector, 0, 1));
        splitter.unstake(1);
        vm.stopPrank();
    }

    // -------------------------------------------------------------------------
    // bare transfers
    // -------------------------------------------------------------------------

    function test_a_bare_transfer_becomes_revenue_only_through_surplus_recognition() public {
        _stakeAs(alice, 1_000e18);
        vm.prank(payer);
        stock.transfer(address(splitter), 100e8);
        assertEq(splitter.claimable(l.stock, alice), 0, "a bare transfer is not yet revenue");

        uint256 safeStock = stock.balanceOf(governance);
        vm.prank(outsider);
        splitter.recognizeSurplusRevenue(l.stock);
        assertEq(splitter.claimable(l.stock, alice), 98e8);
        assertEq(stock.balanceOf(governance) - safeStock, 2e8);

        vm.expectRevert(MemestockSplitterCore.ZeroAmount.selector);
        splitter.recognizeSurplusRevenue(l.stock);
    }

    function test_staked_principal_and_owed_revenue_are_never_recognized_as_surplus() public {
        _stakeAs(alice, 1_000e18);
        vm.prank(payer);
        splitter.depositRecognizedRevenue(l.newToken, 100e18, 0);

        vm.expectRevert(MemestockSplitterCore.ZeroAmount.selector);
        splitter.recognizeSurplusRevenue(l.newToken);

        vm.prank(payer);
        memestock.transfer(address(splitter), 50e18);
        splitter.recognizeSurplusRevenue(l.newToken);
        assertEq(splitter.claimable(l.newToken, alice), 98e18 + 49e18);
        assertEq(splitter.totalStaked(), 1_000e18);
    }

    // -------------------------------------------------------------------------
    // unsupported assets
    // -------------------------------------------------------------------------

    function test_only_the_three_assets_are_recognized_and_strays_go_to_the_safe() public {
        MockERC20 stray = new MockERC20("Stray", "STRAY", 18);
        stray.mint(payer, 10e18);

        vm.startPrank(payer);
        stray.approve(address(splitter), 10e18);
        vm.expectRevert(abi.encodeWithSelector(MemestockSplitterCore.UnsupportedToken.selector, address(stray)));
        splitter.depositRecognizedRevenue(address(stray), 10e18, 0);
        vm.expectRevert(abi.encodeWithSelector(MemestockSplitterCore.UnsupportedToken.selector, StocksBindings.REGENT));
        splitter.depositRecognizedRevenue(StocksBindings.REGENT, 1, 0);
        vm.expectRevert(MemestockSplitterCore.ZeroAmount.selector);
        splitter.depositRecognizedRevenue(l.stock, 0, 0);
        stray.transfer(address(splitter), 10e18);
        vm.stopPrank();

        vm.expectRevert(abi.encodeWithSelector(MemestockSplitterCore.UnsupportedToken.selector, address(stray)));
        splitter.recognizeSurplusRevenue(address(stray));

        vm.prank(outsider);
        splitter.recoverUnsupportedToken(address(stray));
        assertEq(stray.balanceOf(governance), 10e18, "strays always go to the Safe, whoever calls");
        vm.expectRevert(MemestockSplitterCore.ZeroAmount.selector);
        splitter.recoverUnsupportedToken(address(stray));

        vm.expectRevert(abi.encodeWithSelector(MemestockSplitterCore.ProtectedToken.selector, StocksBindings.USDC));
        splitter.recoverUnsupportedToken(StocksBindings.USDC);
        vm.expectRevert(abi.encodeWithSelector(MemestockSplitterCore.ProtectedToken.selector, l.newToken));
        splitter.recoverUnsupportedToken(l.newToken);
        vm.expectRevert(abi.encodeWithSelector(MemestockSplitterCore.ProtectedToken.selector, l.stock));
        splitter.recoverUnsupportedToken(l.stock);
    }

    function test_force_sent_eth_goes_to_the_safe() public {
        vm.expectRevert(MemestockSplitterCore.ZeroAmount.selector);
        splitter.recoverForcedETH();

        (bool accepted,) = address(splitter).call{value: 1}("");
        assertFalse(accepted, "the splitter takes no ETH by ordinary transfer");

        vm.deal(address(splitter), 1 ether);
        uint256 safeBefore = governance.balance;
        vm.prank(outsider);
        splitter.recoverForcedETH();
        assertEq(governance.balance - safeBefore, 1 ether);
    }

    // -------------------------------------------------------------------------
    // REGENT staking problems
    // -------------------------------------------------------------------------

    function test_a_failing_regent_staking_deposit_fails_only_usdc_recognition() public {
        _stakeAs(alice, 1_000e18);

        liveStaking.setPaused(true);
        vm.startPrank(payer);
        vm.expectRevert(MockLiveStaking.Paused.selector);
        splitter.depositRecognizedRevenue(StocksBindings.USDC, 1_000e6, 0);
        splitter.depositRecognizedRevenue(l.stock, 100e8, 0);
        vm.stopPrank();
        liveStaking.setPaused(false);

        liveStaking.setReportsWrongAmount(true);
        vm.expectRevert(abi.encodeWithSelector(MemestockSplitterV1.StakingDepositMismatch.selector, 20e6, 20e6 + 1));
        vm.prank(payer);
        splitter.depositRecognizedRevenue(StocksBindings.USDC, 1_000e6, 0);
        liveStaking.setReportsWrongAmount(false);

        liveStaking.setPullsPartially(true);
        vm.expectRevert();
        vm.prank(payer);
        splitter.depositRecognizedRevenue(StocksBindings.USDC, 1_000e6, 0);
        liveStaking.setPullsPartially(false);

        assertEq(splitter.claimable(StocksBindings.USDC, alice), 0, "failed recognitions changed nothing");
        assertEq(splitter.claimable(l.stock, alice), 98e8);
        assertEq(usdc.balanceOf(address(splitter)), 0);
    }

    // -------------------------------------------------------------------------
    // conservation
    // -------------------------------------------------------------------------

    function testFuzz_every_recognized_unit_is_the_protocols_or_a_stakers(
        uint96 aliceStake,
        uint96 bobStake,
        uint64 first,
        uint64 second
    ) public {
        uint256 a = bound(aliceStake, 1, 3_000e18);
        uint256 b = bound(bobStake, 1, 1_000e18);
        uint256 gross1 = bound(first, 1, 1_000_000e8);
        uint256 gross2 = bound(second, 1, 1_000_000e8);
        stock.mint(payer, gross1 + gross2);
        uint256 safeBefore = stock.balanceOf(governance);

        _stakeAs(alice, a);
        vm.prank(payer);
        splitter.depositRecognizedRevenue(l.stock, gross1, 0);
        _stakeAs(bob, b);
        vm.prank(payer);
        splitter.depositRecognizedRevenue(l.stock, gross2, 0);

        uint256 protocol = stock.balanceOf(governance) - safeBefore;
        assertEq(protocol, gross1 * 200 / 10_000 + gross2 * 200 / 10_000, "2% floored, once per inflow");
        assertEq(splitter.unclaimedLiability(l.stock), gross1 + gross2 - protocol, "the rest is owed to stakers");

        vm.roll(block.number + 1);
        vm.prank(alice);
        splitter.claim(l.stock);
        vm.prank(bob);
        splitter.claim(l.stock);
        uint256 paid = stock.balanceOf(alice) + stock.balanceOf(bob);
        assertLe(paid, gross1 + gross2 - protocol, "never pays more than was recognized");
        assertLe(gross1 + gross2 - protocol - paid, 2, "at most one sub-unit per staker waits as dust");
        assertEq(stock.balanceOf(address(splitter)), splitter.unclaimedLiability(l.stock), "held == owed");
    }

    // -------------------------------------------------------------------------
    // helpers
    // -------------------------------------------------------------------------

    function _stakeAs(address account, uint256 amount) private {
        _stake(l, account, amount);
    }
}
