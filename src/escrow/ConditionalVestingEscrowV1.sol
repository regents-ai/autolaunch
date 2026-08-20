// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {IERC20Minimal} from "../interfaces/IERC20Minimal.sol";
import {BaseBindings} from "../bindings/BaseBindings.sol";
import {IContinuousClearingAuction} from "continuous-clearing-auction/interfaces/IContinuousClearingAuction.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {Initializable} from "solady/utils/Initializable.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/// @title ConditionalVestingEscrowV1
/// @notice The fixed, implementation-locked clone target that custodies one launch's pending 85%
///         SUBJECT allocation until that launch reaches exactly one terminal state.
/// @dev Authority is three immutable-in-lifecycle bindings fixed at initialization: the launch's
///      SUBJECT token, the launch treasury that is the only vesting beneficiary, and the strategy
///      that is the only account allowed to resolve the launch. There is no upgrade path, no
///      reinitializer, no setter, no pending release, no beneficiary rotation, no unsupported-token
///      or native rescue, no retry state, no technical-failure state, and no second resolution.
///
///      Named invariants: `C1-I1` terminal escrow, `C1-I6` fixed authority, `C1-I7` atomic failure.
contract ConditionalVestingEscrowV1 is Initializable, ReentrancyGuard {
    using SafeTransferLib for address;

    /// @notice The only lifecycle a launch can occupy.
    /// @dev The implementation's own storage is never a launch lifecycle: its initializer is
    ///      disabled at construction, so it binds no strategy and no treasury and every entry
    ///      point below is unreachable on it.
    enum Lifecycle {
        Pending,
        Graduated,
        Failed
    }

    /// @notice The exact SUBJECT supply a launch must present before escrow accepts custody.
    uint256 public constant TOTAL_SUPPLY = 100_000_000_000e18;

    /// @notice The exact pending allocation escrow custodies, 85% of `TOTAL_SUPPLY`.
    uint256 public constant PENDING_ALLOCATION = 85_000_000_000e18;

    /// @notice The exact linear vesting duration measured from the activation timestamp.
    uint256 public constant VESTING_DURATION = 365 days;

    /// @notice The launch's SUBJECT token.
    address public subject;

    /// @notice The only account vested SUBJECT is ever released to.
    address public treasury;

    /// @notice The only account allowed to resolve this launch.
    address public strategy;

    /// @notice This launch's terminal state, or `Pending` while it is unresolved.
    Lifecycle public lifecycle;

    /// @notice The timestamp linear vesting is measured from, set once by `activateVesting`.
    uint64 public vestingStart;

    /// @notice Whether the graduated unsold-SUBJECT sweep has already run.
    bool public graduatedSweepDone;

    /// @notice The cumulative SUBJECT already released to the treasury.
    uint256 public totalReleased;

    event EscrowInitialized(address indexed subject, address indexed treasury, address indexed strategy);
    event GraduatedUnsoldSubjectSwept(address indexed auction, uint256 amount);
    event VestingActivated(uint64 startTimestamp, uint256 duration);
    event SubjectReleased(address indexed treasury, uint256 amount);
    event LaunchFailed(address indexed auction, uint256 retiredAmount);
    event LateFailedSubjectRetired(uint256 amount);

    error ZeroAddress();
    error SelfAddress();
    error InvalidSubjectSupply(uint256 found);
    error InexactTransfer(uint256 expected, uint256 found);
    error NotStrategy(address caller);
    error NotPending(Lifecycle found);
    error NotGraduated(Lifecycle found);
    error NotFailed(Lifecycle found);
    error AuctionTokenMismatch(address found);
    error AuctionRecipientMismatch(address found);
    error AuctionIsGraduated();
    error AuctionIsNotGraduated();
    error GraduatedSweepAlreadyDone();
    error GraduatedSweepNotDone();
    error InexactFinalInventory(uint256 found);

    /// @dev The implementation is permanently uninitializable, so only clones hold launches.
    constructor() {
        _disableInitializers();
    }

    modifier onlyStrategy() {
        if (msg.sender != strategy) revert NotStrategy(msg.sender);
        _;
    }

    modifier whilePending() {
        if (lifecycle != Lifecycle.Pending) revert NotPending(lifecycle);
        _;
    }

    /// @notice Bind this clone to one launch and take custody of exactly `PENDING_ALLOCATION`.
    /// @dev Runs exactly once per clone. The initializer is also the funding caller: the exact 85%
    ///      is pulled from `msg.sender` inside this call, so a bound-but-unfunded escrow cannot
    ///      exist. `C1-I6`.
    function initialize(address subject_, address treasury_, address strategy_) external initializer {
        if (subject_ == address(0) || treasury_ == address(0) || strategy_ == address(0)) revert ZeroAddress();
        if (subject_ == address(this) || treasury_ == address(this) || strategy_ == address(this)) {
            revert SelfAddress();
        }

        uint256 supply = IERC20Minimal(subject_).totalSupply();
        if (supply != TOTAL_SUPPLY) revert InvalidSubjectSupply(supply);

        subject = subject_;
        treasury = treasury_;
        strategy = strategy_;

        uint256 before = subject_.balanceOf(address(this));
        subject_.safeTransferFrom(msg.sender, address(this), PENDING_ALLOCATION);
        uint256 received = subject_.balanceOf(address(this)) - before;
        if (received != PENDING_ALLOCATION) revert InexactTransfer(PENDING_ALLOCATION, received);

        emit EscrowInitialized(subject_, treasury_, strategy_);
    }

    /// @notice Resolve this launch as economically failed and retire exactly `TOTAL_SUPPLY`.
    /// @dev The strategy has already sent its isolated 5% reserve when it calls this. Escrow
    ///      checkpoints the named auction, proves it did not graduate, sweeps the failed auction's
    ///      10% back, and requires the resulting balance to be the whole supply to the unit. A
    ///      short or long inventory deliberately leaves the launch unresolved rather than retiring
    ///      a partial supply. `C1-I1`, `C1-I7`.
    ///
    ///      The terminal state is recorded before any state-changing external call, so a re-entrant
    ///      auction meets a launch that is already `Failed` and is refused by `whilePending` even
    ///      before the reentrancy guard answers. Any later revert restores it atomically.
    function resolveFailure(address auction) external nonReentrant onlyStrategy whilePending {
        _requireCanonicalAuction(auction);
        lifecycle = Lifecycle.Failed;

        // slither-disable-next-line unused-return
        IContinuousClearingAuction(auction).checkpoint();
        if (IContinuousClearingAuction(auction).isGraduated()) revert AuctionIsGraduated();
        IContinuousClearingAuction(auction).sweepUnsoldTokens();

        address token = subject;
        uint256 held = token.balanceOf(address(this));
        if (held != TOTAL_SUPPLY) revert InexactFinalInventory(held);

        emit LaunchFailed(auction, TOTAL_SUPPLY);

        token.safeTransfer(BaseBindings.DEAD_ADDRESS, TOTAL_SUPPLY);
        uint256 remaining = token.balanceOf(address(this));
        if (remaining != 0) revert InexactTransfer(TOTAL_SUPPLY, TOTAL_SUPPLY - remaining);
    }

    /// @notice Sweep a graduated auction's unsold SUBJECT into escrow, exactly once, before vesting.
    /// @dev Escrow owns this sweep because escrow is the auction's recipient and `sweepUnsoldTokens`
    ///      is recipient-only. It checkpoints first so `isGraduated` and `remainingSupply` are the
    ///      terminal values, then proves the exact balance delta — which may legitimately be zero
    ///      for a sold-out auction. It changes no lifecycle state and creates no retry mode.
    ///
    ///      The one-shot flag is recorded before any state-changing external call, so a re-entrant
    ///      auction meets a sweep that has already run. Any later revert restores it atomically.
    function sweepGraduatedUnsoldSubject(address auction) external nonReentrant onlyStrategy whilePending {
        if (graduatedSweepDone) revert GraduatedSweepAlreadyDone();
        _requireCanonicalAuction(auction);
        graduatedSweepDone = true;

        // slither-disable-next-line unused-return
        IContinuousClearingAuction(auction).checkpoint();
        if (!IContinuousClearingAuction(auction).isGraduated()) revert AuctionIsNotGraduated();

        address token = subject;
        uint256 expected = IContinuousClearingAuction(auction).remainingSupply();
        uint256 before = token.balanceOf(address(this));

        IContinuousClearingAuction(auction).sweepUnsoldTokens();

        uint256 received = token.balanceOf(address(this)) - before;
        if (received != expected) revert InexactTransfer(expected, received);

        emit GraduatedUnsoldSubjectSwept(auction, expected);
    }

    /// @notice Resolve this launch as graduated and start the 365-day schedule at this timestamp.
    /// @dev Callable only after the graduated sweep completed, so the vesting schedule always
    ///      opens over the launch's whole final escrow inventory. The start and the duration are
    ///      never caller-supplied. `C1-I1`.
    function activateVesting() external onlyStrategy whilePending {
        if (!graduatedSweepDone) revert GraduatedSweepNotDone();

        vestingStart = uint64(block.timestamp);
        lifecycle = Lifecycle.Graduated;

        emit VestingActivated(uint64(block.timestamp), VESTING_DURATION);
    }

    /// @notice Release every SUBJECT unit vested so far to the fixed treasury.
    /// @dev Permissionless to call and impossible to redirect: the recipient is always `treasury`.
    ///      The allocation is recomputed from live custody at each call, so SUBJECT that arrives
    ///      after graduation joins the same original schedule and is immediately vested in
    ///      proportion to elapsed time. State advances before the transfer, so repeated calls
    ///      cannot over-release. A zero releasable amount is a no-op. `C1-I1`, `C1-I6`.
    // slither-disable-next-line incorrect-equality,timestamp
    function release() external nonReentrant {
        if (lifecycle != Lifecycle.Graduated) revert NotGraduated(lifecycle);

        address token = subject;
        uint256 released = totalReleased;
        uint256 held = token.balanceOf(address(this));
        uint256 totalAllocation = held + released;

        uint256 elapsed = block.timestamp - vestingStart;
        uint256 vested = elapsed >= VESTING_DURATION
            ? totalAllocation
            : FixedPointMathLib.fullMulDiv(totalAllocation, elapsed, VESTING_DURATION);

        uint256 releasable = vested - released;
        if (releasable == 0) return;

        totalReleased = released + releasable;
        emit SubjectReleased(treasury, releasable);

        token.safeTransfer(treasury, releasable);
        uint256 delta = held - token.balanceOf(address(this));
        if (delta != releasable) revert InexactTransfer(releasable, delta);
    }

    /// @notice Retire SUBJECT that reaches a failed escrow after retirement, to the dead address.
    /// @dev Permissionless, terminal-state-only, and never reopens the launch. A zero balance is a
    ///      no-op rather than a revert, so a late-arriving unit is always retirable.
    function retireLateFailedSubject() external nonReentrant {
        if (lifecycle != Lifecycle.Failed) revert NotFailed(lifecycle);

        address token = subject;
        uint256 held = token.balanceOf(address(this));
        if (held == 0) return;

        emit LateFailedSubjectRetired(held);

        token.safeTransfer(BaseBindings.DEAD_ADDRESS, held);
        uint256 remaining = token.balanceOf(address(this));
        if (remaining != 0) revert InexactTransfer(held, held - remaining);
    }

    /// @dev Both resolutions accept only the auction that sells this launch's SUBJECT and names
    ///      this escrow as its unsold-token recipient, so a foreign or substituted auction can
    ///      never drive either terminal path.
    function _requireCanonicalAuction(address auction) private view {
        address token = IContinuousClearingAuction(auction).token();
        if (token != subject) revert AuctionTokenMismatch(token);

        address recipient = IContinuousClearingAuction(auction).tokensRecipient();
        if (recipient != address(this)) revert AuctionRecipientMismatch(recipient);
    }
}
