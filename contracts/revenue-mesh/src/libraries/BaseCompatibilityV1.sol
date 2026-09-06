// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Fail-closed evaluation of later, provider-backed Base receiver observations.
/// @dev A `true` result means the supplied observations match an admission. It does not prove that
///      the observations came from the chain and never activates an offline candidate.
library BaseCompatibilityV1 {
    struct Admission {
        bytes32 receiverCodeHash;
        address canonicalBaseUsdc;
        bytes32 provenanceHash;
    }

    struct Observation {
        address receiver;
        bool initialized;
        bytes32 receiverCodeHash;
        address splitter;
        address usdc;
        uint16 referralBps;
        bytes32 provenanceHash;
    }

    function isCompatible(
        address expectedReceiver,
        address expectedSplitter,
        Admission memory admission,
        Observation memory observation
    ) internal pure returns (bool) {
        if (expectedReceiver == address(0) || expectedSplitter == address(0)) return false;
        if (
            admission.receiverCodeHash == bytes32(0) || admission.canonicalBaseUsdc == address(0)
                || admission.provenanceHash == bytes32(0)
        ) return false;

        return observation.initialized && observation.receiver == expectedReceiver
            && observation.receiverCodeHash == admission.receiverCodeHash && observation.splitter == expectedSplitter
            && observation.usdc == admission.canonicalBaseUsdc && observation.referralBps == 0
            && observation.provenanceHash == admission.provenanceHash;
    }
}
