// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Owned} from "src/auth/Owned.sol";
import {SafeTransferLib} from "src/libraries/SafeTransferLib.sol";
import {IERC20SupplyMinimal} from "src/revenue/interfaces/IERC20SupplyMinimal.sol";
import {IRevenueShareSplitter} from "src/revenue/interfaces/IRevenueShareSplitter.sol";

contract RevenueIngressAccount is Owned {
    using SafeTransferLib for address;

    address public immutable usdc;
    address public immutable splitter;
    address public immutable factory;
    bytes32 public immutable subjectId;
    uint256 private _reentrancyGuard = 1;

    string public label;

    event LabelSet(string label);
    event USDCSwept(
        address indexed caller,
        uint256 balanceForwarded,
        uint256 amountRecognized,
        bytes32 indexed sourceRef
    );
    event RescueToken(address indexed token, uint256 amount, address indexed recipient);

    modifier nonReentrant() {
        require(_reentrancyGuard == 1, "REENTRANT");
        _reentrancyGuard = 2;
        _;
        _reentrancyGuard = 1;
    }

    constructor(
        address usdc_,
        address splitter_,
        bytes32 subjectId_,
        string memory label_,
        address owner_
    ) Owned(owner_) {
        require(usdc_ != address(0), "USDC_ZERO");
        require(splitter_ != address(0), "SPLITTER_ZERO");
        require(subjectId_ != bytes32(0), "SUBJECT_ZERO");
        require(IRevenueShareSplitter(splitter_).usdc() == usdc_, "SPLITTER_USDC_MISMATCH");

        usdc = usdc_;
        splitter = splitter_;
        factory = msg.sender;
        subjectId = subjectId_;
        label = label_;
    }

    function setLabel(string calldata label_) external onlyOwner {
        label = label_;
        emit LabelSet(label_);
    }

    function sweepUSDC(bytes32 sourceRef)
        external
        nonReentrant
        returns (uint256 balance, uint256 recognized)
    {
        balance = IERC20SupplyMinimal(usdc).balanceOf(address(this));
        require(balance != 0, "NOTHING_TO_SWEEP");

        usdc.forceApprove(splitter, balance);
        recognized = IRevenueShareSplitter(splitter)
            .depositUSDC(balance, bytes32("ingress_sweep"), sourceRef);
        usdc.forceApprove(splitter, 0);

        emit USDCSwept(msg.sender, balance, recognized, sourceRef);
    }

    function rescueToken(address token, uint256 amount, address recipient)
        external
        onlyOwner
        nonReentrant
    {
        require(token != address(0), "TOKEN_ZERO");
        require(token != usdc, "USE_SWEEP_USDC");
        require(recipient != address(0), "RECIPIENT_ZERO");

        token.safeTransfer(recipient, amount);
        emit RescueToken(token, amount, recipient);
    }

    receive() external payable {
        revert("ETH_NOT_ACCEPTED");
    }
}
