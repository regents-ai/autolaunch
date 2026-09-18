// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {Initializable} from "solady/utils/Initializable.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/// @title MemestockSplitterCore
/// @notice The staking and revenue accounting every memestock splitter shares. One launch's revenue is
///         recognized in exactly three assets — the chain's dollar, the launch's MEMESTOCK and its paired
///         STOCK — the protocol share is floored once at 2%, and the whole remainder belongs to whoever
///         is staked at that moment, pro rata to staked MEMESTOCK. There is no launch treasury, no
///         creator share and no administrator.
/// @dev It is the frozen Agent `SubjectSplitterV1` accounting with one rule changed: the staker share
///      is the complete net, not the net scaled by how much of the supply is staked. Revenue recognized
///      while nothing is staked has no staker to belong to, so all of it is the protocol share.
///
///      The three token bindings are fixed at initialization and never change. There is no upgrade
///      path, no reinitializer, no setter, no pause and no recovery authority. Recovery is
///      permissionless because it decides nothing: the whole unsupported balance, always to the
///      protocol treasury.
///
///      Reward accounting is one accumulator per asset at exact scale `SCALE`, one scaled numerator
///      carry per asset and, per account, a checkpoint plus stored claimable whole units and sub-unit
///      dust. An account's entitlement between checkpoints is `staked * (accumulator - checkpoint)` in
///      scaled units, taken as `fullMulDiv` for the whole part and `mulmod` for the exact remainder, so
///      a stake change neither forfeits nor re-credits anything already earned.
///
///      A chain variant supplies only where the protocol share goes (`_routeProtocolShare`) and which
///      address is the protocol treasury.
abstract contract MemestockSplitterCore is Initializable, ReentrancyGuard {
    using SafeTransferLib for address;

    /// @notice Basis-point denominator for the protocol share.
    uint256 public constant BPS_DENOMINATOR = 10_000;

    /// @notice The protocol share every recognized inflow floors exactly once while anything is staked, 2%.
    uint256 public constant SKIM_BPS = 200;

    /// @notice The exact fixed-point scale of every reward accumulator.
    uint256 public constant SCALE = 1e36;

    /// @notice The chain's dollar this splitter recognizes: USDC on Base, USDG on Robinhood.
    address public dollar;

    /// @notice The launch's own MEMESTOCK, a recognized asset and the only stakeable one.
    address public memestock;

    /// @notice The STOCK the launch is paired with.
    address public stock;

    /// @notice Total MEMESTOCK principal currently staked across all accounts.
    uint256 public totalStaked;

    /// @notice MEMESTOCK principal staked by one account.
    mapping(address account => uint256 amount) public stakedOf;

    /// @notice Cumulative recognized revenue per staked MEMESTOCK unit, scaled by `SCALE`.
    mapping(address token => uint256 accumulator) public accRewardPerShare;

    /// @notice The single scaled numerator this asset carries forward, always below `totalStaked`.
    mapping(address token => uint256 remainder) public carriedRemainder;

    /// @notice Recognized revenue owed to stakers and not yet claimed, per asset.
    mapping(address token => uint256 amount) public unclaimedLiability;

    mapping(address token => mapping(address account => uint256 checkpoint)) private _accCheckpoint;
    mapping(address token => mapping(address account => uint256 amount)) private _claimableWhole;
    mapping(address token => mapping(address account => uint256 dust)) private _claimableDust;

    /// @dev The block an account last staked in; nothing leaves an account in its own stake block.
    mapping(address account => uint256 blockNumber) private _lastStakeBlock;

    event Staked(address indexed account, uint256 amount);
    event Unstaked(address indexed account, uint256 amount);
    event Claimed(address indexed account, address indexed token, uint256 amount);
    /// @notice `gross == protocolShare + stakerShare` exactly.
    event RevenueRecognized(
        address indexed token,
        address indexed source,
        bytes32 indexed revenueRef,
        uint256 gross,
        uint256 protocolShare,
        uint256 stakerShare
    );
    event UnsupportedTokenRecovered(address indexed token, address indexed protocolTreasury, uint256 amount);
    event ForcedEthRecovered(address indexed protocolTreasury, uint256 amount);

    error ZeroAddress();
    error SelfAddress();
    error DuplicateTokenBinding();
    error ZeroAmount();
    error UnsupportedToken(address token);
    error ProtectedToken(address token);
    error InsufficientStake(uint256 staked, uint256 requested);
    error SameBlockStakeExit(address account, uint256 stakeBlock);
    error InexactTransfer(uint256 expected, uint256 found);

    /// @dev The implementation is permanently uninitializable, so only clones hold revenue.
    constructor() {
        _disableInitializers();
    }

    /// @notice Where recovered unsupported tokens and force-sent ETH go, and where the protocol share of
    ///         MEMESTOCK and STOCK goes.
    function protocolTreasury() public view virtual returns (address);

    /// @dev Deliver `amount` of one recognized `token` to the protocol. A failure fails the whole
    ///      recognition.
    function _routeProtocolShare(address token, uint256 amount, bytes32 revenueRef) internal virtual;

    /// @dev Fix the three token bindings. The three must be distinct, or one asset's accumulator and
    ///      liability would alias another's.
    function _bindTokens(address dollar_, address memestock_, address stock_) internal {
        _requireBindable(dollar_);
        _requireBindable(memestock_);
        _requireBindable(stock_);
        if (dollar_ == memestock_ || dollar_ == stock_ || memestock_ == stock_) revert DuplicateTokenBinding();

        dollar = dollar_;
        memestock = memestock_;
        stock = stock_;
    }

    // -------------------------------------------------------------------------
    // caller-only surface
    // -------------------------------------------------------------------------

    /// @notice Stake MEMESTOCK for `msg.sender`, effective immediately.
    /// @dev Pre-change entitlement is banked against the current accumulator before the balance moves.
    ///      The stake block is recorded once the exact pull has succeeded, for the caller only.
    function stake(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();

        _accrueAll(msg.sender);
        _pullExact(memestock, msg.sender, amount);

        stakedOf[msg.sender] += amount;
        totalStaked += amount;
        _lastStakeBlock[msg.sender] = block.number;

        emit Staked(msg.sender, amount);
    }

    /// @notice Return staked MEMESTOCK principal to `msg.sender`, from a later block than its stake.
    function unstake(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();

        uint256 staked = stakedOf[msg.sender];
        if (amount > staked) revert InsufficientStake(staked, amount);
        _requireLaterBlockThanStake(msg.sender);

        _accrueAll(msg.sender);

        stakedOf[msg.sender] = staked - amount;
        totalStaked -= amount;

        emit Unstaked(msg.sender, amount);
        _pushExact(memestock, msg.sender, amount);
    }

    /// @notice Settle one recognized asset for `msg.sender` only, from a later block than its stake.
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
        _claim(dollar, account);
        _claim(memestock, account);
        _claim(stock, account);
    }

    /// @notice Recognize exactly `amount` of `token`, funded by the caller in this call.
    function depositRecognizedRevenue(address token, uint256 amount, bytes32 revenueRef) external nonReentrant {
        _requireSupported(token);
        if (amount == 0) revert ZeroAmount();

        _pullExact(token, msg.sender, amount);
        _recognize(token, amount, revenueRef);
    }

    /// @notice Recognize the whole currently unaccounted balance of `token`.
    /// @dev Permissionless: a bare transfer becomes revenue only here. The unaccounted amount is the
    ///      held balance minus protected inventory, so staked principal and unclaimed liability can
    ///      never be relabeled as new revenue. An aggregate bare balance asserts no reference.
    function recognizeSurplusRevenue(address token) external nonReentrant {
        _requireSupported(token);

        uint256 unaccounted = token.balanceOf(address(this)) - protectedBalance(token);
        if (unaccounted == 0) revert ZeroAmount();

        _recognize(token, unaccounted, bytes32(0));
    }

    // -------------------------------------------------------------------------
    // recovery
    // -------------------------------------------------------------------------

    /// @notice Send this splitter's whole balance of an unsupported ERC20 to the protocol treasury.
    /// @dev Permissionless. The three recognized assets are permanently refused, which keeps recognized
    ///      revenue and staked principal out of reach.
    function recoverUnsupportedToken(address token) external nonReentrant {
        if (token == dollar || token == memestock || token == stock) revert ProtectedToken(token);

        uint256 amount = token.balanceOf(address(this));
        if (amount == 0) revert ZeroAmount();

        address destination = protocolTreasury();
        emit UnsupportedTokenRecovered(token, destination, amount);
        token.safeTransfer(destination, amount);
    }

    /// @notice Send this splitter's whole ETH balance to the protocol treasury.
    /// @dev This contract has no receive or fallback function, so only EVM force-send behavior can
    ///      ever leave ETH here.
    // slither-disable-next-line incorrect-equality
    function recoverForcedETH() external nonReentrant {
        uint256 amount = address(this).balance;
        if (amount == 0) revert ZeroAmount();

        address destination = protocolTreasury();
        emit ForcedEthRecovered(destination, amount);
        destination.safeTransferETH(amount);
    }

    // -------------------------------------------------------------------------
    // views
    // -------------------------------------------------------------------------

    /// @notice The whole units of `token` `account` may claim right now.
    function claimable(address token, address account) public view returns (uint256 whole) {
        (whole,) = _settled(token, account);
    }

    /// @notice The sub-unit entitlement `account` still owns in `token`, scaled by `SCALE`.
    function claimableDust(address token, address account) external view returns (uint256 dust) {
        (, dust) = _settled(token, account);
    }

    /// @notice Inventory of `token` this splitter may never recognize, recover, or spend elsewhere:
    ///         unclaimed recognized revenue for every asset, plus all staked principal for MEMESTOCK.
    function protectedBalance(address token) public view returns (uint256) {
        uint256 protectedAmount = unclaimedLiability[token];
        if (token == memestock) protectedAmount += totalStaked;
        return protectedAmount;
    }

    // -------------------------------------------------------------------------
    // internals
    // -------------------------------------------------------------------------

    function _requireBindable(address value) internal view {
        if (value == address(0)) revert ZeroAddress();
        if (value == address(this)) revert SelfAddress();
    }

    function _requireSupported(address token) private view {
        if (token != dollar && token != memestock && token != stock) revert UnsupportedToken(token);
    }

    /// @dev The one exit rule, shared by every path that can move value out to an account. One block is
    ///      the whole of it, and a top-up restarts it for the caller's complete position, so a stake,
    ///      recognize, claim and exit round trip cannot complete inside one transaction.
    function _requireLaterBlockThanStake(address account) private view {
        uint256 stakeBlock = _lastStakeBlock[account];
        if (block.number <= stakeBlock) revert SameBlockStakeExit(account, stakeBlock);
    }

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
        _accrue(dollar, account);
        _accrue(memestock, account);
        _accrue(stock, account);
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

    /// @dev The one recognition path. While anything is staked the protocol share is the floored 2% and
    ///      current stakers divide the whole remainder; while nothing is staked there is nobody to
    ///      divide it, so the protocol share is the whole inflow. Only the staker share becomes
    ///      liability, before the accumulator division, so the scaled carry and per-account dust are
    ///      subdivisions of that liability rather than further token amounts.
    function _recognize(address token, uint256 gross, bytes32 revenueRef) private {
        uint256 protocolShare = totalStaked == 0 ? gross : (gross * SKIM_BPS) / BPS_DENOMINATOR;
        uint256 stakerShare = gross - protocolShare;

        if (stakerShare != 0) _distribute(token, stakerShare);
        emit RevenueRecognized(token, msg.sender, revenueRef, gross, protocolShare, stakerShare);

        if (protocolShare != 0) _routeProtocolShare(token, protocolShare, revenueRef);
    }

    function _distribute(address token, uint256 share) private {
        uint256 staked = totalStaked;
        uint256 numerator = share * SCALE + carriedRemainder[token];

        unclaimedLiability[token] += share;
        accRewardPerShare[token] += numerator / staked;
        carriedRemainder[token] = numerator % staked;
    }

    function _pullExact(address token, address from, uint256 amount) private {
        uint256 before = token.balanceOf(address(this));
        token.safeTransferFrom(from, address(this), amount);
        uint256 received = token.balanceOf(address(this)) - before;
        if (received != amount) revert InexactTransfer(amount, received);
    }

    function _pushExact(address token, address to, uint256 amount) internal {
        uint256 before = token.balanceOf(address(this));
        token.safeTransfer(to, amount);
        uint256 sent = before - token.balanceOf(address(this));
        if (sent != amount) revert InexactTransfer(amount, sent);
    }
}
