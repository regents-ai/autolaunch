// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {ExposureLegV1} from "../src/ExposureLegV1.sol";
import {ExposureSeriesV1} from "../src/ExposureSeriesV1.sol";
import {MockPrintOracle, MockStock} from "./doubles/Doubles.sol";

/// @notice Drives one series through random mints, redemptions, leg transfers, prints, missed
///         prints, donations and issuer seizures, keeping a ledger of every stock movement.
contract SeriesHandler is Test {
    uint256 internal constant TOKEN = 1e8;
    bytes32 internal constant FEED = keccak256("feed");

    ExposureSeriesV1 public series;
    MockStock public stock;
    MockPrintOracle public oracle;
    ExposureLegV1 public overnight;
    ExposureLegV1 public session;
    uint64[] internal schedule;
    address[3] internal actors = [makeAddr("a"), makeAddr("b"), makeAddr("c")];

    uint256 public deposited;
    uint256 public paid;
    uint256 public seized;
    uint256 public donated;

    constructor(ExposureSeriesV1 series_, MockStock stock_, MockPrintOracle oracle_, uint64[] memory schedule_) {
        series = series_;
        stock = stock_;
        oracle = oracle_;
        overnight = series_.overnight();
        session = series_.session();
        schedule = schedule_;
        for (uint256 i; i < actors.length; ++i) {
            stock.mint(actors[i], 1_000_000 * TOKEN);
            vm.prank(actors[i]);
            stock.approve(address(series_), type(uint256).max);
        }
    }

    function mint(uint256 actorSeed, uint256 amount) external {
        if (series.status() != ExposureSeriesV1.Status.Active) return;
        if (stock.balanceOf(address(series)) < series.accountedAssets()) return;
        address actor = actors[actorSeed % actors.length];
        amount = bound(amount, 1, 1_000 * TOKEN);
        vm.prank(actor);
        series.mint(amount);
        deposited += amount;
    }

    function redeemPair(uint256 actorSeed, uint256 amount) external {
        address actor = actors[actorSeed % actors.length];
        uint256 held = _min(overnight.balanceOf(actor), session.balanceOf(actor));
        if (held == 0) return;
        amount = bound(amount, 1, held);
        vm.prank(actor);
        paid += series.redeem(amount, amount);
    }

    function redeemAny(uint256 actorSeed, uint256 n, uint256 s) external {
        if (series.status() != ExposureSeriesV1.Status.Ended) return;
        address actor = actors[actorSeed % actors.length];
        n = bound(n, 0, overnight.balanceOf(actor));
        s = bound(s, 0, session.balanceOf(actor));
        if (n == 0 && s == 0) return;
        vm.prank(actor);
        paid += series.redeem(n, s);
    }

    function transferLeg(uint256 fromSeed, uint256 toSeed, uint256 amount, bool isOvernight) external {
        address from = actors[fromSeed % actors.length];
        address to = actors[toSeed % actors.length];
        ExposureLegV1 leg = isOvernight ? overnight : session;
        amount = bound(amount, 0, leg.balanceOf(from));
        vm.prank(from);
        leg.transfer(to, amount);
    }

    /// @dev Publishes the next print on time at a price within -60% to +60% of the last (any price
    ///      for the first close) and applies it.
    function settle(uint256 priceSeed) external {
        if (series.status() == ExposureSeriesV1.Status.Ended) return;
        uint256 index = series.settled();
        uint256 last = series.lastPriceWad();
        uint256 price =
            index == 0 ? bound(priceSeed, 1e18, 1e22) : bound(priceSeed, last * 40 / 100 + 1, last * 160 / 100);
        uint64 at = schedule[index];
        if (block.timestamp < at + 60) vm.warp(at + 60);
        oracle.set(FEED, at, index % 2 == 1, uint128(price), uint64(block.timestamp));
        series.settle();
    }

    /// @dev Acts on one call in sixteen once live, so most runs see many prints before a timeout.
    function missPrint(uint256 seed) external {
        if (seed % 16 != 0 || series.status() != ExposureSeriesV1.Status.Active) return;
        uint64 at = schedule[series.settled()];
        uint256 deadline = uint256(at) + series.maxReportDelay();
        if (block.timestamp <= deadline) vm.warp(deadline + 1);
        series.endOnMissingPrint();
    }

    function donate(uint256 actorSeed, uint256 amount) external {
        address actor = actors[actorSeed % actors.length];
        amount = bound(amount, 0, 100 * TOKEN);
        vm.prank(actor);
        stock.transfer(address(series), amount);
        donated += amount;
    }

    function seize(uint256 amount) external {
        amount = bound(amount, 0, stock.balanceOf(address(series)) / 10);
        stock.seize(address(series), amount);
        seized += amount;
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}

contract ExposureSeriesV1InvariantTest is Test {
    SeriesHandler internal handler;
    ExposureSeriesV1 internal series;
    MockStock internal stock;

    function setUp() public {
        vm.warp(1_800_000_000);
        uint64[] memory schedule = new uint64[](41);
        for (uint256 i; i < schedule.length; ++i) {
            schedule[i] = uint64(block.timestamp + 1 hours + i * 12 hours);
        }
        stock = new MockStock();
        MockPrintOracle oracle = new MockPrintOracle();
        series = new ExposureSeriesV1(
            ExposureSeriesV1.Terms({
                asset: address(stock),
                oracle: address(oracle),
                feedId: keccak256("feed"),
                termsHash: keccak256("terms"),
                maxReportDelay: 6 hours,
                depositCap: 1_000_000e8,
                boundaries: schedule,
                overnightName: "N",
                overnightSymbol: "N",
                sessionName: "S",
                sessionSymbol: "S"
            })
        );
        handler = new SeriesHandler(series, stock, oracle, schedule);
        targetContract(address(handler));
    }

    /// @notice Until the end, every outstanding pair is exactly one raw unit of accounted stock.
    function invariant_PairsMatchBackingWhileLive() public view {
        if (series.status() == ExposureSeriesV1.Status.Ended) return;
        uint256 accounted = series.accountedAssets();
        assertEq(series.overnight().totalSupply(), accounted);
        assertEq(series.session().totalSupply(), accounted);
    }

    function invariant_LedgersStayWithinPrice() public view {
        assertLe(series.overnightLedgerWad(), series.lastPriceWad());
    }

    /// @notice After the end, what every outstanding leg is owed never exceeds the accounted stock.
    function invariant_ClaimsNeverExceedAccounted() public view {
        if (series.status() != ExposureSeriesV1.Status.Ended) return;
        uint256 price = series.lastPriceWad();
        uint256 night = series.overnightLedgerWad();
        uint256 claims = series.overnight().totalSupply() * night + series.session().totalSupply() * (price - night);
        assertLe(claims, series.accountedAssets() * price);
    }

    /// @notice Every raw unit is accounted for: in, out, donated and seized.
    function invariant_StockConserved() public view {
        assertEq(
            stock.balanceOf(address(series)),
            handler.deposited() + handler.donated() - handler.paid() - handler.seized()
        );
    }

    /// @notice Without a seizure the series always holds at least what it owes.
    function invariant_FullyBackedUnlessSeized() public view {
        if (handler.seized() != 0) return;
        assertGe(stock.balanceOf(address(series)), series.accountedAssets());
    }
}
