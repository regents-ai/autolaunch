// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {MockERC20} from "./MockERC20.sol";

/// @notice The live REGENT staking surface at this component's two boundaries: `depositUSDC` (the
///         hook's REGENT bucket: pull the approved USDC, measure what arrived, return it) and
///         `fundRegentRewards` (the launch fee: pull exactly `amount` of the stake token from the
///         caller, revert on any shortfall, count it in `totalFundedRegent`, return it), shaped like
///         `RegentRevenueStaking`. Switches reproduce the failure shapes `settle` and `launch` must
///         refuse.
contract MockLiveStaking {
    address public immutable usdc;
    address public immutable stakeToken;

    bool public paused;
    bool public pullsPartially;
    bool public reportsWrongAmount;

    uint256 public depositCalls;
    uint256 public lastAmount;
    bytes32 public lastSourceTag;
    bytes32 public lastSourceRef;
    address public lastCaller;

    uint256 public totalFundedRegent;
    uint256 public fundCalls;
    address public lastFunder;

    error Paused();
    error AmountZero();
    error ShortfallOnPull(uint256 expected, uint256 received);

    constructor(address usdc_, address stakeToken_) {
        usdc = usdc_;
        stakeToken = stakeToken_;
    }

    function setPaused(bool value) external {
        paused = value;
    }

    function setPullsPartially(bool value) external {
        pullsPartially = value;
    }

    function setReportsWrongAmount(bool value) external {
        reportsWrongAmount = value;
    }

    function depositUSDC(uint256 amount, bytes32 sourceTag, bytes32 sourceRef) external returns (uint256 received) {
        if (paused) revert Paused();
        uint256 pull = pullsPartially ? amount / 2 : amount;
        uint256 before = MockERC20(usdc).balanceOf(address(this));
        MockERC20(usdc).transferFrom(msg.sender, address(this), pull);
        received = MockERC20(usdc).balanceOf(address(this)) - before;
        depositCalls += 1;
        lastAmount = amount;
        lastSourceTag = sourceTag;
        lastSourceRef = sourceRef;
        lastCaller = msg.sender;
        if (reportsWrongAmount) received = amount + 1;
    }

    /// @dev Mirrors `RegentRevenueStaking.fundRegentRewards` / `_pullExactStakeToken`: permissionless,
    ///      refuses zero and a paused contract, pulls exactly `amount` from the caller (the token's own
    ///      allowance and balance checks make a shortfall revert), and counts what arrived.
    function fundRegentRewards(uint256 amount) external returns (uint256 received) {
        if (paused) revert Paused();
        if (amount == 0) revert AmountZero();
        uint256 before = MockERC20(stakeToken).balanceOf(address(this));
        MockERC20(stakeToken).transferFrom(msg.sender, address(this), amount);
        received = MockERC20(stakeToken).balanceOf(address(this)) - before;
        if (received != amount) revert ShortfallOnPull(amount, received);
        totalFundedRegent += received;
        fundCalls += 1;
        lastFunder = msg.sender;
        if (reportsWrongAmount) received = amount + 1;
    }
}
