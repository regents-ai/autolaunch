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
///         exactly three assets, skims 2% once, and divides the remainder by how much of the
///         complete SUBJECT supply is staked: current stakers collectively receive that fraction
///         of the net and the launch treasury immediately receives the rest.
/// @dev Six bindings are fixed at initialization and never change: USDC, REGENT, the launch's
///      SUBJECT, the live REGENT staking contract, the Regent Safe, and the launch treasury.
///      There is no upgrade path, no reinitializer, no setter, no pause, no token registry, no
///      epoch, no queue, no external lifecycle read, and no recovery authority of any kind.
///
///      Recovery is permissionless because it has nothing to decide. Both recovery calls read
///      the complete recoverable balance themselves and send it to the immutable treasury, so
///      the caller chooses neither the amount nor the destination and gains nothing by calling.
///      Removing the administrator removes the only account whose disappearance could have made
///      recovery unreachable.
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

    /// @dev The complete SUBJECT supply every authentic launch mints, and the fixed denominator
    ///      of the staker share. Coverage — not the staked share of whoever happens to be
    ///      staked — is what decides how much of a net reaches stakers at all, so a single
    ///      account staking 10% of the supply earns 10% of the net whether it is alone or one of
    ///      many. It is an internal constant with no getter and no setter; initialization refuses
    ///      any SUBJECT that does not report exactly it, so the denominator is the bound token's
    ///      own supply rather than an assumption about it.
    uint256 private constant SUBJECT_TOTAL_SUPPLY = 100_000_000_000e18;

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

    /// @dev The block in which an account last staked. Every later stake resets it for that
    ///      account's whole position and for everything that position has already accrued, so no
    ///      value at all can leave an account in that account's own stake block.
    mapping(address account => uint256 blockNumber) private _lastStakeBlock;

    event SplitterInitialized(
        address usdc,
        address regent,
        address indexed subject,
        address liveStaking,
        address regentSafe,
        address indexed treasury
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
        uint256 stakerShare,
        uint256 treasuryShare
    );
    event UnsupportedTokenRecovered(address indexed token, address indexed treasury, uint256 amount);
    event ForcedEthRecovered(address indexed treasury, uint256 amount);

    error ZeroAddress();
    error SelfAddress();
    error DuplicateTokenBinding();
    error ZeroAmount();
    error UnsupportedToken(address token);
    error ProtectedToken(address token);
    error InsufficientStake(uint256 staked, uint256 requested);
    error SameBlockStakeExit(address account, uint256 stakeBlock);
    error InexactTransfer(uint256 expected, uint256 found);
    error StakingDepositMismatch(uint256 expected, uint256 reported);
    error StakingAllowanceNotCleared(uint256 found);

    /// @dev The implementation is permanently uninitializable, so only clones hold revenue.
    constructor() {
        _disableInitializers();
    }

    /// @notice Fix this clone's six bindings. Runs exactly once. `C1-I6`.
    /// @dev Regent Safe and launch treasury may intentionally be the same Safe, so they are not
    ///      required to differ. The three recognized tokens must be distinct, or one asset's
    ///      accumulator and liability would alias another's.
    ///
    ///      The SUBJECT being bound must report exactly the supply every net is divided by. That
    ///      read happens once, here, before a single binding is written: a token with any other
    ///      supply, or one whose supply cannot be read at all, leaves the clone unbound rather
    ///      than bound to a denominator that is not its own. Nothing is stored, and nothing reads
    ///      the supply again afterwards.
    function initialize(
        address usdc_,
        address regent_,
        address subject_,
        address liveStaking_,
        address regentSafe_,
        address treasury_
    ) external initializer {
        _requireBindable(usdc_);
        _requireBindable(regent_);
        _requireBindable(subject_);
        _requireBindable(liveStaking_);
        _requireBindable(regentSafe_);
        _requireBindable(treasury_);

        if (usdc_ == regent_ || usdc_ == subject_ || regent_ == subject_) revert DuplicateTokenBinding();

        require(IERC20Minimal(subject_).totalSupply() == SUBJECT_TOTAL_SUPPLY);

        usdc = usdc_;
        regent = regent_;
        subject = subject_;
        // slither-disable-next-line missing-zero-check
        liveStaking = liveStaking_;
        // slither-disable-next-line missing-zero-check
        regentSafe = regentSafe_;
        // slither-disable-next-line missing-zero-check
        treasury = treasury_;

        emit SplitterInitialized(usdc_, regent_, subject_, liveStaking_, regentSafe_, treasury_);
    }

    // -------------------------------------------------------------------------
    // caller-only surface
    // -------------------------------------------------------------------------

    /// @notice Stake SUBJECT for `msg.sender`, effective immediately.
    /// @dev Pre-change entitlement — whole units and the sub-unit remainder alike — is banked
    ///      against the current accumulator before the balance moves, so a stake change never
    ///      grants, re-credits, or forfeits anything already earned. `C1-I4`.
    ///
    ///      The stake block is recorded once the exact pull has succeeded, for the caller and only
    ///      for the caller, so a refused stake delays nothing and nobody can reset another
    ///      account's exit delay.
    function stake(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();

        _accrueAll(msg.sender);
        _pullExact(subject, msg.sender, amount);

        stakedOf[msg.sender] += amount;
        totalStaked += amount;
        _lastStakeBlock[msg.sender] = block.number;

        emit Staked(msg.sender, amount);
    }

    /// @notice Return staked SUBJECT principal to `msg.sender`, from a later block than its stake.
    /// @dev Partial and complete withdrawals alike wait for the block after the caller's latest
    ///      stake, so a position funded and recognized inside one transaction cannot also leave in
    ///      it. Zero amount and an over-withdrawal are still refused first, in that order.
    function unstake(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();

        uint256 staked = stakedOf[msg.sender];
        if (amount > staked) revert InsufficientStake(staked, amount);
        _requireLaterBlockThanStake(msg.sender);

        _accrueAll(msg.sender);

        stakedOf[msg.sender] = staked - amount;
        totalStaked -= amount;

        emit Unstaked(msg.sender, amount);
        _pushExact(subject, msg.sender, amount);
    }

    /// @notice Settle one recognized asset for `msg.sender` only, from a later block than its stake.
    /// @dev An unsupported token is refused before the delay is ever consulted.
    function claim(address token) external nonReentrant {
        _requireSupported(token);
        _requireLaterBlockThanStake(msg.sender);
        _claim(token, msg.sender);
    }

    /// @notice Settle exactly the three recognized assets for `msg.sender` only, from a later block
    ///         than its stake.
    function claimAll() external nonReentrant {
        address account = msg.sender;
        _requireLaterBlockThanStake(account);
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

    /// @notice Send this splitter's whole balance of an unsupported ERC20 to the fixed treasury.
    /// @dev Permissionless. The caller names only which token to sweep; the amount is this
    ///      splitter's complete balance of it and the destination is always the immutable
    ///      treasury, so calling this grants the caller nothing. USDC, REGENT and SUBJECT are
    ///      permanently refused, which is what keeps recognized revenue and staked principal out
    ///      of reach. Beyond the balance read it is one guarded transfer and nothing else: no
    ///      enumeration and no semantic probing, so a hostile token can fail only its own call.
    function recoverUnsupportedToken(address token) external nonReentrant {
        if (token == usdc || token == regent || token == subject) revert ProtectedToken(token);

        uint256 amount = token.balanceOf(address(this));
        if (amount == 0) revert ZeroAmount();

        emit UnsupportedTokenRecovered(token, treasury, amount);
        token.safeTransfer(treasury, amount);
    }

    /// @notice Send this splitter's whole ETH balance to the fixed treasury.
    /// @dev Permissionless, for the same reason. This contract has no receive or fallback
    ///      function, so an ordinary ETH transfer reverts and only EVM force-send behavior can
    ///      ever leave ETH here.
    // slither-disable-next-line incorrect-equality
    function recoverForcedETH() external nonReentrant {
        uint256 amount = address(this).balance;
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

    /// @dev The one exit rule, shared by every path that can move value out to an account:
    ///      principal, one asset's claim, and all three. One block is the whole of it — there is
    ///      no cooldown, epoch, queue, or time weighting — and a top-up restarts it for the
    ///      caller's complete position and for everything that position has already accrued, so a
    ///      stake, recognize, claim and exit round trip cannot complete inside one transaction. A
    ///      refused call mutates no principal, claim, reward, or treasury state, and refuses even
    ///      when it would have moved nothing.
    function _requireLaterBlockThanStake(address account) private view {
        uint256 stakeBlock = _lastStakeBlock[account];
        if (block.number <= stakeBlock) revert SameBlockStakeExit(account, stakeBlock);
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

    /// @dev The one recognition path. Floors the skim once, routes it, divides the post-skim net
    ///      by how much of the complete SUBJECT supply is staked, and delivers both parts in this
    ///      same transaction: current stakers collectively receive
    ///      `floor(net * totalStaked / SUBJECT_TOTAL_SUPPLY)` and the treasury immediately
    ///      receives the exact remainder, so coverage rounding is treasury-owned and an unstaked
    ///      supply sends the whole net to the treasury. The event carries both amounts, and
    ///      `gross == skim + stakerShare + treasuryShare` exactly. Only the staker share becomes
    ///      liability, and it does so before the accumulator division, so the scaled carry and
    ///      the per-account division dust are subdivisions of that same liability rather than
    ///      further token amounts. A treasury transfer failure fails the whole recognition.
    ///      `C1-I3`, `C1-I5`.
    function _recognize(address token, uint256 gross, bytes32 revenueRef) private {
        uint256 skim = (gross * SKIM_BPS) / BPS_DENOMINATOR;
        uint256 net = gross - skim;
        uint256 stakerShare = FixedPointMathLib.fullMulDiv(net, totalStaked, SUBJECT_TOTAL_SUPPLY);
        uint256 treasuryShare = net - stakerShare;

        if (stakerShare != 0) _distribute(token, stakerShare);
        emit RevenueRecognized(token, msg.sender, revenueRef, gross, skim, net, stakerShare, treasuryShare);

        if (skim != 0) {
            if (token == usdc) {
                _skimToLiveStaking(skim, revenueRef);
            } else {
                _pushExact(token, regentSafe, skim);
            }
        }
        if (treasuryShare != 0) _pushExact(token, treasury, treasuryShare);
    }

    /// @dev The whole staker share becomes liability; only the divisible part reaches the
    ///      accumulator, and the indivisible scaled numerator rolls forward as this asset's single
    ///      carry. Current stakers divide exactly this share and nothing else.
    function _distribute(address token, uint256 share) private {
        uint256 staked = totalStaked;
        uint256 numerator = share * SCALE + carriedRemainder[token];

        unclaimedLiability[token] += share;
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
