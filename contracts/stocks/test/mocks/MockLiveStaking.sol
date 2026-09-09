// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {MockERC20} from "./MockERC20.sol";

/// @notice The live REGENT staking `depositUSDC` shape at the hook's boundary: pull the approved USDC,
///         measure what arrived, return it. Switches reproduce the failure shapes `settle` must refuse.
contract MockLiveStaking {
    address public immutable usdc;

    bool public paused;
    bool public pullsPartially;
    bool public reportsWrongAmount;

    uint256 public depositCalls;
    uint256 public lastAmount;
    bytes32 public lastSourceTag;
    bytes32 public lastSourceRef;
    address public lastCaller;

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
}
