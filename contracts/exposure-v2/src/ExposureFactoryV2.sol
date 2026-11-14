// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Ownable} from "solady/auth/Ownable.sol";
import {DateTimeLib} from "solady/utils/DateTimeLib.sol";
import {LibString} from "solady/utils/LibString.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

import {ExposureSeriesV2} from "./ExposureSeriesV2.sol";
import {
    BOUNDARY_SETTLE_DELAY,
    IAggregatorDecimals,
    IAggregatorProxy,
    ISeriesConfigSource,
    SeriesConfig
} from "./interfaces/IExposureV2.sol";

/// @title ExposureFactoryV2
/// @notice Opens one exposure series per week, by itself. The owner (the Regent governance Safe) sets a
///         template once: the stock, its Chainlink feed and pinned phase, the deposit cap, the terms
///         hash and the ticker the leg names start with. From then on anyone may open the current
///         week's series, and `deposit` opens it on the first deposit, so no signature is needed
///         each week. Each series sits at a CREATE2 address that depends only on this factory and
///         the week, so it is known before it exists and can never be created twice.
///
///         The owner can change the template for series not yet opened, keep the market calendar
///         (closed days and early closes) for weeks after the current one, and pause the opening
///         of new series. It has no power over a series once opened: a series has no owner.
/// @dev The calendar is the US equity session in New York time: 09:30 to 16:00, or 13:00 on an early
///      close, Monday to Friday except closed days, with US daylight saving time computed from the
///      federal rule (second Sunday of March to first Sunday of November). Week `w` runs Monday
///      `7w - 3` to Sunday `7w + 3` in days since 1970-01-01. Its series starts at the close of the
///      last trading day before that Monday and then takes each trading day's open and close, so
///      consecutive series share a boundary: one matures at the price the next starts from.
contract ExposureFactoryV2 is Ownable, ISeriesConfigSource {
    using SafeTransferLib for address;

    enum DayKind {
        Regular,
        Closed,
        EarlyClose
    }

    struct Template {
        address asset;
        /// Chainlink aggregator proxy.
        address feed;
        /// The proxy phase every price of a series is read from.
        uint16 phase;
        uint256 depositCap;
        bytes32 termsHash;
        /// What the leg names and symbols start with, for example "AMZNc".
        string ticker;
    }

    uint256 internal constant OPEN_MINUTE = 9 * 60 + 30;
    uint256 internal constant CLOSE_MINUTE = 16 * 60;
    uint256 internal constant EARLY_CLOSE_MINUTE = 13 * 60;
    uint256 internal constant MAX_TICKER_LENGTH = 12;

    Template internal _template;
    uint8 public feedDecimals;
    /// @notice While paused, no new series opens; series already open carry on.
    bool public paused;

    mapping(uint256 epochDay => DayKind) public dayKind;
    mapping(uint256 week => ExposureSeriesV2) public seriesOf;
    mapping(address series => bool) public isSeries;

    event TemplateSet(
        address indexed asset, address feed, uint16 phase, uint256 depositCap, bytes32 termsHash, string ticker
    );
    event DaySet(uint256 indexed epochDay, DayKind kind);
    event PausedSet(bool paused);
    event SeriesOpened(
        uint256 indexed week,
        address indexed series,
        address indexed asset,
        address overnight,
        address session,
        address feed,
        uint16 phase,
        bytes32 termsHash
    );

    error ZeroAddress();
    error ZeroAmount();
    error BadTicker();
    error PhaseNotFound(uint16 phase);
    error BadFeedDecimals(uint8 decimals);
    error NotAWeekday(uint256 epochDay);
    error DayLocked(uint256 epochDay);
    error OpeningPaused();
    error NotCurrentWeek(uint256 week, uint256 current);
    error AlreadyOpen(address series);

    /// @param closedDays and `earlyCloseDays` are days since 1970-01-01 (UTC dates).
    constructor(
        address owner_,
        Template memory template_,
        uint256[] memory closedDays,
        uint256[] memory earlyCloseDays
    ) {
        _initializeOwner(owner_);
        _setTemplate(template_);
        for (uint256 i; i < closedDays.length; ++i) {
            _setDay(closedDays[i], DayKind.Closed);
        }
        for (uint256 i; i < earlyCloseDays.length; ++i) {
            _setDay(earlyCloseDays[i], DayKind.EarlyClose);
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Anyone
    // ---------------------------------------------------------------------------------------------

    /// @notice Opens the series for `week`, which must be the current week. Whoever calls it, the
    ///         series is the same: its address depends only on the week, its calendar is locked
    ///         for the current week, and its terms are the owner's template at the moment it opens.
    function open(uint256 week) public returns (ExposureSeriesV2 series) {
        if (paused) revert OpeningPaused();
        uint256 current = currentWeek();
        if (week != current) revert NotCurrentWeek(week, current);
        if (address(seriesOf[week]) != address(0)) revert AlreadyOpen(address(seriesOf[week]));

        series = new ExposureSeriesV2{salt: bytes32(0)}(week);
        seriesOf[week] = series;
        isSeries[address(series)] = true;
        emit SeriesOpened(
            week,
            address(series),
            series.asset(),
            address(series.overnight()),
            address(series.session()),
            series.feed(),
            series.phase(),
            series.termsHash()
        );
    }

    /// @notice Deposits `assets` of the stock from the caller into the series for `week`, opening it
    ///         first if nobody has yet, and mints the caller that many of each leg. `week` is the
    ///         series the caller was shown, so a deposit sent just before a week rolls over fails
    ///         rather than landing in the next week. The caller approves this factory once.
    function deposit(uint256 week, uint256 assets) external returns (ExposureSeriesV2 series) {
        series = seriesOf[week];
        if (address(series) == address(0)) series = open(week);
        address stock = series.asset();
        stock.safeTransferFrom(msg.sender, address(this), assets);
        stock.safeApprove(address(series), assets);
        series.mint(assets, msg.sender);
    }

    // ---------------------------------------------------------------------------------------------
    // Owner
    // ---------------------------------------------------------------------------------------------

    /// @notice Sets the template for every series opened from now on. Series already open keep theirs.
    function setTemplate(Template calldata template_) external onlyOwner {
        _setTemplate(template_);
    }

    /// @notice Marks each of `epochDays` closed, an early close (13:00 New York), or regular again.
    ///         Only days in weeks after the current one: the current week's series, and where the
    ///         next one starts, never change.
    function setDays(uint256[] calldata epochDays, DayKind kind) external onlyOwner {
        uint256 firstOpenDay = mondayOf(currentWeek() + 1);
        for (uint256 i; i < epochDays.length; ++i) {
            if (epochDays[i] < firstOpenDay) revert DayLocked(epochDays[i]);
            _setDay(epochDays[i], kind);
        }
    }

    function setPaused(bool paused_) external onlyOwner {
        paused = paused_;
        emit PausedSet(paused_);
    }

    // ---------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------

    function template() external view returns (Template memory) {
        return _template;
    }

    /// @notice The week whose series takes deposits now: the latest week whose initial close is at
    ///         least `SETTLE_DELAY` past. It turns over an hour after the last close of each week.
    function currentWeek() public view returns (uint256 week) {
        week = weekOfDay(block.timestamp / 1 days) + 2;
        while (block.timestamp < startOf(week) + BOUNDARY_SETTLE_DELAY) {
            --week;
        }
    }

    /// @notice Where the series for `week` is or will be.
    function predictSeries(uint256 week) external view returns (address) {
        bytes32 initCodeHash = keccak256(bytes.concat(type(ExposureSeriesV2).creationCode, abi.encode(week)));
        return
            address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), bytes32(0), initCodeHash))))
            );
    }

    /// @notice Everything the series for `week` is made from, as it would open now. A series reads
    ///         this once, from its constructor.
    function seriesConfig(uint256 week) external view returns (SeriesConfig memory c) {
        Template memory t = _template;
        c.asset = t.asset;
        c.feed = t.feed;
        c.phase = t.phase;
        c.feedDecimals = feedDecimals;
        c.depositCap = t.depositCap;
        c.termsHash = t.termsHash;
        c.boundaries = boundariesOf(week);
        (string memory date, string memory code) = _labels(c.boundaries[c.boundaries.length - 1] / 1 days);
        c.overnightName = string.concat(t.ticker, " After-hours to ", date);
        c.overnightSymbol = string.concat(t.ticker, "-AH-", code);
        c.sessionName = string.concat(t.ticker, " Market-hours to ", date);
        c.sessionSymbol = string.concat(t.ticker, "-MH-", code);
    }

    /// @notice The series boundaries for `week`: the close of the last trading day before its Monday,
    ///         then the open and close of each of its trading days.
    function boundariesOf(uint256 week) public view returns (uint64[] memory times) {
        uint256 monday = mondayOf(week);
        times = new uint64[](11);
        times[0] = startOf(week);
        uint256 count = 1;
        for (uint256 day = monday; day < monday + 5; ++day) {
            if (dayKind[day] == DayKind.Closed) continue;
            times[count++] = openAt(day);
            times[count++] = closeAt(day);
        }
        assembly ("memory-safe") {
            mstore(times, count)
        }
    }

    /// @notice The series start for `week`: the close of the last trading day before its Monday,
    ///         however many days the market was closed before it.
    function startOf(uint256 week) public view returns (uint64) {
        uint256 day = mondayOf(week) - 1;
        while (!isTradingDay(day)) {
            --day;
        }
        return closeAt(day);
    }

    function isTradingDay(uint256 epochDay) public view returns (bool) {
        return DateTimeLib.weekday(epochDay * 1 days) <= DateTimeLib.FRI && dayKind[epochDay] != DayKind.Closed;
    }

    /// @notice 09:30 New York on `epochDay`, in UTC seconds.
    function openAt(uint256 epochDay) public pure returns (uint64) {
        return _newYork(epochDay, OPEN_MINUTE);
    }

    /// @notice 16:00 New York on `epochDay`, or 13:00 on an early close, in UTC seconds.
    function closeAt(uint256 epochDay) public view returns (uint64) {
        return _newYork(epochDay, dayKind[epochDay] == DayKind.EarlyClose ? EARLY_CLOSE_MINUTE : CLOSE_MINUTE);
    }

    /// @notice Whether New York keeps daylight saving time on `epochDay`: from the second Sunday of
    ///         March to the day before the first Sunday of November. Trading never happens on the
    ///         Sundays the clocks change, so the date alone decides the session's UTC offset.
    function isDaylightSaving(uint256 epochDay) public pure returns (bool) {
        (uint256 year,,) = DateTimeLib.epochDayToDate(epochDay);
        uint256 starts = DateTimeLib.nthWeekdayInMonthOfYearTimestamp(year, 3, 2, DateTimeLib.SUN) / 1 days;
        uint256 ends = DateTimeLib.nthWeekdayInMonthOfYearTimestamp(year, 11, 1, DateTimeLib.SUN) / 1 days;
        return epochDay >= starts && epochDay < ends;
    }

    function weekOfDay(uint256 epochDay) public pure returns (uint256) {
        return (epochDay + 3) / 7;
    }

    function mondayOf(uint256 week) public pure returns (uint256) {
        return 7 * week - 3;
    }

    // ---------------------------------------------------------------------------------------------
    // Internal
    // ---------------------------------------------------------------------------------------------

    function _setTemplate(Template memory t) internal {
        if (t.asset == address(0) || t.feed == address(0)) revert ZeroAddress();
        if (t.depositCap == 0) revert ZeroAmount();
        uint256 tickerLength = bytes(t.ticker).length;
        if (tickerLength == 0 || tickerLength > MAX_TICKER_LENGTH) revert BadTicker();
        address aggregator = IAggregatorProxy(t.feed).phaseAggregators(t.phase);
        if (aggregator == address(0)) revert PhaseNotFound(t.phase);
        uint8 decimals = IAggregatorDecimals(aggregator).decimals();
        if (decimals > 18) revert BadFeedDecimals(decimals);

        _template = t;
        feedDecimals = decimals;
        emit TemplateSet(t.asset, t.feed, t.phase, t.depositCap, t.termsHash, t.ticker);
    }

    function _setDay(uint256 epochDay, DayKind kind) internal {
        if (DateTimeLib.weekday(epochDay * 1 days) > DateTimeLib.FRI) revert NotAWeekday(epochDay);
        dayKind[epochDay] = kind;
        emit DaySet(epochDay, kind);
    }

    function _newYork(uint256 epochDay, uint256 minute) internal pure returns (uint64) {
        uint256 offset = isDaylightSaving(epochDay) ? 4 hours : 5 hours;
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint64(epochDay * 1 days + minute * 1 minutes + offset); // any date before year 2^30
    }

    /// @dev "20 Nov 2026" and "1120" for the day `epochDay`.
    function _labels(uint256 epochDay) internal pure returns (string memory date, string memory code) {
        (uint256 year, uint256 month, uint256 day) = DateTimeLib.epochDayToDate(epochDay);
        bytes memory months = "JanFebMarAprMayJunJulAugSepOctNovDec";
        bytes memory name = new bytes(3);
        for (uint256 i; i < 3; ++i) {
            name[i] = months[(month - 1) * 3 + i];
        }
        date = string.concat(LibString.toString(day), " ", string(name), " ", LibString.toString(year));
        code = string.concat(_twoDigits(month), _twoDigits(day));
    }

    function _twoDigits(uint256 n) internal pure returns (string memory) {
        return n < 10 ? string.concat("0", LibString.toString(n)) : LibString.toString(n);
    }
}
