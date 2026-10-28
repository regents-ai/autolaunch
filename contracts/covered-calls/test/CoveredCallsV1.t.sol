// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

import {CoveredCallsV1} from "../src/CoveredCallsV1.sol";
import {B20Double, StakingDouble, UsdcDouble} from "./doubles/Doubles.sol";

contract CoveredCallsV1Test is Test {
    uint256 internal constant TOKEN = 1e8; // one whole stock token, raw
    uint256 internal constant USD = 1e6;
    uint64 internal expiry;

    B20Double internal stock;
    UsdcDouble internal usdc;
    StakingDouble internal staking;
    CoveredCallsV1 internal calls;

    address internal seller = makeAddr("seller");
    address internal buyer = makeAddr("buyer");
    address internal other = makeAddr("other");

    function setUp() public {
        vm.warp(1_800_000_000);
        expiry = uint64(block.timestamp + 3 days);
        stock = new B20Double();
        usdc = new UsdcDouble();
        staking = new StakingDouble(usdc);
        calls = new CoveredCallsV1(address(stock), address(usdc), address(staking));

        stock.mint(seller, 100 * TOKEN);
        vm.prank(seller);
        stock.approve(address(calls), type(uint256).max);
        for (uint256 i; i < 2; ++i) {
            address account = i == 0 ? buyer : other;
            usdc.mint(account, 1_000_000 * USD);
            vm.prank(account);
            usdc.approve(address(calls), type(uint256).max);
        }
    }

    /// Ten tokens at a 110 strike and a 3 USDC premium per token.
    function _list() internal returns (uint256 id) {
        vm.prank(seller);
        id = calls.list(10 * TOKEN, 110 * USD, 3 * USD, expiry);
    }

    function _fill(address who, uint256 id, uint256 amount) internal {
        vm.prank(who);
        calls.fill(id, amount);
    }

    // ---- list ----

    function test_list_locksTheStockAndRecordsTerms() public {
        uint256 id = _list();
        assertEq(id, 1);
        assertEq(stock.balanceOf(address(calls)), 10 * TOKEN);
        assertEq(stock.balanceOf(seller), 90 * TOKEN);
        CoveredCallsV1.Listing memory l = calls.listings(id);
        assertEq(l.seller, seller);
        assertEq(l.amount, 10 * TOKEN);
        assertEq(l.strikePerToken, 110 * USD);
        assertEq(l.premiumPerToken, 3 * USD);
        assertEq(l.expiry, expiry);
    }

    function test_list_refusesZeroTermsAndPastExpiry() public {
        vm.startPrank(seller);
        vm.expectRevert(CoveredCallsV1.ZeroAmount.selector);
        calls.list(0, 110 * USD, 3 * USD, expiry);
        vm.expectRevert(CoveredCallsV1.ZeroAmount.selector);
        calls.list(TOKEN, 0, 3 * USD, expiry);
        vm.expectRevert(CoveredCallsV1.ZeroAmount.selector);
        calls.list(TOKEN, 110 * USD, 0, expiry);
        vm.expectRevert(abi.encodeWithSelector(CoveredCallsV1.ExpiryPassed.selector, uint64(block.timestamp)));
        calls.list(TOKEN, 110 * USD, 3 * USD, uint64(block.timestamp));
        vm.stopPrank();
    }

    function test_list_refusesAScheduledCorporateActionBeforeTheWindowCloses() public {
        uint256 at = uint256(expiry) + 1 days - 1;
        stock.schedule(at);
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(CoveredCallsV1.CorporateActionScheduled.selector, at));
        calls.list(TOKEN, 110 * USD, 3 * USD, expiry);
    }

    function test_list_allowsACorporateActionAfterTheWindowOrAlreadyInThePast() public {
        stock.schedule(uint256(expiry) + 1 days);
        _list();
        stock.schedule(block.timestamp - 1);
        _list();
    }

    function test_list_failsWhenTheSellersStockCannotMove() public {
        stock.setPaused(true);
        vm.prank(seller);
        vm.expectRevert();
        calls.list(TOKEN, 110 * USD, 3 * USD, expiry);
    }

    // ---- fill ----

    function test_fill_paysThePremiumLessOnePercentToTheSellerAndOnePercentToStaking() public {
        uint256 id = _list();
        _fill(buyer, id, 4 * TOKEN);

        // 4 tokens x 3 USDC = 12 USDC; 1% = 0.12 USDC.
        assertEq(usdc.balanceOf(seller), 12 * USD - 120_000);
        assertEq(staking.deposited(), 120_000);
        assertEq(staking.lastTag(), bytes32("autolaunch-covered-calls"));
        assertEq(staking.lastRef(), bytes32(id));
        assertEq(usdc.balanceOf(buyer), 1_000_000 * USD - 12 * USD);
        assertEq(usdc.balanceOf(address(calls)), 0);
        assertEq(calls.held(id, buyer), 4 * TOKEN);
        assertEq(calls.listings(id).filled, 4 * TOKEN);
    }

    function test_fill_partialFillsAddUpAndCannotOversell() public {
        uint256 id = _list();
        _fill(buyer, id, 6 * TOKEN);
        _fill(other, id, 4 * TOKEN);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(CoveredCallsV1.ExceedsAvailable.selector, 1, 0));
        calls.fill(id, 1);
    }

    function test_fill_roundsTheFeeDownAndThePremiumUp() public {
        uint256 id = _list();
        // One raw unit: 3e6 * 1 / 1e8 rounds up to 1 micro-USDC; its 1% fee floors to zero.
        _fill(buyer, id, 1);
        assertEq(usdc.balanceOf(seller), 1);
        assertEq(staking.deposited(), 0);
    }

    function test_fill_closesAtExpiry() public {
        uint256 id = _list();
        vm.warp(expiry);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(CoveredCallsV1.FillsClosed.selector, expiry));
        calls.fill(id, TOKEN);
    }

    function test_fill_refusesWhenACorporateActionIsScheduledAfterListing() public {
        uint256 id = _list();
        stock.schedule(expiry);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(CoveredCallsV1.CorporateActionScheduled.selector, uint256(expiry)));
        calls.fill(id, TOKEN);
    }

    function test_fill_refusesUnknownListingsAndZero() public {
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(CoveredCallsV1.UnknownListing.selector, 7));
        calls.fill(7, TOKEN);
        uint256 id = _list();
        vm.prank(buyer);
        vm.expectRevert(CoveredCallsV1.ZeroAmount.selector);
        calls.fill(id, 0);
    }

    function test_fill_worksWhileStockTransfersArePaused() public {
        uint256 id = _list();
        stock.setPaused(true);
        _fill(buyer, id, TOKEN);
        assertEq(calls.held(id, buyer), TOKEN);
    }

    // ---- cancel ----

    function test_cancel_stopsSalesAndOwesOnlyTheUnsoldPartToTheSeller() public {
        uint256 id = _list();
        _fill(buyer, id, 3 * TOKEN);
        vm.expectEmit(address(calls));
        emit CoveredCallsV1.Cancelled(id, 7 * TOKEN);
        vm.prank(seller);
        calls.cancel(id);
        assertEq(calls.listings(id).amount, 3 * TOKEN);
        assertEq(calls.owed(id, seller), 7 * TOKEN);

        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(CoveredCallsV1.ExceedsAvailable.selector, 1, 0));
        calls.fill(id, 1);
        vm.prank(seller);
        vm.expectRevert(CoveredCallsV1.NothingToCollect.selector);
        calls.cancel(id);

        vm.prank(seller);
        calls.claim(id);
        assertEq(stock.balanceOf(seller), 97 * TOKEN);
        assertEq(stock.balanceOf(address(calls)), 3 * TOKEN);
    }

    function test_cancel_isTheSellersAlone() public {
        uint256 id = _list();
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(CoveredCallsV1.NotSeller.selector, buyer));
        calls.cancel(id);
    }

    function test_cancel_afterTheStockReturnedOwesNothingTwice() public {
        uint256 id = _list();
        _fill(buyer, id, 2 * TOKEN);
        vm.warp(uint256(expiry) + 1 days);
        vm.startPrank(seller);
        calls.claim(id);
        vm.expectRevert(CoveredCallsV1.NothingToCollect.selector);
        calls.cancel(id);
        vm.expectRevert(CoveredCallsV1.NothingToCollect.selector);
        calls.claim(id);
        vm.stopPrank();
        assertEq(stock.balanceOf(seller), 100 * TOKEN);
    }

    function test_cancel_afterTheWindowThenClaimReturnsEachUnitOnce() public {
        uint256 id = _list();
        _fill(buyer, id, 2 * TOKEN);
        vm.warp(expiry);
        vm.prank(buyer);
        calls.exercise(id, TOKEN);
        vm.warp(uint256(expiry) + 1 days);
        vm.startPrank(seller);
        calls.cancel(id); // 8 unsold
        calls.claim(id); // + 1 unexercised
        vm.stopPrank();
        assertEq(stock.balanceOf(seller), 99 * TOKEN);
        assertEq(stock.balanceOf(address(calls)), TOKEN); // the buyer's exercised token
    }

    // ---- exercise, claim, collectStrike: the spec's payoff cases ----

    /// Stock falls to 80: the call is not exercised; the seller keeps the premium and gets the stock back.
    function test_unexercised_sellerKeepsPremiumAndStock() public {
        uint256 id = _list();
        _fill(buyer, id, TOKEN);
        vm.warp(uint256(expiry) + 1 days);
        vm.expectEmit(address(calls));
        emit CoveredCallsV1.StockReturned(id, 10 * TOKEN);
        vm.expectEmit(address(calls));
        emit CoveredCallsV1.Claimed(id, seller, 10 * TOKEN);
        vm.prank(seller);
        calls.claim(id);
        assertEq(stock.balanceOf(seller), 100 * TOKEN);
        assertEq(usdc.balanceOf(seller), 3 * USD - 30_000);
        assertEq(stock.balanceOf(address(calls)), 0);
    }

    /// Stock rises to 120: the buyer pays 110 for each token; the seller gets 110 plus the premium.
    function test_exercised_buyerPaysStrikeForTheStock() public {
        uint256 id = _list();
        _fill(buyer, id, TOKEN);
        vm.warp(expiry);
        vm.expectEmit(address(calls));
        emit CoveredCallsV1.Exercised(id, buyer, TOKEN, 110 * USD);
        vm.prank(buyer);
        calls.exercise(id, TOKEN);
        assertEq(calls.owed(id, buyer), TOKEN);
        assertEq(calls.held(id, buyer), 0);

        vm.prank(buyer);
        calls.claim(id);
        assertEq(stock.balanceOf(buyer), TOKEN);

        vm.expectEmit(address(calls));
        emit CoveredCallsV1.StrikeCollected(id, 110 * USD);
        vm.prank(seller);
        calls.collectStrike(id);
        assertEq(usdc.balanceOf(seller), 110 * USD + 3 * USD - 30_000);

        vm.warp(uint256(expiry) + 1 days);
        vm.prank(seller);
        calls.claim(id);
        assertEq(stock.balanceOf(seller), 99 * TOKEN);
        assertEq(stock.balanceOf(address(calls)), 0);
        assertEq(usdc.balanceOf(address(calls)), 0);
    }

    function test_exercise_onlyInsideTheWindow() public {
        uint256 id = _list();
        _fill(buyer, id, TOKEN);
        vm.warp(uint256(expiry) - 1);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(CoveredCallsV1.OutsideExerciseWindow.selector, expiry));
        calls.exercise(id, TOKEN);
        vm.warp(uint256(expiry) + 1 days - 1);
        vm.prank(buyer);
        calls.exercise(id, 1); // the window's last second
        vm.warp(uint256(expiry) + 1 days);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(CoveredCallsV1.OutsideExerciseWindow.selector, expiry));
        calls.exercise(id, 1);
    }

    function test_exercise_cannotExceedTheHolding() public {
        uint256 id = _list();
        _fill(buyer, id, TOKEN);
        vm.warp(expiry);
        vm.prank(other);
        vm.expectRevert(abi.encodeWithSelector(CoveredCallsV1.ExceedsAvailable.selector, 1, 0));
        calls.exercise(id, 1);
        vm.startPrank(buyer);
        calls.exercise(id, TOKEN / 2);
        vm.expectRevert(abi.encodeWithSelector(CoveredCallsV1.ExceedsAvailable.selector, TOKEN, TOKEN / 2));
        calls.exercise(id, TOKEN);
        vm.stopPrank();
    }

    function test_exercise_roundsTheStrikeUpSoSplittingNeverPaysLess() public {
        uint256 id = _list();
        _fill(buyer, id, TOKEN);
        vm.warp(expiry);
        uint256 before = usdc.balanceOf(buyer);
        vm.startPrank(buyer);
        calls.exercise(id, 1);
        calls.exercise(id, TOKEN - 1);
        vm.stopPrank();
        assertGe(before - usdc.balanceOf(buyer), 110 * USD);
    }

    function test_strikeAnyTimeStockOnlyAfterTheWindow() public {
        uint256 id = _list();
        _fill(buyer, id, 2 * TOKEN);
        vm.warp(expiry);
        vm.prank(buyer);
        calls.exercise(id, TOKEN);

        vm.startPrank(seller);
        calls.collectStrike(id);
        vm.expectRevert(CoveredCallsV1.NothingToCollect.selector);
        calls.collectStrike(id);
        vm.expectRevert(CoveredCallsV1.NothingToCollect.selector);
        calls.claim(id); // nothing owed to the seller inside the window
        assertEq(stock.balanceOf(seller), 90 * TOKEN);

        vm.warp(uint256(expiry) + 1 days);
        calls.claim(id);
        assertEq(stock.balanceOf(seller), 99 * TOKEN); // 8 unsold + 1 unexercised back
        vm.expectRevert(CoveredCallsV1.NothingToCollect.selector);
        calls.claim(id);
        vm.stopPrank();
    }

    function test_collectStrike_isTheSellersAlone() public {
        uint256 id = _list();
        vm.warp(uint256(expiry) + 1 days);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(CoveredCallsV1.NotSeller.selector, buyer));
        calls.collectStrike(id);
    }

    function test_claim_refusesNothingOwedAndNeverPaysAnotherAccount() public {
        uint256 id = _list();
        _fill(buyer, id, TOKEN);
        vm.warp(uint256(expiry) + 1 days);
        vm.prank(buyer);
        vm.expectRevert(CoveredCallsV1.NothingToCollect.selector);
        calls.claim(id); // the unexercised stock is the seller's, not the buyer's
    }

    /// A seller who buys and exercises on their own listing keeps exact books and loses only the fee.
    function test_selfDealing_sellerFillingOwnListingLosesOnlyTheFee() public {
        usdc.mint(seller, 1_000 * USD);
        vm.prank(seller);
        usdc.approve(address(calls), type(uint256).max);
        uint256 id = _list();
        _fill(seller, id, TOKEN);
        vm.warp(expiry);
        vm.startPrank(seller);
        calls.exercise(id, TOKEN);
        calls.collectStrike(id);
        vm.warp(uint256(expiry) + 1 days);
        calls.claim(id);
        vm.stopPrank();
        assertEq(stock.balanceOf(seller), 100 * TOKEN);
        assertEq(usdc.balanceOf(seller), 1_000 * USD - 30_000);
    }

    // ---- what the tokens can refuse ----

    /// A transfer pause during the window never takes away the right to exercise; the stock waits.
    function test_pause_exerciseStillWorksAndTheStockWaitsForTheClaim() public {
        uint256 id = _list();
        _fill(buyer, id, TOKEN);
        vm.warp(expiry);
        stock.setPaused(true);
        vm.prank(buyer);
        calls.exercise(id, TOKEN);

        vm.prank(buyer);
        vm.expectRevert(SafeTransferLib.TransferFailed.selector);
        calls.claim(id);

        vm.warp(uint256(expiry) + 30 days);
        stock.setPaused(false);
        vm.prank(buyer);
        calls.claim(id);
        assertEq(stock.balanceOf(buyer), TOKEN);
    }

    /// A blocklisted buyer cannot take stock out, and that never blocks the seller's own collection.
    function test_blocklist_aBlockedHolderDoesNotStopTheSeller() public {
        uint256 id = _list();
        _fill(buyer, id, TOKEN);
        vm.warp(expiry);
        vm.prank(buyer);
        calls.exercise(id, TOKEN);
        stock.setBlocked(buyer, true);

        vm.prank(buyer);
        vm.expectRevert(SafeTransferLib.TransferFailed.selector);
        calls.claim(id);

        vm.warp(uint256(expiry) + 1 days);
        vm.startPrank(seller);
        calls.claim(id);
        calls.collectStrike(id);
        vm.stopPrank();
        assertEq(stock.balanceOf(seller), 99 * TOKEN);
        assertEq(usdc.balanceOf(seller), 110 * USD + 3 * USD - 30_000);
        assertEq(stock.balanceOf(address(calls)), TOKEN); // still owed to the buyer
    }

    // ---- fuzz: amounts ----

    function testFuzz_premiumAndStrikeRoundUpAndFeeIsOnePercentFloored(
        uint256 amount,
        uint256 premiumPerToken,
        uint256 strikePerToken
    ) public {
        amount = bound(amount, 1, 10 * TOKEN);
        premiumPerToken = bound(premiumPerToken, 1, 10_000 * USD);
        strikePerToken = bound(strikePerToken, 1, 100_000 * USD);
        vm.prank(seller);
        uint256 id = calls.list(10 * TOKEN, strikePerToken, premiumPerToken, expiry);
        usdc.mint(buyer, 10_000_000_000 * USD);

        uint256 premium = calls.premiumFor(id, amount);
        assertGe(premium * TOKEN, amount * premiumPerToken);
        assertLt(premium * TOKEN, amount * premiumPerToken + TOKEN);

        _fill(buyer, id, amount);
        assertEq(staking.deposited(), premium / 100);
        assertEq(usdc.balanceOf(seller), premium - premium / 100);

        uint256 strike = calls.strikeFor(id, amount);
        assertGe(strike * TOKEN, amount * strikePerToken);
        assertLt(strike * TOKEN, amount * strikePerToken + TOKEN);
    }
}
