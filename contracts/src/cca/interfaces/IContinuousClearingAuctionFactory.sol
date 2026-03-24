// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IDistributionContract} from "./external/IDistributionContract.sol";

interface IContinuousClearingAuctionFactory {
    function initializeDistribution(
        address token,
        uint256 amount,
        bytes calldata configData,
        bytes32 salt
    ) external returns (IDistributionContract distributionContract);

    function getAuctionAddress(
        address token,
        uint256 amount,
        bytes calldata configData,
        bytes32 salt,
        address sender
    ) external view returns (address);
}
