// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Owned} from "src/auth/Owned.sol";
import {SafeTransferLib} from "src/libraries/SafeTransferLib.sol";
import {IERC20SupplyMinimal} from "src/revenue/interfaces/IERC20SupplyMinimal.sol";
import {IRevenueShareSplitter} from "src/revenue/interfaces/IRevenueShareSplitter.sol";

contract RevenueIngressAccount is Owned {
    using SafeTransferLib for address;

    bytes32 internal constant DEFAULT_SOURCE_TAG = bytes32("ingress_usdc");

    address public immutable splitter;
    address public immutable usdc;
    bytes32 public immutable ingressId;

    event USDCSwept(uint256 amount, bytes32 indexed sourceRef);
    event UnsupportedTokenRescued(address indexed token, uint256 amount, address recipient);
    event NativeRescued(uint256 amount, address recipient);

    constructor(address splitter_, address usdc_, bytes32 ingressId_, address owner_) Owned(owner_) {
        require(splitter_ != address(0), "SPLITTER_ZERO");
        require(usdc_ != address(0), "USDC_ZERO");
        splitter = splitter_;
        usdc = usdc_;
        ingressId = ingressId_;
    }

    receive() external payable {}

    function sweepUSDC() external returns (uint256 amount) {
        amount = IERC20SupplyMinimal(usdc).balanceOf(address(this));
        require(amount != 0, "NOTHING_TO_SWEEP");

        bytes32 sourceRef = keccak256(abi.encode(ingressId, usdc, amount));
        usdc.forceApprove(splitter, amount);
        IRevenueShareSplitter(splitter).depositUSDC(amount, DEFAULT_SOURCE_TAG, sourceRef);

        emit USDCSwept(amount, sourceRef);
    }

    function rescueUnsupportedToken(address token, uint256 amount, address recipient) external onlyOwner {
        require(token != address(0), "USE_RESCUE_NATIVE");
        require(token != usdc, "USE_SWEEP_USDC");
        require(recipient != address(0), "RECIPIENT_ZERO");

        emit UnsupportedTokenRescued(token, amount, recipient);
        token.safeTransfer(recipient, amount);
    }

    function rescueNative(uint256 amount, address recipient) external onlyOwner {
        require(recipient != address(0), "RECIPIENT_ZERO");
        emit NativeRescued(amount, recipient);
        address(0).safeTransfer(recipient, amount);
    }
}
