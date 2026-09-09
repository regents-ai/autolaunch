// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {MockERC20} from "./MockERC20.sol";

/// @notice An Agent `SubjectSplitterV1` at the hook's boundary: `subject()`, `regent()` and an exact
///         pull in `depositRecognizedRevenue`. Switches reproduce the failure shapes `settle` refuses.
contract MockSplitter {
    address public immutable subject;
    address public immutable regent;

    bool public pullsPartially;
    uint256 public depositCalls;
    address public lastToken;
    uint256 public lastAmount;
    bytes32 public lastRef;

    error ZeroAmount();

    constructor(address subject_, address regent_) {
        subject = subject_;
        regent = regent_;
    }

    function setPullsPartially(bool value) external {
        pullsPartially = value;
    }

    function depositRecognizedRevenue(address token, uint256 amount, bytes32 revenueRef) external {
        if (amount == 0) revert ZeroAmount();
        MockERC20(token).transferFrom(msg.sender, address(this), pullsPartially ? amount / 2 : amount);
        depositCalls += 1;
        lastToken = token;
        lastAmount = amount;
        lastRef = revenueRef;
    }
}
