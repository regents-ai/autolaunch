// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {
    AuctionParameters,
    IContinuousClearingAuction
} from "src/cca/interfaces/IContinuousClearingAuction.sol";
import {
    IContinuousClearingAuctionFactory
} from "src/cca/interfaces/IContinuousClearingAuctionFactory.sol";
import {IDistributionContract} from "src/cca/interfaces/external/IDistributionContract.sol";
import {SafeTransferLib} from "src/libraries/SafeTransferLib.sol";
import {IERC20SupplyMinimal} from "src/revenue/interfaces/IERC20SupplyMinimal.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {ActionConstants} from "@uniswap/v4-periphery/src/libraries/ActionConstants.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

contract RegentLBPStrategy is IDistributionContract {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using SafeTransferLib for address;

    uint16 internal constant BPS_DENOMINATOR = 10_000;

    address public immutable token;
    address public immutable usdc;
    address public immutable auctionInitializerFactory;
    address public immutable officialPoolHook;
    address public immutable agentSafe;
    address public immutable vestingWallet;
    address public immutable operator;
    address public immutable positionRecipient;
    address public immutable positionManager;
    address public immutable poolManager;
    uint24 public immutable officialPoolFee;
    int24 public immutable officialPoolTickSpacing;

    uint64 public immutable migrationBlock;
    uint64 public immutable sweepBlock;
    uint16 public immutable lpCurrencyBps;
    uint24 public immutable tokenSplitToAuctionMps;
    uint128 public immutable totalStrategySupply;
    uint128 public immutable auctionTokenAmount;
    uint128 public immutable reserveTokenAmount;
    uint128 public immutable maxCurrencyAmountForLP;

    AuctionParameters public auctionParameters;
    address public auctionAddress;
    bytes32 public migratedPoolId;
    uint256 public migratedPositionId;
    uint128 public migratedLiquidity;
    uint128 public migratedCurrencyForLP;
    uint128 public migratedTokenForLP;
    bool public migrated;
    uint256 private _reentrancyGuard = 1;
    int24 internal constant POOL_INIT_FAILED = type(int24).max;

    struct StrategyConfig {
        address token;
        address usdc;
        address auctionInitializerFactory;
        AuctionParameters auctionParameters;
        address officialPoolHook;
        address agentSafe;
        address vestingWallet;
        address operator;
        address positionRecipient;
        address positionManager;
        address poolManager;
        uint24 officialPoolFee;
        int24 officialPoolTickSpacing;
        uint64 migrationBlock;
        uint64 sweepBlock;
        uint16 lpCurrencyBps;
        uint24 tokenSplitToAuctionMps;
        uint128 totalStrategySupply;
        uint128 auctionTokenAmount;
        uint128 reserveTokenAmount;
        uint128 maxCurrencyAmountForLP;
    }

    event AuctionCreated(address indexed auction, uint128 auctionTokenAmount);
    event Migrated(
        bytes32 indexed poolId,
        uint256 indexed positionId,
        address indexed positionRecipient,
        uint128 currencyUsedForLP,
        uint128 tokenUsedForLP,
        uint128 liquidity
    );
    event TokensSweptToVesting(address indexed vestingWallet, uint256 amount);
    event CurrencySweptToTreasury(address indexed treasury, uint256 amount);
    event FailedAuctionRecovered(
        address indexed auction, address indexed vestingWallet, uint256 amount
    );
    event NativeRescued(address indexed recipient, uint256 amount);
    event UnsupportedTokenRescued(address indexed token, uint256 amount, address indexed recipient);

    modifier nonReentrant() {
        require(_reentrancyGuard == 1, "REENTRANT");
        _reentrancyGuard = 2;
        _;
        _reentrancyGuard = 1;
    }

    modifier onlyTreasury() {
        require(msg.sender == agentSafe, "ONLY_TREASURY");
        _;
    }

    constructor(StrategyConfig memory cfg) {
        require(cfg.token != address(0), "TOKEN_ZERO");
        require(cfg.usdc != address(0), "USDC_ZERO");
        require(cfg.auctionInitializerFactory != address(0), "AUCTION_FACTORY_ZERO");
        require(cfg.officialPoolHook != address(0), "HOOK_ZERO");
        require(cfg.agentSafe != address(0), "AGENT_SAFE_ZERO");
        require(cfg.vestingWallet != address(0), "VESTING_ZERO");
        require(cfg.operator != address(0), "OPERATOR_ZERO");
        require(cfg.positionRecipient != address(0), "POSITION_RECIPIENT_ZERO");
        require(cfg.positionManager != address(0), "POSITION_MANAGER_ZERO");
        require(cfg.poolManager != address(0), "POOL_MANAGER_ZERO");
        require(cfg.officialPoolTickSpacing > 0, "POOL_TICK_SPACING_INVALID");
        require(cfg.officialPoolFee <= 1_000_000, "POOL_FEE_INVALID");
        require(cfg.auctionParameters.currency == cfg.usdc, "AUCTION_CURRENCY_MISMATCH");
        require(
            cfg.auctionParameters.startBlock < cfg.auctionParameters.endBlock, "AUCTION_BLOCKS_INVALID"
        );
        require(cfg.auctionParameters.claimBlock >= cfg.auctionParameters.endBlock, "CLAIM_BEFORE_END");
        require(cfg.migrationBlock > cfg.auctionParameters.endBlock, "MIGRATION_BEFORE_END");
        require(cfg.sweepBlock > cfg.migrationBlock, "SWEEP_BEFORE_MIGRATION");
        require(cfg.lpCurrencyBps <= BPS_DENOMINATOR, "LP_BPS_INVALID");
        require(cfg.tokenSplitToAuctionMps != 0, "TOKEN_SPLIT_ZERO");
        require(cfg.tokenSplitToAuctionMps <= 10_000_000, "TOKEN_SPLIT_INVALID");
        require(cfg.totalStrategySupply != 0, "SUPPLY_ZERO");
        require(
            uint256(cfg.auctionTokenAmount) + uint256(cfg.reserveTokenAmount)
                == cfg.totalStrategySupply,
            "SUPPLY_SPLIT_INVALID"
        );
        require(cfg.auctionTokenAmount != 0, "AUCTION_SUPPLY_ZERO");
        require(cfg.reserveTokenAmount != 0, "RESERVE_SUPPLY_ZERO");
        require(cfg.maxCurrencyAmountForLP != 0, "MAX_CCY_FOR_LP_ZERO");

        token = cfg.token;
        usdc = cfg.usdc;
        auctionInitializerFactory = cfg.auctionInitializerFactory;
        officialPoolHook = cfg.officialPoolHook;
        agentSafe = cfg.agentSafe;
        vestingWallet = cfg.vestingWallet;
        operator = cfg.operator;
        positionRecipient = cfg.positionRecipient;
        positionManager = cfg.positionManager;
        poolManager = cfg.poolManager;
        officialPoolFee = cfg.officialPoolFee;
        officialPoolTickSpacing = cfg.officialPoolTickSpacing;
        migrationBlock = cfg.migrationBlock;
        sweepBlock = cfg.sweepBlock;
        lpCurrencyBps = cfg.lpCurrencyBps;
        tokenSplitToAuctionMps = cfg.tokenSplitToAuctionMps;
        totalStrategySupply = cfg.totalStrategySupply;
        auctionTokenAmount = cfg.auctionTokenAmount;
        reserveTokenAmount = cfg.reserveTokenAmount;
        maxCurrencyAmountForLP = cfg.maxCurrencyAmountForLP;
        auctionParameters = cfg.auctionParameters;
    }

    function onTokensReceived() external nonReentrant {
        require(auctionAddress == address(0), "AUCTION_ALREADY_CREATED");
        require(
            IERC20SupplyMinimal(token).balanceOf(address(this)) >= totalStrategySupply,
            "STRATEGY_BALANCE_LOW"
        );

        AuctionParameters memory params = auctionParameters;
        params.tokensRecipient = address(this);
        params.fundsRecipient = address(this);
        bytes memory initData = abi.encode(params);
        address predictedAuction = IContinuousClearingAuctionFactory(auctionInitializerFactory)
            .getAuctionAddress(token, auctionTokenAmount, initData, bytes32(0), address(this));
        require(predictedAuction != address(0), "AUCTION_PREDICT_ZERO");

        auctionAddress = predictedAuction;

        IDistributionContract auction = IContinuousClearingAuctionFactory(auctionInitializerFactory)
            .initializeDistribution(token, auctionTokenAmount, initData, bytes32(0));
        require(address(auction) == predictedAuction, "AUCTION_ADDRESS_MISMATCH");

        token.safeTransfer(predictedAuction, auctionTokenAmount);
        auction.onTokensReceived();

        emit AuctionCreated(predictedAuction, auctionTokenAmount);
    }

    function migrate() external nonReentrant {
        require(msg.sender == operator, "NOT_OPERATOR");
        require(block.number >= migrationBlock, "MIGRATION_NOT_ALLOWED");
        require(!migrated, "ALREADY_MIGRATED");
        require(auctionAddress != address(0), "AUCTION_NOT_CREATED");

        uint256 currencyBalance = IERC20SupplyMinimal(usdc).balanceOf(address(this));
        require(currencyBalance != 0, "NO_CURRENCY_RAISED");

        uint256 cappedCurrency = currencyBalance;
        if (cappedCurrency > maxCurrencyAmountForLP) {
            cappedCurrency = maxCurrencyAmountForLP;
        }

        uint256 currencyForLP = (cappedCurrency * lpCurrencyBps) / BPS_DENOMINATOR;
        require(currencyForLP != 0, "LP_CURRENCY_ZERO");

        uint256 tokenBalance = IERC20SupplyMinimal(token).balanceOf(address(this));
        uint256 tokenForLP = tokenBalance > reserveTokenAmount ? reserveTokenAmount : tokenBalance;
        require(tokenForLP != 0, "LP_TOKEN_ZERO");

        PoolKey memory poolKey = _poolKey();
        bytes32 poolId = PoolId.unwrap(poolKey.toId());
        bool tokenIsCurrency0 = Currency.wrap(token) == poolKey.currency0;
        uint160 sqrtPriceX96 = _sqrtPriceX96(tokenIsCurrency0, currencyForLP, tokenForLP);
        uint128 liquidity = _liquidityForAmounts(
            poolKey, tokenIsCurrency0, sqrtPriceX96, currencyForLP, tokenForLP
        );
        require(liquidity != 0, "LP_LIQUIDITY_ZERO");

        uint256 positionId = IPositionManager(positionManager).nextTokenId();
        migrated = true;
        migratedPoolId = poolId;
        migratedPositionId = positionId;
        migratedLiquidity = liquidity;
        migratedCurrencyForLP = uint128(currencyForLP);
        migratedTokenForLP = uint128(tokenForLP);

        token.safeTransfer(positionManager, tokenForLP);
        usdc.safeTransfer(positionManager, currencyForLP);

        int24 initializedTick =
            IPositionManager(positionManager).initializePool(poolKey, sqrtPriceX96);
        require(initializedTick != POOL_INIT_FAILED, "POOL_INIT_FAILED");
        IPositionManager(positionManager)
            .modifyLiquidities(
                abi.encode(
                    bytes.concat(
                        bytes1(uint8(Actions.MINT_POSITION)),
                        bytes1(uint8(Actions.SETTLE)),
                        bytes1(uint8(Actions.SETTLE)),
                        bytes1(uint8(Actions.CLOSE_CURRENCY)),
                        bytes1(uint8(Actions.CLOSE_CURRENCY))
                    ),
                    _migrationParams(
                        poolKey, liquidity, currencyForLP, tokenForLP, tokenIsCurrency0
                    )
                ),
                block.timestamp
            );

        emit Migrated(
            poolId,
            positionId,
            positionRecipient,
            uint128(currencyForLP),
            uint128(tokenForLP),
            liquidity
        );
    }

    function sweepToken() external nonReentrant {
        require(msg.sender == operator, "NOT_OPERATOR");
        require(block.number >= sweepBlock, "SWEEP_NOT_ALLOWED");
        require(migrated, "MIGRATION_REQUIRED");

        uint256 tokenBalance = IERC20SupplyMinimal(token).balanceOf(address(this));
        require(tokenBalance != 0, "NOTHING_TO_SWEEP");

        token.safeTransfer(vestingWallet, tokenBalance);

        emit TokensSweptToVesting(vestingWallet, tokenBalance);
    }

    function sweepCurrency() external nonReentrant {
        require(msg.sender == operator, "NOT_OPERATOR");
        require(block.number >= sweepBlock, "SWEEP_NOT_ALLOWED");
        require(migrated, "MIGRATION_REQUIRED");

        uint256 currencyBalance = IERC20SupplyMinimal(usdc).balanceOf(address(this));
        require(currencyBalance != 0, "NOTHING_TO_SWEEP");

        usdc.safeTransfer(agentSafe, currencyBalance);

        emit CurrencySweptToTreasury(agentSafe, currencyBalance);
    }

    function recoverFailedAuction() external nonReentrant {
        require(msg.sender == operator, "NOT_OPERATOR");
        require(block.number >= sweepBlock, "SWEEP_NOT_ALLOWED");
        require(!migrated, "ALREADY_MIGRATED");
        require(auctionAddress != address(0), "AUCTION_NOT_CREATED");

        IContinuousClearingAuction auction = IContinuousClearingAuction(auctionAddress);
        require(!auction.isGraduated(), "AUCTION_GRADUATED");

        auction.sweepUnsoldTokens();

        uint256 tokenBalance = IERC20SupplyMinimal(token).balanceOf(address(this));
        require(tokenBalance != 0, "NOTHING_TO_SWEEP");

        token.safeTransfer(vestingWallet, tokenBalance);
        emit FailedAuctionRecovered(auctionAddress, vestingWallet, tokenBalance);
    }

    function rescueNative(address recipient) external onlyTreasury nonReentrant {
        require(recipient != address(0), "RECIPIENT_ZERO");

        uint256 amount = address(this).balance;
        require(amount != 0, "NOTHING_TO_RESCUE");

        address(0).safeTransfer(recipient, amount);
        emit NativeRescued(recipient, amount);
    }

    function rescueUnsupportedToken(address token_, uint256 amount, address recipient)
        external
        onlyTreasury
        nonReentrant
    {
        require(token_ != address(0), "TOKEN_ZERO");
        require(token_ != token && token_ != usdc, "PROTECTED_TOKEN");
        require(amount != 0, "AMOUNT_ZERO");
        require(recipient != address(0), "RECIPIENT_ZERO");

        token_.safeTransfer(recipient, amount);
        emit UnsupportedTokenRescued(token_, amount, recipient);
    }

    function _poolKey() internal view returns (PoolKey memory poolKey) {
        (Currency currency0, Currency currency1) = _sortedCurrencies();
        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: officialPoolFee,
            tickSpacing: officialPoolTickSpacing,
            hooks: IHooks(officialPoolHook)
        });
    }

    function _sortedCurrencies() internal view returns (Currency currency0, Currency currency1) {
        Currency tokenCurrency = Currency.wrap(token);
        Currency usdcCurrency = Currency.wrap(usdc);
        (currency0, currency1) = tokenCurrency < usdcCurrency
            ? (tokenCurrency, usdcCurrency)
            : (usdcCurrency, tokenCurrency);
    }

    function _migrationParams(
        PoolKey memory poolKey,
        uint128 liquidity,
        uint256 currencyForLP,
        uint256 tokenForLP,
        bool tokenIsCurrency0
    ) internal view returns (bytes[] memory params) {
        uint128 amount0Max = tokenIsCurrency0 ? uint128(tokenForLP) : uint128(currencyForLP);
        uint128 amount1Max = tokenIsCurrency0 ? uint128(currencyForLP) : uint128(tokenForLP);
        int24 lowerTick = TickMath.minUsableTick(officialPoolTickSpacing);
        int24 upperTick = TickMath.maxUsableTick(officialPoolTickSpacing);

        params = new bytes[](5);
        params[0] = abi.encode(
            poolKey,
            lowerTick,
            upperTick,
            liquidity,
            amount0Max,
            amount1Max,
            positionRecipient,
            bytes("")
        );
        params[1] = abi.encode(poolKey.currency0, ActionConstants.CONTRACT_BALANCE, false);
        params[2] = abi.encode(poolKey.currency1, ActionConstants.CONTRACT_BALANCE, false);
        params[3] = abi.encode(poolKey.currency0);
        params[4] = abi.encode(poolKey.currency1);
    }

    function _liquidityForAmounts(
        PoolKey memory poolKey,
        bool tokenIsCurrency0,
        uint160 sqrtPriceX96,
        uint256 currencyForLP,
        uint256 tokenForLP
    ) internal pure returns (uint128 liquidity) {
        uint128 amount0 = tokenIsCurrency0 ? uint128(tokenForLP) : uint128(currencyForLP);
        uint128 amount1 = tokenIsCurrency0 ? uint128(currencyForLP) : uint128(tokenForLP);
        liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(TickMath.minUsableTick(poolKey.tickSpacing)),
            TickMath.getSqrtPriceAtTick(TickMath.maxUsableTick(poolKey.tickSpacing)),
            amount0,
            amount1
        );
    }

    function _sqrtPriceX96(bool tokenIsCurrency0, uint256 currencyForLP, uint256 tokenForLP)
        internal
        pure
        returns (uint160 sqrtPriceX96)
    {
        uint256 amount0 = tokenIsCurrency0 ? tokenForLP : currencyForLP;
        uint256 amount1 = tokenIsCurrency0 ? currencyForLP : tokenForLP;
        uint256 ratioX192 = FullMath.mulDiv(amount1, uint256(1) << 192, amount0);
        uint256 sqrtPrice = Math.sqrt(ratioX192);
        require(sqrtPrice <= type(uint160).max, "SQRT_PRICE_OVERFLOW");
        sqrtPriceX96 = uint160(sqrtPrice);
    }
}
