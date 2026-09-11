// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {Initializable} from "solady/utils/Initializable.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {IERC20Minimal} from "autolaunch-stocks/interfaces/IERC20Minimal.sol";
import {IRobinhoodProtocolRevenueInboxV1} from "./interfaces/IRobinhoodProtocolRevenueInboxV1.sol";
import {IRobinhoodSubjectSplitterV1} from "./interfaces/IRobinhoodSubjectSplitterV1.sol";
import {RobinhoodPreset} from "./RobinhoodPreset.sol";

/// @title RobinhoodSubjectSplitterV1
/// @notice The implementation-locked clone target behind every Robinhood revenue-share launch. It
///         is the frozen Base `SubjectSplitterV1` with one recognized asset instead of three: USDG
///         is the only revenue, NEW is the only stake, the 2% skim goes to the protocol revenue inbox
///         instead of REGENT staking, and there is no REGENT or USDC binding at all.
/// @dev Four bindings are fixed at initialization and never change. No upgrade path, no setter, no
///      pause, no administrator. Recovery is permissionless because it decides nothing: the whole
///      unsupported balance, always to the immutable treasury.
///
///      Reward accounting is one accumulator at exact scale `SCALE`, one scaled numerator carry, and
///      per account a checkpoint plus stored claimable whole units and sub-unit dust. An account's
///      entitlement between checkpoints is `staked * (accumulator - checkpoint)` in scaled units,
///      taken as `fullMulDiv` for the whole part and `mulmod` for the exact remainder, so a stake
///      change neither forfeits nor re-credits anything already earned. The staker share of a net is
///      `net * totalStaked / REVSHARE_TOTAL_SUPPLY`: coverage of the complete supply, not the share
///      of whoever happens to be staked, decides how much reaches stakers at all.
contract RobinhoodSubjectSplitterV1 is Initializable, ReentrancyGuard, IRobinhoodSubjectSplitterV1 {
    using SafeTransferLib for address;

    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant SCALE = 1e36;

    /// @notice The `sourceTag` every skim carries into the inbox.
    // forge-lint: disable-next-line(unsafe-typecast)
    bytes32 public constant SKIM_SOURCE_TAG = bytes32("robinhood-splitter");

    address public override usdg;
    address public override subject;
    address public override inbox;
    address public override treasury;

    uint256 public override totalStaked;
    mapping(address account => uint256 amount) public override stakedOf;

    /// @notice Cumulative recognized USDG per staked NEW unit, scaled by `SCALE`.
    uint256 public accRewardPerShare;
    /// @notice The single scaled numerator carried forward, always below `totalStaked`.
    uint256 public carriedRemainder;
    /// @notice Recognized USDG owed to stakers and not yet claimed.
    uint256 public override unclaimedLiability;

    mapping(address account => uint256 checkpoint) private _accCheckpoint;
    mapping(address account => uint256 amount) private _claimableWhole;
    mapping(address account => uint256 dust) private _claimableDust;
    /// @dev The block an account last staked in; nothing leaves an account in its own stake block.
    mapping(address account => uint256 blockNumber) private _lastStakeBlock;

    error ZeroAddress();
    error SelfAddress();
    error DuplicateTokenBinding();
    error ZeroAmount();
    error UnsupportedToken(address token);
    error ProtectedToken(address token);
    error SubjectSupplyMismatch(uint256 expected, uint256 found);
    error InsufficientStake(uint256 staked, uint256 requested);
    error SameBlockStakeExit(address account, uint256 stakeBlock);
    error InexactTransfer(uint256 expected, uint256 found);
    error InboxDepositMismatch(uint256 expected, uint256 reported);
    error InboxAllowanceNotCleared(uint256 found);

    /// @dev The implementation is permanently uninitializable, so only clones hold revenue.
    constructor() {
        _disableInitializers();
    }

    /// @notice Fix this clone's four bindings. Runs exactly once.
    /// @dev The NEW being bound must report exactly the supply every net is divided by, read once here
    ///      and never stored.
    function initialize(address usdg_, address subject_, address inbox_, address treasury_) external initializer {
        _requireBindable(usdg_);
        _requireBindable(subject_);
        _requireBindable(inbox_);
        _requireBindable(treasury_);
        if (usdg_ == subject_) revert DuplicateTokenBinding();

        uint256 supply = IERC20Minimal(subject_).totalSupply();
        if (supply != RobinhoodPreset.REVSHARE_TOTAL_SUPPLY) {
            revert SubjectSupplyMismatch(RobinhoodPreset.REVSHARE_TOTAL_SUPPLY, supply);
        }

        usdg = usdg_;
        subject = subject_;
        inbox = inbox_;
        treasury = treasury_;

        emit SplitterInitialized(usdg_, subject_, inbox_, treasury_);
    }

    // -------------------------------------------------------------------------
    // caller-only surface
    // -------------------------------------------------------------------------

    /// @inheritdoc IRobinhoodSubjectSplitterV1
    function stake(uint256 amount) external override nonReentrant {
        if (amount == 0) revert ZeroAmount();

        _accrue(msg.sender);
        _pullExact(subject, msg.sender, amount);

        stakedOf[msg.sender] += amount;
        totalStaked += amount;
        _lastStakeBlock[msg.sender] = block.number;

        emit Staked(msg.sender, amount);
    }

    /// @inheritdoc IRobinhoodSubjectSplitterV1
    function unstake(uint256 amount) external override nonReentrant {
        if (amount == 0) revert ZeroAmount();

        uint256 staked = stakedOf[msg.sender];
        if (amount > staked) revert InsufficientStake(staked, amount);
        _requireLaterBlockThanStake(msg.sender);

        _accrue(msg.sender);

        stakedOf[msg.sender] = staked - amount;
        totalStaked -= amount;

        emit Unstaked(msg.sender, amount);
        _pushExact(subject, msg.sender, amount);
    }

    /// @inheritdoc IRobinhoodSubjectSplitterV1
    function claim() external override nonReentrant {
        address account = msg.sender;
        _requireLaterBlockThanStake(account);
        _accrue(account);

        uint256 amount = _claimableWhole[account];
        if (amount == 0) return;

        _claimableWhole[account] = 0;
        unclaimedLiability -= amount;

        emit Claimed(account, amount);
        _pushExact(usdg, account, amount);
    }

    /// @inheritdoc IRobinhoodSubjectSplitterV1
    function depositRecognizedRevenue(address token, uint256 amount, bytes32 revenueRef)
        external
        override
        nonReentrant
    {
        if (token != usdg) revert UnsupportedToken(token);
        if (amount == 0) revert ZeroAmount();

        _pullExact(token, msg.sender, amount);
        _recognize(amount, revenueRef);
    }

    /// @inheritdoc IRobinhoodSubjectSplitterV1
    /// @dev Permissionless: a bare USDG transfer becomes revenue only here. The unaccounted amount is
    ///      the held balance minus unclaimed liability, so nothing owed to stakers can be relabeled as
    ///      new revenue. An aggregate bare balance asserts no reference, so the reference is zero.
    function recognizeSurplusRevenue() external override nonReentrant {
        uint256 unaccounted = usdg.balanceOf(address(this)) - unclaimedLiability;
        if (unaccounted == 0) revert ZeroAmount();
        _recognize(unaccounted, bytes32(0));
    }

    // -------------------------------------------------------------------------
    // recovery
    // -------------------------------------------------------------------------

    /// @inheritdoc IRobinhoodSubjectSplitterV1
    function recoverUnsupportedToken(address token) external override nonReentrant {
        if (token == usdg || token == subject) revert ProtectedToken(token);

        uint256 amount = token.balanceOf(address(this));
        if (amount == 0) revert ZeroAmount();

        emit UnsupportedTokenRecovered(token, treasury, amount);
        token.safeTransfer(treasury, amount);
    }

    /// @inheritdoc IRobinhoodSubjectSplitterV1
    // slither-disable-next-line incorrect-equality
    function recoverForcedETH() external override nonReentrant {
        uint256 amount = address(this).balance;
        if (amount == 0) revert ZeroAmount();

        emit ForcedEthRecovered(treasury, amount);
        treasury.safeTransferETH(amount);
    }

    // -------------------------------------------------------------------------
    // views
    // -------------------------------------------------------------------------

    /// @inheritdoc IRobinhoodSubjectSplitterV1
    function claimable(address account) public view override returns (uint256 whole) {
        (whole,) = _settled(account);
    }

    // -------------------------------------------------------------------------
    // internals
    // -------------------------------------------------------------------------

    function _requireBindable(address value) private view {
        if (value == address(0)) revert ZeroAddress();
        if (value == address(this)) revert SelfAddress();
    }

    function _requireLaterBlockThanStake(address account) private view {
        uint256 stakeBlock = _lastStakeBlock[account];
        if (block.number <= stakeBlock) revert SameBlockStakeExit(account, stakeBlock);
    }

    function _settled(address account) private view returns (uint256 whole, uint256 dust) {
        uint256 staked = stakedOf[account];
        uint256 delta = accRewardPerShare - _accCheckpoint[account];

        whole = _claimableWhole[account] + FixedPointMathLib.fullMulDiv(staked, delta, SCALE);
        dust = _claimableDust[account] + mulmod(staked, delta, SCALE);
        if (dust >= SCALE) {
            dust -= SCALE;
            whole += 1;
        }
    }

    function _accrue(address account) private {
        (uint256 whole, uint256 dust) = _settled(account);
        _claimableWhole[account] = whole;
        _claimableDust[account] = dust;
        _accCheckpoint[account] = accRewardPerShare;
    }

    /// @dev The one recognition path: floor the skim once, divide the net by staked coverage of the
    ///      complete supply, deliver both parts in this transaction. `gross == skim + stakerShare +
    ///      treasuryShare` exactly. An inbox or treasury transfer failure fails the whole recognition.
    function _recognize(uint256 gross, bytes32 revenueRef) private {
        uint256 skim = (gross * RobinhoodPreset.PROTOCOL_SKIM_BPS) / BPS_DENOMINATOR;
        uint256 net = gross - skim;
        uint256 stakerShare = FixedPointMathLib.fullMulDiv(net, totalStaked, RobinhoodPreset.REVSHARE_TOTAL_SUPPLY);
        uint256 treasuryShare = net - stakerShare;

        if (stakerShare != 0) _distribute(stakerShare);
        emit RevenueRecognized(msg.sender, revenueRef, gross, skim, net, stakerShare, treasuryShare);

        if (skim != 0) _skimToInbox(skim, revenueRef);
        if (treasuryShare != 0) _pushExact(usdg, treasury, treasuryShare);
    }

    function _distribute(uint256 share) private {
        uint256 staked = totalStaked;
        uint256 numerator = share * SCALE + carriedRemainder;

        unclaimedLiability += share;
        accRewardPerShare += numerator / staked;
        carriedRemainder = numerator % staked;
    }

    /// @dev Exact approval, the inbox deposit, three independent checks and allowance cleanup.
    function _skimToInbox(uint256 amount, bytes32 revenueRef) private {
        address token = usdg;
        address destination = inbox;

        uint256 before = token.balanceOf(address(this));
        token.safeApprove(destination, amount);
        uint256 reported = IRobinhoodProtocolRevenueInboxV1(destination).deposit(amount, SKIM_SOURCE_TAG, revenueRef);
        if (reported != amount) revert InboxDepositMismatch(amount, reported);

        uint256 sent = before - token.balanceOf(address(this));
        if (sent != amount) revert InexactTransfer(amount, sent);

        uint256 residual = IERC20Minimal(token).allowance(address(this), destination);
        if (residual != 0) revert InboxAllowanceNotCleared(residual);
    }

    function _pullExact(address token, address from, uint256 amount) private {
        uint256 before = token.balanceOf(address(this));
        token.safeTransferFrom(from, address(this), amount);
        uint256 received = token.balanceOf(address(this)) - before;
        if (received != amount) revert InexactTransfer(amount, received);
    }

    function _pushExact(address token, address to, uint256 amount) private {
        uint256 before = token.balanceOf(address(this));
        token.safeTransfer(to, amount);
        uint256 sent = before - token.balanceOf(address(this));
        if (sent != amount) revert InexactTransfer(amount, sent);
    }
}
