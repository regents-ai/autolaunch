// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IRegentStakingRevenueRouter} from "src/revenue/interfaces/IRegentStakingRevenueRouter.sol";

contract MockRegentStakingRevenueRouter is IRegentStakingRevenueRouter {
    address public immutable override usdc;
    address public immutable override regentRevenueStaking;
    uint16 public override protocolSkimBps = 1000;
    bool public shouldRevert;
    uint256 public totalUsdcProcessed;
    uint256 public totalUsdcDepositedToRegentStaking;
    bytes32 public lastSubjectId;
    address public lastSubjectTreasury;
    bytes32 public lastSourceRef;

    constructor(address usdc_, address regentRevenueStaking_) {
        usdc = usdc_;
        regentRevenueStaking = regentRevenueStaking_;
    }

    function setProtocolSkimBps(uint16 newBps) external {
        protocolSkimBps = newBps;
    }

    function setShouldRevert(bool shouldRevert_) external {
        shouldRevert = shouldRevert_;
    }

    function processProtocolFee(
        bytes32 subjectId,
        address subjectTreasury,
        uint256 usdcAmount,
        bytes32 sourceRef
    ) external override returns (uint256 depositedUsdc) {
        require(!shouldRevert, "MOCK_ROUTER_REVERT");
        totalUsdcProcessed += usdcAmount;
        totalUsdcDepositedToRegentStaking += usdcAmount;
        lastSubjectId = subjectId;
        lastSubjectTreasury = subjectTreasury;
        lastSourceRef = sourceRef;
        return usdcAmount;
    }
}
