// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

import {IB20AssetMinimal} from "./interfaces/IB20AssetMinimal.sol";
import {IRegentRevenueStakingMinimal} from "./interfaces/IRegentRevenueStakingMinimal.sol";

/// @title CoveredCallsV1
/// @notice Fully collateralized, physically settled covered calls on one Base stock token, paid in
///         USDC. A seller locks stock and lists it with a strike, a premium and an expiry; any buyer
///         fills part or all of it by paying the premium; during the 24 hours after expiry a holder
///         may pay the strike to take the stock; afterwards the seller takes back what was not
///         exercised. There is no owner, oracle, upgrade or pause.
/// @dev Amounts of stock are raw B20 units, so a split or a dividend (a multiplier change) never
///      changes what a listing holds or owes. Prices are USDC per whole token (10**decimals raw
///      units) and every USDC amount rounds up, in the seller's favour. Each call moves at most one
///      token, and stock only ever leaves through `claim` and USDC strike through `collectStrike`,
///      both pulls by their own party with no deadline. So a pause or blocklist on one token, or on
///      one party, only ever delays that party's own pull of that token: `cancel` and `exercise`
///      move no stock, and nothing a seller is owed in USDC waits on the stock, or the reverse.
contract CoveredCallsV1 is ReentrancyGuard {
    using SafeTransferLib for address;

    /// @notice The share of each premium paid that goes to REGENT staking, in basis points.
    uint256 public constant FEE_BPS = 100;
    /// @notice How long after expiry a holder may exercise.
    uint256 public constant EXERCISE_WINDOW = 1 days;
    /// @notice The tag every fee deposit carries in REGENT staking's events.
    // forge-lint: disable-next-line(unsafe-typecast)
    bytes32 public constant FEE_SOURCE_TAG = bytes32("autolaunch-covered-calls");

    address public immutable stock;
    address public immutable usdc;
    address public immutable staking;
    /// @notice Raw units in one whole stock token.
    uint256 public immutable unit;

    struct Listing {
        address seller;
        uint64 expiry;
        bool stockReturned;
        uint256 amount;
        uint256 filled;
        uint256 exercised;
        uint256 strikePerToken;
        uint256 premiumPerToken;
        uint256 strikePaid;
        uint256 strikeCollected;
    }

    uint256 public listingCount;
    mapping(uint256 listingId => Listing) internal _listings;
    /// @notice Stock a buyer may still exercise, by listing.
    mapping(uint256 listingId => mapping(address holder => uint256)) public held;
    /// @notice Stock an account may `claim` from a listing: a holder's exercised stock, and the
    ///         seller's cancelled remainder and, once booked after the window, unexercised stock.
    mapping(uint256 listingId => mapping(address holder => uint256)) public owed;

    event Listed(
        uint256 indexed listingId,
        address indexed seller,
        uint256 amount,
        uint256 strikePerToken,
        uint256 premiumPerToken,
        uint64 expiry
    );
    event Filled(uint256 indexed listingId, address indexed buyer, uint256 amount, uint256 premium, uint256 fee);
    /// @notice The unsold remainder stopped selling and became the seller's to claim.
    event Cancelled(uint256 indexed listingId, uint256 unsold);
    event Exercised(uint256 indexed listingId, address indexed holder, uint256 amount, uint256 strike);
    /// @notice After the window, the stock not exercised became the seller's to claim.
    event StockReturned(uint256 indexed listingId, uint256 amount);
    event Claimed(uint256 indexed listingId, address indexed account, uint256 amount);
    event StrikeCollected(uint256 indexed listingId, uint256 amount);

    error ZeroAddress();
    error ZeroAmount();
    error ExpiryPassed(uint64 expiry);
    error CorporateActionScheduled(uint256 effectiveAt);
    error UnknownListing(uint256 listingId);
    error NotSeller(address caller);
    error FillsClosed(uint64 expiry);
    error ExceedsAvailable(uint256 requested, uint256 available);
    error OutsideExerciseWindow(uint64 expiry);
    error NothingToCollect();
    error DepositMismatch(uint256 expected, uint256 received);

    constructor(address stock_, address usdc_, address staking_) {
        if (stock_ == address(0) || usdc_ == address(0) || staking_ == address(0)) revert ZeroAddress();
        stock = stock_;
        usdc = usdc_;
        staking = staking_;
        unit = 10 ** IB20AssetMinimal(stock_).decimals();
    }

    /// @notice Locks `amount` raw stock from the caller and lists it as calls.
    function list(uint256 amount, uint256 strikePerToken, uint256 premiumPerToken, uint64 expiry)
        external
        nonReentrant
        returns (uint256 listingId)
    {
        if (amount == 0 || strikePerToken == 0 || premiumPerToken == 0) revert ZeroAmount();
        if (expiry <= block.timestamp) revert ExpiryPassed(expiry);
        _requireNoCorporateActionBefore(expiry);

        listingId = ++listingCount;
        _listings[listingId] = Listing({
            seller: msg.sender,
            expiry: expiry,
            stockReturned: false,
            amount: amount,
            filled: 0,
            exercised: 0,
            strikePerToken: strikePerToken,
            premiumPerToken: premiumPerToken,
            strikePaid: 0,
            strikeCollected: 0
        });
        emit Listed(listingId, msg.sender, amount, strikePerToken, premiumPerToken, expiry);

        stock.safeTransferFrom(msg.sender, address(this), amount);
    }

    /// @notice Buys `amount` raw stock's worth of calls from a listing, paying its premium now.
    function fill(uint256 listingId, uint256 amount) external nonReentrant {
        Listing storage listing = _listing(listingId);
        if (amount == 0) revert ZeroAmount();
        if (block.timestamp >= listing.expiry) revert FillsClosed(listing.expiry);
        uint256 available = listing.amount - listing.filled;
        if (amount > available) revert ExceedsAvailable(amount, available);
        _requireNoCorporateActionBefore(listing.expiry);

        uint256 premium = premiumFor(listingId, amount);
        uint256 fee = premium * FEE_BPS / 10_000;
        listing.filled += amount;
        held[listingId][msg.sender] += amount;
        emit Filled(listingId, msg.sender, amount, premium, fee);

        usdc.safeTransferFrom(msg.sender, listing.seller, premium - fee);
        if (fee != 0) {
            usdc.safeTransferFrom(msg.sender, address(this), fee);
            usdc.safeApprove(staking, fee);
            uint256 received =
                IRegentRevenueStakingMinimal(staking).depositUSDC(fee, FEE_SOURCE_TAG, bytes32(listingId));
            if (received != fee) revert DepositMismatch(fee, received);
        }
    }

    /// @notice Stops the unsold part of the caller's listing selling, now; it becomes the seller's to
    ///         `claim`. What was sold stays locked for its buyers.
    function cancel(uint256 listingId) external nonReentrant {
        Listing storage listing = _listing(listingId);
        if (msg.sender != listing.seller) revert NotSeller(msg.sender);
        uint256 unsold = listing.amount - listing.filled;
        if (unsold == 0 || listing.stockReturned) revert NothingToCollect();

        listing.amount = listing.filled;
        owed[listingId][msg.sender] += unsold;
        emit Cancelled(listingId, unsold);
    }

    /// @notice During the exercise window, pays the strike for `amount` of the caller's calls. The
    ///         stock is then the caller's to `claim`.
    function exercise(uint256 listingId, uint256 amount) external nonReentrant {
        Listing storage listing = _listing(listingId);
        if (block.timestamp < listing.expiry || block.timestamp >= uint256(listing.expiry) + EXERCISE_WINDOW) {
            revert OutsideExerciseWindow(listing.expiry);
        }
        if (amount == 0) revert ZeroAmount();
        uint256 holding = held[listingId][msg.sender];
        if (amount > holding) revert ExceedsAvailable(amount, holding);

        uint256 strike = strikeFor(listingId, amount);
        held[listingId][msg.sender] = holding - amount;
        owed[listingId][msg.sender] += amount;
        listing.exercised += amount;
        listing.strikePaid += strike;
        emit Exercised(listingId, msg.sender, amount, strike);

        usdc.safeTransferFrom(msg.sender, address(this), strike);
    }

    /// @notice Sends the caller all the stock it is owed on a listing. For the seller, once the
    ///         exercise window has closed, that includes every unit not exercised.
    function claim(uint256 listingId) external nonReentrant {
        Listing storage listing = _listing(listingId);
        if (
            msg.sender == listing.seller && !listing.stockReturned
                && block.timestamp >= uint256(listing.expiry) + EXERCISE_WINDOW
        ) {
            uint256 unexercised = listing.amount - listing.exercised;
            listing.stockReturned = true;
            owed[listingId][msg.sender] += unexercised;
            emit StockReturned(listingId, unexercised);
        }
        uint256 amount = owed[listingId][msg.sender];
        if (amount == 0) revert NothingToCollect();

        owed[listingId][msg.sender] = 0;
        emit Claimed(listingId, msg.sender, amount);

        stock.safeTransfer(msg.sender, amount);
    }

    /// @notice Sends the seller the strike paid on a listing so far.
    function collectStrike(uint256 listingId) external nonReentrant {
        Listing storage listing = _listing(listingId);
        if (msg.sender != listing.seller) revert NotSeller(msg.sender);
        uint256 amount = listing.strikePaid - listing.strikeCollected;
        if (amount == 0) revert NothingToCollect();

        listing.strikeCollected = listing.strikePaid;
        emit StrikeCollected(listingId, amount);

        usdc.safeTransfer(msg.sender, amount);
    }

    /// @notice The premium, in USDC, for `amount` raw stock of a listing.
    function premiumFor(uint256 listingId, uint256 amount) public view returns (uint256) {
        return FixedPointMathLib.mulDivUp(amount, _listing(listingId).premiumPerToken, unit);
    }

    /// @notice The strike, in USDC, for `amount` raw stock of a listing.
    function strikeFor(uint256 listingId, uint256 amount) public view returns (uint256) {
        return FixedPointMathLib.mulDivUp(amount, _listing(listingId).strikePerToken, unit);
    }

    function listings(uint256 listingId) external view returns (Listing memory) {
        return _listing(listingId);
    }

    function _listing(uint256 listingId) internal view returns (Listing storage listing_) {
        listing_ = _listings[listingId];
        if (listing_.seller == address(0)) revert UnknownListing(listingId);
    }

    /// @dev A scheduled multiplier change (a split or a dividend) taking effect before the exercise
    ///      window closes would change the share count mid-life, so no listing or fill may span one.
    function _requireNoCorporateActionBefore(uint64 expiry) internal view {
        uint256 effectiveAt = IB20AssetMinimal(stock).effectiveAt();
        if (effectiveAt > block.timestamp && effectiveAt < uint256(expiry) + EXERCISE_WINDOW) {
            revert CorporateActionScheduled(effectiveAt);
        }
    }
}
