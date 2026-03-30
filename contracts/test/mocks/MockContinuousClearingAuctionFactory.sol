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

    function _deploymentSalt(
        address sender,
        address token,
        uint256 amount,
        bytes calldata configData,
        bytes32 salt
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(sender, token, amount, keccak256(configData), salt));
    }

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

        MockDistributionContract auction = new MockDistributionContract{
            salt: _deploymentSalt(msg.sender, token, amount, configData, salt)
        }();
        lastAuction = address(auction);
        return auction;
    }

    function getAuctionAddress(
        address token,
        uint256 amount,
        bytes calldata configData,
        bytes32 salt,
        address sender
    ) external view returns (address) {
        bytes32 deploymentSalt = _deploymentSalt(sender, token, amount, configData, salt);
        bytes32 bytecodeHash = keccak256(type(MockDistributionContract).creationCode);
        return address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(bytes1(0xff), address(this), deploymentSalt, bytecodeHash)
                    )
                )
            )
        );
    }
}
