// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

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
import {PositionPlanner} from "liquidity-launcher/src/libraries/PositionPlanner.sol";
import {TokenPricing} from "liquidity-launcher/src/libraries/TokenPricing.sol";
import {
    CurrencyAmounts,
    Plan,
    Position,
    PositionDefinition
} from "liquidity-launcher/src/types/PositionPlannerTypes.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {ActionConstants} from "@uniswap/v4-periphery/src/libraries/ActionConstants.sol";
import {LibClone} from "solady/utils/LibClone.sol";
import {ReentrancyGuardTransient} from "solady/utils/ReentrancyGuardTransient.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {IUERC20Factory} from "uerc20-factory/interfaces/IUERC20Factory.sol";
import {UERC20Metadata} from "uerc20-factory/libraries/UERC20MetadataLibrary.sol";
import {UERC20} from "uerc20-factory/tokens/UERC20.sol";
import {IERC20Views} from "./interfaces/IERC20Views.sol";
import {IStockRoute} from "./interfaces/IStockRoute.sol";
import {IStocksLaunchpadV1} from "./interfaces/IStocksLaunchpadV1.sol";
import {MemestockLPLocker} from "./MemestockLPLocker.sol";
import {MemestockSplitterV1} from "./MemestockSplitterV1.sol";
import {StocksBindings} from "./StocksBindings.sol";
import {StocksFeeHookV1} from "./StocksFeeHookV1.sol";
import {StocksPreset} from "./StocksPreset.sol";

