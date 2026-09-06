// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseCompatibilityV1} from "../../src/libraries/BaseCompatibilityV1.sol";

contract BaseCompatibilityHarness {
    function isCompatible(
        address expectedReceiver,
        address expectedSplitter,
        BaseCompatibilityV1.Admission memory admission,
        BaseCompatibilityV1.Observation memory observation
    ) external pure returns (bool) {
        return BaseCompatibilityV1.isCompatible(expectedReceiver, expectedSplitter, admission, observation);
    }
}
