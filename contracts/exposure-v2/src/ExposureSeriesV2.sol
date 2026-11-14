// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

import {ExposureLegV2} from "./ExposureLegV2.sol";
import {BOUNDARY_SETTLE_DELAY, ISeriesConfigSource, SeriesConfig} from "./interfaces/IExposureV2.sol";

interface IStock {
    function decimals() external view returns (uint8);
    function balanceOf(address account) external view returns (uint256);
}

/// @title ExposureSeriesV2
/// @notice One week of one Base stock token split into two isolated exposure tokens. Depositing raw
///         stock mints the same amount of OVERNIGHT (After-hours) and SESSION (Market-hours); one of
///         each always redeems for exactly one raw unit. Between the week's boundaries OVERNIGHT
///         carries every close-to-open move and SESSION every open-to-close move, in dollars on a
///         ledger that starts at half the stock's price. Once the series ends each leg redeems on its
///         own for its ledger's share of the stock. There is no owner, admin, upgrade, pause or fee.
/// @dev Prices record themselves. The price for a boundary is the Chainlink round of the series'
///      pinned feed phase in force at that moment: the last round updated at or before it. Rounds
///      stay readable for ever, so a boundary can be applied at any later time and always gives the
///      same price; there is no recorder and no recording window. Applying is deterministic and
///      takes no input: `settle`, `mint` and any single-leg `redeem` first apply every boundary that
///      is due, finding each round by an on-chain search that starts from the previous boundary's
///      round. Whole pairs never need prices, so pair redemptions never read the feed.
///
///      A boundary is due `SETTLE_DELAY` after it. The feed's `updatedAt` is the block time of the
///      round's transmission, so once a block is past the boundary no round stamped at or before it
///      can still appear; the delay is margin on top. The ledgers always sum to the last price
///      (`N + S = P`); a price that would take either ledger to zero or below ends the series there.
///      A round in force more than `MAX_STALENESS` old, no round at all, or a non-positive answer
///      ends the series at the last applied ledgers. A feed whose reads fail ends it the same way,
///      but only once reads have been seen failing `UNREADABLE_GRACE` apart with no good read in
///      between, so a brief outage cannot end a series however long it went unsettled. Every read
///      uses a fixed gas budget behind a gas floor, so a caller cannot fake a failing read by sending
///      too little gas.
contract ExposureSeriesV2 is ReentrancyGuard {
    using SafeTransferLib for address;

    enum Status {
        /// The initial close is not applied yet; nothing can be minted.
        Pending,
        /// Ledgers live; minting open; only whole pairs redeem.
        Active,
        /// Ledgers frozen; any mix of legs redeems.
        Ended
    }

    enum EndReason {
        None,
        Maturity,
        OvernightDepleted,
        SessionDepleted,
        /// No round of the pinned phase in force at a boundary, or the one in force too old.
        StaleFeed,
        /// The round in force had a non-positive or out-of-range answer.
        BadPrice,
        /// Reads of the feed were seen failing `UNREADABLE_GRACE` apart, with no good read between.
        FeedUnreadable
    }

    /// @dev The settlement state, walked in memory and written back once per call.
    struct State {
        uint256 price;
        uint256 night;
        uint256 settled;
        uint64 round;
        uint64 roundUpdatedAt;
        uint64 unreadableSince;
        Status status;
        EndReason reason;
    }

    enum Step {
        None,
        Print,
        Halt
    }

    enum Read {
        Found,
        NoRound,
        Unreadable
    }

    /// @notice How long after a boundary before it is applied.
    uint256 public constant SETTLE_DELAY = BOUNDARY_SETTLE_DELAY;
    /// @notice The oldest the round in force may be at a boundary: 84 hours. The longest normal gap
    ///         in the AMZN feed's history is 75.9 hours (Friday evening to Tuesday after Labor Day).
    uint256 public constant MAX_STALENESS = 84 hours;
    /// @notice How long after a settle first sees the feed's reads fail before one that still sees
    ///         them fail ends the series.
    uint256 public constant UNREADABLE_GRACE = 7 days;
    /// @notice An initial close and five trading days.
    uint256 public constant MAX_BOUNDARIES = 11;
    /// @notice Gas each round read may use. A read that needs more counts as failing.
    uint256 public constant PROBE_GAS = 50_000;
    /// @dev Enough that 63/64 of what is left at the call, after a cold account access, still
    ///      covers `PROBE_GAS`.
    uint256 internal constant PROBE_GAS_FLOOR = PROBE_GAS + PROBE_GAS / 63 + 4_000;
    /// @dev `getRoundData(uint80)`.
    bytes4 internal constant GET_ROUND_DATA = 0x9a6fc8f5;

    address public immutable factory;
    uint256 public immutable week;
    address public immutable asset;
    ExposureLegV2 public immutable overnight;
    ExposureLegV2 public immutable session;
    address public immutable feed;
    uint16 public immutable phase;
    uint256 internal immutable _scale;
    uint256 public immutable depositCap;
    bytes32 public immutable termsHash;

    uint64[] internal _boundaries;

    /// @notice The last applied price, USD per whole raw token, 18 decimals.
    uint128 public lastPriceWad;
    /// @notice OVERNIGHT's ledger in the same units; SESSION's is `lastPriceWad - overnightLedgerWad`.
    uint128 public overnightLedgerWad;
    Status public status;
    EndReason public endReason;
    /// @notice How many boundaries have been applied; the next one is `boundaries(settled)`.
    uint8 public settled;
    /// @notice The round of the pinned phase the last applied price came from, and its update time.
    uint64 public lastRound;
    uint64 public lastRoundUpdatedAt;
    /// @notice When a settle first saw the feed's reads fail, or zero after a good read.
    uint64 public unreadableSince;
    /// @notice Raw stock the outstanding legs are owed. The balance can exceed it (donations, dust),
    ///         never the other way round unless the issuer takes stock from the series.
    uint256 public accountedAssets;

    event Minted(address indexed payer, address indexed to, uint256 assets);
    /// @notice `owed` is what the legs were worth in raw stock; `paid` is less only after the issuer
    ///         took stock from the series, when every redemption is cut by the same fraction.
    event Redeemed(address indexed account, uint256 overnightAmount, uint256 sessionAmount, uint256 owed, uint256 paid);
    event PrintApplied(
        uint256 indexed index,
        uint64 scheduledAt,
        uint80 roundId,
        uint64 updatedAt,
        uint256 priceWad,
        uint256 overnightLedgerWad,
        uint256 sessionLedgerWad
    );
    event SeriesEnded(
        EndReason reason, uint256 printsApplied, uint256 priceWad, uint256 overnightLedgerWad, uint256 sessionLedgerWad
    );

    error ZeroAddress();
    error ZeroAmount();
    error BadSchedule();
    error BadFeedDecimals();
    error CapReached(uint256 room);
    error NotActive();
    error Matured();
    error PairRequired(uint256 overnightAmount, uint256 sessionAmount);
    error OracleGasTooLow();
    error BackingShort(uint256 balance, uint256 accounted);
    error DepositMismatch(uint256 expected, uint256 received);

    /// @dev Created by the factory with CREATE2, so its address depends only on the factory and the
    ///      week; everything else is read back from the factory here, once.
    constructor(uint256 week_) {
        SeriesConfig memory c = ISeriesConfigSource(msg.sender).seriesConfig(week_);
        if (c.asset == address(0) || c.feed == address(0)) revert ZeroAddress();
        if (c.depositCap == 0) revert ZeroAmount();
        if (c.feedDecimals > 18) revert BadFeedDecimals();
        uint256 count = c.boundaries.length;
        if (count < 3 || count > MAX_BOUNDARIES || count % 2 == 0 || c.boundaries[0] == 0) revert BadSchedule();
        for (uint256 i = 1; i < count; ++i) {
            if (c.boundaries[i] <= c.boundaries[i - 1]) revert BadSchedule();
        }

        factory = msg.sender;
        week = week_;
        asset = c.asset;
        feed = c.feed;
        phase = c.phase;
        _scale = 10 ** (18 - c.feedDecimals);
        depositCap = c.depositCap;
        termsHash = c.termsHash;
        _boundaries = c.boundaries;

        uint8 decimals = IStock(c.asset).decimals();
        overnight = new ExposureLegV2(c.overnightName, c.overnightSymbol, decimals);
        session = new ExposureLegV2(c.sessionName, c.sessionSymbol, decimals);
    }

    // ---------------------------------------------------------------------------------------------
    // Holders
    // ---------------------------------------------------------------------------------------------

    /// @notice Applies every due price, then deposits `assets` raw stock from the caller and mints
    ///         `to` that many of each leg. A pair is always worth exactly the stock behind it, so
    ///         minting at any point of the week is fair. Open from the initial close until the last.
    function mint(uint256 assets, address to) external nonReentrant {
        _settle();
        if (status != Status.Active) revert NotActive();
        if (block.timestamp >= _boundaries[_boundaries.length - 1]) revert Matured();
        if (assets == 0) revert ZeroAmount();
        if (to == address(0)) revert ZeroAddress();
        uint256 accounted = accountedAssets;
        if (assets > depositCap - accounted) revert CapReached(depositCap - accounted);
        uint256 balance = _balance();
        // New stock must not make up a shortfall the issuer caused for existing holders.
        if (balance < accounted) revert BackingShort(balance, accounted);

        asset.safeTransferFrom(msg.sender, address(this), assets);
        uint256 received = _balance() - balance;
        if (received != assets) revert DepositMismatch(assets, received);

        accountedAssets = accounted + assets;
        overnight.mint(to, assets);
        session.mint(to, assets);
        emit Minted(msg.sender, to, assets);
    }

    /// @notice Burns the caller's legs and sends the caller the stock they are worth. Stock only
    ///         ever goes to the account redeeming, so the issuer's own transfer rules apply to it.
    ///         Equal amounts are whole pairs and redeem one raw unit each at any time, without
    ///         reading prices. Unequal amounts first apply every due price and then need the series
    ///         to have ended; they redeem at its final ledgers.
    function redeem(uint256 overnightAmount, uint256 sessionAmount) external nonReentrant returns (uint256 paid) {
        if (overnightAmount == 0 && sessionAmount == 0) revert ZeroAmount();
        if (overnightAmount != sessionAmount) _settle();
        uint256 owed = _owed(status, lastPriceWad, overnightLedgerWad, overnightAmount, sessionAmount);
        uint256 accounted = accountedAssets;
        paid = _afterShortfall(owed, accounted);
        // Legs worth something are never burned for nothing, even after a total seizure.
        if (paid == 0 && owed != 0) revert BackingShort(_balance(), accounted);

        accountedAssets = accounted - owed;
        if (overnightAmount != 0) overnight.burn(msg.sender, overnightAmount);
        if (sessionAmount != 0) session.burn(msg.sender, sessionAmount);
        emit Redeemed(msg.sender, overnightAmount, sessionAmount, owed, paid);

        if (paid != 0) asset.safeTransfer(msg.sender, paid);
    }

    /// @notice Applies every price that is due. Anyone may call it at any time; it takes no input and
    ///         gives the same ledgers whenever and however often it is called.
    function settle() external nonReentrant returns (uint256 applied) {
        return _settle();
    }

    // ---------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------

    /// @notice The raw stock `redeem` would send for these amounts right now, after the due prices.
    function previewRedeem(uint256 overnightAmount, uint256 sessionAmount) external view returns (uint256) {
        if (overnightAmount == sessionAmount) {
            return _afterShortfall(overnightAmount, accountedAssets);
        }
        State memory s = _preview();
        return _afterShortfall(_owed(s.status, s.price, s.night, overnightAmount, sessionAmount), accountedAssets);
    }

    /// @notice The state `settle` would leave right now: what the page shows without a transaction.
    function previewState()
        external
        view
        returns (Status status_, EndReason reason, uint256 printsApplied, uint256 priceWad, uint256 overnightWad)
    {
        State memory s = _preview();
        return (s.status, s.reason, s.settled, s.price, s.night);
    }

    function sessionLedgerWad() external view returns (uint256) {
        return uint256(lastPriceWad) - overnightLedgerWad;
    }

    function boundaries(uint256 index) external view returns (uint64) {
        return _boundaries[index];
    }

    function boundaryCount() external view returns (uint256) {
        return _boundaries.length;
    }

    /// @notice The last boundary: minting stops here and, once it is applied, the series ends.
    function maturityAt() external view returns (uint64) {
        return _boundaries[_boundaries.length - 1];
    }

    /// @notice The next boundary to apply, or zero once the series has ended.
    function nextBoundaryAt() external view returns (uint64) {
        return status == Status.Ended ? 0 : _boundaries[settled];
    }

    /// @notice The proxy round id of round `round` of the pinned phase.
    function roundIdOf(uint64 round) public view returns (uint80) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint80((uint256(phase) << 64) | round); // 16 + 64 bits
    }

    // ---------------------------------------------------------------------------------------------
    // Settlement
    // ---------------------------------------------------------------------------------------------

    function _settle() internal returns (uint256 applied) {
        State memory s = _load();
        while (true) {
            uint256 index = s.settled;
            Step kind = _step(s);
            if (kind == Step.None) break;
            ++applied;
            if (kind == Step.Print) {
                emit PrintApplied(
                    index, _boundaries[index], roundIdOf(s.round), s.roundUpdatedAt, s.price, s.night, s.price - s.night
                );
            }
            if (s.status == Status.Ended) {
                emit SeriesEnded(s.reason, s.settled, s.price, s.night, s.price - s.night);
            }
        }
        if (applied != 0 || s.unreadableSince != unreadableSince) _store(s);
    }

    function _preview() internal view returns (State memory s) {
        s = _load();
        while (_step(s) != Step.None) {}
    }

    /// @dev Applies the next boundary to `s` if it is due and decided. An open moves OVERNIGHT by the
    ///      change since the last close; a close moves SESSION by the change since the open. A failing
    ///      read applies nothing; the first one starts the grace clock and any good read stops it.
    function _step(State memory s) internal view returns (Step) {
        if (s.status == Status.Ended) return Step.None;
        uint256 index = s.settled;
        uint64 at = _boundaries[index];
        if (block.timestamp < uint256(at) + SETTLE_DELAY) return Step.None;

        (Read read, uint64 round, int256 answer, uint64 updatedAt) =
            _roundInForce(at, s.round, s.roundUpdatedAt, s.price / _scale);
        if (read == Read.Unreadable) {
            // forge-lint: disable-next-line(unsafe-typecast)
            if (s.unreadableSince == 0) s.unreadableSince = uint64(block.timestamp); // seconds fit in 64 bits
            if (block.timestamp < uint256(s.unreadableSince) + UNREADABLE_GRACE) return Step.None;
            return _halt(s, EndReason.FeedUnreadable);
        }
        s.unreadableSince = 0;
        if (read == Read.NoRound || at - updatedAt > MAX_STALENESS) return _halt(s, EndReason.StaleFeed);
        // forge-lint: disable-next-line(unsafe-typecast)
        if (answer <= 0 || uint256(answer) > type(uint128).max / _scale) return _halt(s, EndReason.BadPrice);
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 price = uint256(answer) * _scale; // answer is positive

        uint256 night;
        EndReason reason = EndReason.None;
        if (index == 0) {
            night = price / 2;
            if (night == 0) reason = EndReason.OvernightDepleted;
            s.status = Status.Active;
        } else if (index % 2 == 1) {
            // Open: SESSION holds; OVERNIGHT is whatever the new price leaves above it.
            uint256 day = s.price - s.night;
            if (price <= day) {
                night = 0;
                reason = EndReason.OvernightDepleted;
            } else {
                night = price - day;
            }
        } else {
            // Close: OVERNIGHT holds; SESSION is whatever the new price leaves above it.
            night = s.night;
            if (price <= night) {
                night = price;
                reason = EndReason.SessionDepleted;
            }
        }

        s.price = price;
        s.night = night;
        s.settled = index + 1;
        s.round = round;
        s.roundUpdatedAt = updatedAt;
        if (reason == EndReason.None && index + 1 == _boundaries.length) reason = EndReason.Maturity;
        if (reason != EndReason.None) {
            s.status = Status.Ended;
            s.reason = reason;
        }
        return Step.Print;
    }

    function _halt(State memory s, EndReason reason) internal pure returns (Step) {
        s.status = Status.Ended;
        s.reason = reason;
        return Step.Halt;
    }

    /// @dev The round of the pinned phase in force at `at`: the highest-numbered round updated at or
    ///      before it. Rounds of a phase are numbered 1, 2, ... in transmission order and a missing
    ///      round reads as all zeros, so the rounds updated at or before `at` are a prefix. The search
    ///      starts from `cursor`, the round in force at the previous boundary (or round 1), gallops
    ///      forward and then halves, so its cost grows with the logarithm of the rounds in between.
    ///      Its answer is a pure function of the phase's history up to `at`.
    function _roundInForce(uint64 at, uint64 cursor, uint64 cursorUpdatedAt, uint256 cursorAnswer)
        internal
        view
        returns (Read, uint64 round, int256 answer, uint64 updatedAt)
    {
        bool ok;
        int256 a;
        uint256 u;
        if (cursor == 0) {
            (ok, a, u) = _probe(1);
            if (!ok) return (Read.Unreadable, 0, 0, 0);
            if (u == 0 || u > at) return (Read.NoRound, 0, 0, 0);
            round = 1;
            answer = a;
            // forge-lint: disable-next-line(unsafe-typecast)
            updatedAt = uint64(u); // u <= at
        } else {
            // The previous boundary's round, updated before that boundary and so before this one.
            round = cursor;
            // forge-lint: disable-next-line(unsafe-typecast)
            answer = int256(cursorAnswer); // a positive answer below 2^128
            updatedAt = cursorUpdatedAt;
        }

        uint256 hi = round;
        uint256 stride = 1;
        while (true) {
            hi = uint256(round) + stride;
            if (hi > type(uint64).max) {
                hi = uint256(type(uint64).max) + 1;
                break;
            }
            // forge-lint: disable-next-line(unsafe-typecast)
            (ok, a, u) = _probe(uint64(hi)); // checked above
            if (!ok) return (Read.Unreadable, 0, 0, 0);
            if (u == 0 || u > at) break;
            // forge-lint: disable-next-line(unsafe-typecast)
            (round, answer, updatedAt) = (uint64(hi), a, uint64(u)); // u <= at
            stride <<= 1;
        }
        // Round `round` is updated at or before `at`; round `hi` is not (or is past the id space).
        while (hi - round > 1) {
            uint256 mid = (uint256(round) + hi) / 2;
            // forge-lint: disable-next-line(unsafe-typecast)
            (ok, a, u) = _probe(uint64(mid)); // round < mid < hi <= 2^64
            if (!ok) return (Read.Unreadable, 0, 0, 0);
            if (u != 0 && u <= at) {
                // forge-lint: disable-next-line(unsafe-typecast)
                (round, answer, updatedAt) = (uint64(mid), a, uint64(u)); // u <= at
            } else {
                hi = mid;
            }
        }
        return (Read.Found, round, answer, updatedAt);
    }

    /// @dev Reads round `round` of the pinned phase through the proxy with a fixed gas budget and a
    ///      fixed-size reply. `ok` is false when the read fails or replies in the wrong shape; a
    ///      missing round is a successful read of zeros.
    function _probe(uint64 round) internal view returns (bool ok, int256 answer, uint256 updatedAt) {
        address target = feed;
        uint256 roundId = (uint256(phase) << 64) | round;
        if (gasleft() < PROBE_GAS_FLOOR) revert OracleGasTooLow();
        bytes4 selector = GET_ROUND_DATA;
        assembly ("memory-safe") {
            let m := mload(0x40)
            mstore(m, selector)
            mstore(add(m, 0x04), roundId)
            // Copies at most five words, so an oversized reply costs nothing and is rejected. The
            // size is read in its own statement: Yul evaluates arguments right to left.
            ok := staticcall(PROBE_GAS, target, m, 0x24, m, 0xa0)
            ok := and(ok, eq(returndatasize(), 0xa0))
            if ok {
                answer := mload(add(m, 0x20))
                updatedAt := mload(add(m, 0x60))
            }
        }
    }

    function _load() internal view returns (State memory s) {
        s.price = lastPriceWad;
        s.night = overnightLedgerWad;
        s.settled = settled;
        s.round = lastRound;
        s.roundUpdatedAt = lastRoundUpdatedAt;
        s.unreadableSince = unreadableSince;
        s.status = status;
        s.reason = endReason;
    }

    function _store(State memory s) internal {
        // forge-lint: disable-next-line(unsafe-typecast)
        lastPriceWad = uint128(s.price); // at most type(uint128).max, checked in _step
        // forge-lint: disable-next-line(unsafe-typecast)
        overnightLedgerWad = uint128(s.night); // night <= price
        // forge-lint: disable-next-line(unsafe-typecast)
        settled = uint8(s.settled); // at most MAX_BOUNDARIES
        lastRound = s.round;
        lastRoundUpdatedAt = s.roundUpdatedAt;
        unreadableSince = s.unreadableSince;
        status = s.status;
        endReason = s.reason;
    }

    // ---------------------------------------------------------------------------------------------
    // Redemption arithmetic
    // ---------------------------------------------------------------------------------------------

    function _owed(Status status_, uint256 price, uint256 night, uint256 overnightAmount, uint256 sessionAmount)
        internal
        pure
        returns (uint256)
    {
        if (overnightAmount == sessionAmount) return overnightAmount;
        if (status_ != Status.Ended) revert PairRequired(overnightAmount, sessionAmount);
        // Matched amounts are whole pairs and redeem exactly; only the unmatched rest rounds, down.
        if (overnightAmount > sessionAmount) {
            return sessionAmount + FixedPointMathLib.fullMulDiv(overnightAmount - sessionAmount, night, price);
        }
        return overnightAmount + FixedPointMathLib.fullMulDiv(sessionAmount - overnightAmount, price - night, price);
    }

    /// @dev If the issuer took stock from the series, every redemption is cut by the same fraction,
    ///      rounding down, so the remaining holders' fraction never falls and nobody can race the rest.
    function _afterShortfall(uint256 owed, uint256 accounted) internal view returns (uint256) {
        uint256 balance = _balance();
        return balance < accounted ? FixedPointMathLib.mulDiv(owed, balance, accounted) : owed;
    }

    /// @dev A plain call, so a failing read reverts rather than looking like an empty vault.
    function _balance() internal view returns (uint256) {
        return IStock(asset).balanceOf(address(this));
    }
}
