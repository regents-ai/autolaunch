// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {CoveredCallsV1} from "../src/CoveredCallsV1.sol";
import {B20Double, StakingDouble, UsdcDouble} from "./doubles/Doubles.sol";

/// @notice The Friday 21:00 UTC expiry rule, the fee rounding up, and the `claimable` view, from the
///         adversarial review's third pass (28 Oct 2026): attack attempts and independent
///         recomputations, each checked to fail on a deliberately broken contract.
contract CoveredCallsV1RulesTest is Test {
    uint256 internal constant TOKEN = 1e8;
    uint256 internal constant USD = 1e6;
    /// 2026-10-30 21:00:00 UTC, a Friday (checked independently with Python's calendar).
    uint64 internal constant FRI_2026_10_30_2100 = 1_793_394_000;

    B20Double internal stock;
    UsdcDouble internal usdc;
    StakingDouble internal staking;
    CoveredCallsV1 internal calls;

    address internal seller = makeAddr("seller");
    address internal buyer = makeAddr("buyer");
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        vm.warp(1_793_000_000); // Sunday 2026-10-26
        stock = new B20Double();
        usdc = new UsdcDouble();
        staking = new StakingDouble(usdc);
        calls = new CoveredCallsV1(address(stock), address(usdc), address(staking));
        stock.mint(seller, 1_000 * TOKEN);
        address[3] memory accounts = [seller, buyer, stranger];
        for (uint256 i; i < 3; ++i) {
            usdc.mint(accounts[i], 1_000_000_000 * USD);
            vm.startPrank(accounts[i]);
            stock.approve(address(calls), type(uint256).max);
            usdc.approve(address(calls), type(uint256).max);
            vm.stopPrank();
        }
    }

    function _list(uint256 amount, uint256 premiumPerToken, uint64 expiry) internal returns (uint256 id) {
        vm.prank(seller);
        id = calls.list(amount, 110 * USD, premiumPerToken, expiry);
    }

    // ---- 1. weekly expiry ----

    /// Calendar weekday (0 = Sunday … 5 = Friday) and second of day, worked out independently.
    function _weekday(uint256 t) internal pure returns (uint256) {
        return (t / 1 days + 4) % 7; // 1970-01-01 was a Thursday (4)
    }

    function test_3p_onlyFridayAt2100UtcIsAccepted() public {
        assertEq(_weekday(FRI_2026_10_30_2100), 5);
        assertEq(FRI_2026_10_30_2100 % 1 days, 21 hours);
        _list(TOKEN, 3 * USD, FRI_2026_10_30_2100);
        _list(TOKEN, 3 * USD, FRI_2026_10_30_2100 + 1 weeks);

        uint64[6] memory refused = [
            FRI_2026_10_30_2100 - 1,
            FRI_2026_10_30_2100 + 1,
            FRI_2026_10_30_2100 - 1 hours, // the US close in summer (20:00 UTC)
            FRI_2026_10_30_2100 - 1 days, // Thursday 21:00
            FRI_2026_10_30_2100 + 1 days, // Saturday 21:00
            FRI_2026_10_30_2100 + 3 days + 12 hours // Monday 09:00
        ];
        for (uint256 i; i < refused.length; ++i) {
            vm.prank(seller);
            vm.expectRevert(abi.encodeWithSelector(CoveredCallsV1.NotAWeeklyExpiry.selector, refused[i]));
            calls.list(TOKEN, 110 * USD, 3 * USD, refused[i]);
        }
    }

    /// Any expiry the contract accepts is a future Friday at exactly 21:00:00 UTC, and every future
    /// Friday 21:00 is accepted, up to the largest one a uint64 can hold.
    function testFuzz_3p_acceptedExactlyWhenAFutureFridayAt2100(uint64 expiry, uint8 snap) public {
        // Most draws snap near some week's 1 day 21 hours mark (exact, or off by a second or an
        // hour), so the accepted branch is exercised, not just the 1-in-604,800 random hit.
        if (snap % 4 != 0 && expiry > 2 weeks) {
            uint256 snapped = uint256(expiry) - uint256(expiry) % 1 weeks + 1 days + 21 hours;
            int256[4] memory nudge = [int256(0), int256(-1), int256(1), int256(-1 hours)];
            expiry = uint64(uint256(int256(snapped) + nudge[(snap >> 2) % 4]) - 1 weeks);
        }
        bool friday2100 = _weekday(expiry) == 5 && expiry % 1 days == 21 hours;
        bool future = expiry > block.timestamp;
        vm.prank(seller);
        try calls.list(1, 110 * USD, 3 * USD, expiry) {
            assertTrue(friday2100 && future);
        } catch {
            assertFalse(friday2100 && future);
        }
    }

    function test_3p_largestWeeklyExpiryStillWorksThroughTheWindow() public {
        uint64 last = uint64(type(uint64).max - (type(uint64).max - 1 days - 21 hours) % 1 weeks);
        assertEq(_weekday(last), 5);
        uint256 id = _list(TOKEN, 3 * USD, last);
        vm.prank(buyer);
        calls.fill(id, TOKEN);
        vm.warp(uint256(last) + 1 days);
        vm.prank(seller);
        calls.claim(id);
        assertEq(stock.balanceOf(seller), 1_000 * TOKEN);
    }

    /// The window is Friday 21:00 to Saturday 21:00 UTC. A corporate action effective Saturday
    /// 20:59:59 is refused; one effective at Saturday 21:00 or Monday's open is allowed.
    function test_3p_corporateActionAgainstTheWeekendWindow() public {
        uint64 e = FRI_2026_10_30_2100;
        stock.schedule(uint256(e) + 1 days - 1);
        vm.prank(seller);
        vm.expectRevert(
            abi.encodeWithSelector(CoveredCallsV1.CorporateActionScheduled.selector, uint256(e) + 1 days - 1)
        );
        calls.list(TOKEN, 110 * USD, 3 * USD, e);
        stock.schedule(uint256(e) + 1 days);
        _list(TOKEN, 3 * USD, e);
        stock.schedule(uint256(e) + 2 days + 16 hours + 30 minutes); // Monday 13:30 UTC
        _list(TOKEN, 3 * USD, e);
    }

    // ---- 2. fee rounds up ----

    /// A 1 micro-USDC premium is all fee: the seller gets 0 (a zero-value transfer that succeeds).
    function test_3p_oneMicroPremiumIsAllFee() public {
        uint256 id = _list(10 * TOKEN, 3 * USD, FRI_2026_10_30_2100);
        uint256 before = usdc.balanceOf(seller);
        vm.prank(buyer);
        calls.fill(id, 1); // premium ceil(1 * 3e6 / 1e8) = 1
        assertEq(staking.deposited(), 1);
        assertEq(usdc.balanceOf(seller), before);
        assertEq(calls.held(id, buyer), 1);
    }

    /// Fee is ceil(1%), never more than the premium, and premium = seller + staking exactly, for
    /// every premium from 1 micro-USDC up.
    function testFuzz_3p_feeIsCeilOnePercentAndNeverExceedsThePremium(uint256 amount, uint256 premiumPerToken) public {
        amount = bound(amount, 1, 1_000 * TOKEN);
        premiumPerToken = bound(premiumPerToken, 1, 100_000 * USD);
        uint256 id = _list(1_000 * TOKEN, premiumPerToken, FRI_2026_10_30_2100);
        uint256 premium = calls.premiumFor(id, amount);
        uint256 sellerBefore = usdc.balanceOf(seller);
        uint256 buyerBefore = usdc.balanceOf(buyer);
        vm.prank(buyer);
        calls.fill(id, amount);
        uint256 fee = staking.deposited();
        assertLe(fee, premium);
        assertGe(fee * 100, premium);
        assertLt(fee * 100, premium + 100);
        assertEq(buyerBefore - usdc.balanceOf(buyer), premium);
        assertEq(usdc.balanceOf(seller) - sellerBefore + fee, premium);
        assertEq(usdc.balanceOf(address(calls)), 0);
        assertEq(usdc.allowance(address(calls), address(staking)), 0);
    }

    /// Informational: with the fee never zero, a refusing staking contract now stops every fill,
    /// including the tiny ones that used to carry no fee.
    function test_3p_stakingRefusalNowStopsEvenTinyFills() public {
        uint256 id = _list(10 * TOKEN, 3 * USD, FRI_2026_10_30_2100);
        staking.setRefuses(true);
        vm.prank(buyer);
        vm.expectRevert(bytes("staking paused"));
        calls.fill(id, 1);
    }

    // ---- 3. claimable equals what claim pays ----

    function _checkClaimableMatchesClaim(uint256[] memory ids) internal {
        address[3] memory who = [seller, buyer, stranger];
        uint256[3][] memory shown = new uint256[3][](ids.length);
        for (uint256 j; j < ids.length; ++j) {
            for (uint256 k; k < 3; ++k) {
                shown[j][k] = calls.claimable(ids[j], who[k]);
            }
        }
        for (uint256 j; j < ids.length; ++j) {
            for (uint256 k; k < 3; ++k) {
                uint256 before = stock.balanceOf(who[k]);
                vm.prank(who[k]);
                try calls.claim(ids[j]) {
                    assertEq(stock.balanceOf(who[k]) - before, shown[j][k], "claim paid other than claimable");
                } catch (bytes memory reason) {
                    assertEq(shown[j][k], 0, "claimable showed stock but claim reverted");
                    assertEq(bytes4(reason), CoveredCallsV1.NothingToCollect.selector);
                }
                assertEq(calls.claimable(ids[j], who[k]), 0, "claimable not zero right after a claim");
            }
        }
    }

    /// Two listings (one where the seller is also a holder), random fractional fills, cancels at
    /// random stages, exercises, and claimable checked against claim at five moments.
    function testFuzz_3p_claimableIsWhatClaimPays(uint256 seed) public {
        uint256[] memory ids = new uint256[](2);
        ids[0] = _list(10 * TOKEN + seed % 1e8, 3 * USD, FRI_2026_10_30_2100);
        ids[1] = _list(7 * TOKEN + (seed >> 30) % 1e8, 1, FRI_2026_10_30_2100);
        address[3] memory who = [seller, buyer, stranger];

        for (uint256 i; i < 8; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            uint256 id = ids[seed % 2];
            CoveredCallsV1.Listing memory l = calls.listings(id);
            if (l.amount == l.filled) continue;
            vm.prank(who[(seed >> 4) % 3]);
            calls.fill(id, bound(seed >> 8, 1, l.amount - l.filled));
        }
        if (seed % 3 == 0) _tryCancel(ids[0]);
        _checkClaimableMatchesClaim(ids);

        vm.warp(FRI_2026_10_30_2100 + (seed >> 20) % 1 days);
        if (seed % 3 == 1) _tryCancel(ids[1]);
        for (uint256 j; j < 2; ++j) {
            for (uint256 k; k < 3; ++k) {
                uint256 h = calls.held(ids[j], who[k]);
                uint256 x = h == 0 ? 0 : bound(uint256(keccak256(abi.encode(seed, j, k))), 0, h);
                if (x == 0) continue;
                vm.prank(who[k]);
                calls.exercise(ids[j], x);
            }
        }
        _checkClaimableMatchesClaim(ids);

        vm.warp(uint256(FRI_2026_10_30_2100) + 1 days - 1);
        _checkClaimableMatchesClaim(ids);
        vm.warp(uint256(FRI_2026_10_30_2100) + 1 days);
        if (seed % 3 == 2) _tryCancel(ids[0]);
        _checkClaimableMatchesClaim(ids);
        _tryCancel(ids[1]);
        _checkClaimableMatchesClaim(ids);
        assertEq(stock.balanceOf(address(calls)), 0);
    }

    function _tryCancel(uint256 id) internal {
        vm.prank(seller);
        try calls.cancel(id) {} catch {}
    }

    /// Informational: `claimable` reports what is owed, not whether the transfer can go through
    /// now; while the stock is paused it shows 10 tokens and `claim` reverts.
    function test_3p_claimableShowsOwedEvenWhileTheStockIsPaused() public {
        uint256 id = _list(10 * TOKEN, 3 * USD, FRI_2026_10_30_2100);
        vm.warp(uint256(FRI_2026_10_30_2100) + 1 days);
        stock.setPaused(true);
        assertEq(calls.claimable(id, seller), 10 * TOKEN);
        vm.prank(seller);
        vm.expectRevert();
        calls.claim(id);
        vm.expectRevert(abi.encodeWithSelector(CoveredCallsV1.UnknownListing.selector, 99));
        calls.claimable(99, seller);
    }
}
