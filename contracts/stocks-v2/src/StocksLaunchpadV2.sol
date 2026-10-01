// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {
    AuctionParameters,
    IContinuousClearingAuction
} from "continuous-clearing-auction/interfaces/IContinuousClearingAuction.sol";
import {
    IContinuousClearingAuctionFactory
} from "continuous-clearing-auction/interfaces/IContinuousClearingAuctionFactory.sol";
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
import {IStocksLaunchpadV2} from "./interfaces/IStocksLaunchpadV2.sol";
import {MemestockLPLocker} from "./MemestockLPLocker.sol";
import {MemestockSplitterV1} from "./MemestockSplitterV1.sol";
import {StocksBindings} from "./StocksBindings.sol";
import {StocksFeeHookV1} from "./StocksFeeHookV1.sol";
import {StocksPreset} from "./StocksPreset.sol";

/// @title StocksLaunchpadV2
/// @notice Admission, creation, custody and migration of Autolaunch Stocks.
/// @dev One launch mints exactly `S0` of a new UERC20 (NEW) to this contract, sells 49.5% as the sale
///      allocation through a pinned Continuous Clearing Auction denominated in one admitted STOCK,
///      custodies 49.5% as the reserve and 1% as the launcher's vesting, and after the auction either
///      graduates or retires the inventory. Every economic term comes from `StocksPreset`; a launcher
///      supplies metadata and the STOCK, nothing else, and keeps no authority over the launch
///      afterwards. Every auction opens at the one fixed floor, and the required raise is the whole
///      sale allocation at that floor, rounded up, so an auction nobody bid in never graduates. The
///      auction opens `START_LEAD_BLOCKS` after creation.
///
///      An auction that reaches the required raise has sold its whole sale allocation, but for rounding:
///      the pinned CCA carries unsold supply forward and never lowers its clearing price, so the bids
///      themselves are paid the allocation by the auction. The official pool opens at the final
///      clearing price. Because no unit sold above that price, the raise never buys more than the sale
///      allocation there, so one full-range position pairs the whole raise with at most the reserve,
///      and the reserve it did not pair is locked as a NEW-only position above the opening price.
///      Graduation creates the launch's own memestock splitter, the fixed destination of the hook's
///      staker lane, registers the launcher as the fixed destination of the hook's creator lane, mints
///      both positions to the permanent fee-only locker, which deposits their LP fees into that same
///      splitter, and starts the launcher's vesting. Every other unit of the launch's NEW still held
///      afterwards (rounding crumbs and anything sent here) is retired to the dead address. No
///      principal path exists.
///
///      The launcher's 1% vests linearly per block over `CREATOR_VESTING_BLOCKS` from the graduation
///      block; anyone may release what has vested, and it only ever goes to the recorded launcher.
///
///      The CCA creation, `_graduate`, `_mintLockedPositions` and `_exactlyFundedPlan` mirror the
///      frozen Agent `RegentLBPStrategy` technique: the auction is read back field by field before any
///      value moves, the price is converted through the pinned `TokenPricing`, the position is planned
///      by the pinned `PositionPlanner`, and the two settlement amounts are pinned to what this
///      graduation actually funds so nothing already sitting at the shared PositionManager is touched.
///
///      A launch costs nothing beyond gas: no REGENT is pulled and the launchpad never holds REGENT.
contract StocksLaunchpadV2 is ReentrancyGuardTransient, IStocksLaunchpadV2 {
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

    /// @dev What one graduation locked in the locker. `newOnlyTokenId` is zero when the reserve the
    ///      full range left was below one unit of liquidity and no NEW-only position was minted.
    struct LockedLiquidity {
        uint256 tokenId;
        uint128 stockUsed;
        uint128 newUsed;
        uint256 newOnlyTokenId;
        uint128 newOnlyUsed;
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
    error LaunchNotGraduated(Lifecycle found);
    error MigrationNotYetAllowed(uint64 migrationBlock, uint256 currentBlock);
    error CurrencyRaisedMismatch(uint256 expected, uint256 found);
    error NoFullRangePosition();
    error UnexpectedNewOnlyPositionCount(uint256 found);
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

    /// @inheritdoc IStocksLaunchpadV2
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

        address controller =
            address(IContinuousClearingAuctionFactory(StocksBindings.CCA_FACTORY).protocolFeeController());
        if (controller != address(0)) revert ProtocolFeeControllerNotZero(controller);

        launchId = nextLaunchId;
        nextLaunchId = launchId + 1;

        newToken = _createNew(params, launchId);

        uint64 startBlock = SafeCastLib.toUint64(block.number) + StocksPreset.START_LEAD_BLOCKS;
        uint64 endBlock = startBlock + StocksPreset.AUCTION_DURATION_BLOCKS;
        auction = _createAuction(newToken, params, launchId, startBlock, endBlock);

        Launch storage record = _launches[launchId];
        record.launcher = msg.sender;
        record.newToken = newToken;
        record.stock = params.stock;
        record.auction = auction;
        record.startBlock = startBlock;
        record.endBlock = endBlock;
        record.claimBlock = endBlock + StocksPreset.CLAIM_DELAY_BLOCKS;
        record.migrationBlock = endBlock + StocksPreset.MIGRATION_DELAY_BLOCKS;
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
            StocksPreset.AUCTION_INVENTORY,
            StocksPreset.MIGRATION_RESERVE,
            StocksPreset.CREATOR_VESTING
        );
        // Custody: exactly the inventory leaves for the auction and exactly the reserve and the
        // vesting stay.
        uint256 auctionHeld = newToken.balanceOf(auction);
        newToken.safeTransfer(auction, StocksPreset.AUCTION_INVENTORY);
        uint256 delivered = newToken.balanceOf(auction) - auctionHeld;
        if (delivered != StocksPreset.AUCTION_INVENTORY) {
            revert InexactTransfer(StocksPreset.AUCTION_INVENTORY, delivered);
        }
        IContinuousClearingAuction(auction).onTokensReceived();

        uint256 held = newToken.balanceOf(address(this));
        uint256 kept = uint256(StocksPreset.MIGRATION_RESERVE) + StocksPreset.CREATOR_VESTING;
        if (held != kept) revert ReserveMismatch(kept, held);
    }

    /// @inheritdoc IStocksLaunchpadV2
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

    /// @inheritdoc IStocksLaunchpadV2
    /// @dev Nothing vested yet is a zero-amount no-op rather than a revert. The paid amount is
    ///      recorded before the transfer.
    function releaseCreatorVesting(uint256 launchId) external override nonReentrant returns (uint256 amount) {
        Launch storage record = _launches[launchId];
        if (record.lifecycle != Lifecycle.Graduated) revert LaunchNotGraduated(record.lifecycle);

        amount = _creatorVested(record) - record.creatorReleased;
        if (amount == 0) return 0;

        record.creatorReleased += SafeCastLib.toUint128(amount);
        address launcher = record.launcher;
        emit CreatorVestingReleased(launchId, launcher, amount);
        record.newToken.safeTransfer(launcher, amount);
    }

    // -------------------------------------------------------------------------
    // governance
    // -------------------------------------------------------------------------

    /// @inheritdoc IStocksLaunchpadV2
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

    /// @inheritdoc IStocksLaunchpadV2
    /// @dev Stops new launches only. The recorded route stays so existing pools can still settle.
    function revokeStock(address stock) external override onlyGovernance {
        if (!_admissions[stock].admitted) revert StockNotAdmitted(stock);
        _admissions[stock].admitted = false;
        emit StockRevoked(stock);
    }

    /// @inheritdoc IStocksLaunchpadV2
    function pauseLaunches() external override onlyGovernance {
        if (launchesPaused) revert LaunchesAlreadyPaused();
        launchesPaused = true;
        emit LaunchesPaused();
    }

    /// @inheritdoc IStocksLaunchpadV2
    function unpauseLaunches() external override onlyGovernance {
        if (!launchesPaused) revert LaunchesNotPaused();
        launchesPaused = false;
        emit LaunchesUnpaused();
    }

    // -------------------------------------------------------------------------
    // reads
    // -------------------------------------------------------------------------

    /// @inheritdoc IStocksLaunchpadV2
    function launches(uint256 launchId) external view override returns (Launch memory) {
        return _launches[launchId];
    }

    /// @inheritdoc IStocksLaunchpadV2
    function stockAdmission(address stock)
        external
        view
        override
        returns (bool admitted, uint8 decimals, address route)
    {
        Admission storage admission = _admissions[stock];
        return (admission.admitted, admission.decimals, admission.route);
    }

    /// @inheritdoc IStocksLaunchpadV2
    function creatorReleasable(uint256 launchId) external view override returns (uint256) {
        Launch storage record = _launches[launchId];
        if (record.lifecycle != Lifecycle.Graduated) return 0;
        return _creatorVested(record) - record.creatorReleased;
    }

    /// @dev The launcher's vesting earned by now: linear per block from the graduation block, whole
    ///      after `CREATOR_VESTING_BLOCKS`. Only meaningful for a graduated launch.
    function _creatorVested(Launch storage record) private view returns (uint256) {
        uint256 elapsed = block.number - record.vestingStartBlock;
        if (elapsed >= StocksPreset.CREATOR_VESTING_BLOCKS) return StocksPreset.CREATOR_VESTING;
        return uint256(StocksPreset.CREATOR_VESTING) * elapsed / StocksPreset.CREATOR_VESTING_BLOCKS;
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
        uint64 endBlock
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
                            tickSpacing: StocksPreset.BID_TICK_SPACING_Q96,
                            validationHook: address(0),
                            floorPrice: StocksPreset.FLOOR_PRICE_Q96,
                            requiredCurrencyRaised: StocksPreset.REQUIRED_STOCK_RAISED,
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
        _requireBinding(9, StocksPreset.FLOOR_PRICE_Q96, cca.floorPrice());
        _requireBinding(10, StocksPreset.BID_TICK_SPACING_Q96, cca.tickSpacing());
    }

    // -------------------------------------------------------------------------
    // internals: terminal states
    // -------------------------------------------------------------------------

    /// @dev Economic failure: the swept inventory, the reserve and the vesting are retired; bidder STOCK is never
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

        // The launch's own splitter: the fixed destination of the hook's staker lane and of the locked
        // position's LP fees. It exists only for a launch that graduated.
        address splitter = LibClone.clone(splitterImplementation);
        MemestockSplitterV1(splitter).initialize(newToken, stock);
        record.splitter = splitter;
        emit MemestockSplitterCreated(launchId, newToken, stock, splitter);

        PoolKey memory key = _poolKeyOf(newToken, stock);
        bytes32 poolId = StocksFeeHookV1(hook).registerPool(key, stock, newToken, splitter, record.launcher);

        uint256 stockBefore = stock.balanceOf(address(this));
        IContinuousClearingAuction(auction).sweepCurrency();
        uint256 raised = stock.balanceOf(address(this)) - stockBefore;
        if (raised != lbp.currencyRaised) revert CurrencyRaisedMismatch(lbp.currencyRaised, raised);

        IContinuousClearingAuction(auction).sweepUnsoldTokens();

        // The pool opens at the auction's final clearing price (STOCK per NEW, Q96).
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
        MemestockLPLocker(locker).register(locked.tokenId, key, splitter);
        if (locked.newOnlyTokenId != 0) MemestockLPLocker(locker).register(locked.newOnlyTokenId, key, splitter);

        // Only this launch's own STOCK delta moves on. Anything unrelated already held here stays.
        // After the full range this is the rounding remainder below one unit of liquidity.
        uint256 stockDust = stock.balanceOf(address(this)) - stockBefore;
        if (stockDust != 0) {
            stock.safeApprove(hook, stockDust);
            StocksFeeHookV1(hook).creditRegentLane(poolId, stockDust);
            uint256 remaining = IERC20Views(stock).allowance(address(this), hook);
            if (remaining != 0) revert AllowanceNotConsumed(hook, remaining);
        }

        // Every unit of this launch's NEW still here but the vesting — the unsold rounding, the
        // positions' rounding and anything sent here — is retired. No principal path exists.
        uint256 retired = newToken.balanceOf(address(this)) - StocksPreset.CREATOR_VESTING;
        if (retired != 0) newToken.safeTransfer(StocksBindings.DEAD_ADDRESS, retired);

        record.poolId = poolId;
        record.finalSqrtPriceX96 = sqrtPriceX96;
        record.lpTokenId = locked.tokenId;
        record.lpStockUsed = locked.stockUsed;
        record.lpNewUsed = locked.newUsed;
        record.newOnlyTokenId = locked.newOnlyTokenId;
        record.newOnlyUsed = locked.newOnlyUsed;
        record.vestingStartBlock = SafeCastLib.toUint64(block.number);
        record.retiredNew = retired;

        emit StockLaunchGraduated(
            launchId,
            auction,
            poolId,
            sqrtPriceX96,
            locked.tokenId,
            locked.stockUsed,
            locked.newUsed,
            locked.newOnlyTokenId,
            locked.newOnlyUsed,
            raised,
            stockDust,
            retired
        );
    }

    /// @dev The two locked positions, planned by the pinned planner and minted straight to the locker
    ///      in one call: the full range from the whole raise and the reserve, then a NEW-only position
    ///      above the opening price from the reserve the full range did not pair. Each position's
    ///      amounts never exceed the budget it was planned from (floor liquidity, then round-up amounts
    ///      of that liquidity), so the total settled is exactly what this function transfers in.
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
        (locked.stockUsed, locked.newUsed) = _stockAndNew(stockIsCurrency0, fullRange[0]);

        // slither-disable-next-line unused-return
        (Position[] memory newOnly,) = PositionPlanner.resolve(
            _newOnlyDefinition(stockIsCurrency0),
            sqrtPriceX96,
            StocksPreset.POOL_TICK_SPACING,
            _currencyAmounts(stockIsCurrency0, 0, reserve - locked.newUsed),
            locker
        );
        if (newOnly.length > 1) revert UnexpectedNewOnlyPositionCount(newOnly.length);

        Position[] memory positions = new Position[](1 + newOnly.length);
        positions[0] = fullRange[0];
        if (newOnly.length == 1) {
            positions[1] = newOnly[0];
            (, locked.newOnlyUsed) = _stockAndNew(stockIsCurrency0, newOnly[0]);
        }

        uint128 newPlaced = locked.newUsed + locked.newOnlyUsed;
        Plan memory plan = _exactlyFundedPlan(
            positions,
            key,
            stockIsCurrency0 ? locked.stockUsed : newPlaced,
            stockIsCurrency0 ? newPlaced : locked.stockUsed
        );

        address positionManager = StocksBindings.POSITION_MANAGER;
        locked.tokenId = IPositionManager(positionManager).nextTokenId();
        if (newOnly.length == 1) locked.newOnlyTokenId = locked.tokenId + 1;

        stock.safeTransfer(positionManager, locked.stockUsed);
        newToken.safeTransfer(positionManager, newPlaced);
        IPositionManager(positionManager).modifyLiquidities(abi.encode(plan.actions, plan.params), block.timestamp);

        uint256 expected = locked.tokenId + positions.length;
        uint256 minted = IPositionManager(positionManager).nextTokenId();
        if (minted != expected) revert UnexpectedPositionMintCount(expected, minted);
    }

    /// @dev The one-sided NEW position as the pinned planner reads it: offsets from the initial tick
    ///      (`StocksPreset` geometry), the whole budget, the default (locker) recipient. NEW is currency1
    ///      when STOCK is currency0, so its side of the book is below the pool price.
    function _newOnlyDefinition(bool stockIsCurrency0) private pure returns (PositionDefinition[] memory definitions) {
        definitions = new PositionDefinition[](1);
        definitions[0] = PositionDefinition({
            offsetLower: stockIsCurrency0
                ? StocksPreset.NEW_ONLY_BELOW_LOWER_OFFSET
                : StocksPreset.NEW_ONLY_ABOVE_LOWER_OFFSET,
            offsetUpper: stockIsCurrency0
                ? StocksPreset.NEW_ONLY_BELOW_UPPER_OFFSET
                : StocksPreset.NEW_ONLY_ABOVE_UPPER_OFFSET,
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
