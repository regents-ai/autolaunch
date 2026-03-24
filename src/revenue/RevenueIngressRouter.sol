// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Owned} from "src/auth/Owned.sol";
import {SafeTransferLib} from "src/libraries/SafeTransferLib.sol";
import {ISubjectRegistry} from "src/revenue/interfaces/ISubjectRegistry.sol";
import {IRevenueShareSplitter} from "src/revenue/interfaces/IRevenueShareSplitter.sol";

contract RevenueIngressRouter is Owned {
    using SafeTransferLib for address;

    address public immutable usdc;
    ISubjectRegistry public immutable subjectRegistry;
    bool public paused;

    event PausedSet(bool paused);
    event USDCRouted(
        bytes32 indexed subjectId,
        address indexed payer,
        uint256 amount,
        bytes32 sourceTag,
        bytes32 sourceRef,
        address splitter
    );

    constructor(address owner_, address usdc_, ISubjectRegistry subjectRegistry_) Owned(owner_) {
        require(usdc_ != address(0), "USDC_ZERO");
        require(address(subjectRegistry_) != address(0), "REGISTRY_ZERO");
        usdc = usdc_;
        subjectRegistry = subjectRegistry_;
    }

    modifier whenNotPaused() {
        require(!paused, "PAUSED");
        _;
    }

    function setPaused(bool paused_) external onlyOwner {
        paused = paused_;
        emit PausedSet(paused_);
    }

    function depositUSDC(bytes32 subjectId, uint256 amount, bytes32 sourceTag, bytes32 sourceRef)
        external
        whenNotPaused
        returns (uint256 received)
    {
        require(amount != 0, "AMOUNT_ZERO");

        address splitter = subjectRegistry.splitterOfSubject(subjectId);
        require(splitter != address(0), "SPLITTER_NOT_FOUND");

        usdc.safeTransferFrom(msg.sender, address(this), amount);
        usdc.forceApprove(splitter, amount);
        received = IRevenueShareSplitter(splitter).depositUSDC(amount, sourceTag, sourceRef);

        emit USDCRouted(subjectId, msg.sender, received, sourceTag, sourceRef, splitter);
    }
}
