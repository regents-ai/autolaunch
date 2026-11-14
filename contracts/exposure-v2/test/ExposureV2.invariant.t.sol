// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

import {ExposureFactoryV2} from "../src/ExposureFactoryV2.sol";
import {ExposureLegV2} from "../src/ExposureLegV2.sol";
import {ExposureSeriesV2} from "../src/ExposureSeriesV2.sol";
import {MockFeed, MockStock} from "./doubles/Doubles.sol";
import {Fixture} from "./Fixture.sol";

/// @notice Drives one live series through any interleaving of deposits, pair and single-leg
///         redemptions, leg transfers, settles, price rounds, time, issuer seizures and donations,
///         while an identical series from a second factory sees the same prices but is settled only
///         when the fuzzer happens to ask.
contract ExposureV2Handler is Test {
    uint256 internal constant TOKEN = 1e8;
    uint16 internal constant PHASE = 2;

    MockStock public stock;
    MockFeed public feed;
    ExposureFactoryV2 public factory;
    ExposureSeriesV2 public series;
    ExposureSeriesV2 public shadow;
    ExposureLegV2 public overnight;
    ExposureLegV2 public session;
    uint256 public week;
    address[3] public actors;

    uint256 public ghostDeposited;
    uint256 public ghostDonated;
    uint256 public ghostSeized;
    uint256 public ghostPaid;
    uint256 public ghostOwed;
    uint256 public ghostUnequalRedemptions;
    bool public ghostSettleNotIdempotent;
    bool public ghostPaidMoreThanOwed;
    bool public ghostPairPaidWrong;

    constructor(
        MockStock stock_,
        MockFeed feed_,
        ExposureFactoryV2 factory_,
        ExposureSeriesV2 series_,
        ExposureSeriesV2 shadow_,
        uint256 week_
    ) {
        (stock, feed, factory, series, shadow, week) = (stock_, feed_, factory_, series_, shadow_, week_);
        overnight = series_.overnight();
        session = series_.session();
        actors = [makeAddr("actor 0"), makeAddr("actor 1"), makeAddr("actor 2")];
        for (uint256 i; i < actors.length; ++i) {
            vm.prank(actors[i]);
            stock.approve(address(factory), type(uint256).max);
        }
    }

    function actorCount() external pure returns (uint256) {
        return 3;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    // ---------------------------------------------------------------------------------------------
    // Holders
    // ---------------------------------------------------------------------------------------------

    function deposit(uint256 actorSeed, uint256 assets) external {
        address who = _actor(actorSeed);
        assets = bound(assets, 1, 100 * TOKEN);
        stock.mint(who, assets);
        vm.prank(who);
        try factory.deposit(week, assets) {
            ghostDeposited += assets;
        } catch {
            stock.seize(who, assets);
        }
    }

    function redeemPairs(uint256 actorSeed, uint256 amount) external {
        address who = _actor(actorSeed);
        uint256 held = FixedPointMathLib.min(overnight.balanceOf(who), session.balanceOf(who));
        if (held == 0) return;
        amount = bound(amount, 1, held);
        uint256 preview = series.previewRedeem(amount, amount);
        _redeem(who, amount, amount);
        if (series.status() != ExposureSeriesV2.Status.Ended && ghostSeized == 0 && preview != amount) {
            ghostPairPaidWrong = true;
        }
    }

    function redeemLegs(uint256 actorSeed, uint256 night, uint256 day) external {
        address who = _actor(actorSeed);
        night = bound(night, 0, overnight.balanceOf(who));
        day = bound(day, 0, session.balanceOf(who));
        if (night == day) return;
        if (_redeem(who, night, day)) ++ghostUnequalRedemptions;
    }

    function transferLeg(uint256 fromSeed, uint256 toSeed, bool night, uint256 amount) external {
        address from = _actor(fromSeed);
        ExposureLegV2 leg = night ? overnight : session;
        uint256 held = leg.balanceOf(from);
        if (held == 0) return;
        amount = bound(amount, 1, held);
        vm.prank(from);
        leg.transfer(_actor(toSeed), amount);
    }

    function _redeem(address who, uint256 night, uint256 day) internal returns (bool) {
        uint256 accountedBefore = series.accountedAssets();
        uint256 balanceBefore = stock.balanceOf(who);
        vm.prank(who);
        try series.redeem(night, day) returns (uint256 paid) {
            uint256 owed = accountedBefore - series.accountedAssets();
            if (paid > owed || stock.balanceOf(who) - balanceBefore != paid) ghostPaidMoreThanOwed = true;
            ghostPaid += paid;
            ghostOwed += owed;
            return true;
        } catch {
            return false;
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Settlement and the feed
    // ---------------------------------------------------------------------------------------------

    function settle() external {
        series.settle();
        bytes32 before = _stored(series);
        if (series.settle() != 0 || _stored(series) != before) ghostSettleNotIdempotent = true;
    }

    function settleShadow() external {
        shadow.settle();
    }

    /// A price round now. One round in forty carries a broken answer.
    function transmit(uint256 dollars, uint256 cents) external {
        int256 answer = int256(bound(dollars, 1, 1_000) * 1e8 + bound(cents, 0, 99) * 1e6);
        if (cents % 40 == 39) answer = 0;
        feed.transmit(PHASE, answer);
    }

    function warp(uint256 seconds_) external {
        vm.warp(vm.getBlockTimestamp() + bound(seconds_, 1 minutes, 30 hours));
    }

    // ---------------------------------------------------------------------------------------------
    // The issuer and strangers
    // ---------------------------------------------------------------------------------------------

    function seize(uint256 amount) external {
        uint256 balance = stock.balanceOf(address(series));
        if (balance == 0 || amount % 8 != 0) return; // rare
        amount = bound(amount, 1, balance);
        stock.seize(address(series), amount);
        ghostSeized += amount;
    }

    function donate(uint256 amount) external {
        amount = bound(amount, 1, 10 * TOKEN);
        stock.mint(address(series), amount);
        ghostDonated += amount;
    }

    function _stored(ExposureSeriesV2 s) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                s.status(),
                s.endReason(),
                s.settled(),
                s.lastPriceWad(),
                s.overnightLedgerWad(),
                s.lastRound(),
                s.lastRoundUpdatedAt()
            )
        );
    }
}

