// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {BlockNumberish} from "blocknumberish/src/BlockNumberish.sol";
import {
    AuctionParameters,
    IContinuousClearingAuction
} from "continuous-clearing-auction/interfaces/IContinuousClearingAuction.sol";
import {
    IContinuousClearingAuctionFactory
} from "continuous-clearing-auction/interfaces/IContinuousClearingAuctionFactory.sol";
import {ConstantsLib} from "continuous-clearing-auction/libraries/ConstantsLib.sol";
import {MaxBidPriceLib} from "continuous-clearing-auction/libraries/MaxBidPriceLib.sol";
import {LBPInitializationParams} from "liquidity-launcher/src/interfaces/ILBPInitializer.sol";
import {TokenPricing} from "liquidity-launcher/src/libraries/TokenPricing.sol";
import {CurrencyAmounts, Position, PositionDefinition} from "liquidity-launcher/src/types/PositionPlannerTypes.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {ReentrancyGuardTransient} from "solady/utils/ReentrancyGuardTransient.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {IUERC20Factory} from "uerc20-factory/interfaces/IUERC20Factory.sol";
import {UERC20Metadata} from "uerc20-factory/libraries/UERC20MetadataLibrary.sol";
import {UERC20} from "uerc20-factory/tokens/UERC20.sol";
import {IERC20Minimal} from "autolaunch-stocks/interfaces/IERC20Minimal.sol";
import {StocksPreset} from "autolaunch-stocks/StocksPreset.sol";
import {IRobinhoodLaunchpadBase} from "./interfaces/IRobinhoodLaunchpadBase.sol";
import {IRobinhoodProtocolRevenueInboxV1} from "./interfaces/IRobinhoodProtocolRevenueInboxV1.sol";
import {RobinhoodFeeHookFactory} from "./RobinhoodFeeHookFactory.sol";
import {RobinhoodFeeHookV1} from "./RobinhoodFeeHookV1.sol";
import {RobinhoodPreset} from "./RobinhoodPreset.sol";
import {RobinhoodPositionsLib} from "./libraries/RobinhoodPositionsLib.sol";

