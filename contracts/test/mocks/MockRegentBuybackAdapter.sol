// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IRegentBuybackAdapter} from "src/revenue/interfaces/IRegentBuybackAdapter.sol";
import {MintableERC20Mock} from "test/mocks/MintableERC20Mock.sol";

contract MockRegentBuybackAdapter is IRegentBuybackAdapter {
    address public immutable override usdc;
    address public immutable override regent;
    bool public shouldRevert;
    uint256 public outputAmount;
    uint256 public totalUsdcReceived;

    constructor(address usdc_, address regent_) {
        usdc = usdc_;
        regent = regent_;
    }

    function setShouldRevert(bool shouldRevert_) external {
        shouldRevert = shouldRevert_;
    }

    function setOutputAmount(uint256 outputAmount_) external {
        outputAmount = outputAmount_;
    }

    function buyRegent(uint256 usdcAmount, uint256 minRegentOut, address recipient)
        external
        override
        returns (uint256 regentOut)
    {
        require(!shouldRevert, "MOCK_BUYBACK_REVERT");
        require(usdcAmount != 0, "AMOUNT_ZERO");
        require(minRegentOut != 0, "MIN_OUT_ZERO");
        MintableERC20Mock(usdc).transferFrom(msg.sender, address(this), usdcAmount);

        regentOut = outputAmount == 0 ? usdcAmount : outputAmount;
        require(regentOut >= minRegentOut, "REGENT_OUT_LOW");
        totalUsdcReceived += usdcAmount;
        MintableERC20Mock(regent).mint(recipient, regentOut);
    }
}
