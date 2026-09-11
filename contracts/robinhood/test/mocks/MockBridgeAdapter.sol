// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {MockERC20} from "autolaunch-stocks-test/mocks/MockERC20.sol";
import {IRobinhoodBridgeAdapterV1} from "../../src/interfaces/IRobinhoodBridgeAdapterV1.sol";
import {RobinhoodPreset} from "../../src/RobinhoodPreset.sol";

/// @notice A reviewed bridge adapter's surface: pulls exactly the approved USDG from the inbox and
///         records the batch it was told about. Switches reproduce the failure shapes the inbox refuses.
contract MockBridgeAdapter is IRobinhoodBridgeAdapterV1 {
    address public immutable override usdg;
    uint256 public immutable override destinationChainId;

    bool public pullsPartially;
    bool public wrongChain;

    uint256 public calls;
    uint256 public lastAmount;
    address public lastDestination;
    uint256 public lastMinimumOut;
    uint256 public lastDeadline;
    uint256 public lastBatchId;

    constructor(address usdg_, bool wrongChain_) {
        usdg = usdg_;
        destinationChainId = wrongChain_ ? 1 : RobinhoodPreset.BASE_CHAIN_ID;
    }

    function setPullsPartially(bool value) external {
        pullsPartially = value;
    }

    function bridge(
        uint256 amountUsdg,
        address baseDestination,
        uint256 minimumUsdcOut,
        uint256 deadline,
        uint256 batchId
    ) external override returns (bytes32 transferRef) {
        uint256 pull = pullsPartially ? amountUsdg / 2 : amountUsdg;
        MockERC20(usdg).transferFrom(msg.sender, address(this), pull);
        calls += 1;
        lastAmount = amountUsdg;
        lastDestination = baseDestination;
        lastMinimumOut = minimumUsdcOut;
        lastDeadline = deadline;
        lastBatchId = batchId;
        transferRef = keccak256(abi.encode(batchId, amountUsdg, baseDestination));
    }
}
