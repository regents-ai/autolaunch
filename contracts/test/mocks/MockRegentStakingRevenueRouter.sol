// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IRegentStakingRevenueRouter} from "src/revenue/interfaces/IRegentStakingRevenueRouter.sol";

contract MockRegentStakingRevenueRouter is IRegentStakingRevenueRouter {
    address public immutable override usdc;
    address public immutable override regentRevenueStaking;
    address public override buybackAdapter;
    uint16 public override protocolSkimBps = 100;
    uint16 public override treasuryBuybackBps = 1000;
    bool public shouldRevert;
    bool public shouldRevertBuyback;
    uint256 public totalUsdcProcessed;
    uint256 public totalUsdcDepositedToRegentStaking;
    uint256 public totalUsdcUsedForTreasuryBuyback;
    uint256 public totalRegentBoughtForTreasuries;
    bytes32 public lastSubjectId;
    address public lastSubjectTreasury;
    bytes32 public lastSourceRef;

    constructor(address usdc_, address regentRevenueStaking_) {
        usdc = usdc_;
        regentRevenueStaking = regentRevenueStaking_;
    }

    function setBuybackAdapter(address buybackAdapter_) external {
        buybackAdapter = buybackAdapter_;
    }

    function setShouldRevert(bool shouldRevert_) external {
        shouldRevert = shouldRevert_;
    }

    function setShouldRevertBuyback(bool shouldRevertBuyback_) external {
        shouldRevertBuyback = shouldRevertBuyback_;
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

    function processTreasuryBuyback(
        bytes32 subjectId,
        address subjectTreasury,
        uint256 usdcAmount,
        bytes32 sourceRef
    ) external override returns (uint256 regentOut) {
        require(!shouldRevertBuyback, "MOCK_BUYBACK_REVERT");
        totalUsdcUsedForTreasuryBuyback += usdcAmount;
        totalRegentBoughtForTreasuries += usdcAmount;
        lastSubjectId = subjectId;
        lastSubjectTreasury = subjectTreasury;
        lastSourceRef = sourceRef;
        return usdcAmount;
    }
}
