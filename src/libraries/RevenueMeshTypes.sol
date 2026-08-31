// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

library RevenueMeshTypes {
    bytes32 internal constant BRIDGE_SECURITY_CLASS = "CCTP_ISSUER_NATIVE";
    bytes32 internal constant SETTLEMENT_TRANSPORT = "CCTP_V2_STANDARD";
    bytes32 internal constant OFFLINE_STATUS = "UNVERIFIED_INACTIVE";

    struct RouteFacts {
        bytes32 routeId;
        address predictedInbox;
        address acceptedSourceToken;
        address tokenMessengerV2;
        uint32 sourceDomain;
        bytes32 sourceNamespace;
        uint256 sourceChainId;
        uint32 destinationDomain;
        uint32 finalityThreshold;
        bool permissionlessCompletion;
        uint256 minimumSweep;
        uint256 maxBurnPerMessage;
        uint256 maxFeeBps;
        address baseReceiver;
        address baseSplitter;
        address admittedFactory;
        bytes32 inboxRuntimeCodeHash;
        bytes32 bridgeSecurityClass;
        bytes32 settlementTransport;
        bytes32 status;
        bool compatibilityVerified;
        bool active;
    }
}
