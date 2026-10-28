// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";

import {ChainlinkPrintOracleV1} from "../src/ChainlinkPrintOracleV1.sol";
import {ExposureFactoryV1} from "../src/ExposureFactoryV1.sol";
import {ExposureSeriesV1} from "../src/ExposureSeriesV1.sol";

/// @title DeployAfterHours
/// @notice After-hours Exposure on Base: `run` deploys the AMZN Chainlink print oracle and the series
///         factory owned by the Governance and Regent Safe; `firstSeriesCall` prints the Safe's
///         `createSeries` call for the first AMZNc series (Fri 30 Oct to Fri 6 Nov 2026 closes).
/// @dev Deploying is a protected action: broadcast only on Sean's go naming it. The terms hash is
///      keccak256 of the approved terms file's exact bytes
///      (platform/docs/after-hours-terms-amznc-2026-11-06.md), passed in once that wording is final.
contract DeployAfterHours is Script {
    address internal constant SAFE = 0x9fa152B0EAdbFe9A7c5C0a8e1D11784f22669a3e;
    address internal constant AMZNC = 0xb200000000000000000000d9192b6B456483C2E8;
    address internal constant AMZN_FEED = 0x06A8E4b3aBB3B7543d8396FB2B763d22820cB295;
    /// @notice 40 AMZNc (8 decimals), about $10,000.
    uint256 internal constant DEPOSIT_CAP = 40e8;
    uint64 internal constant MAX_REPORT_DELAY = 2 days;

    error WrongChain(uint256 chainId);

    function run() external returns (ChainlinkPrintOracleV1 oracle, ExposureFactoryV1 factory) {
        if (block.chainid != 8453) revert WrongChain(block.chainid);
        vm.startBroadcast();
        oracle = new ChainlinkPrintOracleV1(AMZN_FEED);
        factory = new ExposureFactoryV1(SAFE);
        vm.stopBroadcast();
        console.log("ChainlinkPrintOracleV1", address(oracle));
        console.log("ExposureFactoryV1", address(factory));
    }

    /// @notice The calldata the Safe sends to `factory` to create the first series.
    function firstSeriesCall(address oracle, bytes32 termsHash) external view returns (bytes memory data) {
        data = abi.encodeCall(ExposureFactoryV1.createSeries, (firstSeriesTerms(oracle, termsHash)));
        console.logBytes(data);
    }

    /// @notice Friday 30 Oct 2026 16:00 New York, then each 09:30 and 16:00 New York from Monday 2 to
    ///         Friday 6 November. US clocks go back on Sunday 1 November, so the first close is 20:00
    ///         UTC and the rest are 14:30 and 21:00 UTC. No market holidays that week.
    function firstSeriesTerms(address oracle, bytes32 termsHash)
        public
        view
        returns (ExposureSeriesV1.Terms memory terms)
    {
        uint64[] memory boundaries = new uint64[](11);
        boundaries[0] = 1793390400; // Fri 30 Oct 20:00 UTC
        for (uint64 day; day < 5; ++day) {
            uint64 monday = 1793629800 + day * 1 days; // Mon 2 Nov 14:30 UTC
            boundaries[1 + 2 * day] = monday;
            boundaries[2 + 2 * day] = monday + 6.5 hours;
        }
        terms = ExposureSeriesV1.Terms({
            asset: AMZNC,
            oracle: oracle,
            feedId: ChainlinkPrintOracleV1(oracle).feedId(),
            termsHash: termsHash,
            maxReportDelay: MAX_REPORT_DELAY,
            depositCap: DEPOSIT_CAP,
            boundaries: boundaries,
            overnightName: "AMZNc After-hours to 6 Nov 2026",
            overnightSymbol: "AMZNc-AH-1106",
            sessionName: "AMZNc Market-hours to 6 Nov 2026",
            sessionSymbol: "AMZNc-MH-1106"
        });
    }
}
