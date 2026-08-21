// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {IERC20Minimal} from "../interfaces/IERC20Minimal.sol";
import {IRegentRevenueStakingMinimal} from "../interfaces/IRegentRevenueStakingMinimal.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {Initializable} from "solady/utils/Initializable.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/// @title SubjectSplitterV1
/// @notice The fixed, implementation-locked clone target that recognizes one launch's revenue in
///         exactly three assets, skims 2% once, and pays the remainder to current SUBJECT stakers
///         or, when nobody is staked, straight to the launch treasury.
/// @dev Seven bindings are fixed at initialization and never change: USDC, REGENT, the launch's
///      SUBJECT, the live REGENT staking contract, the Regent Safe, the launch treasury, and the
///      recovery admin. There is no upgrade path, no reinitializer, no setter, no pause, no token
///      registry, no epoch, no queue, and no external lifecycle read.
///
///      The recovery admin is admitted as a deployed contract exactly once, at launch, by
///      `RegentLBPStrategy.initializeDistribution`. This initializer deliberately does not
///      re-evaluate that fact: whether an address still carries code is mutable environmental
///      state — EIP-6780 lets a contract created and destroyed in one transaction disappear — and
///      graduation is the only migration path a launched auction has. Re-checking it here would
///      let a launcher's own admin, destroyed after admission, permanently strand a graduated
///      launch. The recorded consequence is narrower and is disclosed in
///      `docs/security/threat-model.md`: if that immutable admin loses its code, this splitter's
///      `recoverUnsupportedToken` and `recoverForcedETH` — and the same two calls on every
///      receiver created for the launch — can never be called again, while graduation, revenue
///      recognition, staking, claims and unstaking all remain available.
///
///      Reward accounting is one accumulator per asset at exact scale `SCALE`, one global scaled
///      numerator carry per asset, and, per account, an accumulator checkpoint plus stored
///      claimable whole units and stored sub-unit dust. An account's entitlement between two
///      checkpoints is `staked * (accumulator - checkpoint)` in scaled units. That product can
///      exceed `uint256`, so it is never formed as one number: Solady's full-precision
///      `fullMulDiv` takes the whole part and `mulmod` takes the exact sub-unit remainder. Because
///      the remainder is banked rather than dropped, a stake change neither forfeits nor
///      re-credits the fraction of a unit an account had already earned.
///
///      Named invariants: `C1-I2` principal isolation, `C1-I3` recognized solvency, `C1-I4`
///      snapshot fairness, `C1-I6` fixed authority, `C1-I7` atomic failure.
contract SubjectSplitterV1 is Initializable, ReentrancyGuard {
    using SafeTransferLib for address;

    /// @notice Basis-point denominator for the skim.
    uint256 public constant BPS_DENOMINATOR = 10_000;

    /// @notice The skim every recognized inflow floors exactly once, 2%.
    uint256 public constant SKIM_BPS = 200;

    /// @notice The exact fixed-point scale of every reward accumulator.
    uint256 public constant SCALE = 1e36;

    /// @notice The USDC binding this splitter recognizes.
    address public usdc;

    /// @notice The REGENT binding this splitter recognizes.
    address public regent;

    /// @notice The launch's own SUBJECT token, the only stakeable asset.
    address public subject;

    /// @notice The live REGENT staking contract the USDC skim is deposited into.
    address public liveStaking;

    /// @notice The Regent Safe the REGENT and SUBJECT skims are sent to.
    address public regentSafe;

    /// @notice The launch treasury, the zero-stake destination and the only recovery destination.
    address public treasury;

    /// @notice The only account allowed to recover forced ETH or an unsupported ERC20.
    address public recoveryAdmin;

    /// @notice Total SUBJECT principal currently staked across all accounts.
    uint256 public totalStaked;

    /// @notice SUBJECT principal staked by one account.
    mapping(address account => uint256 amount) public stakedOf;

    /// @notice Cumulative recognized revenue per staked SUBJECT unit, scaled by `SCALE`.
    mapping(address token => uint256 accumulator) public accRewardPerShare;

    /// @notice The single scaled numerator this asset carries forward, always below `totalStaked`.
    mapping(address token => uint256 remainder) public carriedRemainder;

    /// @notice Recognized revenue owed to stakers and not yet claimed, per asset.
    mapping(address token => uint256 amount) public unclaimedLiability;

    /// @dev The accumulator value an account's earnings were last measured against.
    mapping(address token => mapping(address account => uint256 checkpoint)) private _accCheckpoint;

    /// @dev Whole units already earned out of the accumulator and not yet transferred.
    mapping(address token => mapping(address account => uint256 amount)) private _claimableWhole;

    /// @dev The sub-unit entitlement an account still owns, scaled by `SCALE` and always below it.
    mapping(address token => mapping(address account => uint256 dust)) private _claimableDust;

    event SplitterInitialized(
        address usdc,
        address regent,
        address indexed subject,
        address liveStaking,
        address regentSafe,
        address indexed treasury,
        address indexed recoveryAdmin
    );
    event Staked(address indexed account, uint256 amount);
    event Unstaked(address indexed account, uint256 amount);
    event Claimed(address indexed account, address indexed token, uint256 amount);
    event RevenueRecognized(
        address indexed token,
        address indexed source,
        bytes32 indexed revenueRef,
        uint256 gross,
        uint256 skim,
        uint256 net,
        bool paidToStakers
    );
    event UnsupportedTokenRecovered(address indexed token, address indexed treasury, uint256 amount);
    event ForcedEthRecovered(address indexed treasury, uint256 amount);

    error ZeroAddress();
    error SelfAddress();
    error DuplicateTokenBinding();
    error ZeroAmount();
    error UnsupportedToken(address token);
    error ProtectedToken(address token);
    error NotRecoveryAdmin(address caller);
    error InsufficientStake(uint256 staked, uint256 requested);
    error InexactTransfer(uint256 expected, uint256 found);
    error StakingDepositMismatch(uint256 expected, uint256 reported);
    error StakingAllowanceNotCleared(uint256 found);

    /// @dev The implementation is permanently uninitializable, so only clones hold revenue.
    constructor() {
        _disableInitializers();
    }

    modifier onlyRecoveryAdmin() {
        if (msg.sender != recoveryAdmin) revert NotRecoveryAdmin(msg.sender);
        _;
    }

    /// @notice Fix this clone's seven bindings. Runs exactly once. `C1-I6`.
    /// @dev Regent Safe and launch treasury may intentionally be the same Safe, so they are not
    ///      required to differ. The three recognized tokens must be distinct, or one asset's
    ///      accumulator and liability would alias another's.
    function initialize(
        address usdc_,
        address regent_,
        address subject_,
        address liveStaking_,
        address regentSafe_,
        address treasury_,
        address recoveryAdmin_
    ) external initializer {
        _requireBindable(usdc_);
        _requireBindable(regent_);
        _requireBindable(subject_);
        _requireBindable(liveStaking_);
        _requireBindable(regentSafe_);
        _requireBindable(treasury_);
        _requireBindable(recoveryAdmin_);

        if (usdc_ == regent_ || usdc_ == subject_ || regent_ == subject_) revert DuplicateTokenBinding();

        usdc = usdc_;
        regent = regent_;
        subject = subject_;
        // slither-disable-next-line missing-zero-check
        liveStaking = liveStaking_;
        // slither-disable-next-line missing-zero-check
        regentSafe = regentSafe_;
        // slither-disable-next-line missing-zero-check
        treasury = treasury_;
        // slither-disable-next-line missing-zero-check
        recoveryAdmin = recoveryAdmin_;

        emit SplitterInitialized(usdc_, regent_, subject_, liveStaking_, regentSafe_, treasury_, recoveryAdmin_);
    }

    // -------------------------------------------------------------------------
    // caller-only surface
    // -------------------------------------------------------------------------

    /// @notice Stake SUBJECT for `msg.sender`, effective immediately.
    /// @dev Pre-change entitlement — whole units and the sub-unit remainder alike — is banked
    ///      against the current accumulator before the balance moves, so a stake change never
    ///      grants, re-credits, or forfeits anything already earned. `C1-I4`.
    function stake(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();

        _accrueAll(msg.sender);
        _pullExact(subject, msg.sender, amount);

        stakedOf[msg.sender] += amount;
        totalStaked += amount;

        emit Staked(msg.sender, amount);
    }

    /// @notice Return staked SUBJECT principal to `msg.sender`.
    function unstake(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();

        uint256 staked = stakedOf[msg.sender];
        if (amount > staked) revert InsufficientStake(staked, amount);

        _accrueAll(msg.sender);

        stakedOf[msg.sender] = staked - amount;
        totalStaked -= amount;

        emit Unstaked(msg.sender, amount);
        _pushExact(subject, msg.sender, amount);
    }

    /// @notice Settle one recognized asset for `msg.sender` only.
    function claim(address token) external nonReentrant {
        _requireSupported(token);
        _claim(token, msg.sender);
    }

    /// @notice Settle exactly the three recognized assets for `msg.sender` only.
    function claimAll() external nonReentrant {
        address account = msg.sender;
        _claim(usdc, account);
        _claim(regent, account);
        _claim(subject, account);
    }

    /// @notice Recognize exactly `amount` of `token`, funded by the caller in this call.
    function depositRecognizedRevenue(address token, uint256 amount, bytes32 revenueRef) external nonReentrant {
        _requireSupported(token);
        if (amount == 0) revert ZeroAmount();

        _pullExact(token, msg.sender, amount);
        _recognize(token, amount, revenueRef);
    }

    /// @notice Recognize the whole currently unaccounted balance of `token`.
    /// @dev Permissionless by design: a bare transfer becomes revenue only here. The unaccounted
    ///      amount is the held balance minus protected inventory, so staked principal, unclaimed
    ///      liability, the carried remainder, and per-account division dust can never be relabeled
    ///      as new revenue. `C1-I3`, `C1-I4`.
    function recognizeSurplusRevenue(address token, bytes32 revenueRef) external nonReentrant {
        _requireSupported(token);

        uint256 unaccounted = token.balanceOf(address(this)) - protectedBalance(token);
        if (unaccounted == 0) revert ZeroAmount();

        _recognize(token, unaccounted, revenueRef);
    }

    // -------------------------------------------------------------------------
    // recovery
    // -------------------------------------------------------------------------

    /// @notice Send an unsupported ERC20 to the fixed treasury. Recovery admin only.
    /// @dev One guarded transfer and nothing else: no enumeration, no semantic probing, and no
    ///      balance assertion, so a hostile token can fail only this call.
    function recoverUnsupportedToken(address token, uint256 amount) external nonReentrant onlyRecoveryAdmin {
        if (token == usdc || token == regent || token == subject) revert ProtectedToken(token);
        if (amount == 0) revert ZeroAmount();

        emit UnsupportedTokenRecovered(token, treasury, amount);
        token.safeTransfer(treasury, amount);
    }

    /// @notice Send forced ETH to the fixed treasury. Recovery admin only.
    /// @dev This contract has no receive or fallback function, so an ordinary ETH transfer reverts
    ///      and only EVM force-send behavior can ever leave ETH here.
    function recoverForcedETH(uint256 amount) external nonReentrant onlyRecoveryAdmin {
        if (amount == 0) revert ZeroAmount();

        emit ForcedEthRecovered(treasury, amount);
        treasury.safeTransferETH(amount);
    }

    // -------------------------------------------------------------------------
    // views
    // -------------------------------------------------------------------------

    /// @notice The whole units of `token` `account` may claim right now.
    function claimable(address token, address account) public view returns (uint256 whole) {
        (whole,) = _settled(token, account);
    }

    /// @notice The sub-unit entitlement `account` still owns in `token`, scaled by `SCALE`.
    /// @dev Below one whole unit by construction. It stays inside `unclaimedLiability` until a
    ///      later recognition completes it into a claimable unit; it is never separately
    ///      withdrawable, surplus-recognizable, or recoverable. `C1-I4`.
    function claimableDust(address token, address account) external view returns (uint256 dust) {
        (, dust) = _settled(token, account);
    }

    /// @notice Inventory of `token` this splitter may never recognize, recover, or spend elsewhere.
    /// @dev Unclaimed recognized revenue for every asset, plus all staked principal for SUBJECT.
    ///      `C1-I2`, `C1-I3`.
    function protectedBalance(address token) public view returns (uint256) {
        uint256 protectedAmount = unclaimedLiability[token];
        if (token == subject) protectedAmount += totalStaked;
        return protectedAmount;
    }

    // -------------------------------------------------------------------------
    // internals
    // -------------------------------------------------------------------------

    function _requireBindable(address value) private view {
        if (value == address(0)) revert ZeroAddress();
        if (value == address(this)) revert SelfAddress();
    }

    function _requireSupported(address token) private view {
        if (token != usdc && token != regent && token != subject) revert UnsupportedToken(token);
    }

    /// @dev `account`'s exact entitlement in `token`: the whole units it may claim now and the
    ///      sub-unit remainder it still owns. Entitlement earned since the last checkpoint is
    ///      `stakedOf[account] * (accRewardPerShare[token] - checkpoint)` in scaled units, which
    ///      is not always representable, so it is never formed as one number — `fullMulDiv` takes
    ///      the whole part in full precision and `mulmod` takes the exact remainder. Banking that
    ///      remainder instead of re-flooring the account's position at every stake change is what
    ///      keeps aggregate claimability inside recognized liability. `C1-I3`, `C1-I4`.
    function _settled(address token, address account) private view returns (uint256 whole, uint256 dust) {
        uint256 staked = stakedOf[account];
        uint256 delta = accRewardPerShare[token] - _accCheckpoint[token][account];

        whole = _claimableWhole[token][account] + FixedPointMathLib.fullMulDiv(staked, delta, SCALE);
        dust = _claimableDust[token][account] + mulmod(staked, delta, SCALE);
        if (dust >= SCALE) {
            dust -= SCALE;
            whole += 1;
        }
    }

    function _accrueAll(address account) private {
        _accrue(usdc, account);
        _accrue(regent, account);
        _accrue(subject, account);
    }

    function _accrue(address token, address account) private {
        (uint256 whole, uint256 dust) = _settled(token, account);
        _claimableWhole[token][account] = whole;
        _claimableDust[token][account] = dust;
        _accCheckpoint[token][account] = accRewardPerShare[token];
    }

    function _claim(address token, address account) private {
        _accrue(token, account);

        uint256 amount = _claimableWhole[token][account];
        if (amount == 0) return;

        _claimableWhole[token][account] = 0;
        unclaimedLiability[token] -= amount;

        emit Claimed(account, token, amount);
        _pushExact(token, account, amount);
    }

    /// @dev The one recognition path. Floors the skim once, routes it, and either distributes the
    ///      full net to stakers or sends it straight to the treasury. In the staked branch the
    ///      whole net becomes liability before the accumulator division, so the scaled carry and
    ///      the per-account division dust stay inside protected inventory forever. `C1-I3`, `C1-I5`.
    function _recognize(address token, uint256 gross, bytes32 revenueRef) private {
        uint256 skim = (gross * SKIM_BPS) / BPS_DENOMINATOR;
        uint256 net = gross - skim;
        bool paidToStakers = totalStaked != 0;

        if (paidToStakers) _distribute(token, net);
        emit RevenueRecognized(token, msg.sender, revenueRef, gross, skim, net, paidToStakers);

        if (skim != 0) {
            if (token == usdc) {
                _skimToLiveStaking(skim, revenueRef);
            } else {
                _pushExact(token, regentSafe, skim);
            }
        }
        if (!paidToStakers) _pushExact(token, treasury, net);
    }

    /// @dev The whole net becomes liability; only the divisible part reaches the accumulator, and
    ///      the indivisible scaled numerator rolls forward as this asset's single carry.
    function _distribute(address token, uint256 net) private {
        uint256 staked = totalStaked;
        uint256 numerator = net * SCALE + carriedRemainder[token];

        unclaimedLiability[token] += net;
        accRewardPerShare[token] += numerator / staked;
        carriedRemainder[token] = numerator % staked;
    }

    /// @dev Exact approval, the pinned live-staking deposit, three independent behavior checks, and
    ///      allowance cleanup. A paused or reverting live staking contract fails this call and rolls
    ///      the whole recognition back. `C1-I7`.
    function _skimToLiveStaking(uint256 amount, bytes32 revenueRef) private {
        address token = usdc;
        address staking = liveStaking;

        uint256 splitterBefore = token.balanceOf(address(this));
        uint256 stakingBefore = token.balanceOf(staking);

        token.safeApprove(staking, amount);
        uint256 reported =
            IRegentRevenueStakingMinimal(staking).depositUSDC(amount, bytes32(uint256(uint160(subject))), revenueRef);
        if (reported != amount) revert StakingDepositMismatch(amount, reported);

        uint256 sent = splitterBefore - token.balanceOf(address(this));
        if (sent != amount) revert InexactTransfer(amount, sent);

        uint256 landed = token.balanceOf(staking) - stakingBefore;
        if (landed != amount) revert InexactTransfer(amount, landed);

        token.safeApprove(staking, 0);
        uint256 residual = IERC20Minimal(token).allowance(address(this), staking);
        if (residual != 0) revert StakingAllowanceNotCleared(residual);
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
