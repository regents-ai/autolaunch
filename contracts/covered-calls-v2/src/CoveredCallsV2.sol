// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

import {IB20AssetMinimal} from "./interfaces/IB20AssetMinimal.sol";
import {IRegentRevenueStakingMinimal} from "./interfaces/IRegentRevenueStakingMinimal.sol";

/// @title CoveredCallsV2
/// @notice Fully collateralized, physically settled covered calls on one Base stock token, paid in
///         USDC, with standing buyer bids. A seller either lists stock at a premium for any buyer to
///         fill (as in V1), or sells into a buyer's bid and is paid that bid's premium at once. A
///         bidder escrows the whole premium up front; a sale into a bid locks the seller's stock as a
///         fully filled listing held by the bidder, so exercise, claim and collectStrike are the same
///         for every call. During the 24 hours after expiry a holder may pay the strike to take the
///         stock; afterwards the seller takes back what was not exercised. There is no owner, oracle,
///         upgrade or pause.
/// @dev Amounts of stock are raw B20 units, so a split or a dividend (a multiplier change) never
///      changes what a listing or bid holds or owes. Prices are USDC per whole token (10**decimals
///      raw units) and round up, in the seller's favour. A bid's escrow is always exactly
///      `costFor(amount, premiumPerToken) - costFor(filled, premiumPerToken)` plus what closing it
///      released, so the sales into one bid are together paid exactly what one fill of everything
///      sold would pay, and carry exactly its fee, however they are split. Every way out of the
///      contract is a pull by its own party with no deadline (`claim`, `collectStrike`,
///      `refundBid`), and `cancel` and `cancelBid` move no tokens, so a pause or blocklist on one
///      token or one account only delays that party's own pull of that token.
contract CoveredCallsV2 is ReentrancyGuard {
    using SafeTransferLib for address;

    /// @notice The share of each premium paid that goes to REGENT staking, in basis points.
    uint256 public constant FEE_BPS = 100;
    /// @notice How long after expiry a holder may exercise.
    uint256 public constant EXERCISE_WINDOW = 1 days;
    /// @notice Every expiry is a Friday at 21:00 UTC: the US close in winter and an hour after it in
    ///         summer, so a series never expires while the market is open. Unix time began on a
    ///         Thursday, so that is 1 day 21 hours into a week counted from the epoch.
    uint256 public constant WEEKLY_EXPIRY_OFFSET = 1 days + 21 hours;
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

    struct Bid {
        address bidder;
        uint64 expiry;
        /// Raw stock the bid asks for in all; lowered to `filled` when the bid closes.
        uint256 amount;
        /// Raw stock sold into the bid.
        uint256 filled;
        uint256 strikePerToken;
        uint256 premiumPerToken;
        /// The smallest raw amount one sale may be, unless it sells the bid's whole remainder.
        uint256 minSale;
        /// Escrow released by closing the bid and not yet refunded.
        uint256 refundDue;
    }

    uint256 public listingCount;
    mapping(uint256 listingId => Listing) internal _listings;
    /// @notice Stock a buyer may still exercise, by listing.
    mapping(uint256 listingId => mapping(address holder => uint256)) public held;
    /// @notice Stock an account may `claim` from a listing: a holder's exercised stock, and the
    ///         seller's cancelled remainder and, once booked after the window, unexercised stock.
    mapping(uint256 listingId => mapping(address holder => uint256)) public owed;

    uint256 public bidCount;
    mapping(uint256 bidId => Bid) internal _bids;

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
    /// @notice A bid was posted with `escrow` USDC, the premium for all of `amount`.
    event BidPosted(
        uint256 indexed bidId,
        address indexed bidder,
        uint256 amount,
        uint256 strikePerToken,
        uint256 premiumPerToken,
        uint64 expiry,
        uint256 minSale,
        uint256 escrow
    );
    /// @notice A bid now asks for `amount` more, and `escrow` more USDC is held for it.
    event BidRaised(uint256 indexed bidId, uint256 amount, uint256 escrow);
    /// @notice A seller sold `amount` into a bid as listing `listingId`, held by the bidder, and was
    ///         paid `premium` less `fee`.
    event SoldToBid(
        uint256 indexed bidId,
        uint256 indexed listingId,
        address indexed seller,
        uint256 amount,
        uint256 premium,
        uint256 fee
    );
    /// @notice A bid stopped selling (cancelled, or past its expiry); its `escrow` for the `unsold`
    ///         amount became the bidder's to refund.
    event BidClosed(uint256 indexed bidId, uint256 unsold, uint256 escrow);
    event BidRefunded(uint256 indexed bidId, uint256 amount);

    error ZeroAddress();
    error ZeroAmount();
    error ExpiryPassed(uint64 expiry);
    error NotAWeeklyExpiry(uint64 expiry);
    error CorporateActionScheduled(uint256 effectiveAt);
    error UnknownListing(uint256 listingId);
    error UnknownBid(uint256 bidId);
    error NotSeller(address caller);
    error NotBidder(address caller);
    error FillsClosed(uint64 expiry);
    error ExceedsAvailable(uint256 requested, uint256 available);
    error BelowMinSale(uint256 amount, uint256 minSale);
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

    // ---- listings ----

    /// @notice Locks `amount` raw stock from the caller and lists it as calls.
    function list(uint256 amount, uint256 strikePerToken, uint256 premiumPerToken, uint64 expiry)
        external
        nonReentrant
        returns (uint256 listingId)
    {
        _requireNewTerms(amount, strikePerToken, premiumPerToken, expiry);

        listingId = _openListing(amount, 0, strikePerToken, premiumPerToken, expiry);
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
        uint256 fee = _fee(premium);
        listing.filled += amount;
        held[listingId][msg.sender] += amount;
        emit Filled(listingId, msg.sender, amount, premium, fee);

        usdc.safeTransferFrom(msg.sender, listing.seller, premium - fee);
        usdc.safeTransferFrom(msg.sender, address(this), fee);
        _depositFee(fee, listingId);
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

    // ---- bids ----

    /// @notice Posts a standing bid for calls on `amount` raw stock and escrows its whole premium,
    ///         `costFor(amount, premiumPerToken)`, from the caller. Each sale into it must be at
    ///         least `minSale` raw stock, or exactly the bid's whole remainder, so a bid cannot be
    ///         broken into dust listings.
    function bid(uint256 amount, uint256 strikePerToken, uint256 premiumPerToken, uint64 expiry, uint256 minSale)
        external
        nonReentrant
        returns (uint256 bidId)
    {
        _requireNewTerms(amount, strikePerToken, premiumPerToken, expiry);
        if (minSale == 0) revert ZeroAmount();
        if (minSale > amount) revert ExceedsAvailable(minSale, amount);

        uint256 escrow = costFor(amount, premiumPerToken);
        bidId = ++bidCount;
        _bids[bidId] = Bid({
            bidder: msg.sender,
            expiry: expiry,
            amount: amount,
            filled: 0,
            strikePerToken: strikePerToken,
            premiumPerToken: premiumPerToken,
            minSale: minSale,
            refundDue: 0
        });
        emit BidPosted(bidId, msg.sender, amount, strikePerToken, premiumPerToken, expiry, minSale, escrow);

        usdc.safeTransferFrom(msg.sender, address(this), escrow);
    }

    /// @notice Asks for `amount` more raw stock on the caller's bid, at the same terms and minimum
    ///         sale, and escrows the premium that adds (`raiseCostFor`).
    function raiseBid(uint256 bidId, uint256 amount) external nonReentrant {
        Bid storage b = _bid(bidId);
        if (msg.sender != b.bidder) revert NotBidder(msg.sender);
        if (amount == 0) revert ZeroAmount();
        if (block.timestamp >= b.expiry) revert FillsClosed(b.expiry);
        _requireNoCorporateActionBefore(b.expiry);

        uint256 escrow = raiseCostFor(bidId, amount);
        b.amount += amount;
        emit BidRaised(bidId, amount, escrow);

        usdc.safeTransferFrom(msg.sender, address(this), escrow);
    }

    /// @notice Stops selling into the caller's bid, now; its unspent escrow becomes the bidder's to
    ///         `refundBid`. What was sold stays the bidder's calls.
    function cancelBid(uint256 bidId) external nonReentrant {
        Bid storage b = _bid(bidId);
        if (msg.sender != b.bidder) revert NotBidder(msg.sender);
        if (b.amount == b.filled) revert NothingToCollect();

        _closeBid(bidId, b);
    }

    /// @notice Sells calls on `amount` raw stock into a bid: locks the caller's stock as a new, fully
    ///         filled listing held by the bidder, and pays the caller its premium less the fee now.
    ///         `amount` must be at least the bid's `minSale`, or exactly its whole remainder.
    function sellToBid(uint256 bidId, uint256 amount) external nonReentrant returns (uint256 listingId) {
        Bid storage b = _bid(bidId);
        if (amount == 0) revert ZeroAmount();
        if (block.timestamp >= b.expiry) revert FillsClosed(b.expiry);
        uint256 available = b.amount - b.filled;
        if (amount > available) revert ExceedsAvailable(amount, available);
        if (amount < b.minSale && amount != available) revert BelowMinSale(amount, b.minSale);
        _requireNoCorporateActionBefore(b.expiry);

        (uint256 premium, uint256 fee) = salePremiumFor(bidId, amount);
        b.filled += amount;
        listingId = _openListing(amount, amount, b.strikePerToken, b.premiumPerToken, b.expiry);
        held[listingId][b.bidder] += amount;
        emit SoldToBid(bidId, listingId, msg.sender, amount, premium, fee);

        stock.safeTransferFrom(msg.sender, address(this), amount);
        usdc.safeTransfer(msg.sender, premium - fee);
        _depositFee(fee, listingId);
    }

    /// @notice Sends the bidder the escrow released from its bid. Once the bid's expiry has passed,
    ///         that includes all of it that was not spent.
    function refundBid(uint256 bidId) external nonReentrant {
        Bid storage b = _bid(bidId);
        if (msg.sender != b.bidder) revert NotBidder(msg.sender);
        if (block.timestamp >= b.expiry && b.amount != b.filled) _closeBid(bidId, b);
        uint256 amount = b.refundDue;
        if (amount == 0) revert NothingToCollect();

        b.refundDue = 0;
        emit BidRefunded(bidId, amount);

        usdc.safeTransfer(msg.sender, amount);
    }

    // ---- views ----

    /// @notice All the stock `account` may `claim` from a listing right now, including, for the seller
    ///         after the window, the unexercised stock that `claim` books first.
    function claimable(uint256 listingId, address account) external view returns (uint256 amount) {
        Listing storage listing = _listing(listingId);
        amount = owed[listingId][account];
        if (
            account == listing.seller && !listing.stockReturned
                && block.timestamp >= uint256(listing.expiry) + EXERCISE_WINDOW
        ) amount += listing.amount - listing.exercised;
    }

    /// @notice All the USDC `refundBid` would send the bidder right now, including, after the bid's
    ///         expiry, the unspent escrow it books first.
    function refundable(uint256 bidId) external view returns (uint256 amount) {
        Bid storage b = _bid(bidId);
        amount = b.refundDue;
        if (block.timestamp >= b.expiry) amount += _escrowLeft(b);
    }

    /// @notice USDC for `amount` raw stock at `perToken` USDC per whole token, rounded up: a fill's
    ///         premium, an exercise's strike, a new bid's escrow.
    function costFor(uint256 amount, uint256 perToken) public view returns (uint256) {
        return FixedPointMathLib.mulDivUp(amount, perToken, unit);
    }

    /// @notice The premium, in USDC, for `amount` raw stock of a listing.
    function premiumFor(uint256 listingId, uint256 amount) public view returns (uint256) {
        return costFor(amount, _listing(listingId).premiumPerToken);
    }

    /// @notice The strike, in USDC, for `amount` raw stock of a listing.
    function strikeFor(uint256 listingId, uint256 amount) public view returns (uint256) {
        return costFor(amount, _listing(listingId).strikePerToken);
    }

    /// @notice What selling `amount` into a bid pays now: its premium, and the fee taken from it.
    /// @dev The sales into one bid are together paid `costFor(filled)` and carry `_fee` of that, so
    ///      each sale takes the next slice of both.
    function salePremiumFor(uint256 bidId, uint256 amount) public view returns (uint256 premium, uint256 fee) {
        Bid storage b = _bid(bidId);
        uint256 paidBefore = costFor(b.filled, b.premiumPerToken);
        uint256 paidAfter = costFor(b.filled + amount, b.premiumPerToken);
        premium = paidAfter - paidBefore;
        fee = _fee(paidAfter) - _fee(paidBefore);
    }

    /// @notice The USDC `raiseBid` takes to add `amount` to a bid.
    function raiseCostFor(uint256 bidId, uint256 amount) public view returns (uint256) {
        Bid storage b = _bid(bidId);
        return costFor(b.amount + amount, b.premiumPerToken) - costFor(b.amount, b.premiumPerToken);
    }

    function listings(uint256 listingId) external view returns (Listing memory) {
        return _listing(listingId);
    }

    function bids(uint256 bidId) external view returns (Bid memory) {
        return _bid(bidId);
    }

    // ---- internal ----

    function _listing(uint256 listingId) internal view returns (Listing storage listing_) {
        listing_ = _listings[listingId];
        if (listing_.seller == address(0)) revert UnknownListing(listingId);
    }

    function _bid(uint256 bidId) internal view returns (Bid storage bid_) {
        bid_ = _bids[bidId];
        if (bid_.bidder == address(0)) revert UnknownBid(bidId);
    }

    /// @dev A new listing whose seller is the caller.
    function _openListing(
        uint256 amount,
        uint256 filled,
        uint256 strikePerToken,
        uint256 premiumPerToken,
        uint64 expiry
    ) internal returns (uint256 listingId) {
        listingId = ++listingCount;
        _listings[listingId] = Listing({
            seller: msg.sender,
            expiry: expiry,
            stockReturned: false,
            amount: amount,
            filled: filled,
            exercised: 0,
            strikePerToken: strikePerToken,
            premiumPerToken: premiumPerToken,
            strikePaid: 0,
            strikeCollected: 0
        });
    }

    /// @dev Stops a bid selling and releases its unspent escrow to the bidder's refund.
    function _closeBid(uint256 bidId, Bid storage b) internal {
        uint256 unsold = b.amount - b.filled;
        uint256 escrow = _escrowLeft(b);
        b.amount = b.filled;
        b.refundDue += escrow;
        emit BidClosed(bidId, unsold, escrow);
    }

    /// @dev The escrow still standing behind a bid's unsold amount.
    function _escrowLeft(Bid storage b) internal view returns (uint256) {
        return costFor(b.amount, b.premiumPerToken) - costFor(b.filled, b.premiumPerToken);
    }

    /// @dev 1% of a premium, rounded up.
    function _fee(uint256 premium) internal pure returns (uint256) {
        return FixedPointMathLib.mulDivUp(premium, FEE_BPS, 10_000);
    }

    /// @dev Hands `fee` USDC, already in this contract, to live REGENT staking, which must report
    ///      receiving exactly that.
    function _depositFee(uint256 fee, uint256 listingId) internal {
        if (fee == 0) return;
        usdc.safeApprove(staking, fee);
        uint256 received = IRegentRevenueStakingMinimal(staking).depositUSDC(fee, FEE_SOURCE_TAG, bytes32(listingId));
        if (received != fee) revert DepositMismatch(fee, received);
    }

    /// @dev Terms a new listing or bid must have.
    function _requireNewTerms(uint256 amount, uint256 strikePerToken, uint256 premiumPerToken, uint64 expiry)
        internal
        view
    {
        if (amount == 0 || strikePerToken == 0 || premiumPerToken == 0) revert ZeroAmount();
        if (expiry % 1 weeks != WEEKLY_EXPIRY_OFFSET) revert NotAWeeklyExpiry(expiry);
        if (expiry <= block.timestamp) revert ExpiryPassed(expiry);
        _requireNoCorporateActionBefore(expiry);
    }

    /// @dev A scheduled multiplier change (a split or a dividend) taking effect before the exercise
    ///      window closes would change the share count mid-life, so no listing, bid, fill or sale may
    ///      span one.
    function _requireNoCorporateActionBefore(uint64 expiry) internal view {
        uint256 effectiveAt = IB20AssetMinimal(stock).effectiveAt();
        if (effectiveAt > block.timestamp && effectiveAt < uint256(expiry) + EXERCISE_WINDOW) {
            revert CorporateActionScheduled(effectiveAt);
        }
    }
}
