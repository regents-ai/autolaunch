// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {MockERC20} from "./MockERC20.sol";

/// @notice The live REGENT staking `depositUSDC` behavior at the splitter's boundary.
/// @dev Mirrors the pinned implementation: pull the approved USDC, measure what actually arrived,
///      and return that. The switches reproduce the failure shapes the splitter must survive — a
///      paused or reverting contract, a partial pull, and a wrong reported amount. The deployed
///      runtime behind the frozen binding stays unproven here; `DEP-045` owns that on the fork gate.
contract MockLiveStaking {
    address public immutable usdc;

    bool public paused;
    bool public pullsPartially;
    bool public reportsWrongAmount;
    /// @notice When set, the reported amount is whatever was asked for rather than what arrived.
    bool public lieAboutReceived;

    uint256 public lastAmount;
    bytes32 public lastSourceTag;
    bytes32 public lastSourceRef;
    address public lastCaller;
    uint256 public depositCalls;

    error Paused();

    constructor(address usdc_) {
        usdc = usdc_;
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

    function setLieAboutReceived(bool value) external {
        lieAboutReceived = value;
    }

    function depositUSDC(uint256 amount, bytes32 sourceTag, bytes32 sourceRef) external returns (uint256 received) {
        if (paused) revert Paused();

        uint256 pull = pullsPartially ? amount / 2 : amount;
        uint256 before = MockERC20(usdc).balanceOf(address(this));
        MockERC20(usdc).transferFrom(msg.sender, address(this), pull);
        received = MockERC20(usdc).balanceOf(address(this)) - before;

        lastAmount = amount;
        lastSourceTag = sourceTag;
        lastSourceRef = sourceRef;
        lastCaller = msg.sender;
        depositCalls += 1;

        if (lieAboutReceived) received = amount;
        if (reportsWrongAmount) received = amount + 1;
    }
}
