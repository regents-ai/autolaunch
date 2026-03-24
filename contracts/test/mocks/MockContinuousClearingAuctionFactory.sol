// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {
    IContinuousClearingAuctionFactory
} from "src/cca/interfaces/IContinuousClearingAuctionFactory.sol";
import {IDistributionContract} from "src/cca/interfaces/external/IDistributionContract.sol";

contract MockDistributionContract is IDistributionContract {
    bool public received;

    function onTokensReceived() external {
        received = true;
    }
}

contract MockContinuousClearingAuctionFactory is IContinuousClearingAuctionFactory {
    address public lastToken;
    uint256 public lastAmount;
    bytes public lastConfigData;
    bytes32 public lastSalt;
    address public lastAuction;

    function initializeDistribution(
        address token,
        uint256 amount,
        bytes calldata configData,
        bytes32 salt
    ) external returns (IDistributionContract distributionContract) {
        lastToken = token;
        lastAmount = amount;
        lastConfigData = configData;
        lastSalt = salt;

        MockDistributionContract auction = new MockDistributionContract();
        lastAuction = address(auction);
        return auction;
    }

    function getAuctionAddress(address, uint256, bytes calldata, bytes32, address)
        external
        view
        returns (address)
    {
        return lastAuction;
    }
}