/// @title StocksLaunchpadV1
/// @notice Admission, creation, custody and migration of Autolaunch Stocks.
/// @dev One launch mints exactly `S0` of a new UERC20 (NEW) to this contract, sells the 80% inventory
///      through a pinned Continuous Clearing Auction denominated in one admitted STOCK, custodies the
///      20% reserve, and after the auction either graduates into two locked NEW/STOCK positions or
///      retires the inventory. Every economic term comes from `StocksPreset`; a launcher supplies
///      metadata, the STOCK, the floor price and the required raise, nothing else, and keeps no
///      authority over the launch afterwards. The auction opens `START_LEAD_BLOCKS` after creation.
///
///      Graduation creates the launch's own memestock splitter, the fixed destination of the hook's
///      staker lane, and mints both positions to the permanent fee-only locker, which deposits their
///      LP fees into that same splitter. No principal path exists.
///
///      The CCA creation, `_graduate`, `_mintLockedPositions` and `_exactlyFundedPlan` mirror the
///      frozen Agent `RegentLBPStrategy` technique: the auction is read back field by field before any
///      value moves, the final price is converted through the pinned `TokenPricing`, every position is
///      planned by the pinned `PositionPlanner`, and the two settlement amounts are pinned to what this
///      graduation actually funds so nothing already sitting at the shared PositionManager is touched.
///      Stocks departs from Agent in what it does with STOCK the full range cannot pair: Agent sends it
///      to a treasury, Stocks locks it in a second, one-sided STOCK position (brief P13).
///
///      A launch costs nothing beyond gas: no REGENT is pulled and the launchpad never holds REGENT.
contract StocksLaunchpadV1 is ReentrancyGuardTransient, IStocksLaunchpadV1 {
    using SafeTransferLib for address;
    using PoolIdLibrary for PoolKey;

    /// @dev The runtime code hash the pinned UERC20 factory must present, as the frozen Agent factory
    ///      demands it (`RegentsAutolaunchFactoryV1.UERC20_FACTORY_RUNTIME_CODE_HASH`).
    bytes32 internal constant UERC20_FACTORY_RUNTIME_CODE_HASH =
        0x47a5ee559aa5c815a6a350486a1de3beb868d238ba5b2d46e62db5128645195f;

    struct Admission {
        bool admitted;
        uint8 decimals;
        address route;
    }

    /// @dev What one graduation locked in the locker.
    struct LockedLiquidity {
        uint256 fullRangeTokenId;
        uint128 fullRangeStock;
        uint128 fullRangeNew;
        /// @dev Zero when the STOCK the full range could not pair was below one unit of liquidity.
        uint256 stockOnlyTokenId;
        uint128 stockOnlyStock;
    }

    /// @dev The pinned UERC20 factory every NEW is created by. A constructor argument; the lab records
    ///      it in its run documents.
    address internal immutable uerc20Factory;

    /// @notice The clone target of every launch's memestock splitter, deployed by this constructor.
    address public immutable override splitterImplementation;

    /// @notice The permanent fee-only custodian of every graduated position, deployed by this constructor.
    address public immutable override locker;

    /// @notice The one official-pool hook, mined and deployed by this constructor.
    address public immutable override hook;

    uint256 public override nextLaunchId = 1;

    /// @notice Born paused; only governance opens launches.
    bool public override launchesPaused = true;

    mapping(address stock => Admission) private _admissions;
    mapping(uint256 launchId => Launch) private _launches;
    mapping(address auction => uint256 launchId) public override launchIdOfAuction;
    mapping(address newToken => uint256 launchId) public override launchIdOfToken;

    error UnexpectedRuntimeCodeHash(address account, bytes32 expected, bytes32 found);
    error ZeroAddress();
    error NoCode(address account);
    error NotGovernance(address caller);
    error LaunchesAlreadyPaused();
    error LaunchesNotPaused();
    error LaunchesArePaused();
    error EmptyMetadataField(uint256 field);
    error MetadataFieldTooLong(uint256 field, uint256 maximum, uint256 found);
    error StockNotAdmitted(address stock);
    error StockRefused(address stock);
    error RouteBindingMismatch(address expected, address found);
    error FloorPriceTooLow(uint256 floorPriceQ96);
    error FloorPriceNotOnGrid(uint256 floorPriceQ96);
    error TickSpacingTooSmall(uint256 tickSpacingQ96);
    error UnreachableRequiredRaise(uint256 requiredStockRaised, uint256 maximum);
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
    error NoFullRangePosition();
    error UnexpectedStockOnlyPositionCount(uint256 found);
    error UnexpectedPositionMintCount(uint256 expected, uint256 found);
    error AllowanceNotConsumed(address spender, uint256 remaining);

    /// @param hookSalt The pre-mined CREATE2 salt giving the hook the exact permission bits v4
    ///        encodes in a hook address. Not stored; a wrong salt simply fails construction.
    constructor(address uerc20Factory_, bytes32 hookSalt) {
        _requireRuntimeCodeHash(uerc20Factory_, UERC20_FACTORY_RUNTIME_CODE_HASH);

        // The zero address has no code and therefore cannot carry the required runtime hash.
        // slither-disable-next-line missing-zero-check
        uerc20Factory = uerc20Factory_;
        splitterImplementation = address(new MemestockSplitterV1());
        locker = address(new MemestockLPLocker(address(this), StocksBindings.POSITION_MANAGER));
        hook = address(new StocksFeeHookV1{salt: hookSalt}(IPoolManager(StocksBindings.POOL_MANAGER), address(this)));
    }

    modifier onlyGovernance() {
        if (msg.sender != StocksBindings.GOVERNANCE_AND_REGENT_SAFE) revert NotGovernance(msg.sender);
        _;
    }

    // -------------------------------------------------------------------------
    // creation
    // -------------------------------------------------------------------------

    /// @inheritdoc IStocksLaunchpadV1
    // slither-disable-next-line reentrancy-no-eth,reentrancy-benign
    function launch(LaunchParams calldata params)
        external
        override
        nonReentrant
        returns (uint256 launchId, address newToken, address auction)
    {
        if (launchesPaused) revert LaunchesArePaused();

        _requireBytes(0, bytes(params.name).length, StocksPreset.MAX_NAME_BYTES);
        _requireBytes(1, bytes(params.symbol).length, StocksPreset.MAX_SYMBOL_BYTES);
        _requireBytes(2, bytes(params.description).length, StocksPreset.MAX_DESCRIPTION_BYTES);
        _requireBytes(3, bytes(params.website).length, StocksPreset.MAX_WEBSITE_BYTES);
        _requireBytes(4, bytes(params.image).length, StocksPreset.MAX_IMAGE_BYTES);

        Admission storage admission = _admissions[params.stock];
        if (!admission.admitted) revert StockNotAdmitted(params.stock);

        uint256 tickSpacing = bidTickSpacingFor(params.floorPriceQ96);
        // The launcher chooses the STOCK raise. It must be a nonzero amount the fixed inventory can
        // actually settle on: the inventory at the highest on-grid price the pinned CCA admits.
        uint256 reachable = _maxReachableRaise(tickSpacing);
        if (params.requiredStockRaised == 0 || params.requiredStockRaised > reachable) {
            revert UnreachableRequiredRaise(params.requiredStockRaised, reachable);
        }

        address controller =
            address(IContinuousClearingAuctionFactory(StocksBindings.CCA_FACTORY).protocolFeeController());
        if (controller != address(0)) revert ProtocolFeeControllerNotZero(controller);

        launchId = nextLaunchId;
        nextLaunchId = launchId + 1;

        newToken = _createNew(params, launchId);

        uint64 startBlock = SafeCastLib.toUint64(block.number) + StocksPreset.START_LEAD_BLOCKS;
        uint64 endBlock = startBlock + StocksPreset.AUCTION_DURATION_BLOCKS;
        auction = _createAuction(newToken, params, launchId, startBlock, endBlock, tickSpacing);

        Launch storage record = _launches[launchId];
        record.launcher = msg.sender;
        record.newToken = newToken;
        record.stock = params.stock;
        record.auction = auction;
        record.startBlock = startBlock;
        record.endBlock = endBlock;
        record.claimBlock = endBlock + StocksPreset.CLAIM_DELAY_BLOCKS;
        record.migrationBlock = endBlock + StocksPreset.MIGRATION_DELAY_BLOCKS;
        record.requiredStockRaised = params.requiredStockRaised;
        record.floorPriceQ96 = params.floorPriceQ96;
        record.lifecycle = Lifecycle.Active;
        launchIdOfAuction[auction] = launchId;
        launchIdOfToken[newToken] = launchId;

        emit StockLaunchCreated(
            launchId,
            msg.sender,
            newToken,
            params.stock,
            auction,
            startBlock,
            endBlock,
            params.floorPriceQ96,
            params.requiredStockRaised,
            StocksPreset.AUCTION_INVENTORY,
            StocksPreset.MIGRATION_RESERVE
        );
        // Custody: exactly the inventory leaves for the auction and exactly the reserve stays.
        uint256 auctionHeld = newToken.balanceOf(auction);
        newToken.safeTransfer(auction, StocksPreset.AUCTION_INVENTORY);
        uint256 delivered = newToken.balanceOf(auction) - auctionHeld;
        if (delivered != StocksPreset.AUCTION_INVENTORY) {
            revert InexactTransfer(StocksPreset.AUCTION_INVENTORY, delivered);
        }
        IContinuousClearingAuction(auction).onTokensReceived();

        uint256 held = newToken.balanceOf(address(this));
        if (held != StocksPreset.MIGRATION_RESERVE) revert ReserveMismatch(StocksPreset.MIGRATION_RESERVE, held);
    }

    /// @inheritdoc IStocksLaunchpadV1
    // slither-disable-next-line reentrancy-no-eth
    function migrate(uint256 launchId) external override nonReentrant {
        Launch storage record = _launches[launchId];
        if (record.auction == address(0)) revert UnknownLaunch(launchId);
        if (record.lifecycle != Lifecycle.Active) revert LaunchNotActive(record.lifecycle);
        if (block.number < record.migrationBlock) revert MigrationNotYetAllowed(record.migrationBlock, block.number);

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
    // governance
    // -------------------------------------------------------------------------

    /// @inheritdoc IStocksLaunchpadV1
    function admitStock(address stock, address route) external override onlyGovernance {
        if (stock == address(0) || route == address(0)) revert ZeroAddress();
        if (stock == StocksBindings.USDC || stock == StocksBindings.REGENT) revert StockRefused(stock);
        if (stock.code.length == 0) revert NoCode(stock);
        if (route.code.length == 0) revert NoCode(route);
        address routeStock = IStockRoute(route).stock();
        if (routeStock != stock) revert RouteBindingMismatch(stock, routeStock);
        address routeUsdc = IStockRoute(route).usdc();
        if (routeUsdc != StocksBindings.USDC) revert RouteBindingMismatch(StocksBindings.USDC, routeUsdc);

        uint8 decimals = IERC20Views(stock).decimals();
        _admissions[stock] = Admission({admitted: true, decimals: decimals, route: route});
        emit StockAdmitted(stock, decimals);
    }

    /// @inheritdoc IStocksLaunchpadV1
    /// @dev Stops new launches only. The recorded route stays so existing pools can still settle.
    function revokeStock(address stock) external override onlyGovernance {
        if (!_admissions[stock].admitted) revert StockNotAdmitted(stock);
        _admissions[stock].admitted = false;
        emit StockRevoked(stock);
    }

    /// @inheritdoc IStocksLaunchpadV1
    function pauseLaunches() external override onlyGovernance {
        if (launchesPaused) revert LaunchesAlreadyPaused();
        launchesPaused = true;
        emit LaunchesPaused();
    }

    /// @inheritdoc IStocksLaunchpadV1
    function unpauseLaunches() external override onlyGovernance {
        if (!launchesPaused) revert LaunchesNotPaused();
        launchesPaused = false;
        emit LaunchesUnpaused();
    }

    // -------------------------------------------------------------------------
    // reads
    // -------------------------------------------------------------------------

    /// @inheritdoc IStocksLaunchpadV1
    function launches(uint256 launchId) external view override returns (Launch memory) {
        return _launches[launchId];
    }

    /// @inheritdoc IStocksLaunchpadV1
    function stockAdmission(address stock)
        external
        view
        override
        returns (bool admitted, uint8 decimals, address route)
    {
        Admission storage admission = _admissions[stock];
        return (admission.admitted, admission.decimals, admission.route);
    }

    /// @inheritdoc IStocksLaunchpadV1
    function bidTickSpacingFor(uint256 floorPriceQ96) public pure override returns (uint256 tickSpacing) {
        if (floorPriceQ96 < ConstantsLib.MIN_FLOOR_PRICE) revert FloorPriceTooLow(floorPriceQ96);
        if (floorPriceQ96 % StocksPreset.BID_TICK_DIVISOR != 0) revert FloorPriceNotOnGrid(floorPriceQ96);
        tickSpacing = floorPriceQ96 / StocksPreset.BID_TICK_DIVISOR;
        if (tickSpacing < ConstantsLib.MIN_TICK_SPACING) revert TickSpacingTooSmall(tickSpacing);
    }

    /// @dev The largest STOCK raise the fixed inventory can settle on for a bid grid: the inventory at
    ///      the highest on-grid price the pinned CCA admits, capped at what the auction can carry.
    function _maxReachableRaise(uint256 tickSpacing) private pure returns (uint256 reachable) {
        uint256 maxBidPrice = MaxBidPriceLib.maxBidPrice(StocksPreset.AUCTION_INVENTORY);
        uint256 onGrid = maxBidPrice - (maxBidPrice % tickSpacing);
        reachable = FullMath.mulDiv(StocksPreset.AUCTION_INVENTORY, onGrid, FixedPoint96.Q96);
        if (reachable > type(uint128).max) reachable = type(uint128).max;
    }

    /// @dev The official pool key one launch graduates into.
    function _poolKeyOf(address newToken, address stock) private view returns (PoolKey memory key) {
        bool stockIsCurrency0 = stock < newToken;
        key = PoolKey({
            currency0: Currency.wrap(stockIsCurrency0 ? stock : newToken),
            currency1: Currency.wrap(stockIsCurrency0 ? newToken : stock),
            fee: StocksPreset.POOL_FEE,
            tickSpacing: StocksPreset.POOL_TICK_SPACING,
            hooks: IHooks(hook)
        });
    }

    // -------------------------------------------------------------------------
    // internals: creation
    // -------------------------------------------------------------------------

    /// @dev Exactly `S0` of NEW, minted once, to this contract, by the pinned UERC20 factory.
    function _createNew(LaunchParams calldata params, uint256 launchId) private returns (address newToken) {
        bytes32 graffiti = bytes32(launchId);
        newToken = IUERC20Factory(uerc20Factory)
            .createToken(
                params.name,
                params.symbol,
                StocksPreset.NEW_DECIMALS,
                StocksPreset.INITIAL_SUPPLY,
                address(this),
                abi.encode(
                    UERC20Metadata({description: params.description, website: params.website, image: params.image})
                ),
                graffiti
            );

        if (newToken.code.length == 0) revert TokenHasNoCode(newToken);
        address creator = UERC20(newToken).creator();
        if (creator != address(this)) revert TokenCreatorMismatch(creator);
        bytes32 found = UERC20(newToken).graffiti();
        if (found != graffiti) revert TokenGraffitiMismatch(found);
        uint256 supply = IERC20Views(newToken).totalSupply();
        if (supply != StocksPreset.INITIAL_SUPPLY) revert TokenSupplyMismatch(StocksPreset.INITIAL_SUPPLY, supply);
        uint256 held = newToken.balanceOf(address(this));
        if (held != StocksPreset.INITIAL_SUPPLY) revert TokenSupplyMismatch(StocksPreset.INITIAL_SUPPLY, held);
    }

    /// @dev The canonical fixed auction: currency STOCK, both recipients this contract, no validation
    ///      hook, the preset schedule. Every exposed binding is read back before any value moves.
    function _createAuction(
        address newToken,
        LaunchParams calldata params,
        uint256 launchId,
        uint64 startBlock,
        uint64 endBlock,
        uint256 tickSpacing
    ) private returns (address auction) {
        auction = address(
            IContinuousClearingAuctionFactory(StocksBindings.CCA_FACTORY)
                .create(
                    newToken,
                    StocksPreset.AUCTION_INVENTORY,
                    abi.encode(
                        AuctionParameters({
                            currency: params.stock,
                            tokensRecipient: address(this),
                            fundsRecipient: address(this),
                            startBlock: startBlock,
                            endBlock: endBlock,
                            claimBlock: endBlock + StocksPreset.CLAIM_DELAY_BLOCKS,
                            tickSpacing: tickSpacing,
                            validationHook: address(0),
                            floorPrice: params.floorPriceQ96,
                            requiredCurrencyRaised: params.requiredStockRaised,
                            auctionStepsData: StocksPreset.AUCTION_STEPS
                        })
                    ),
                    bytes32(launchId)
                )
        );

        // A code-presence check, not an arithmetic equality: a CREATE2 address without code is no auction.
        // slither-disable-next-line incorrect-equality
        if (auction.code.length == 0) revert AuctionHasNoCode(auction);
        IContinuousClearingAuction cca = IContinuousClearingAuction(auction);
        _requireBinding(0, uint256(uint160(newToken)), uint256(uint160(cca.token())));
        _requireBinding(1, uint256(uint160(params.stock)), uint256(uint160(cca.currency())));
        _requireBinding(2, StocksPreset.AUCTION_INVENTORY, cca.totalSupply());
        _requireBinding(3, uint256(uint160(address(this))), uint256(uint160(cca.tokensRecipient())));
        _requireBinding(4, uint256(uint160(address(this))), uint256(uint160(cca.fundsRecipient())));
        _requireBinding(5, startBlock, cca.startBlock());
        _requireBinding(6, endBlock, cca.endBlock());
        _requireBinding(7, endBlock + StocksPreset.CLAIM_DELAY_BLOCKS, cca.claimBlock());
        _requireBinding(8, 0, uint256(uint160(address(cca.validationHook()))));
        _requireBinding(9, params.floorPriceQ96, cca.floorPrice());
        _requireBinding(10, tickSpacing, cca.tickSpacing());
    }

    // -------------------------------------------------------------------------
    // internals: terminal states
    // -------------------------------------------------------------------------

    /// @dev Economic failure: the swept inventory and the reserve are retired; bidder STOCK is never
    ///      touched and refunds go through the CCA. The terminal lifecycle is written before the sweep
    ///      and `migrate` is guarded, so the amount recorded after it is the only late write.
    // slither-disable-next-line reentrancy-no-eth
    function _retire(uint256 launchId, Launch storage record) private {
        record.lifecycle = Lifecycle.Failed;

        address newToken = record.newToken;
        address auction = record.auction;
        IContinuousClearingAuction(auction).sweepUnsoldTokens();

        uint256 retired = newToken.balanceOf(address(this));
        record.retiredNew = retired;
        emit StockLaunchRetired(launchId, auction, retired);
        if (retired != 0) newToken.safeTransfer(StocksBindings.DEAD_ADDRESS, retired);
    }

    /// @dev Graduation, in one fixed order. The terminal lifecycle is written before the first external
    ///      call; every later revert rolls the whole transaction back together.
    // slither-disable-next-line reentrancy-no-eth
    function _graduate(uint256 launchId, Launch storage record) private {
        address newToken = record.newToken;
        address stock = record.stock;
        address auction = record.auction;

        // Reverts unless checkpointed at the exact end block and actually graduated.
        LBPInitializationParams memory lbp = IContinuousClearingAuction(auction).lbpInitializationParams();

        record.lifecycle = Lifecycle.Graduated;

        // The launch's own splitter: the fixed destination of the hook's staker lane and of both
        // locked positions' LP fees. It exists only for a launch that graduated.
        address splitter = LibClone.clone(splitterImplementation);
        MemestockSplitterV1(splitter).initialize(newToken, stock);
        record.splitter = splitter;
        emit MemestockSplitterCreated(launchId, newToken, stock, splitter);

        PoolKey memory key = _poolKeyOf(newToken, stock);
        bytes32 poolId = StocksFeeHookV1(hook).registerPool(key, stock, newToken, splitter);

        uint256 stockBefore = stock.balanceOf(address(this));
        IContinuousClearingAuction(auction).sweepCurrency();
        uint256 raised = stock.balanceOf(address(this)) - stockBefore;
        if (raised != lbp.currencyRaised) revert CurrencyRaisedMismatch(lbp.currencyRaised, raised);

        IContinuousClearingAuction(auction).sweepUnsoldTokens();

        bool stockIsCurrency0 = Currency.unwrap(key.currency0) == stock;
        uint160 sqrtPriceX96 =
            TokenPricing.convertToSqrtPriceX96(TokenPricing.convertToPriceX192(lbp.initialPriceX96, stockIsCurrency0));
        // slither-disable-next-line unused-return
        IPoolManager(StocksBindings.POOL_MANAGER).initialize(key, sqrtPriceX96);

        LockedLiquidity memory locked = _mintLockedPositions(
            key,
            sqrtPriceX96,
            stockIsCurrency0,
            stock,
            newToken,
            SafeCastLib.toUint128(raised),
            StocksPreset.MIGRATION_RESERVE
        );
        MemestockLPLocker(locker).register(locked.fullRangeTokenId, key, splitter);
        if (locked.stockOnlyTokenId != 0) MemestockLPLocker(locker).register(locked.stockOnlyTokenId, key, splitter);

        // Only this launch's own STOCK delta moves on. Anything unrelated already held here stays.
        // After both positions this is the rounding remainder below one unit of liquidity.
        uint256 stockDust = stock.balanceOf(address(this)) - stockBefore;
        if (stockDust != 0) {
            stock.safeApprove(hook, stockDust);
            StocksFeeHookV1(hook).creditRegentLane(poolId, stockDust);
            uint256 remaining = IERC20Views(stock).allowance(address(this), hook);
            if (remaining != 0) revert AllowanceNotConsumed(hook, remaining);
        }

        // Every unit of this launch's NEW still here — unsold inventory and the reserve the full range
        // did not consume — is retired. No principal path exists.
        uint256 retired = newToken.balanceOf(address(this));
        if (retired != 0) newToken.safeTransfer(StocksBindings.DEAD_ADDRESS, retired);

        record.poolId = poolId;
        record.finalSqrtPriceX96 = sqrtPriceX96;
        record.lpTokenId = locked.fullRangeTokenId;
        record.lpStockUsed = locked.fullRangeStock;
        record.lpNewUsed = locked.fullRangeNew;
        record.retiredNew = retired;
        record.lpStockOnlyTokenId = locked.stockOnlyTokenId;
        record.lpStockOnlyUsed = locked.stockOnlyStock;

        emit StockLaunchGraduated(
            launchId,
            auction,
            poolId,
            sqrtPriceX96,
            locked.fullRangeTokenId,
            locked.fullRangeStock,
            locked.fullRangeNew,
            locked.stockOnlyTokenId,
            locked.stockOnlyStock,
            raised,
            stockDust,
            retired
        );
    }

    /// @dev The two locked positions, planned by the pinned planner and minted straight to the locker
    ///      in one PositionManager call. First the full range from the whole reserve and the
    ///      STOCK it pairs with at the initial price; then every remaining unit of STOCK as a one-sided
    ///      position on the STOCK side of the book (`StocksPreset` geometry). The planner's implicit
    ///      full-range fallback in the second plan has no NEW budget and therefore no liquidity, so the
    ///      second plan yields exactly the one-sided position, or nothing when the remainder is below
    ///      one unit of liquidity. Each position's amounts never exceed the budget it was planned from
    ///      (floor liquidity, then round-up amounts of that liquidity), so the total settled is exactly
    ///      what this function transfers in.
    function _mintLockedPositions(
        PoolKey memory key,
        uint160 sqrtPriceX96,
        bool stockIsCurrency0,
        address stock,
        address newToken,
        uint128 stockBudget,
        uint128 reserve
    ) private returns (LockedLiquidity memory locked) {
        // slither-disable-next-line unused-return
        (Position[] memory fullRange,) = PositionPlanner.resolve(
            new PositionDefinition[](0),
            sqrtPriceX96,
            StocksPreset.POOL_TICK_SPACING,
            _currencyAmounts(stockIsCurrency0, stockBudget, reserve),
            locker
        );
        if (fullRange.length != 1) revert NoFullRangePosition();
        (locked.fullRangeStock, locked.fullRangeNew) = _stockAndNew(stockIsCurrency0, fullRange[0]);

        // slither-disable-next-line unused-return
        (Position[] memory stockOnly,) = PositionPlanner.resolve(
            _stockOnlyDefinition(stockIsCurrency0),
            sqrtPriceX96,
            StocksPreset.POOL_TICK_SPACING,
            _currencyAmounts(stockIsCurrency0, stockBudget - locked.fullRangeStock, 0),
            locker
        );
        if (stockOnly.length > 1) revert UnexpectedStockOnlyPositionCount(stockOnly.length);

        Position[] memory positions = new Position[](1 + stockOnly.length);
        positions[0] = fullRange[0];
        if (stockOnly.length == 1) {
            positions[1] = stockOnly[0];
            (locked.stockOnlyStock,) = _stockAndNew(stockIsCurrency0, stockOnly[0]);
        }

        uint128 stockPlaced = locked.fullRangeStock + locked.stockOnlyStock;
        Plan memory plan = _exactlyFundedPlan(
            positions,
            key,
            stockIsCurrency0 ? stockPlaced : locked.fullRangeNew,
            stockIsCurrency0 ? locked.fullRangeNew : stockPlaced
        );

        address positionManager = StocksBindings.POSITION_MANAGER;
        locked.fullRangeTokenId = IPositionManager(positionManager).nextTokenId();
        if (stockOnly.length == 1) locked.stockOnlyTokenId = locked.fullRangeTokenId + 1;

        stock.safeTransfer(positionManager, stockPlaced);
        newToken.safeTransfer(positionManager, locked.fullRangeNew);
        IPositionManager(positionManager).modifyLiquidities(abi.encode(plan.actions, plan.params), block.timestamp);

        uint256 expected = locked.fullRangeTokenId + positions.length;
        uint256 minted = IPositionManager(positionManager).nextTokenId();
        if (minted != expected) revert UnexpectedPositionMintCount(expected, minted);
    }

    /// @dev The one-sided STOCK position as the pinned planner reads it: offsets from the initial tick
    ///      (`StocksPreset` geometry), the whole budget, the default (locker) recipient.
    function _stockOnlyDefinition(bool stockIsCurrency0)
        private
        pure
        returns (PositionDefinition[] memory definitions)
    {
        definitions = new PositionDefinition[](1);
        definitions[0] = PositionDefinition({
            offsetLower: stockIsCurrency0
                ? StocksPreset.STOCK_ONLY_ABOVE_LOWER_OFFSET
                : StocksPreset.STOCK_ONLY_BELOW_LOWER_OFFSET,
            offsetUpper: stockIsCurrency0
                ? StocksPreset.STOCK_ONLY_ABOVE_UPPER_OFFSET
                : StocksPreset.STOCK_ONLY_BELOW_UPPER_OFFSET,
            weight: PositionPlanner.MPS,
            overridePositionRecipient: address(0)
        });
    }

    function _currencyAmounts(bool stockIsCurrency0, uint128 stockAmount, uint128 newAmount)
        private
        pure
        returns (CurrencyAmounts memory)
    {
        return CurrencyAmounts({
            amount0: stockIsCurrency0 ? stockAmount : newAmount, amount1: stockIsCurrency0 ? newAmount : stockAmount
        });
    }

    function _stockAndNew(bool stockIsCurrency0, Position memory position)
        private
        pure
        returns (uint128 stockAmount, uint128 newAmount)
    {
        (stockAmount, newAmount) = stockIsCurrency0
            ? (SafeCastLib.toUint128(position.amount0), SafeCastLib.toUint128(position.amount1))
            : (SafeCastLib.toUint128(position.amount1), SafeCastLib.toUint128(position.amount0));
    }

    /// @dev The pinned plan with its two `CONTRACT_BALANCE` settlement sentinels replaced by the exact
    ///      two amounts this graduation transfers in, so the shared PositionManager's other inventory
    ///      is never settled as this launch's credit.
    function _exactlyFundedPlan(Position[] memory positions, PoolKey memory key, uint128 amount0, uint128 amount1)
        private
        pure
        returns (Plan memory plan)
    {
        plan = PositionPlanner.toPlan(positions, key, ActionConstants.MSG_SENDER);
        uint256 settleOffset = positions.length;
        plan.params[settleOffset] = abi.encode(key.currency0, uint256(amount0), false);
        plan.params[settleOffset + 1] = abi.encode(key.currency1, uint256(amount1), false);
    }

    // -------------------------------------------------------------------------
    // internals: checks
    // -------------------------------------------------------------------------

    function _requireRuntimeCodeHash(address account, bytes32 expected) private view {
        bytes32 found = account.codehash;
        if (found != expected) revert UnexpectedRuntimeCodeHash(account, expected, found);
    }

    function _requireBytes(uint256 field, uint256 length, uint256 maximum) private pure {
        if (length == 0) revert EmptyMetadataField(field);
        if (length > maximum) revert MetadataFieldTooLong(field, maximum, length);
    }

    function _requireBinding(uint256 field, uint256 expected, uint256 found) private pure {
        if (expected != found) revert AuctionBindingMismatch(field, expected, found);
    }
}
