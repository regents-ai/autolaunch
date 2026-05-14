// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Owned} from "src/auth/Owned.sol";
import {IRevenueShareSplitter} from "src/revenue/interfaces/IRevenueShareSplitter.sol";
import {ISubjectRegistry} from "src/revenue/interfaces/ISubjectRegistry.sol";
import {PaymentLinkReceiver} from "src/revenue/PaymentLinkReceiver.sol";
import {InputBounds} from "src/revenue/libraries/InputBounds.sol";

contract PaymentLinkFactory is Owned {
    address public immutable usdc;
    address public immutable subjectRegistry;

    mapping(address => bool) public isPaymentLink;
    mapping(bytes32 => address[]) private paymentLinksBySubject;
    mapping(address => address[]) private paymentLinksByCreator;

    event PaymentLinkCreated(
        bytes32 indexed subjectId, address indexed receiver, address indexed creator, string label
    );

    constructor(address owner_, address usdc_, address subjectRegistry_) Owned(owner_) {
        require(usdc_ != address(0), "USDC_ZERO");
        require(subjectRegistry_ != address(0), "SUBJECT_REGISTRY_ZERO");

        usdc = usdc_;
        subjectRegistry = subjectRegistry_;
    }

    function createPaymentLink(bytes32 subjectId, string calldata label, bytes32 salt)
        external
        returns (address receiver)
    {
        require(subjectId != bytes32(0), "SUBJECT_ZERO");
        InputBounds.requireStringMax(label, InputBounds.MAX_LABEL_BYTES, "LABEL_TOO_LONG");

        ISubjectRegistry.SubjectConfig memory subject =
            ISubjectRegistry(subjectRegistry).getSubject(subjectId);
        require(subject.active, "SUBJECT_INACTIVE");
        require(subject.splitter != address(0), "SPLITTER_ZERO");
        require(IRevenueShareSplitter(subject.splitter).usdc() == usdc, "SPLITTER_USDC_MISMATCH");
        require(
            IRevenueShareSplitter(subject.splitter).subjectId() == subjectId,
            "SPLITTER_SUBJECT_MISMATCH"
        );

        bytes32 deploymentSalt = keccak256(abi.encode(msg.sender, subjectId, salt));
        PaymentLinkReceiver deployed = new PaymentLinkReceiver{salt: deploymentSalt}(
            usdc, subjectRegistry, subjectId, msg.sender, label
        );
        receiver = address(deployed);

        isPaymentLink[receiver] = true;
        paymentLinksBySubject[subjectId].push(receiver);
        paymentLinksByCreator[msg.sender].push(receiver);

        emit PaymentLinkCreated(subjectId, receiver, msg.sender, label);
    }

    function paymentLinkCountForSubject(bytes32 subjectId) external view returns (uint256) {
        return paymentLinksBySubject[subjectId].length;
    }

    function paymentLinkForSubjectAt(bytes32 subjectId, uint256 index)
        external
        view
        returns (address)
    {
        return paymentLinksBySubject[subjectId][index];
    }

    function paymentLinksForSubject(bytes32 subjectId) external view returns (address[] memory) {
        return paymentLinksBySubject[subjectId];
    }

    function paymentLinkCountForCreator(address creator) external view returns (uint256) {
        return paymentLinksByCreator[creator].length;
    }

    function paymentLinkForCreatorAt(address creator, uint256 index)
        external
        view
        returns (address)
    {
        return paymentLinksByCreator[creator][index];
    }

    function paymentLinksForCreator(address creator) external view returns (address[] memory) {
        return paymentLinksByCreator[creator];
    }
}
