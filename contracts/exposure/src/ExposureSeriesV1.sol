// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

import {ExposureLegV1} from "./ExposureLegV1.sol";
import {IFinalizedPrintOracle} from "./interfaces/IFinalizedPrintOracle.sol";

interface IStock {
    function decimals() external view returns (uint8);
    function balanceOf(address account) external view returns (uint256);
}

/// @title ExposureSeriesV1
/// @notice Splits one Base stock token into two isolated exposure tokens for a fixed term. Depositing
///         raw stock mints the same amount of OVERNIGHT and SESSION; one of each always redeems for
///         exactly one raw unit back. Between the scheduled prints, OVERNIGHT carries every
///         close-to-open move and SESSION every open-to-close move, in dollars on a ledger that
///         starts at half the stock's price. At the end of the term each leg redeems for its
///         ledger's share of the stock. There is no owner, admin, upgrade, pause or fee.
/// @dev The two ledgers always sum to the last print: `N + S = P`. Only `P` and `N` are stored, so
///      `S = P - N` and `0 <= N <= P` hold by construction. A print that would take either ledger to
///      zero or below ends the series there, with the other leg owning all of the stock: no leg can
///      ever claim more than the stock behind the pairs. Collateral is raw B20 units throughout, so a
///      split or a dividend changes only the oracle's price per raw token, never what the series
///      holds or owes.
///
///      Prints are applied strictly in schedule order by anyone, one per `settle`. A print counts
///      only if the oracle made it final within `maxReportDelay` of its scheduled time; once that
///      deadline passes with no such print, anyone may end the series at the last applied ledgers.
///      The oracle is read with a fixed gas budget and a fixed-size reply, so a broken oracle counts
///      as a missing print and a caller cannot fake an outage by sending too little gas.
contract ExposureSeriesV1 is ReentrancyGuard {
    using SafeTransferLib for address;

    enum Status {
        /// Waiting for the first close; nothing can be minted yet.
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
        MissingPrint
    }

    struct Terms {
        address asset;
        address oracle;
        bytes32 feedId;
        /// keccak256 of the published terms: stock, feed, calendar, report delay and the payout rules.
        bytes32 termsHash;
        uint64 maxReportDelay;
        /// Most raw stock the series may hold for outstanding pairs at once.
        uint256 depositCap;
        /// Initial close, then open/close pairs, ending on a close. Strictly increasing UTC seconds.
        uint64[] boundaries;
        string overnightName;
        string overnightSymbol;
        string sessionName;
        string sessionSymbol;
    }

    /// @notice A year of trading days: one initial close and 252 open/close pairs.
    uint256 public constant MAX_BOUNDARIES = 505;
    uint256 public constant MAX_REPORT_DELAY = 7 days;
    /// @notice Gas each oracle read may use. A read that needs more counts as no print.
    uint256 public constant ORACLE_GAS = 100_000;
    /// @dev Enough that 63/64 of what is left at the call still covers `ORACLE_GAS`.
    uint256 internal constant ORACLE_GAS_FLOOR = 105_000;

    address public immutable asset;
    ExposureLegV1 public immutable overnight;
    ExposureLegV1 public immutable session;
    address public immutable oracle;
    bytes32 public immutable feedId;
    bytes32 public immutable termsHash;
    uint64 public immutable maxReportDelay;
    uint256 public immutable depositCap;

    uint64[] internal _boundaries;

    /// @notice The last applied print, USD per whole raw token, 18 decimals.
    uint128 public lastPriceWad;
    /// @notice OVERNIGHT's ledger in the same units; SESSION's is `lastPriceWad - overnightLedgerWad`.
    uint128 public overnightLedgerWad;
    Status public status;
    EndReason public endReason;
    /// @notice How many boundaries have been applied; the next one is `boundaries(settled)`.
    uint64 public settled;
    /// @notice Raw stock the outstanding legs are owed. The balance can exceed it (donations, dust),
    ///         never the other way round unless the issuer takes stock from the series.
    uint256 public accountedAssets;

    event Minted(address indexed account, uint256 assets);
    /// @notice `owed` is what the legs were worth in raw stock; `paid` is less only after the issuer
    ///         took stock from the series, when every redemption is cut by the same fraction.
    event Redeemed(address indexed account, uint256 overnightAmount, uint256 sessionAmount, uint256 owed, uint256 paid);
    event PrintApplied(
        uint256 indexed index,
        uint64 scheduledAt,
        uint256 priceWad,
        uint256 overnightLedgerWad,
        uint256 sessionLedgerWad
    );
    event SeriesEnded(EndReason reason, uint256 priceWad, uint256 overnightLedgerWad, uint256 sessionLedgerWad);

    error ZeroAddress();
    error ZeroAmount();
    error BadSchedule();
    error BadReportDelay();
    error CapReached(uint256 room);
    error NotActive();
    error AlreadyEnded();
    error PairRequired(uint256 overnightAmount, uint256 sessionAmount);
    error PrintUnavailable(uint64 scheduledAt);
    error PrintNotOverdue(uint256 deadline);
    error PrintAvailable(uint64 scheduledAt);
    error OracleGasTooLow();
    error BackingShort(uint256 balance, uint256 accounted);
    error DepositMismatch(uint256 expected, uint256 received);

    constructor(Terms memory terms) {
        if (terms.asset == address(0) || terms.oracle == address(0)) revert ZeroAddress();
        if (terms.maxReportDelay == 0 || terms.maxReportDelay > MAX_REPORT_DELAY) revert BadReportDelay();
        if (terms.depositCap == 0) revert ZeroAmount();
        uint256 count = terms.boundaries.length;
        if (count < 3 || count > MAX_BOUNDARIES || count % 2 == 0 || terms.boundaries[0] == 0) revert BadSchedule();
        for (uint256 i = 1; i < count; ++i) {
            if (terms.boundaries[i] <= terms.boundaries[i - 1]) revert BadSchedule();
        }

        asset = terms.asset;
        oracle = terms.oracle;
        feedId = terms.feedId;
        termsHash = terms.termsHash;
        maxReportDelay = terms.maxReportDelay;
        depositCap = terms.depositCap;
        _boundaries = terms.boundaries;

        uint8 decimals = IStock(terms.asset).decimals();
        overnight = new ExposureLegV1(terms.overnightName, terms.overnightSymbol, decimals);
        session = new ExposureLegV1(terms.sessionName, terms.sessionSymbol, decimals);
    }

    // ---------------------------------------------------------------------------------------------
    // Holders
    // ---------------------------------------------------------------------------------------------

    /// @notice Deposits `assets` raw stock from the caller and mints the caller `assets` of each
    ///         leg. A pair is always worth exactly the stock behind it, so minting at any point in
    ///         the term is fair.
    function mint(uint256 assets) external nonReentrant {
        if (status != Status.Active) revert NotActive();
        if (assets == 0) revert ZeroAmount();
        uint256 accounted = accountedAssets;
        if (assets > depositCap - accounted) revert CapReached(depositCap - accounted);
        uint256 balance = _balance();
        // New stock must not make up a shortfall the issuer caused for existing holders.
        if (balance < accounted) revert BackingShort(balance, accounted);

        asset.safeTransferFrom(msg.sender, address(this), assets);
        uint256 received = _balance() - balance;
        if (received != assets) revert DepositMismatch(assets, received);

        accountedAssets = accounted + assets;
        overnight.mint(msg.sender, assets);
        session.mint(msg.sender, assets);
        emit Minted(msg.sender, assets);
    }

    /// @notice Burns the caller's legs and sends the caller the stock they are worth. Stock only
    ///         ever goes to the account redeeming, so the issuer's own transfer rules apply to it.
    ///         Before the series ends only whole pairs redeem (equal amounts, one raw unit each);
    ///         afterwards any mix does, at the frozen ledgers.
    function redeem(uint256 overnightAmount, uint256 sessionAmount) external nonReentrant returns (uint256 paid) {
        if (overnightAmount == 0 && sessionAmount == 0) revert ZeroAmount();
        uint256 owed = _owed(overnightAmount, sessionAmount);
        uint256 accounted = accountedAssets;
        paid = _afterShortfall(owed, accounted);
        // Legs worth something are never burned for nothing, even after a total seizure.
        if (paid == 0 && owed != 0) revert BackingShort(_balance(), accounted);

        if (overnightAmount != 0) overnight.burn(msg.sender, overnightAmount);
        if (sessionAmount != 0) session.burn(msg.sender, sessionAmount);
        accountedAssets = accounted - owed;

        if (paid != 0) asset.safeTransfer(msg.sender, paid);
        emit Redeemed(msg.sender, overnightAmount, sessionAmount, owed, paid);
    }

    /// @notice The raw stock `redeem` would send for these amounts right now.
    function previewRedeem(uint256 overnightAmount, uint256 sessionAmount) external view returns (uint256) {
        return _afterShortfall(_owed(overnightAmount, sessionAmount), accountedAssets);
    }

    // ---------------------------------------------------------------------------------------------
    // Prints (anyone)
    // ---------------------------------------------------------------------------------------------

    /// @notice Applies the next scheduled print. The first is the initial close, which sets both
    ///         ledgers to half its price and opens minting. An open moves OVERNIGHT by the change
    ///         since the last close; a close moves SESSION by the change since the open.
    function settle() external {
        if (status == Status.Ended) revert AlreadyEnded();
        uint256 index = settled;
        uint64 scheduledAt = _boundaries[index];
        uint256 price = _eligiblePrice(index, scheduledAt);
        if (price == 0) revert PrintUnavailable(scheduledAt);

        uint256 night;
        EndReason reason;
        if (index == 0) {
            night = price / 2;
            if (night == 0) reason = EndReason.OvernightDepleted;
            status = Status.Active;
        } else if (index % 2 == 1) {
            // Open: SESSION holds; OVERNIGHT is whatever the new price leaves above it.
            uint256 day = uint256(lastPriceWad) - overnightLedgerWad;
            if (price <= day) {
                night = 0;
                reason = EndReason.OvernightDepleted;
            } else {
                night = price - day;
            }
        } else {
            // Close: OVERNIGHT holds; SESSION is whatever the new price leaves above it.
            night = overnightLedgerWad;
            if (price <= night) {
                night = price;
                reason = EndReason.SessionDepleted;
            }
        }

        // forge-lint: disable-next-line(unsafe-typecast)
        lastPriceWad = uint128(price); // _eligiblePrice returns at most type(uint128).max
        // forge-lint: disable-next-line(unsafe-typecast)
        overnightLedgerWad = uint128(night); // night <= price
        // forge-lint: disable-next-line(unsafe-typecast)
        settled = uint64(index + 1); // at most MAX_BOUNDARIES
        emit PrintApplied(index, scheduledAt, price, night, price - night);

        if (reason != EndReason.None) {
            _end(reason);
        } else if (index + 1 == _boundaries.length) {
            _end(EndReason.Maturity);
        }
    }

    /// @notice Ends the series at the last applied ledgers when the next print was not made final
    ///         by its deadline. A print that was final in time blocks this however late it is
    ///         applied, so a slow keeper can never pick an older allocation.
    function endOnMissingPrint() external {
        if (status == Status.Ended) revert AlreadyEnded();
        uint256 index = settled;
        uint64 scheduledAt = _boundaries[index];
        uint256 deadline = uint256(scheduledAt) + maxReportDelay;
        if (block.timestamp <= deadline) revert PrintNotOverdue(deadline);
        if (_eligiblePrice(index, scheduledAt) != 0) revert PrintAvailable(scheduledAt);
        _end(EndReason.MissingPrint);
    }

    // ---------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------

    function sessionLedgerWad() external view returns (uint256) {
        return uint256(lastPriceWad) - overnightLedgerWad;
    }

    function boundaries(uint256 index) external view returns (uint64) {
        return _boundaries[index];
    }

    function boundaryCount() external view returns (uint256) {
        return _boundaries.length;
    }

    /// @notice The next print to apply, or zero once the series has ended.
    function nextBoundaryAt() external view returns (uint64) {
        return status == Status.Ended ? 0 : _boundaries[settled];
    }

    // ---------------------------------------------------------------------------------------------
    // Internal
    // ---------------------------------------------------------------------------------------------

    function _owed(uint256 overnightAmount, uint256 sessionAmount) internal view returns (uint256) {
        if (status != Status.Ended) {
            if (overnightAmount != sessionAmount) revert PairRequired(overnightAmount, sessionAmount);
            return overnightAmount;
        }
        // Matched amounts are whole pairs and redeem exactly; only the unmatched rest rounds, down.
        uint256 price = lastPriceWad;
        uint256 night = overnightLedgerWad;
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

    function _end(EndReason reason) internal {
        status = Status.Ended;
        endReason = reason;
        uint256 price = lastPriceWad;
        uint256 night = overnightLedgerWad;
        emit SeriesEnded(reason, price, night, price - night);
    }

    /// @dev The print for boundary `index` if it is usable, else zero. Usable means: for exactly
    ///      this boundary, positive, fits in uint128, and made final on chain no earlier than the
    ///      boundary and no later than its deadline.
    function _eligiblePrice(uint256 index, uint64 scheduledAt) internal view returns (uint256 price) {
        bytes memory request = abi.encodeCall(IFinalizedPrintOracle.getPrint, (feedId, scheduledAt, index % 2 == 1));
        address target = oracle;
        if (gasleft() < ORACLE_GAS_FLOOR) revert OracleGasTooLow();
        bool ok;
        uint256 observedAt;
        uint256 finalizedAt;
        assembly ("memory-safe") {
            let out := mload(0x40)
            // Copies at most three words, so an oversized reply costs nothing and is rejected. The
            // size is read in its own statement: Yul evaluates arguments right to left.
            ok := staticcall(ORACLE_GAS, target, add(request, 0x20), mload(request), out, 0x60)
            ok := and(ok, eq(returndatasize(), 0x60))
            if ok {
                price := mload(out)
                observedAt := mload(add(out, 0x20))
                finalizedAt := mload(add(out, 0x40))
            }
        }
        uint256 deadline = uint256(scheduledAt) + maxReportDelay;
        if (
            !ok || price > type(uint128).max || observedAt != scheduledAt || finalizedAt < scheduledAt
                || finalizedAt > deadline || finalizedAt > block.timestamp
        ) return 0;
    }

    /// @dev A plain call, so a failing read reverts rather than looking like an empty vault.
    function _balance() internal view returns (uint256) {
        return IStock(asset).balanceOf(address(this));
    }
}
