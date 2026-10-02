// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {IERC20Views} from "autolaunch-stocks/interfaces/IERC20Views.sol";
import {StocksPreset} from "autolaunch-stocks/StocksPreset.sol";
import {IRobinhoodStockAdmission} from "./interfaces/IRobinhoodStockAdmission.sol";
import {IRobinhoodStockRoute} from "./interfaces/IRobinhoodStockRoute.sol";
import {IRobinhoodStocksLaunchpadV2} from "./interfaces/IRobinhoodStocksLaunchpadV2.sol";
import {RobinhoodFeeHookV1} from "./RobinhoodFeeHookV1.sol";
import {RobinhoodLaunchpadBase} from "./RobinhoodLaunchpadBase.sol";

/// @title RobinhoodStocksLaunchpadV2
/// @notice The Base Stocks launchpad's rules on the Robinhood chain, with USDG as the dollar: 49.5% of
///         a NEW's supply is sold for an admitted STOCK, 49.5% is the reserve and 1% vests to the
///         launcher over 30 days from graduation. Every auction opens at the one fixed floor and the
///         required raise is the whole sale allocation at it, rounded up. Graduation creates the
///         launch's own memestock splitter, opens the pool at the final clearing price, locks a
///         full-range position of the whole raise and a NEW-only position of the reserve it left in the
///         fee-only locker, credits the rounding remainder to the pool's protocol lane, starts the
///         vesting and retires the NEW left over. There is no launch fee and no governance minimum
///         raise.
/// @dev No launch has an administrator. All three hook lanes are always on; the splitter, created by
///      this contract at graduation, and the launcher are their only configuration.
contract RobinhoodStocksLaunchpadV2 is RobinhoodLaunchpadBase, IRobinhoodStocksLaunchpadV2 {
    using SafeTransferLib for address;

    struct Admission {
        bool admitted;
        uint8 decimals;
        address route;
    }

    mapping(address stock => Admission) private _admissions;

    error StockNotAdmitted(address stock);
    error StockRefused(address stock);
    error RouteBindingMismatch(address expected, address found);

    constructor(Bindings memory bindings, bytes32 hookSalt) RobinhoodLaunchpadBase(bindings, hookSalt) {}

    // -------------------------------------------------------------------------
    // launcher surface
    // -------------------------------------------------------------------------

    /// @inheritdoc IRobinhoodStocksLaunchpadV2
    function launch(LaunchParams calldata params)
        external
        override
        nonReentrant
        returns (uint256 launchId, address newToken, address auction)
    {
        if (!_admissions[params.stock].admitted) revert StockNotAdmitted(params.stock);

        (launchId, newToken, auction) = _create(params.core, params.stock);

        Launch storage record = _launches[launchId];
        emit StockLaunchCreated(
            launchId,
            msg.sender,
            newToken,
            params.stock,
            auction,
            record.startBlock,
            record.endBlock,
            StocksPreset.AUCTION_INVENTORY,
            StocksPreset.MIGRATION_RESERVE,
            StocksPreset.CREATOR_VESTING
        );
    }

    // -------------------------------------------------------------------------
    // Safe surface
    // -------------------------------------------------------------------------

    /// @inheritdoc IRobinhoodStocksLaunchpadV2
    function admitStock(address stock, address route) external override onlySafe {
        if (stock == address(0) || route == address(0)) revert ZeroAddress();
        if (stock == usdg) revert StockRefused(stock);
        if (stock.code.length == 0) revert NoCode(stock);
        if (route.code.length == 0) revert NoCode(route);
        address routeStock = IRobinhoodStockRoute(route).stock();
        if (routeStock != stock) revert RouteBindingMismatch(stock, routeStock);
        address routeUsdg = IRobinhoodStockRoute(route).usdg();
        if (routeUsdg != usdg) revert RouteBindingMismatch(usdg, routeUsdg);

        uint8 decimals = IERC20Views(stock).decimals();
        _admissions[stock] = Admission({admitted: true, decimals: decimals, route: route});
        emit StockAdmitted(stock, decimals, route);
    }

    /// @inheritdoc IRobinhoodStocksLaunchpadV2
    /// @dev Stops new launches only. The recorded route stays so existing pools can still settle.
    function revokeStock(address stock) external override onlySafe {
        if (!_admissions[stock].admitted) revert StockNotAdmitted(stock);
        _admissions[stock].admitted = false;
        emit StockRevoked(stock);
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

    // -------------------------------------------------------------------------
    // launch internals
    // -------------------------------------------------------------------------

    function _terms() internal pure override returns (Terms memory) {
        return Terms({
            totalSupply: StocksPreset.INITIAL_SUPPLY,
            auctionInventory: StocksPreset.AUCTION_INVENTORY,
            migrationReserve: StocksPreset.MIGRATION_RESERVE,
            creatorVesting: StocksPreset.CREATOR_VESTING
        });
    }

    /// @dev The rounding remainder below one unit of liquidity is credited to the pool's protocol
    ///      lane. No principal path exists.
    function _finishGraduation(uint256 launchId, Launch storage record, uint256 raised, uint256 stockDust)
        internal
        override
    {
        address stock = record.currency;
        bytes32 poolId = record.poolId;
        if (stockDust != 0) {
            stock.safeApprove(hook, stockDust);
            RobinhoodFeeHookV1(hook).creditProtocolLane(poolId, stockDust);
            uint256 remaining = IERC20Views(stock).allowance(address(this), hook);
            if (remaining != 0) revert AllowanceNotConsumed(hook, remaining);
        }

        emit StockLaunchGraduated(
            launchId,
            record.auction,
            poolId,
            record.finalSqrtPriceX96,
            record.lpTokenId,
            record.lpCurrencyUsed,
            record.lpNewUsed,
            record.newOnlyTokenId,
            record.newOnlyUsed,
            raised,
            stockDust,
            record.retiredNew
        );
    }
}
