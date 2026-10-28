// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test, console} from "forge-std/Test.sol";

import {CoveredCallsV1} from "../src/CoveredCallsV1.sol";
import {B20Double, StakingDouble, UsdcDouble} from "./doubles/Doubles.sol";
import {WeeklyExpiry} from "./doubles/WeeklyExpiry.sol";

/// @notice Drives random sequences of every call by several accounts across time, with the stock's
///         transfer pause and blocklist, USDC's pause and blacklist, scheduled corporate actions and a
///         refusing staking contract switched on and off, and keeps the books the contract must match.
contract CoveredCallsHandler is Test {
    CoveredCallsV1 public immutable calls;
    B20Double public immutable stock;
    UsdcDouble public immutable usdc;
    StakingDouble public immutable staking;

    address[] public actors;
    mapping(uint256 listingId => uint256) public listedOf;
    mapping(uint256 listingId => uint256) public claimedOf;
    uint256 public feesExpected;
    /// Claims that paid something other than what `claimable` showed just before; must stay zero.
    uint256 public claimMismatches;
    /// Successful calls of each kind, so a run that never reaches an action is visible.
    mapping(bytes4 selector => uint256) public succeeded;

    constructor(CoveredCallsV1 calls_, B20Double stock_, UsdcDouble usdc_, StakingDouble staking_) {
        calls = calls_;
        stock = stock_;
        usdc = usdc_;
        staking = staking_;
        for (uint256 i; i < 4; ++i) {
            address actor = address(uint160(0xA000 + i));
            actors.push(actor);
            stock.mint(actor, 1_000e8);
            usdc.mint(actor, 1e15);
            vm.startPrank(actor);
            stock.approve(address(calls), type(uint256).max);
            usdc.approve(address(calls), type(uint256).max);
            vm.stopPrank();
        }
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _someListing(uint256 seed) internal view returns (uint256) {
        uint256 count = calls.listingCount();
        return count == 0 ? 0 : 1 + seed % count;
    }

    function list(uint256 who, uint256 amount, uint256 strike, uint256 premium, uint256 weeksAhead) external {
        amount = bound(amount, 1, 50e8);
        strike = bound(strike, 1, 1_000e6);
        premium = bound(premium, 1, 100e6);
        uint64 expiry = WeeklyExpiry.next(block.timestamp, bound(weeksAhead, 0, 2));
        vm.prank(_actor(who));
        try calls.list(amount, strike, premium, expiry) returns (uint256 id) {
            listedOf[id] = amount;
            ++succeeded[this.list.selector];
        } catch {}
    }

    function fill(uint256 who, uint256 listingSeed, uint256 amount) external {
        uint256 id = _someListing(listingSeed);
        if (id == 0) return;
        CoveredCallsV1.Listing memory l = calls.listings(id);
        if (l.amount == l.filled) return;
        amount = bound(amount, 1, l.amount - l.filled);
        // The premium, worked out here from the listing's terms, not read from the contract.
        uint256 premium = (amount * l.premiumPerToken + 1e8 - 1) / 1e8;
        vm.prank(_actor(who));
        try calls.fill(id, amount) {
            feesExpected += (premium + 99) / 100;
            ++succeeded[this.fill.selector];
        } catch {}
    }

    function cancel(uint256 listingSeed) external {
        uint256 id = _someListing(listingSeed);
        if (id == 0) return;
        vm.prank(calls.listings(id).seller);
        try calls.cancel(id) {
            ++succeeded[this.cancel.selector];
        } catch {}
    }

    function exercise(uint256 who, uint256 listingSeed, uint256 amount, uint256 into) external {
        uint256 id = _someListing(listingSeed);
        if (id == 0) return;
        address holder = _actor(who);
        uint256 holding = calls.held(id, holder);
        if (holding == 0) return;
        // Time only moves forward: step into the listing's exercise window when it is still ahead.
        uint256 expiry = calls.listings(id).expiry;
        if (block.timestamp < expiry) vm.warp(expiry + bound(into, 0, 1 days - 1));
        vm.prank(holder);
        try calls.exercise(id, bound(amount, 1, holding)) {
            ++succeeded[this.exercise.selector];
        } catch {}
    }

    /// Half the time the seller claims, stepping past the window first when asked; otherwise an
    /// account owed stock on the listing claims.
    function claim(uint256 who, uint256 listingSeed, bool sellerAfterWindow) external {
        uint256 id = _someListing(listingSeed);
        if (id == 0) return;
        address account;
        if (who % 2 == 0) {
            account = calls.listings(id).seller;
            uint256 windowEnd = uint256(calls.listings(id).expiry) + calls.EXERCISE_WINDOW();
            if (sellerAfterWindow && block.timestamp < windowEnd) vm.warp(windowEnd);
        } else {
            account = _actor(who);
            for (uint256 i; i < actors.length && calls.owed(id, account) == 0; ++i) {
                account = _actor(who % actors.length + i);
            }
        }
        uint256 before = stock.balanceOf(account);
        uint256 shown = calls.claimable(id, account);
        vm.prank(account);
        try calls.claim(id) {
            uint256 paid = stock.balanceOf(account) - before;
            claimedOf[id] += paid;
            if (paid != shown) ++claimMismatches;
            ++succeeded[this.claim.selector];
        } catch {}
    }

    function collectStrike(uint256 listingSeed) external {
        uint256 id = _someListing(listingSeed);
        if (id == 0) return;
        vm.prank(calls.listings(id).seller);
        try calls.collectStrike(id) {
            ++succeeded[this.collectStrike.selector];
        } catch {}
    }

    function passTime(uint256 seconds_) external {
        vm.warp(block.timestamp + bound(seconds_, 1, 6 hours));
    }

    /// Switches one restriction on (one time in four) or off: the stock's transfer pause or blocklist
    /// on an actor, USDC's pause or blacklist on an actor, or staking refusing deposits.
    function restrict(uint256 seed, uint256 who) external {
        bool on = seed % 4 == 0;
        uint256 kind = (seed / 4) % 5;
        if (kind == 0) stock.setPaused(on);
        else if (kind == 1) stock.setBlocked(_actor(who), on);
        else if (kind == 2) usdc.setPaused(on);
        else if (kind == 3) usdc.setBlacklisted(_actor(who), on);
        else staking.setRefuses(on);
    }

    /// Schedules a corporate action up to 20 days out one time in eight, and otherwise clears it.
    function scheduleCorporateAction(uint256 inSeconds) external {
        stock.schedule(inSeconds % 8 == 0 ? block.timestamp + bound(inSeconds, 0, 20 days) : 0);
    }

    /// Lifts every restriction, moves past every exercise window and has every account take all it is
    /// owed. Called once a run ends.
    function recoverEverything() external {
        stock.setPaused(false);
        usdc.setPaused(false);
        for (uint256 a; a < actors.length; ++a) {
            stock.setBlocked(actors[a], false);
            usdc.setBlacklisted(actors[a], false);
        }
        vm.warp(block.timestamp + 22 days + calls.EXERCISE_WINDOW());
        for (uint256 id = 1; id <= calls.listingCount(); ++id) {
            CoveredCallsV1.Listing memory l = calls.listings(id);
            if (l.strikePaid != l.strikeCollected) {
                vm.prank(l.seller);
                calls.collectStrike(id);
            }
            for (uint256 a; a < actors.length; ++a) {
                address account = actors[a];
                bool sellerStockDue = account == l.seller && !l.stockReturned && l.amount != l.exercised;
                if (calls.owed(id, account) != 0 || sellerStockDue) {
                    uint256 before = stock.balanceOf(account);
                    vm.prank(account);
                    calls.claim(id);
                    claimedOf[id] += stock.balanceOf(account) - before;
                }
            }
        }
    }
}

contract CoveredCallsV1InvariantTest is Test {
    CoveredCallsV1 internal calls;
    B20Double internal stock;
    UsdcDouble internal usdc;
    StakingDouble internal staking;
    CoveredCallsHandler internal handler;
    uint256 internal stockSupply;
    uint256 internal usdcSupply;

    function setUp() public {
        vm.warp(1_800_000_000);
        stock = new B20Double();
        usdc = new UsdcDouble();
        staking = new StakingDouble(usdc);
        calls = new CoveredCallsV1(address(stock), address(usdc), address(staking));
        handler = new CoveredCallsHandler(calls, stock, usdc, staking);
        stockSupply = stock.totalSupply();
        usdcSupply = usdc.totalSupply();
        bytes4[] memory endOnly = new bytes4[](1);
        endOnly[0] = handler.recoverEverything.selector;
        excludeSelector(FuzzSelector({addr: address(handler), selectors: endOnly}));
        targetContract(address(handler));
    }

    /// The contract holds exactly the stock it still owes: every listing's unexercised stock until it
    /// is returned to the seller, plus everything any account may still claim.
    function invariant_stockHeldEqualsStockOwed() public view {
        uint256 owedTotal;
        for (uint256 id = 1; id <= calls.listingCount(); ++id) {
            CoveredCallsV1.Listing memory l = calls.listings(id);
            if (!l.stockReturned) owedTotal += l.amount - l.exercised;
            for (uint256 a; a < handler.actorCount(); ++a) {
                owedTotal += calls.owed(id, handler.actors(a));
            }
        }
        assertEq(stock.balanceOf(address(calls)), owedTotal);
    }

    /// The contract holds exactly the strike paid and not yet collected; premiums and fees pass through.
    function invariant_usdcHeldEqualsStrikeUncollected() public view {
        uint256 uncollected;
        for (uint256 id = 1; id <= calls.listingCount(); ++id) {
            CoveredCallsV1.Listing memory l = calls.listings(id);
            uncollected += l.strikePaid - l.strikeCollected;
        }
        assertEq(usdc.balanceOf(address(calls)), uncollected);
    }

    /// Nothing is oversold, and every unit a listing ever locked is still locked, owed or claimed.
    function invariant_noOversellingAndEveryUnitAccounted() public view {
        for (uint256 id = 1; id <= calls.listingCount(); ++id) {
            CoveredCallsV1.Listing memory l = calls.listings(id);
            assertLe(l.filled, l.amount);
            assertLe(l.exercised, l.filled);
            uint256 heldTotal;
            uint256 owedTotal;
            for (uint256 a; a < handler.actorCount(); ++a) {
                heldTotal += calls.held(id, handler.actors(a));
                owedTotal += calls.owed(id, handler.actors(a));
            }
            assertEq(heldTotal + l.exercised, l.filled);
            uint256 locked = l.stockReturned ? 0 : l.amount - l.exercised;
            assertEq(locked + owedTotal + handler.claimedOf(id), handler.listedOf(id));
        }
    }

    /// A claim pays exactly what `claimable` showed for that account just before it.
    function invariant_claimPaysWhatClaimableShows() public view {
        assertEq(handler.claimMismatches(), 0);
    }

    /// Stock is never created or lost.
    function invariant_stockIsConserved() public view {
        uint256 total = stock.balanceOf(address(calls));
        for (uint256 a; a < handler.actorCount(); ++a) {
            total += stock.balanceOf(handler.actors(a));
        }
        assertEq(total, stockSupply);
    }

    /// Every fee reached staking exactly once: 1% of each premium paid, rounded up.
    function invariant_feesReachStakingOnce() public view {
        assertEq(staking.deposited(), handler.feesExpected());
        assertEq(usdc.balanceOf(address(staking)), handler.feesExpected());
    }

    /// USDC is never created or lost.
    function invariant_usdcIsConserved() public view {
        uint256 total = usdc.balanceOf(address(calls)) + usdc.balanceOf(address(staking));
        for (uint256 a; a < handler.actorCount(); ++a) {
            total += usdc.balanceOf(handler.actors(a));
        }
        assertEq(total, usdcSupply);
    }

    /// Once every restriction lifts, every party recovers everything that is theirs and the contract
    /// is left holding nothing.
    function afterInvariant() public {
        console.log("list", handler.succeeded(handler.list.selector), "fill", handler.succeeded(handler.fill.selector));
        console.log(
            "cancel",
            handler.succeeded(handler.cancel.selector),
            "exercise",
            handler.succeeded(handler.exercise.selector)
        );
        console.log(
            "claim",
            handler.succeeded(handler.claim.selector),
            "collectStrike",
            handler.succeeded(handler.collectStrike.selector)
        );
        handler.recoverEverything();
        assertEq(stock.balanceOf(address(calls)), 0);
        assertEq(usdc.balanceOf(address(calls)), 0);
        invariant_noOversellingAndEveryUnitAccounted();
    }
}