/// @title RobinhoodLaunchpadBase
/// @notice Everything the two Robinhood launch kinds share: bindings, pause and fee governance, the
///         USDG launch fee, NEW creation, CCA creation and read-back, custody, migration, and the
///         locked-liquidity technique of the Base Stocks launchpad. A launch kind supplies its terms
///         (supply split), its locked positions, its subject destination and what it does with the
///         currency the full range could not pair.
/// @dev Bindings are constructor immutables, each proved to be deployed code and, where it has one,
///      to present the expected binding (USDG decimals, the inbox's USDG). Nothing is hard-coded:
///      no Robinhood address is known at build time, and a deployment with a wrong binding fails at
///      construction rather than at the first launch. The hook is deployed here, through the bound hook
///      factory, so no launchpad can exist without exactly one hook bound to it.
abstract contract RobinhoodLaunchpadBase is BlockNumberish, ReentrancyGuardTransient, IRobinhoodLaunchpadBase {
    using SafeTransferLib for address;
    using PoolIdLibrary for PoolKey;

    /// @dev The runtime code hash the pinned UERC20 factory must present (the frozen Base value).
    bytes32 internal constant UERC20_FACTORY_RUNTIME_CODE_HASH =
        0x47a5ee559aa5c815a6a350486a1de3beb868d238ba5b2d46e62db5128645195f;

    address internal constant DEAD_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    /// @notice `sourceTag` every launch fee carries into the inbox.
    // forge-lint: disable-next-line(unsafe-typecast)
    bytes32 public constant LAUNCH_FEE_SOURCE_TAG = bytes32("robinhood-launch-fee");

    struct Bindings {
        address uerc20Factory;
        address ccaFactory;
        address poolManager;
        address positionManager;
        address hookFactory;
        address usdg;
        address inbox;
        address adminSafe;
    }

    /// @dev The fixed supply split of one launch kind.
    struct Terms {
        uint256 totalSupply;
        uint128 auctionInventory;
        uint128 migrationReserve;
    }

    address public immutable override uerc20Factory;
    address public immutable override ccaFactory;
    address public immutable override poolManager;
    address public immutable override positionManager;
    address public immutable override usdg;
    address public immutable override inbox;
    address public immutable override adminSafe;
    address public immutable override hook;

    uint256 public override nextLaunchId = 1;
    /// @notice Born paused; only the Safe opens launches.
    bool public override launchesPaused = true;
    uint256 public override launchFee = RobinhoodPreset.LAUNCH_FEE_USDG;

    mapping(uint256 launchId => Launch) internal _launches;
    mapping(address auction => uint256 launchId) public override launchIdOfAuction;
    mapping(address newToken => uint256 launchId) public override launchIdOfToken;

    error ZeroAddress();
    error SelfAddress();
    error NoCode(address account);
    error UnexpectedRuntimeCodeHash(address account, bytes32 expected, bytes32 found);
    error UnexpectedDecimals(uint8 expected, uint8 found);
    error InboxBindingMismatch(address expected, address found);
    error HookBindingMismatch(address expected, address found);
    error NotSafe(address caller);
    error LaunchesAlreadyPaused();
    error LaunchesNotPaused();
    error LaunchesArePaused();
    error EmptyMetadataField(uint256 field);
    error MetadataFieldTooLong(uint256 field, uint256 maximum, uint256 found);
    error StartBlockOutOfWindow(uint64 startBlock, uint256 earliest, uint256 latest);
    error FloorPriceTooLow(uint256 floorPriceQ96);
    error FloorPriceNotOnGrid(uint256 floorPriceQ96);
    error TickSpacingTooSmall(uint256 tickSpacingQ96);
    error UnreachableRequiredRaise(uint256 requiredRaise, uint256 maximum);
    error ProtocolFeeControllerNotZero(address controller);
    error TokenHasNoCode(address token);
    error TokenCreatorMismatch(address found);
    error TokenGraffitiMismatch(bytes32 found);
    error TokenSupplyMismatch(uint256 expected, uint256 found);
    error AuctionHasNoCode(address auction);
    error AuctionBindingMismatch(uint256 field, uint256 expected, uint256 found);
    error InexactTransfer(uint256 expected, uint256 found);
    error ReserveMismatch(uint256 expected, uint256 found);
    error UnknownLaunch(uint256 launchId);
    error LaunchNotActive(Lifecycle found);
    error MigrationNotYetAllowed(uint64 migrationBlock, uint256 currentBlock);
    error CurrencyRaisedMismatch(uint256 expected, uint256 found);
    error NoPositions();
    error UnexpectedPositionMintCount(uint256 expected, uint256 found);
    error AllowanceNotConsumed(address spender, uint256 remaining);
    error StaleLaunchFee(uint256 current, uint256 expected);
    error LaunchFeeAllowanceMismatch(uint256 expected, uint256 found);

    /// @param hookSalt The pre-mined CREATE2 salt giving the hook the exact permission bits v4
    ///        encodes in a hook address. Not stored; a wrong salt simply fails construction.
    constructor(Bindings memory bindings, bytes32 hookSalt) {
        _requireRuntimeCodeHash(bindings.uerc20Factory, UERC20_FACTORY_RUNTIME_CODE_HASH);
        _requireContract(bindings.ccaFactory);
        _requireContract(bindings.poolManager);
        _requireContract(bindings.positionManager);
        _requireContract(bindings.hookFactory);
        _requireContract(bindings.usdg);
        _requireContract(bindings.inbox);
        if (bindings.adminSafe == address(0)) revert ZeroAddress();

        uint8 decimals = IERC20Minimal(bindings.usdg).decimals();
        if (decimals != RobinhoodPreset.USDG_DECIMALS) {
            revert UnexpectedDecimals(RobinhoodPreset.USDG_DECIMALS, decimals);
        }
        address inboxUsdg = IRobinhoodProtocolRevenueInboxV1(bindings.inbox).usdg();
        if (inboxUsdg != bindings.usdg) revert InboxBindingMismatch(bindings.usdg, inboxUsdg);

        // The zero address has no code and therefore cannot carry the required runtime hash.
        // slither-disable-next-line missing-zero-check
        uerc20Factory = bindings.uerc20Factory;
        ccaFactory = bindings.ccaFactory;
        poolManager = bindings.poolManager;
        positionManager = bindings.positionManager;
        usdg = bindings.usdg;
        inbox = bindings.inbox;
        adminSafe = bindings.adminSafe;

        address factoryPoolManager = RobinhoodFeeHookFactory(bindings.hookFactory).poolManager();
        if (factoryPoolManager != bindings.poolManager) {
            revert HookBindingMismatch(bindings.poolManager, factoryPoolManager);
        }
        address deployed = RobinhoodFeeHookFactory(bindings.hookFactory)
            .deploy(hookSalt, bindings.usdg, bindings.inbox, bindings.adminSafe);
        _requireHookBinding(address(this), RobinhoodFeeHookV1(deployed).launchpad());
        _requireHookBinding(bindings.usdg, RobinhoodFeeHookV1(deployed).usdg());
        _requireHookBinding(bindings.inbox, RobinhoodFeeHookV1(deployed).inbox());
        _requireHookBinding(bindings.poolManager, address(RobinhoodFeeHookV1(deployed).poolManager()));
        hook = deployed;
    }

    modifier onlySafe() {
        if (msg.sender != adminSafe) revert NotSafe(msg.sender);
        _;
    }

    // -------------------------------------------------------------------------
    // kind-specific surface
    // -------------------------------------------------------------------------

    /// @dev The fixed supply split of this launch kind.
    function _terms() internal pure virtual returns (Terms memory);

    /// @dev The destination of the subject lane the official pool is registered with. Runs at
    ///      graduation before anything else moves; a kind that creates its splitter here does so now.
    function _subjectDestination(uint256 launchId, Launch storage record) internal virtual returns (address);

    /// @dev The positions this kind locks at the dead address, from the raised currency and the
    ///      reserve. The first must be the full range.
    function _lockedPositions(
        PoolKey memory key,
        uint160 sqrtPriceX96,
        bool currencyIsCurrency0,
        uint128 currencyBudget,
        uint128 reserve
    ) internal view virtual returns (Position[] memory positions);

    /// @dev What this kind does with the currency the positions did not consume and with every unit
    ///      of NEW still held after graduation, and its graduation event.
    function _finishGraduation(
        uint256 launchId,
        Launch storage record,
        Position[] memory positions,
        uint256 raised,
        uint256 currencyRemainder
    ) internal virtual;

    // -------------------------------------------------------------------------
    // migration
    // -------------------------------------------------------------------------

    /// @inheritdoc IRobinhoodLaunchpadBase
    // slither-disable-next-line reentrancy-no-eth
    function migrate(uint256 launchId) external override nonReentrant {
        Launch storage record = _launches[launchId];
        if (record.auction == address(0)) revert UnknownLaunch(launchId);
        if (record.lifecycle != Lifecycle.Active) revert LaunchNotActive(record.lifecycle);
        uint256 current = _getBlockNumberish();
        if (current < record.migrationBlock) revert MigrationNotYetAllowed(record.migrationBlock, current);

        // The final checkpoint is the whole classification.
        // slither-disable-next-line unused-return
        IContinuousClearingAuction(record.auction).checkpoint();

        if (IContinuousClearingAuction(record.auction).isGraduated()) {
            _graduate(launchId, record);
        } else {
            _retire(launchId, record);
        }
    }

    // -------------------------------------------------------------------------
    // Safe surface
    // -------------------------------------------------------------------------

    /// @inheritdoc IRobinhoodLaunchpadBase
    function pauseLaunches() external override onlySafe {
        if (launchesPaused) revert LaunchesAlreadyPaused();
        launchesPaused = true;
        emit LaunchesPaused();
    }

    /// @inheritdoc IRobinhoodLaunchpadBase
    function unpauseLaunches() external override onlySafe {
        if (!launchesPaused) revert LaunchesNotPaused();
        launchesPaused = false;
        emit LaunchesUnpaused();
    }

    /// @inheritdoc IRobinhoodLaunchpadBase
    /// @dev A launcher who reviewed the previous fee is refused with `StaleLaunchFee`, never charged.
    function setLaunchFee(uint256 newFee) external override onlySafe {
        uint256 previousFee = launchFee;
        launchFee = newFee;
        emit LaunchFeeUpdated(previousFee, newFee);
    }

    // -------------------------------------------------------------------------
    // reads
    // -------------------------------------------------------------------------

    /// @inheritdoc IRobinhoodLaunchpadBase
    function launches(uint256 launchId) external view override returns (Launch memory) {
        return _launches[launchId];
    }

    /// @inheritdoc IRobinhoodLaunchpadBase
    function bidTickSpacingFor(uint256 floorPriceQ96) public pure override returns (uint256 tickSpacing) {
        if (floorPriceQ96 < ConstantsLib.MIN_FLOOR_PRICE) revert FloorPriceTooLow(floorPriceQ96);
        if (floorPriceQ96 % StocksPreset.BID_TICK_DIVISOR != 0) revert FloorPriceNotOnGrid(floorPriceQ96);
        tickSpacing = floorPriceQ96 / StocksPreset.BID_TICK_DIVISOR;
        if (tickSpacing < ConstantsLib.MIN_TICK_SPACING) revert TickSpacingTooSmall(tickSpacing);
    }

    /// @inheritdoc IRobinhoodLaunchpadBase
    function currentBlock() external view override returns (uint256) {
        return _getBlockNumberish();
    }

    // -------------------------------------------------------------------------
    // internals: creation
    // -------------------------------------------------------------------------

    /// @dev The whole shared creation path. The caller has already validated its kind-specific
    ///      inputs and derived `requiredRaise`; nothing here is kind-specific but the terms.
    function _create(CoreParams memory core, address currency, uint128 requiredRaise)
        internal
        returns (uint256 launchId, address newToken, address auction)
    {
        if (launchesPaused) revert LaunchesArePaused();

        _requireBytes(0, bytes(core.name).length, StocksPreset.MAX_NAME_BYTES);
        _requireBytes(1, bytes(core.symbol).length, StocksPreset.MAX_SYMBOL_BYTES);
        _requireBytes(2, bytes(core.description).length, StocksPreset.MAX_DESCRIPTION_BYTES);
        _requireBytes(3, bytes(core.website).length, StocksPreset.MAX_WEBSITE_BYTES);
        _requireBytes(4, bytes(core.image).length, StocksPreset.MAX_IMAGE_BYTES);

        uint256 current = _getBlockNumberish();
        uint256 earliest = current + StocksPreset.MIN_START_LEAD_BLOCKS;
        uint256 latest = current + StocksPreset.MAX_START_LEAD_BLOCKS;
        if (core.startBlock < earliest || core.startBlock > latest) {
            revert StartBlockOutOfWindow(core.startBlock, earliest, latest);
        }

        Terms memory terms = _terms();
        uint256 tickSpacing = bidTickSpacingFor(core.floorPriceQ96);
        uint256 reachable = _maxReachableRaise(terms.auctionInventory, tickSpacing);
        if (requiredRaise == 0 || requiredRaise > reachable) revert UnreachableRequiredRaise(requiredRaise, reachable);

        address controller = address(IContinuousClearingAuctionFactory(ccaFactory).protocolFeeController());
        if (controller != address(0)) revert ProtocolFeeControllerNotZero(controller);

        launchId = nextLaunchId;
        nextLaunchId = launchId + 1;

        // The fee is the first value to move: nothing of the launch exists yet, so a refused fee
        // costs the launcher only gas, and a launch never exists without its fee having been deposited.
        _collectAndDepositLaunchFee(launchId, core.expectedLaunchFee);

        newToken = _createNew(core, launchId, terms.totalSupply);

        uint64 endBlock = core.startBlock + StocksPreset.AUCTION_DURATION_BLOCKS;
        auction = _createAuction(newToken, currency, core, launchId, endBlock, tickSpacing, requiredRaise, terms);

        Launch storage record = _launches[launchId];
        record.launcher = msg.sender;
        record.newToken = newToken;
        record.currency = currency;
        record.auction = auction;
        record.startBlock = core.startBlock;
        record.endBlock = endBlock;
        record.claimBlock = endBlock + StocksPreset.CLAIM_DELAY_BLOCKS;
        record.migrationBlock = endBlock + StocksPreset.MIGRATION_DELAY_BLOCKS;
        record.requiredRaise = requiredRaise;
        record.floorPriceQ96 = core.floorPriceQ96;
        record.lifecycle = Lifecycle.Active;
        launchIdOfAuction[auction] = launchId;
        launchIdOfToken[newToken] = launchId;

        // Custody: exactly the inventory leaves for the auction and exactly the reserve stays.
        uint256 auctionHeld = newToken.balanceOf(auction);
        newToken.safeTransfer(auction, terms.auctionInventory);
        uint256 delivered = newToken.balanceOf(auction) - auctionHeld;
        if (delivered != terms.auctionInventory) revert InexactTransfer(terms.auctionInventory, delivered);
        IContinuousClearingAuction(auction).onTokensReceived();

        uint256 held = newToken.balanceOf(address(this));
        uint256 reserve = terms.totalSupply - terms.auctionInventory;
        if (held != reserve) revert ReserveMismatch(reserve, held);
    }

    /// @dev The USDG launch fee, with the Base launchpads' exact-allowance discipline and the inbox as
    ///      its destination: the fee passes through this contract only for the duration of the call.
    ///      The fee the launcher reviewed must be the current one and the allowance must equal it
    ///      exactly; a zero fee moves nothing and still requires a zero allowance. Every leg is proved
    ///      by balance delta and both temporary allowances are proved back at zero.
    function _collectAndDepositLaunchFee(uint256 launchId, uint256 expectedFee) private {
        uint256 fee = launchFee;
        if (fee != expectedFee) revert StaleLaunchFee(fee, expectedFee);

        address token = usdg;
        uint256 allowed = IERC20Minimal(token).allowance(msg.sender, address(this));
        if (allowed != fee) revert LaunchFeeAllowanceMismatch(fee, allowed);
        if (fee == 0) return;

        uint256 held = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), fee);
        uint256 pulled = token.balanceOf(address(this)) - held;
        if (pulled != fee) revert InexactTransfer(fee, pulled);
        uint256 remaining = IERC20Minimal(token).allowance(msg.sender, address(this));
        if (remaining != 0) revert AllowanceNotConsumed(address(this), remaining);

        address destination = inbox;
        token.safeApprove(destination, fee);
        uint256 received =
            IRobinhoodProtocolRevenueInboxV1(destination).deposit(fee, LAUNCH_FEE_SOURCE_TAG, bytes32(launchId));
        if (received != fee) revert InexactTransfer(fee, received);
        uint256 afterDeposit = token.balanceOf(address(this));
        if (afterDeposit != held) revert InexactTransfer(held, afterDeposit);
        remaining = IERC20Minimal(token).allowance(address(this), destination);
        if (remaining != 0) revert AllowanceNotConsumed(destination, remaining);

        emit LaunchFeeCollected(launchId, msg.sender, destination, fee);
    }

    /// @dev Exactly `totalSupply` of NEW, minted once, to this contract, by the pinned UERC20 factory.
    function _createNew(CoreParams memory core, uint256 launchId, uint256 totalSupply)
        private
        returns (address newToken)
    {
        bytes32 graffiti = bytes32(launchId);
        newToken = IUERC20Factory(uerc20Factory)
            .createToken(
                core.name,
                core.symbol,
                StocksPreset.NEW_DECIMALS,
                totalSupply,
                address(this),
                abi.encode(UERC20Metadata({description: core.description, website: core.website, image: core.image})),
                graffiti
            );

        if (newToken.code.length == 0) revert TokenHasNoCode(newToken);
        address creator = UERC20(newToken).creator();
        if (creator != address(this)) revert TokenCreatorMismatch(creator);
        bytes32 found = UERC20(newToken).graffiti();
        if (found != graffiti) revert TokenGraffitiMismatch(found);
        uint256 supply = IERC20Minimal(newToken).totalSupply();
        if (supply != totalSupply) revert TokenSupplyMismatch(totalSupply, supply);
        uint256 held = newToken.balanceOf(address(this));
        if (held != totalSupply) revert TokenSupplyMismatch(totalSupply, held);
    }

    /// @dev The canonical fixed auction: the launch currency, both recipients this contract, no
    ///      validation hook, the preset schedule. Every exposed binding is read back before any value moves.
    function _createAuction(
        address newToken,
        address currency,
        CoreParams memory core,
        uint256 launchId,
        uint64 endBlock,
        uint256 tickSpacing,
        uint128 requiredRaise,
        Terms memory terms
    ) private returns (address auction) {
        auction = address(
            IContinuousClearingAuctionFactory(ccaFactory)
                .create(
                    newToken,
                    terms.auctionInventory,
                    abi.encode(
                        AuctionParameters({
                            currency: currency,
                            tokensRecipient: address(this),
                            fundsRecipient: address(this),
                            startBlock: core.startBlock,
                            endBlock: endBlock,
                            claimBlock: endBlock + StocksPreset.CLAIM_DELAY_BLOCKS,
                            tickSpacing: tickSpacing,
                            validationHook: address(0),
                            floorPrice: core.floorPriceQ96,
                            requiredCurrencyRaised: requiredRaise,
                            auctionStepsData: StocksPreset.AUCTION_STEPS
                        })
                    ),
                    bytes32(launchId)
                )
        );

        if (auction.code.length == 0) revert AuctionHasNoCode(auction);
        IContinuousClearingAuction cca = IContinuousClearingAuction(auction);
        _requireBinding(0, uint256(uint160(newToken)), uint256(uint160(cca.token())));
        _requireBinding(1, uint256(uint160(currency)), uint256(uint160(cca.currency())));
        _requireBinding(2, terms.auctionInventory, cca.totalSupply());
        _requireBinding(3, uint256(uint160(address(this))), uint256(uint160(cca.tokensRecipient())));
        _requireBinding(4, uint256(uint160(address(this))), uint256(uint160(cca.fundsRecipient())));
        _requireBinding(5, core.startBlock, cca.startBlock());
        _requireBinding(6, endBlock, cca.endBlock());
        _requireBinding(7, endBlock + StocksPreset.CLAIM_DELAY_BLOCKS, cca.claimBlock());
        _requireBinding(8, 0, uint256(uint160(address(cca.validationHook()))));
        _requireBinding(9, core.floorPriceQ96, cca.floorPrice());
        _requireBinding(10, tickSpacing, cca.tickSpacing());
    }

    /// @dev The largest raise the inventory can settle on for a bid grid: the inventory at the highest
    ///      on-grid price the pinned CCA admits, capped at what the CCA can carry.
    function _maxReachableRaise(uint128 inventory, uint256 tickSpacing) internal pure returns (uint256 reachable) {
        uint256 maxBidPrice = MaxBidPriceLib.maxBidPrice(inventory);
        uint256 onGrid = maxBidPrice - (maxBidPrice % tickSpacing);
        reachable = FullMath.mulDiv(inventory, onGrid, FixedPoint96.Q96);
        if (reachable > type(uint128).max) reachable = type(uint128).max;
    }

    // -------------------------------------------------------------------------
    // internals: terminal states
    // -------------------------------------------------------------------------

    /// @dev Economic failure: every unit of this launch's NEW still held, the swept inventory and the
    ///      reserve alike, is retired; bidder currency is never touched and refunds go through the CCA.
    // slither-disable-next-line reentrancy-no-eth
    function _retire(uint256 launchId, Launch storage record) private {
        record.lifecycle = Lifecycle.Failed;

        address newToken = record.newToken;
        address auction = record.auction;
        IContinuousClearingAuction(auction).sweepUnsoldTokens();

        uint256 retired = newToken.balanceOf(address(this));
        record.retiredNew = retired;
        emit LaunchRetired(launchId, auction, retired);
        if (retired != 0) newToken.safeTransfer(DEAD_ADDRESS, retired);
    }

    /// @dev Graduation, in one fixed order. The terminal lifecycle is written before the first external
    ///      call; every later revert rolls the whole transaction back together.
    // slither-disable-next-line reentrancy-no-eth
    function _graduate(uint256 launchId, Launch storage record) private {
        address newToken = record.newToken;
        address currency = record.currency;
        address auction = record.auction;

        // Reverts unless checkpointed at the exact end block and actually graduated.
        LBPInitializationParams memory lbp = IContinuousClearingAuction(auction).lbpInitializationParams();

        record.lifecycle = Lifecycle.Graduated;

        address subject = _subjectDestination(launchId, record);
        PoolKey memory key = _poolKeyOf(newToken, currency);
        bytes32 poolId = RobinhoodFeeHookV1(hook).registerPool(key, currency, newToken, subject);

        uint256 currencyBefore = currency.balanceOf(address(this));
        IContinuousClearingAuction(auction).sweepCurrency();
        uint256 raised = currency.balanceOf(address(this)) - currencyBefore;
        if (raised != lbp.currencyRaised) revert CurrencyRaisedMismatch(lbp.currencyRaised, raised);

        IContinuousClearingAuction(auction).sweepUnsoldTokens();

        bool currencyIsCurrency0 = Currency.unwrap(key.currency0) == currency;
        uint160 sqrtPriceX96 = TokenPricing.convertToSqrtPriceX96(
            TokenPricing.convertToPriceX192(lbp.initialPriceX96, currencyIsCurrency0)
        );
        // slither-disable-next-line unused-return
        IPoolManager(poolManager).initialize(key, sqrtPriceX96);

        Position[] memory positions = _lockedPositions(
            key, sqrtPriceX96, currencyIsCurrency0, SafeCastLib.toUint128(raised), _terms().migrationReserve
        );
        if (positions.length == 0) revert NoPositions();
        (uint128 currencyPlaced, uint128 newPlaced) = _placedAmounts(currencyIsCurrency0, positions);
        uint256 firstTokenId =
            _mintPositions(key, positions, currency, newToken, currencyIsCurrency0, currencyPlaced, newPlaced);

        record.poolId = poolId;
        record.finalSqrtPriceX96 = sqrtPriceX96;
        record.lpTokenId = firstTokenId;
        record.lpCurrencyUsed = currencyPlaced;
        record.lpNewUsed = newPlaced;

        // Only this launch's own currency delta moves on. Anything unrelated already held here stays.
        uint256 currencyRemainder = currency.balanceOf(address(this)) - currencyBefore;
        _finishGraduation(launchId, record, positions, raised, currencyRemainder);
    }

    /// @dev The official pool key one launch graduates into.
    function _poolKeyOf(address newToken, address currency) internal view returns (PoolKey memory key) {
        bool currencyIsCurrency0 = currency < newToken;
        key = PoolKey({
            currency0: Currency.wrap(currencyIsCurrency0 ? currency : newToken),
            currency1: Currency.wrap(currencyIsCurrency0 ? newToken : currency),
            fee: StocksPreset.POOL_FEE,
            tickSpacing: StocksPreset.POOL_TICK_SPACING,
            hooks: IHooks(hook)
        });
    }

    /// @dev The full-range position the pinned planner resolves from a currency budget and the reserve.
    function _fullRangePosition(uint160 sqrtPriceX96, bool currencyIsCurrency0, uint128 currencyBudget, uint128 reserve)
        internal
        pure
        returns (Position memory)
    {
        return RobinhoodPositionsLib.fullRange(sqrtPriceX96, currencyIsCurrency0, currencyBudget, reserve);
    }

    /// @dev One position from an explicit definition and a budget; empty when the budget is below one
    ///      unit of liquidity.
    function _definedPosition(uint160 sqrtPriceX96, PositionDefinition memory definition, CurrencyAmounts memory budget)
        internal
        pure
        returns (Position[] memory)
    {
        return RobinhoodPositionsLib.defined(sqrtPriceX96, definition, budget);
    }

    function _currencyAmounts(bool currencyIsCurrency0, uint128 currencyAmount, uint128 newAmount)
        internal
        pure
        returns (CurrencyAmounts memory)
    {
        return RobinhoodPositionsLib.currencyAmounts(currencyIsCurrency0, currencyAmount, newAmount);
    }

    function _currencyAndNew(bool currencyIsCurrency0, Position memory position)
        internal
        pure
        returns (uint128 currencyAmount, uint128 newAmount)
    {
        (currencyAmount, newAmount) = currencyIsCurrency0
            ? (SafeCastLib.toUint128(position.amount0), SafeCastLib.toUint128(position.amount1))
            : (SafeCastLib.toUint128(position.amount1), SafeCastLib.toUint128(position.amount0));
    }

    function _placedAmounts(bool currencyIsCurrency0, Position[] memory positions)
        private
        pure
        returns (uint128 currencyPlaced, uint128 newPlaced)
    {
        for (uint256 i = 0; i < positions.length; i++) {
            (uint128 currencyAmount, uint128 newAmount) = _currencyAndNew(currencyIsCurrency0, positions[i]);
            currencyPlaced += currencyAmount;
            newPlaced += newAmount;
        }
    }

    /// @dev Mint every position straight to the dead address in one PositionManager call, funded with
    ///      exactly the two summed amounts, so nothing already sitting at the shared PositionManager is
    ///      settled as this launch's credit. Each position's amounts never exceed the budget it was
    ///      planned from, so the total settled is exactly what this function transfers in.
    function _mintPositions(
        PoolKey memory key,
        Position[] memory positions,
        address currency,
        address newToken,
        bool currencyIsCurrency0,
        uint128 currencyPlaced,
        uint128 newPlaced
    ) private returns (uint256 firstTokenId) {
        bytes memory unlockData = RobinhoodPositionsLib.exactlyFundedPlan(
            positions,
            key,
            currencyIsCurrency0 ? currencyPlaced : newPlaced,
            currencyIsCurrency0 ? newPlaced : currencyPlaced
        );

        address manager = positionManager;
        firstTokenId = IPositionManager(manager).nextTokenId();

        currency.safeTransfer(manager, currencyPlaced);
        newToken.safeTransfer(manager, newPlaced);
        IPositionManager(manager).modifyLiquidities(unlockData, block.timestamp);

        uint256 expected = firstTokenId + positions.length;
        uint256 minted = IPositionManager(manager).nextTokenId();
        if (minted != expected) revert UnexpectedPositionMintCount(expected, minted);
    }

    // -------------------------------------------------------------------------
    // internals: checks
    // -------------------------------------------------------------------------

    function _requireContract(address account) internal view {
        if (account == address(0)) revert ZeroAddress();
        if (account.code.length == 0) revert NoCode(account);
    }

    function _requireRuntimeCodeHash(address account, bytes32 expected) internal view {
        bytes32 found = account.codehash;
        if (found != expected) revert UnexpectedRuntimeCodeHash(account, expected, found);
    }

    function _requireBytes(uint256 field, uint256 length, uint256 maximum) private pure {
        if (length == 0) revert EmptyMetadataField(field);
        if (length > maximum) revert MetadataFieldTooLong(field, maximum, length);
    }

    function _requireHookBinding(address expected, address found) private pure {
        if (expected != found) revert HookBindingMismatch(expected, found);
    }

    function _requireBinding(uint256 field, uint256 expected, uint256 found) private pure {
        if (expected != found) revert AuctionBindingMismatch(field, expected, found);
    }

    function _requireLaunch(uint256 launchId) internal view returns (Launch storage record) {
        record = _launches[launchId];
        if (record.auction == address(0)) revert UnknownLaunch(launchId);
    }
}
