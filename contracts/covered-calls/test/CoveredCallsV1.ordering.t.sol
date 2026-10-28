// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {CoveredCallsV1} from "../src/CoveredCallsV1.sol";
import {B20Double, StakingDouble, UsdcDouble} from "./doubles/Doubles.sol";
import {WeeklyExpiry} from "./doubles/WeeklyExpiry.sol";

/// @notice Cancel, claim and the after-window return in every order, from the adversarial review's
///         second pass (28 Oct 2026). Each test is an attack on paying a unit twice, touching another
///         listing or another account, or blocking a party; each was checked to fail on a
///         deliberately broken contract.
contract CoveredCallsV1OrderingTest is Test {
    uint256 internal constant TOKEN = 1e8;
    uint256 internal constant USD = 1e6;
    uint64 internal expiry;
    uint256 internal windowEnd;

    B20Double internal stock;
    UsdcDouble internal usdc;
    StakingDouble internal staking;
    CoveredCallsV1 internal calls;

    address internal seller = makeAddr("seller");
    address internal buyer = makeAddr("buyer");
    address internal stranger = makeAddr("stranger");
    address internal bystander = makeAddr("bystander");

    function setUp() public {
        vm.warp(1_800_000_000);
        expiry = WeeklyExpiry.next(block.timestamp, 0);
        windowEnd = uint256(expiry) + 1 days;
        stock = new B20Double();
        usdc = new UsdcDouble();
        staking = new StakingDouble(usdc);
        calls = new CoveredCallsV1(address(stock), address(usdc), address(staking));

        stock.mint(seller, 100 * TOKEN);
        // Another seller's listing, so any overpayment to our seller would find stock to take.
        stock.mint(bystander, 50 * TOKEN);
        vm.startPrank(bystander);
        stock.approve(address(calls), type(uint256).max);
        calls.list(50 * TOKEN, 110 * USD, 3 * USD, WeeklyExpiry.next(block.timestamp, 4));
        vm.stopPrank();
        address[3] memory accounts = [seller, buyer, stranger];
        for (uint256 i; i < 3; ++i) {
            usdc.mint(accounts[i], 1_000_000 * USD);
            vm.startPrank(accounts[i]);
            stock.approve(address(calls), type(uint256).max);
            usdc.approve(address(calls), type(uint256).max);
            vm.stopPrank();
        }
    }

    /// The after-window return already includes the never-cancelled remainder, so a cancel after it
    /// must not credit that remainder again (which would pay it out of the bystander's listing).
    function test_2p_cancelAfterTheReturnCannotDrainAnotherListing() public {
        uint256 id = _list(10 * TOKEN);
        _as(buyer);
        calls.fill(id, 4 * TOKEN);
        vm.warp(windowEnd);
        _as(seller);
        calls.claim(id);
        assertEq(stock.balanceOf(seller), 100 * TOKEN);
        _as(seller);
        vm.expectRevert(CoveredCallsV1.NothingToCollect.selector);
        calls.cancel(id);
        assertEq(stock.balanceOf(address(calls)), 50 * TOKEN);
    }

    function _list(uint256 amount) internal returns (uint256 id) {
        vm.prank(seller);
        id = calls.list(amount, 110 * USD, 3 * USD, expiry);
    }

    function _as(address who) internal {
        vm.prank(who);
    }

    /// Cancel, claim the cancelled part inside the window, then the after-window return: each unit
    /// once, and nothing a holder is owed reaches the seller.
    function test_2p_cancelThenClaimThenAfterWindowPaysEachUnitOnce() public {
        uint256 id = _list(10 * TOKEN);
        _as(buyer);
        calls.fill(id, 4 * TOKEN);
        _as(seller);
        calls.cancel(id);
        assertEq(calls.owed(id, seller), 6 * TOKEN);

        vm.warp(expiry);
        _as(seller);
        calls.claim(id); // the cancelled six, inside the window: no after-window booking yet
        assertEq(stock.balanceOf(seller), 96 * TOKEN);
        assertFalse(calls.listings(id).stockReturned);
        _as(buyer);
        calls.exercise(id, 1 * TOKEN);

        vm.warp(windowEnd);
        _as(seller);
        calls.claim(id); // the three sold and not exercised
        assertEq(stock.balanceOf(seller), 99 * TOKEN);

        _as(seller);
        vm.expectRevert(CoveredCallsV1.NothingToCollect.selector);
        calls.cancel(id);
        _as(seller);
        vm.expectRevert(CoveredCallsV1.NothingToCollect.selector);
        calls.claim(id);
        assertEq(stock.balanceOf(address(calls)), 51 * TOKEN); // still the buyer's
        _as(buyer);
        calls.claim(id);
        assertEq(stock.balanceOf(address(calls)), 50 * TOKEN);
    }

    /// Cancel after the window closes but before the seller's first claim: the uncancelled remainder
    /// is not counted twice (once by cancel, once by the after-window return).
    function test_2p_cancelAfterTheWindowBeforeClaimCountsEachUnitOnce() public {
        uint256 id = _list(10 * TOKEN);
        _as(buyer);
        calls.fill(id, 4 * TOKEN);
        vm.warp(windowEnd + 7 days);
        _as(seller);
        calls.cancel(id);
        _as(seller);
        calls.claim(id);
        assertEq(stock.balanceOf(seller), 100 * TOKEN);
        assertEq(stock.balanceOf(address(calls)), 50 * TOKEN);
    }

    /// A seller who is also a holder on its own listing shares one `owed` balance; the sum is exact
    /// and the other holder's stock is untouched.
    function test_2p_sellerWhoIsAlsoAHolderGetsExactlyItsOwn() public {
        uint256 id = _list(10 * TOKEN);
        _as(seller);
        calls.fill(id, 4 * TOKEN);
        _as(buyer);
        calls.fill(id, 3 * TOKEN);
        _as(seller);
        calls.cancel(id); // 3 unsold
        vm.warp(expiry);
        _as(seller);
        calls.exercise(id, 2 * TOKEN);
        _as(buyer);
        calls.exercise(id, 1 * TOKEN);

        _as(seller);
        calls.claim(id); // 3 cancelled + 2 exercised
        assertEq(stock.balanceOf(seller), 95 * TOKEN);

        vm.warp(windowEnd);
        _as(seller);
        calls.claim(id); // 7 listed after cancel - 3 exercised = 4 (2 of the seller's own calls, 2 of the buyer's)
        assertEq(stock.balanceOf(seller), 99 * TOKEN);
        assertEq(calls.owed(id, buyer), 1 * TOKEN);
        assertEq(stock.balanceOf(address(calls)), 51 * TOKEN);
    }

    /// A seller who never claims keeps nobody else waiting: holders claim, the strike is collected,
    /// and the contract holds exactly the seller's unexercised stock, forever claimable.
    function test_2p_sellerWhoNeverClaimsBlocksNobody() public {
        uint256 id = _list(10 * TOKEN);
        _as(buyer);
        calls.fill(id, 5 * TOKEN);
        vm.warp(expiry);
        _as(buyer);
        calls.exercise(id, 2 * TOKEN);
        vm.warp(windowEnd + 3650 days);
        _as(buyer);
        calls.claim(id);
        _as(seller);
        calls.collectStrike(id);
        assertEq(stock.balanceOf(address(calls)), 58 * TOKEN);
        assertEq(usdc.balanceOf(address(calls)), 0);
        _as(seller);
        calls.claim(id);
        assertEq(stock.balanceOf(seller), 98 * TOKEN);
    }

    /// Nobody but the seller can trigger the after-window booking, and a stranger's claim changes
    /// nothing.
    function test_2p_strangerClaimCannotTouchTheListing() public {
        uint256 id = _list(10 * TOKEN);
        _as(buyer);
        calls.fill(id, 5 * TOKEN);
        vm.warp(windowEnd);
        _as(stranger);
        vm.expectRevert(CoveredCallsV1.NothingToCollect.selector);
        calls.claim(id);
        _as(buyer);
        vm.expectRevert(CoveredCallsV1.NothingToCollect.selector);
        calls.claim(id); // unexercised calls are worth nothing after the window
        assertFalse(calls.listings(id).stockReturned);
        assertEq(calls.owed(id, seller), 0);
    }

    /// The window boundary is shared exactly: at `expiry + 1 day` exercising is closed and the
    /// return opens, never both in one second.
    function test_2p_returnOpensTheSecondExercisingCloses() public {
        uint256 id = _list(10 * TOKEN);
        _as(buyer);
        calls.fill(id, 10 * TOKEN);
        vm.warp(windowEnd - 1);
        _as(seller);
        vm.expectRevert(CoveredCallsV1.NothingToCollect.selector);
        calls.claim(id);
        vm.warp(windowEnd);
        _as(buyer);
        vm.expectRevert(abi.encodeWithSelector(CoveredCallsV1.OutsideExerciseWindow.selector, expiry));
        calls.exercise(id, 1);
        _as(seller);
        calls.claim(id);
        assertEq(stock.balanceOf(seller), 100 * TOKEN);
    }

    /// Informational for the indexer: when every sold unit was exercised but a cancelled remainder is
    /// still owed, the seller's after-window claim emits `StockReturned(id, 0)` before `Claimed`.
    /// And until that claim, `owed(id, seller)` shows only the cancelled part, not the stock due back.
    function test_2p_indexerSeesAZeroStockReturnedAndALazyOwed() public {
        uint256 id = _list(10 * TOKEN);
        _as(buyer);
        calls.fill(id, 4 * TOKEN);
        _as(seller);
        calls.cancel(id);
        vm.warp(expiry);
        _as(buyer);
        calls.exercise(id, 4 * TOKEN);
        vm.warp(windowEnd);

        vm.expectEmit(address(calls));
        emit CoveredCallsV1.StockReturned(id, 0);
        vm.expectEmit(address(calls));
        emit CoveredCallsV1.Claimed(id, seller, 6 * TOKEN);
        _as(seller);
        calls.claim(id);

        // After its window, `owed` shows 0 for the seller of an unsold listing although 5 tokens are
        // due; `claimable` shows the 5 that `claim` will pay.
        vm.prank(seller);
        uint64 expiry2 = WeeklyExpiry.next(block.timestamp, 0);
        uint256 id2 = calls.list(5 * TOKEN, 110 * USD, 3 * USD, expiry2);
        vm.warp(uint256(expiry2) + calls.EXERCISE_WINDOW());
        assertEq(calls.owed(id2, seller), 0);
        assertEq(calls.claimable(id2, seller), 5 * TOKEN);
        assertEq(calls.claimable(id2, buyer), 0);
        _as(seller);
        calls.claim(id2);
        assertEq(stock.balanceOf(seller), 100 * TOKEN - 4 * TOKEN);
    }

    /// Model check: random fractional fills by the seller and two others, cancel at a random point
    /// (before, during or after the window), exercises, and claims in random order and repetition.
    /// Every account ends with exactly its own stock and the contract ends empty.
    function testFuzz_2p_everyUnitPaidOnceWhateverTheOrder(uint256 seed) public {
        uint256 listed = 10 * TOKEN + (seed % 1e8);
        uint256 id = _list(listed);
        address[3] memory who = [seller, buyer, stranger];
        uint256[3] memory exercisedBy;
        uint256 cancelStage = seed % 4; // 0 none, 1 before expiry, 2 inside window, 3 after window

        for (uint256 i; i < 6; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            CoveredCallsV1.Listing memory l = calls.listings(id);
            if (l.amount == l.filled) break;
            _as(who[seed % 3]);
            calls.fill(id, bound(seed >> 8, 1, l.amount - l.filled));
        }
        if (cancelStage == 1) _tryCancel(id);
        _tryClaimAll(id, seed);

        vm.warp(uint256(expiry) + (seed >> 40) % 1 days);
        if (cancelStage == 2) _tryCancel(id);
        for (uint256 k; k < 3; ++k) {
            uint256 h = calls.held(id, who[k]);
            uint256 x = h == 0 ? 0 : bound(uint256(keccak256(abi.encode(seed, k))), 0, h);
            if (x == 0) continue;
            exercisedBy[k] = x;
            _as(who[k]);
            calls.exercise(id, x);
        }
        _tryClaimAll(id, seed >> 3);

        vm.warp(windowEnd + (seed >> 80) % 30 days);
        if (cancelStage == 3) _tryCancel(id);
        _tryClaimAll(id, seed >> 5);
        _tryClaimAll(id, seed >> 7);
        _tryCancel(id);
        _tryClaimAll(id, seed >> 9);

        uint256 exercisedTotal = exercisedBy[0] + exercisedBy[1] + exercisedBy[2];
        assertEq(stock.balanceOf(seller), 100 * TOKEN - exercisedTotal + exercisedBy[0]);
        assertEq(stock.balanceOf(buyer), exercisedBy[1]);
        assertEq(stock.balanceOf(stranger), exercisedBy[2]);
        assertEq(stock.balanceOf(address(calls)), 50 * TOKEN); // only the bystander's listing
        assertTrue(calls.listings(id).stockReturned || calls.listings(id).amount == calls.listings(id).exercised);
    }

    function _tryCancel(uint256 id) internal {
        _as(seller);
        try calls.cancel(id) {} catch {}
    }

    function _tryClaimAll(uint256 id, uint256 order) internal {
        address[3] memory who = [seller, buyer, stranger];
        for (uint256 k; k < 3; ++k) {
            _as(who[(order + k) % 3]);
            try calls.claim(id) {} catch {}
        }
    }
}
