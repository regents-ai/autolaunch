// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {RevenueShareSplitterV2} from "src/revenue/RevenueShareSplitterV2.sol";

contract RevenueShareSplitterV2Deployer {
    function deploy(
        address stakeToken,
        address usdc,
        address ingressFactory,
        address subjectRegistry,
        bytes32 subjectId,
        address treasuryRecipient,
        address feeRouter,
        uint256 revenueShareSupplyDenominator,
        string calldata label,
        address owner
    ) external returns (address splitter) {
        splitter = address(
            new RevenueShareSplitterV2(
                stakeToken,
                usdc,
                ingressFactory,
                subjectRegistry,
                subjectId,
                treasuryRecipient,
                feeRouter,
                revenueShareSupplyDenominator,
                label,
                owner
            )
        );
    }
}
