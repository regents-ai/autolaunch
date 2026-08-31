// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {CctpRevenueInboxV1} from "../../src/CctpRevenueInboxV1.sol";
import {RevenueInboxFactoryV1} from "../../src/RevenueInboxFactoryV1.sol";

contract SweepActor {
    function sweep(CctpRevenueInboxV1 inbox, uint256 maxFee) external returns (uint256) {
        return inbox.sweep(maxFee);
    }

    function trySweep(CctpRevenueInboxV1 inbox, uint256 maxFee) external returns (bool success, bytes memory data) {
        return address(inbox).call(abi.encodeCall(inbox.sweep, (maxFee)));
    }
}

contract FactoryActor {
    function deploy(RevenueInboxFactoryV1 factory, address baseReceiver, address baseSplitter)
        external
        returns (CctpRevenueInboxV1)
    {
        return factory.deploy(baseReceiver, baseSplitter);
    }
}

contract MockBaseReceiver {
    address public splitter;
    address public usdc;
    uint16 public referralBps;
    bool public initialized;

    constructor(address splitter_, address usdc_, uint16 referralBps_, bool initialized_) {
        splitter = splitter_;
        usdc = usdc_;
        referralBps = referralBps_;
        initialized = initialized_;
    }
}