contract ExposureV2InvariantTest is Fixture {
    ExposureV2Handler internal handler;
    ExposureSeriesV2 internal shadow;

    function setUp() public override {
        super.setUp();
        feed.setRound(PHASE, 1, 200e8, b[0] - 10 minutes);
        vm.warp(b[0] + 1 hours);
        _use(factory.open(WEEK));
        shadow = _newFactory().open(WEEK);

        handler = new ExposureV2Handler(stock, feed, factory, series, shadow, WEEK);
        bytes4[] memory selectors = new bytes4[](11);
        selectors[0] = handler.deposit.selector;
        selectors[1] = handler.deposit.selector;
        selectors[2] = handler.redeemPairs.selector;
        selectors[3] = handler.redeemLegs.selector;
        selectors[4] = handler.transferLeg.selector;
        selectors[5] = handler.settle.selector;
        selectors[6] = handler.settleShadow.selector;
        selectors[7] = handler.transmit.selector;
        selectors[8] = handler.warp.selector;
        selectors[9] = handler.seize.selector;
        selectors[10] = handler.donate.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// Every raw unit is where the ledger of movements says it is.
    function invariant_conservation() public view {
        assertEq(
            stock.balanceOf(address(series)) + handler.ghostSeized() + handler.ghostPaid(),
            handler.ghostDeposited() + handler.ghostDonated()
        );
        assertEq(series.accountedAssets(), handler.ghostDeposited() - handler.ghostOwed());
        if (handler.ghostSeized() == 0) {
            assertGe(stock.balanceOf(address(series)), series.accountedAssets());
            assertEq(handler.ghostPaid(), handler.ghostOwed());
        }
        assertFalse(handler.ghostPaidMoreThanOwed(), "paid only the redeemer, never more than owed");
    }

    /// While the series runs, every outstanding pair is backed one for one.
    function invariant_pairsBackedWhileLive() public view {
        if (series.status() == ExposureSeriesV2.Status.Ended) return;
        assertEq(overnight.totalSupply(), session.totalSupply());
        assertEq(overnight.totalSupply(), series.accountedAssets());
        assertFalse(handler.ghostPairPaidWrong());
    }

    /// Once it has ended, everyone's legs together are owed no more than the series accounts for,
    /// and what rounding leaves behind stays small.
    function invariant_claimsWithinBacking() public view {
        if (series.status() != ExposureSeriesV2.Status.Ended || series.lastPriceWad() == 0) return;
        uint256 claims;
        for (uint256 i; i < handler.actorCount(); ++i) {
            address who = handler.actors(i);
            uint256 o = overnight.balanceOf(who);
            uint256 s = session.balanceOf(who);
            claims += _owed(o, s);
        }
        uint256 accounted = series.accountedAssets();
        assertLe(claims, accounted);
        assertLe(accounted - claims, handler.ghostUnequalRedemptions() + 2 * handler.actorCount());
    }

    /// The state is the same whether the series was settled at every step or never.
    function invariant_timingDoesNotMatter() public view {
        (ExposureSeriesV2.Status a, ExposureSeriesV2.EndReason ra, uint256 na, uint256 pa, uint256 oa) =
            series.previewState();
        (ExposureSeriesV2.Status b_, ExposureSeriesV2.EndReason rb, uint256 nb, uint256 pb, uint256 ob) =
            shadow.previewState();
        assertEq(uint8(a), uint8(b_));
        assertEq(uint8(ra), uint8(rb));
        assertEq(na, nb);
        assertEq(pa, pb);
        assertEq(oa, ob);
        // Stored states are points on one path: the same number of prices means the same prices.
        // (A halt ends a series without a price, so the status can differ at the same count.)
        if (series.settled() == shadow.settled()) {
            assertEq(series.lastPriceWad(), shadow.lastPriceWad());
            assertEq(series.overnightLedgerWad(), shadow.overnightLedgerWad());
            assertEq(series.lastRound(), shadow.lastRound());
        }
        assertFalse(handler.ghostSettleNotIdempotent());
    }

    function _owed(uint256 o, uint256 s) internal view returns (uint256) {
        uint256 price = series.lastPriceWad();
        uint256 night = series.overnightLedgerWad();
        if (o >= s) return s + FixedPointMathLib.fullMulDiv(o - s, night, price);
        return o + FixedPointMathLib.fullMulDiv(s - o, price - night, price);
    }
}
