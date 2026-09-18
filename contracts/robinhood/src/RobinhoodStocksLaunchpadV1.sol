// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {PositionPlanner} from "liquidity-launcher/src/libraries/PositionPlanner.sol";
import {Position, PositionDefinition} from "liquidity-launcher/src/types/PositionPlannerTypes.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {IERC20Minimal} from "autolaunch-stocks/interfaces/IERC20Minimal.sol";
import {StocksPreset} from "autolaunch-stocks/StocksPreset.sol";
import {IRobinhoodStockAdmission} from "./interfaces/IRobinhoodStockAdmission.sol";
import {IRobinhoodStockRoute} from "./interfaces/IRobinhoodStockRoute.sol";
import {IRobinhoodStocksLaunchpadV1} from "./interfaces/IRobinhoodStocksLaunchpadV1.sol";
import {RobinhoodFeeHookV1} from "./RobinhoodFeeHookV1.sol";
import {RobinhoodLaunchpadBase} from "./RobinhoodLaunchpadBase.sol";
import {RobinhoodPreset} from "./RobinhoodPreset.sol";

/// @title RobinhoodStocksLaunchpadV1
/// @notice The Base Stocks launchpad's rules on the Robinhood chain, with USDG as the dollar: a NEW is
///         sold for an admitted STOCK; the required raise is the Safe's USDG minimum converted into
///         STOCK by the admitted route's quote at creation; graduation creates the launch's own
///         memestock splitter, locks the full range and a one-sided STOCK position in the fee-only
///         locker and credits the rounding remainder to the pool's protocol lane; the launch fee is
///         USDG, deposited into the protocol revenue inbox.
/// @dev No launch has an administrator. Both hook lanes are always on and the splitter, created by
///      this contract at graduation, is their only configuration.
contract RobinhoodStocksLaunchpadV1 is RobinhoodLaunchpadBase, IRobinhoodStocksLaunchpadV1 {
    using SafeTransferLib for address;

    struct Admission {
        bool admitted;
        uint8 decimals;
        address route;
    }

    uint256 public override minimumRaiseUsdg = RobinhoodPreset.MINIMUM_RAISE_USDG_STOCKS;

    mapping(address stock => Admission) private _admissions;
    mapping(uint256 launchId => StockRecord) private _stockRecords;

    error StockNotAdmitted(address stock);
    error StockRefused(address stock);
    error RouteBindingMismatch(address expected, address found);
    error ZeroMinimumRaise();
    error UnexpectedStockOnlyPositionCount(uint256 found);

    constructor(Bindings memory bindings, bytes32 hookSalt) RobinhoodLaunchpadBase(bindings, hookSalt) {}

    // -------------------------------------------------------------------------
    // launcher surface
    // -------------------------------------------------------------------------

    /// @inheritdoc IRobinhoodStocksLaunchpadV1
    // slither-disable-next-line reentrancy-no-eth
    function launch(LaunchParams calldata params)
        external
        override
        nonReentrant
        returns (uint256 launchId, address newToken, address auction)
    {
        Admission storage admission = _admissions[params.stock];
        if (!admission.admitted) revert StockNotAdmitted(params.stock);

        // The required raise is the Safe's USDG minimum converted into STOCK by the admitted route's
        // quote at this block: the launcher never chooses it. The base proves it is reachable.
        uint256 required = IRobinhoodStockRoute(admission.route).quoteExactIn(usdg, params.stock, minimumRaiseUsdg);
        uint128 requiredStockRaised = SafeCastLib.toUint128(required);

        (launchId, newToken, auction) = _create(params.core, params.stock, requiredStockRaised);

        emit StockLaunchCreated(
            launchId,
            msg.sender,
            newToken,
            params.stock,
            auction,
            params.core.startBlock,
            params.core.startBlock + StocksPreset.AUCTION_DURATION_BLOCKS,
            params.core.floorPriceQ96,
            requiredStockRaised,
            StocksPreset.AUCTION_INVENTORY,
            StocksPreset.MIGRATION_RESERVE
        );
    }

    // -------------------------------------------------------------------------
    // Safe surface
    // -------------------------------------------------------------------------

    /// @inheritdoc IRobinhoodStocksLaunchpadV1
    function admitStock(address stock, address route) external override onlySafe {
        if (stock == address(0) || route == address(0)) revert ZeroAddress();
        if (stock == usdg) revert StockRefused(stock);
        if (stock.code.length == 0) revert NoCode(stock);
        if (route.code.length == 0) revert NoCode(route);
        address routeStock = IRobinhoodStockRoute(route).stock();
        if (routeStock != stock) revert RouteBindingMismatch(stock, routeStock);
        address routeUsdg = IRobinhoodStockRoute(route).usdg();
        if (routeUsdg != usdg) revert RouteBindingMismatch(usdg, routeUsdg);

        uint8 decimals = IERC20Minimal(stock).decimals();
        _admissions[stock] = Admission({admitted: true, decimals: decimals, route: route});
        emit StockAdmitted(stock, decimals, route);
    }

    /// @inheritdoc IRobinhoodStocksLaunchpadV1
    /// @dev Stops new launches only. The recorded route stays so existing pools can still settle.
    function revokeStock(address stock) external override onlySafe {
        if (!_admissions[stock].admitted) revert StockNotAdmitted(stock);
        _admissions[stock].admitted = false;
        emit StockRevoked(stock);
    }

    /// @inheritdoc IRobinhoodStocksLaunchpadV1
    /// @dev Applies to launches created afterwards only; a recorded auction keeps its STOCK raise.
    function setMinimumRaiseUsdg(uint256 newMinimum) external override onlySafe {
        if (newMinimum == 0) revert ZeroMinimumRaise();
        uint256 previousMinimum = minimumRaiseUsdg;
        minimumRaiseUsdg = newMinimum;
        emit MinimumRaiseUsdgUpdated(previousMinimum, newMinimum);
    }

    // -------------------------------------------------------------------------
    // reads
    // -------------------------------------------------------------------------

    /// @inheritdoc IRobinhoodStockAdmission
    function stockAdmission(address stock)
        external
        view
        override
        returns (bool admitted, uint8 decimals, address route)
    {
        Admission storage admission = _admissions[stock];
        return (admission.admitted, admission.decimals, admission.route);
    }

    /// @inheritdoc IRobinhoodStocksLaunchpadV1
    function stockRecords(uint256 launchId) external view override returns (StockRecord memory) {
        return _stockRecords[launchId];
    }

    // -------------------------------------------------------------------------
    // launch internals
    // -------------------------------------------------------------------------

    function _terms() internal pure override returns (Terms memory) {
        return Terms({
            totalSupply: StocksPreset.INITIAL_SUPPLY,
            auctionInventory: StocksPreset.AUCTION_INVENTORY,
            migrationReserve: StocksPreset.MIGRATION_RESERVE
        });
    }

    /// @dev First the full range from the whole reserve and the STOCK it pairs with at the initial
    ///      price; then every remaining unit of STOCK as a one-sided position on the STOCK side of the
    ///      book (`StocksPreset` geometry). The planner's implicit full-range fallback in the second
    ///      plan has no NEW budget and therefore no liquidity, so the second plan yields exactly the
    ///      one-sided position, or nothing when the remainder is below one unit of liquidity.
    function _lockedPositions(
        PoolKey memory,
        uint160 sqrtPriceX96,
        bool stockIsCurrency0,
        uint128 stockBudget,
        uint128 reserve
    ) internal view override returns (Position[] memory positions) {
        Position memory fullRange = _fullRangePosition(sqrtPriceX96, stockIsCurrency0, stockBudget, reserve);
        (uint128 fullRangeStock,) = _currencyAndNew(stockIsCurrency0, fullRange);

        Position[] memory stockOnly = _definedPosition(
            sqrtPriceX96,
            PositionDefinition({
                offsetLower: stockIsCurrency0
                    ? StocksPreset.STOCK_ONLY_ABOVE_LOWER_OFFSET
                    : StocksPreset.STOCK_ONLY_BELOW_LOWER_OFFSET,
                offsetUpper: stockIsCurrency0
                    ? StocksPreset.STOCK_ONLY_ABOVE_UPPER_OFFSET
                    : StocksPreset.STOCK_ONLY_BELOW_UPPER_OFFSET,
                weight: PositionPlanner.MPS,
                overridePositionRecipient: address(0)
            }),
            _currencyAmounts(stockIsCurrency0, stockBudget - fullRangeStock, 0)
        );
        if (stockOnly.length > 1) revert UnexpectedStockOnlyPositionCount(stockOnly.length);

        positions = new Position[](1 + stockOnly.length);
        positions[0] = fullRange;
        if (stockOnly.length == 1) positions[1] = stockOnly[0];
    }

    /// @dev The rounding remainder below one unit of liquidity is credited to the pool's protocol
    ///      lane; every unit of this launch's NEW still here is retired. No principal path exists.
    function _finishGraduation(
        uint256 launchId,
        Launch storage record,
        Position[] memory positions,
        uint256 raised,
        uint256 stockDust
    ) internal override {
        address stock = record.currency;
        bytes32 poolId = record.poolId;
        if (stockDust != 0) {
            stock.safeApprove(hook, stockDust);
            RobinhoodFeeHookV1(hook).creditProtocolLane(poolId, stockDust);
            uint256 remaining = IERC20Minimal(stock).allowance(address(this), hook);
            if (remaining != 0) revert AllowanceNotConsumed(hook, remaining);
        }

        address newToken = record.newToken;
        uint256 retired = newToken.balanceOf(address(this));
        if (retired != 0) newToken.safeTransfer(DEAD_ADDRESS, retired);
        record.retiredNew = retired;

        StockRecord storage stockRecord = _stockRecords[launchId];
        bool stockIsCurrency0 = stock < newToken;
        if (positions.length == 2) {
            stockRecord.stockOnlyTokenId = record.lpTokenId + 1;
            (stockRecord.stockOnlyStock,) = _currencyAndNew(stockIsCurrency0, positions[1]);
        }
        (uint128 fullRangeStock, uint128 fullRangeNew) = _currencyAndNew(stockIsCurrency0, positions[0]);

        emit StockLaunchGraduated(
            launchId,
            record.auction,
            poolId,
            record.finalSqrtPriceX96,
            record.lpTokenId,
            fullRangeStock,
            fullRangeNew,
            stockRecord.stockOnlyTokenId,
            stockRecord.stockOnlyStock,
            raised,
            stockDust,
            retired
        );
    }
}
