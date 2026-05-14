// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Owned} from "src/auth/Owned.sol";
import {SafeTransferLib} from "src/libraries/SafeTransferLib.sol";
import {IERC20SupplyMinimal} from "src/revenue/interfaces/IERC20SupplyMinimal.sol";
import {IRevenueShareSplitter} from "src/revenue/interfaces/IRevenueShareSplitter.sol";
import {ISubjectRegistry} from "src/revenue/interfaces/ISubjectRegistry.sol";
import {InputBounds} from "src/revenue/libraries/InputBounds.sol";

contract PaymentLinkReceiver is Owned {
    using SafeTransferLib for address;

    address public immutable usdc;
    address public immutable subjectRegistry;
    address public immutable factory;
    address public immutable creator;
    bytes32 public immutable subjectId;
    uint256 private _reentrancyGuard = 1;

    string public label;

    event LabelSet(string label);
    event PaymentLinkDeposit(address indexed payer, uint256 amount, bytes32 indexed paymentRef);
    event PaymentLinkSwept(
        address indexed caller,
        address indexed destination,
        uint256 balanceForwarded,
        uint256 amountRecognized,
        bytes32 indexed paymentRef
    );

    modifier nonReentrant() {
        require(_reentrancyGuard == 1, "REENTRANT");
        _reentrancyGuard = 2;
        _;
        _reentrancyGuard = 1;
    }

    constructor(
        address usdc_,
        address subjectRegistry_,
        bytes32 subjectId_,
        address creator_,
        string memory label_
    ) Owned(creator_) {
        require(usdc_ != address(0), "USDC_ZERO");
        require(subjectRegistry_ != address(0), "SUBJECT_REGISTRY_ZERO");
        require(subjectId_ != bytes32(0), "SUBJECT_ZERO");
        require(creator_ != address(0), "CREATOR_ZERO");
        InputBounds.requireStringMax(label_, InputBounds.MAX_LABEL_BYTES, "LABEL_TOO_LONG");

        ISubjectRegistry.SubjectConfig memory subject =
            ISubjectRegistry(subjectRegistry_).getSubject(subjectId_);
        require(subject.active, "SUBJECT_INACTIVE");
        require(subject.splitter != address(0), "SPLITTER_ZERO");
        require(IRevenueShareSplitter(subject.splitter).usdc() == usdc_, "SPLITTER_USDC_MISMATCH");
        require(
            IRevenueShareSplitter(subject.splitter).subjectId() == subjectId_,
            "SPLITTER_SUBJECT_MISMATCH"
        );

        usdc = usdc_;
        subjectRegistry = subjectRegistry_;
        factory = msg.sender;
        creator = creator_;
        subjectId = subjectId_;
        label = label_;
    }

    function setLabel(string calldata label_) external onlyOwner {
        InputBounds.requireStringMax(label_, InputBounds.MAX_LABEL_BYTES, "LABEL_TOO_LONG");
        label = label_;
        emit LabelSet(label_);
    }

    function destination() public view returns (address splitter) {
        splitter = ISubjectRegistry(subjectRegistry).splitterOfSubject(subjectId);
        require(splitter != address(0), "SPLITTER_ZERO");
    }

    function depositUSDC(uint256 amount, bytes32 paymentRef)
        external
        nonReentrant
        returns (uint256 received, uint256 recognized)
    {
        require(amount != 0, "AMOUNT_ZERO");

        usdc.safeTransferFrom(msg.sender, address(this), amount);
        received = amount;

        emit PaymentLinkDeposit(msg.sender, received, paymentRef);

        (, recognized) = _forwardUSDC(paymentRef);
    }

    function sweepUSDC(bytes32 paymentRef)
        external
        nonReentrant
        returns (uint256 balance, uint256 recognized)
    {
        return _forwardUSDC(paymentRef);
    }

    function _forwardUSDC(bytes32 paymentRef)
        internal
        returns (uint256 balance, uint256 recognized)
    {
        address splitter = destination();
        require(IRevenueShareSplitter(splitter).usdc() == usdc, "SPLITTER_USDC_MISMATCH");
        require(
            IRevenueShareSplitter(splitter).subjectId() == subjectId, "SPLITTER_SUBJECT_MISMATCH"
        );

        balance = IERC20SupplyMinimal(usdc).balanceOf(address(this));
        require(balance != 0, "NOTHING_TO_SWEEP");

        usdc.forceApprove(splitter, balance);
        recognized = IRevenueShareSplitter(splitter)
            .depositUSDC(balance, bytes32("payment_link"), paymentRef);

        emit PaymentLinkSwept(msg.sender, splitter, balance, recognized, paymentRef);
    }

    receive() external payable {
        revert("ETH_NOT_ACCEPTED");
    }

    function _isProtectedToken(address token) internal view override returns (bool) {
        return token == usdc;
    }
}
