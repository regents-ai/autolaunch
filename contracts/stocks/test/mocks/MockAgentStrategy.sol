// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {IAgentStrategyMinimal} from "../../src/interfaces/IAgentStrategyMinimal.sol";

/// @notice The two provenance reads of the Agent strategy, with settable records, so unit tests can
///         present authentic and inauthentic splitters. The fork suite reads the real strategy.
contract MockAgentStrategy is IAgentStrategyMinimal {
    mapping(address subject => address auction) public override auctionOfSubject;
    mapping(address auction => Distribution) private _distributions;

    function record(address subject, address auction, address splitter) external {
        auctionOfSubject[subject] = auction;
        Distribution storage d = _distributions[auction];
        d.lifecycle = Lifecycle.Graduated;
        d.subject = subject;
        d.splitter = splitter;
    }

    function distribution(address auction) external view override returns (Distribution memory) {
        return _distributions[auction];
    }
}
