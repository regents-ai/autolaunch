// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {CctpRevenueInboxV1} from "./CctpRevenueInboxV1.sol";
import {RevenueMeshTypes} from "./libraries/RevenueMeshTypes.sol";

/// @notice Deterministic candidate factory for one immutable source-chain CCTP configuration.
/// @dev Canonical status remains relative to later admission of this factory and configuration.
contract RevenueInboxFactoryV1 {
    string public constant ROUTE_VERSION_TAG = "AUTOLAUNCH_REVENUE_ROUTE_V1";
    string public constant ROUTE_KIND = "CCTP_V2_STANDARD";
    uint256 public constant BASE_CHAIN_ID = 8453;
    uint32 public constant BASE_CCTP_DOMAIN = 6;
    uint32 public constant FINALITY_THRESHOLD = 2000;
    uint256 public constant BPS_DENOMINATOR = 10_000;

    address public immutable sourceUsdc;
    address public immutable tokenMessenger;
    uint32 public immutable sourceDomain;
    uint256 public immutable sourceChainId;
    bytes32 public immutable sourceNamespace;
    uint256 public immutable minimumSweep;
    uint256 public immutable maxBurnPerMessage;
    uint256 public immutable maxFeeBps;

    event RevenueInboxDeployed(
        bytes32 indexed routeId, address indexed inbox, address indexed baseReceiver, address baseSplitter
    );

    error ZeroBinding();
    error SourceChainMismatch(uint256 configured, uint256 executing);
    error InvalidSweepBounds(uint256 minimumSweep, uint256 maxBurnPerMessage);
    error InvalidFeeCeiling(uint256 maxFeeBps);
    error Create2DeploymentFailed(bytes32 routeId);
    error ExistingInboxCodeMismatch(address inbox, bytes32 expected, bytes32 found);
    error ExistingInboxBindingMismatch(address inbox);

    constructor(
        address sourceUsdc_,
        address tokenMessenger_,
        uint32 sourceDomain_,
        uint256 sourceChainId_,
        bytes32 sourceNamespace_,
        uint256 minimumSweep_,
        uint256 maxBurnPerMessage_,
        uint256 maxFeeBps_
    ) {
        if (
            sourceUsdc_ == address(0) || tokenMessenger_ == address(0) || sourceChainId_ == 0
                || sourceNamespace_ == bytes32(0)
        ) revert ZeroBinding();
        if (sourceChainId_ != block.chainid) revert SourceChainMismatch(sourceChainId_, block.chainid);
        if (minimumSweep_ == 0 || minimumSweep_ > maxBurnPerMessage_) {
            revert InvalidSweepBounds(minimumSweep_, maxBurnPerMessage_);
        }
        if (maxFeeBps_ > BPS_DENOMINATOR) revert InvalidFeeCeiling(maxFeeBps_);

        sourceUsdc = sourceUsdc_;
        tokenMessenger = tokenMessenger_;
        sourceDomain = sourceDomain_;
        sourceChainId = sourceChainId_;
        sourceNamespace = sourceNamespace_;
        minimumSweep = minimumSweep_;
        maxBurnPerMessage = maxBurnPerMessage_;
        maxFeeBps = maxFeeBps_;
    }

    /// @notice Creates or returns the one exact route for a Base receiver/splitter pair.
    function deploy(address baseReceiver, address baseSplitter) external returns (CctpRevenueInboxV1 inbox) {
        if (baseReceiver == address(0) || baseSplitter == address(0)) revert ZeroBinding();

        bytes32 routeId = computeRouteId(baseReceiver, baseSplitter);
        bytes memory creationCode = _creationCode(routeId, baseReceiver, baseSplitter);
        address predicted = _computeCreate2Address(routeId, keccak256(creationCode));

        if (predicted.code.length != 0) {
            _requireExpectedInbox(predicted, routeId, baseReceiver, baseSplitter);
            return CctpRevenueInboxV1(predicted);
        }

        // CREATE2 has no high-level Solidity equivalent with explicit salt semantics.
        // slither-disable-next-line assembly
        assembly ("memory-safe") {
            inbox := create2(0, add(creationCode, 0x20), mload(creationCode), routeId)
        }
        if (address(inbox) == address(0)) revert Create2DeploymentFailed(routeId);
        _requireExpectedInbox(address(inbox), routeId, baseReceiver, baseSplitter);

        emit RevenueInboxDeployed(routeId, address(inbox), baseReceiver, baseSplitter);
    }

    function computeRouteId(address baseReceiver, address baseSplitter) public view returns (bytes32) {
        return keccak256(
            abi.encode(
                ROUTE_VERSION_TAG, BASE_CHAIN_ID, baseReceiver, baseSplitter, sourceNamespace, sourceChainId, ROUTE_KIND
            )
        );
    }

    function computeInboxAddress(address baseReceiver, address baseSplitter) public view returns (address) {
        if (baseReceiver == address(0) || baseSplitter == address(0)) revert ZeroBinding();
        bytes32 routeId = computeRouteId(baseReceiver, baseSplitter);
        return _computeCreate2Address(routeId, keccak256(_creationCode(routeId, baseReceiver, baseSplitter)));
    }

    function inboxRuntimeCodeHash() public pure returns (bytes32) {
        return keccak256(type(CctpRevenueInboxV1).runtimeCode);
    }

    /// @notice Returns offline manifest facts. This candidate can never report itself active.
    function routeFacts(address baseReceiver, address baseSplitter)
        external
        view
        returns (RevenueMeshTypes.RouteFacts memory facts)
    {
        bytes32 routeId = computeRouteId(baseReceiver, baseSplitter);
        facts = RevenueMeshTypes.RouteFacts({
            routeId: routeId,
            predictedInbox: computeInboxAddress(baseReceiver, baseSplitter),
            acceptedSourceToken: sourceUsdc,
            tokenMessengerV2: tokenMessenger,
            sourceDomain: sourceDomain,
            sourceNamespace: sourceNamespace,
            sourceChainId: sourceChainId,
            destinationDomain: BASE_CCTP_DOMAIN,
            finalityThreshold: FINALITY_THRESHOLD,
            permissionlessCompletion: true,
            minimumSweep: minimumSweep,
            maxBurnPerMessage: maxBurnPerMessage,
            maxFeeBps: maxFeeBps,
            baseReceiver: baseReceiver,
            baseSplitter: baseSplitter,
            candidateFactory: address(this),
            inboxRuntimeCodeHash: inboxRuntimeCodeHash(),
            bridgeSecurityClass: RevenueMeshTypes.BRIDGE_SECURITY_CLASS,
            settlementTransport: RevenueMeshTypes.SETTLEMENT_TRANSPORT,
            status: RevenueMeshTypes.OFFLINE_STATUS,
            compatibilityVerified: false,
            active: false
        });
    }

    function _creationCode(bytes32 routeId, address baseReceiver, address baseSplitter)
        private
        view
        returns (bytes memory)
    {
        return abi.encodePacked(
            type(CctpRevenueInboxV1).creationCode,
            abi.encode(
                routeId,
                sourceUsdc,
                tokenMessenger,
                sourceDomain,
                sourceChainId,
                sourceNamespace,
                minimumSweep,
                maxBurnPerMessage,
                maxFeeBps,
                baseReceiver,
                baseSplitter
            )
        );
    }

    function _computeCreate2Address(bytes32 salt, bytes32 creationCodeHash) private view returns (address) {
        return
            address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, creationCodeHash)))));
    }

    function _requireExpectedInbox(address inbox, bytes32 routeId, address baseReceiver, address baseSplitter)
        private
        view
    {
        bytes32 expectedCodeHash = inboxRuntimeCodeHash();
        bytes32 foundCodeHash = inbox.codehash;
        if (foundCodeHash != expectedCodeHash) {
            revert ExistingInboxCodeMismatch(inbox, expectedCodeHash, foundCodeHash);
        }

        CctpRevenueInboxV1 candidate = CctpRevenueInboxV1(inbox);
        if (
            candidate.routeId() != routeId || address(candidate.usdc()) != sourceUsdc
                || address(candidate.tokenMessenger()) != tokenMessenger || candidate.sourceDomain() != sourceDomain
                || candidate.sourceChainId() != sourceChainId || candidate.sourceNamespace() != sourceNamespace
                || candidate.minimumSweep() != minimumSweep || candidate.maxBurnPerMessage() != maxBurnPerMessage
                || candidate.maxFeeBps() != maxFeeBps || candidate.baseReceiver() != baseReceiver
                || candidate.baseSplitter() != baseSplitter
        ) revert ExistingInboxBindingMismatch(inbox);
    }
}
