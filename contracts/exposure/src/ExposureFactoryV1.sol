// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Ownable} from "solady/auth/Ownable.sol";

import {ExposureSeriesV1} from "./ExposureSeriesV1.sol";

/// @title ExposureFactoryV1
/// @notice The list of exposure series Autolaunch offers. Only the owner (the Regent governance Safe)
///         creates series, so each stock, oracle feed and calendar is reviewed before it is listed.
///         The owner has no power over a series once created: a series has no owner at all.
contract ExposureFactoryV1 is Ownable {
    mapping(address series => bool) public isSeries;

    event SeriesCreated(
        address indexed series,
        address indexed asset,
        address overnight,
        address session,
        address oracle,
        bytes32 feedId,
        bytes32 termsHash
    );

    constructor(address owner_) {
        _initializeOwner(owner_);
    }

    function createSeries(ExposureSeriesV1.Terms calldata terms) external onlyOwner returns (ExposureSeriesV1 series) {
        series = new ExposureSeriesV1(terms);
        isSeries[address(series)] = true;
        emit SeriesCreated(
            address(series),
            terms.asset,
            address(series.overnight()),
            address(series.session()),
            terms.oracle,
            terms.feedId,
            terms.termsHash
        );
    }
}
