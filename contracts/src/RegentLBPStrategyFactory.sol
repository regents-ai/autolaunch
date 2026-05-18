// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AuctionParameters} from "src/cca/interfaces/IContinuousClearingAuction.sol";
import {IDistributionContract} from "src/cca/interfaces/external/IDistributionContract.sol";
import {IDistributionStrategy} from "src/interfaces/IDistributionStrategy.sol";
import {Owned} from "src/auth/Owned.sol";
import {RegentLBPStrategy} from "src/RegentLBPStrategy.sol";
import {BaseRegent} from "src/libraries/BaseRegent.sol";

contract RegentLBPStrategyFactory is Owned, IDistributionStrategy {
    struct RegentLBPStrategyConfig {
        address quoteToken;
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
        uint128 auctionTokenAmount;
        uint128 reserveTokenAmount;
    }

    mapping(address => bool) public authorizedCreators;

    event DistributionInitialized(
        address indexed distributionContract, address indexed token, uint256 amount
    );
    event RegentStrategyCreated(
        address indexed strategy, address indexed token, uint256 strategySupply
    );
    event AuthorizedCreatorSet(address indexed account, bool enabled);

    constructor(address owner_) Owned(owner_) {}

    modifier onlyAuthorizedCreator() {
        require(msg.sender == owner || authorizedCreators[msg.sender], "ONLY_AUTHORIZED_CREATOR");
        _;
    }

    function setAuthorizedCreator(address account, bool enabled) external onlyOwner {
        require(account != address(0), "ACCOUNT_ZERO");
        authorizedCreators[account] = enabled;
        emit AuthorizedCreatorSet(account, enabled);
    }

    function initializeDistribution(
        address token,
        uint256 amount,
        bytes calldata configData,
        bytes32
    ) external onlyAuthorizedCreator returns (IDistributionContract distributionContract) {
        RegentLBPStrategyConfig memory cfg = abi.decode(configData, (RegentLBPStrategyConfig));
        require(amount <= type(uint128).max, "STRATEGY_SUPPLY_TOO_LARGE");
        _validateQuoteToken(cfg);

        distributionContract = IDistributionContract(
            address(
                new RegentLBPStrategy(
                    RegentLBPStrategy.StrategyConfig({
                        token: token,
                        quoteToken: cfg.quoteToken,
                        auctionInitializerFactory: cfg.auctionInitializerFactory,
                        auctionParameters: cfg.auctionParameters,
                        officialPoolHook: cfg.officialPoolHook,
                        agentSafe: cfg.agentSafe,
                        vestingWallet: cfg.vestingWallet,
                        operator: cfg.operator,
                        positionRecipient: cfg.positionRecipient,
                        positionManager: cfg.positionManager,
                        poolManager: cfg.poolManager,
                        officialPoolFee: cfg.officialPoolFee,
                        officialPoolTickSpacing: cfg.officialPoolTickSpacing,
                        auctionCreator: msg.sender,
                        migrationBlock: cfg.migrationBlock,
                        sweepBlock: cfg.sweepBlock,
                        lpCurrencyBps: cfg.lpCurrencyBps,
                        tokenSplitToAuctionMps: cfg.tokenSplitToAuctionMps,
                        // forge-lint: disable-next-line(unsafe-typecast)
                        totalStrategySupply: uint128(amount),
                        auctionTokenAmount: cfg.auctionTokenAmount,
                        reserveTokenAmount: cfg.reserveTokenAmount
                    })
                )
            )
        );

        emit DistributionInitialized(address(distributionContract), token, amount);
        emit RegentStrategyCreated(address(distributionContract), token, amount);
    }

    function _validateQuoteToken(RegentLBPStrategyConfig memory cfg) internal view {
        BaseRegent.requireCanonical(cfg.quoteToken);
        require(cfg.auctionParameters.currency == cfg.quoteToken, "AUCTION_QUOTE_TOKEN_MISMATCH");
        require(cfg.quoteToken.code.length != 0, "QUOTE_TOKEN_NO_CODE");
        require(IERC20MetadataMinimal(cfg.quoteToken).decimals() == 18, "QUOTE_TOKEN_DECIMALS");
    }
}

interface IERC20MetadataMinimal {
    function decimals() external view returns (uint8);
}
