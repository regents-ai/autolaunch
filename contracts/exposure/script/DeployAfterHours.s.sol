// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";

import {ChainlinkPrintOracleV2, IAggregatorProxy} from "../src/ChainlinkPrintOracleV2.sol";
import {ExposureFactoryV1} from "../src/ExposureFactoryV1.sol";
import {ExposureSeriesV1} from "../src/ExposureSeriesV1.sol";

/// @title DeployAfterHours
/// @notice After-hours Exposure on Base: `run` deploys the AMZN Chainlink print oracle, pinned to
///         the feed's current phase; `firstSeriesCall` and `mondaySeriesCall` print the Safe's
///         `createSeries` call to the deployed factory for the first AMZNc series (Fri 30 Oct to Fri
///         6 Nov 2026 closes) and the public one (Mon 2 Nov to Fri 6 Nov 2026 closes).
/// @dev The factory (owned by the Governance and Regent Safe) was deployed on 28 Oct 2026 at `FACTORY`.
///      Deploying is a protected action: broadcast only on Sean's go naming it. The terms hash is
///      keccak256 of the approved terms file's exact bytes
///      (platform/priv/exposure_terms/0x5f67343b39277939aea7613c578fa3931b8b89da7a65eb36dd7217c81a5a2e8f.md).
contract DeployAfterHours is Script {
    address internal constant SAFE = 0x9fa152B0EAdbFe9A7c5C0a8e1D11784f22669a3e;
    address public constant FACTORY = 0xAECE72c94CaC843f9Ecd54aC6Ca833bF4CFED048;
    address internal constant AMZNC = 0xb200000000000000000000d9192b6B456483C2E8;
    address internal constant AMZN_FEED = 0x06A8E4b3aBB3B7543d8396FB2B763d22820cB295;
    /// @notice 0.4 AMZNc (8 decimals), about $100: the first series is a live demo (Sean, 28 Oct 2026).
    uint256 internal constant DEPOSIT_CAP = 0.4e8;
    /// @notice 40 AMZNc (8 decimals), about $10,000: the first public series (Sean, 29 Oct 2026).
    uint256 internal constant MONDAY_DEPOSIT_CAP = 40e8;
    /// @notice A week, so the prices can be recorded in two sittings: Friday's close on the evening
    ///         itself, and the rest after the last close.
    uint64 internal constant MAX_REPORT_DELAY = 7 days;

    error WrongChain(uint256 chainId);

    function run() external returns (ChainlinkPrintOracleV2 oracle) {
        if (block.chainid != 8453) revert WrongChain(block.chainid);
        vm.startBroadcast();
        oracle = new ChainlinkPrintOracleV2(AMZN_FEED);
        vm.stopBroadcast();
        console.log("ChainlinkPrintOracleV2", address(oracle));
        console.log("pinned phase", oracle.phase());
    }

    /// @notice The calldata the Safe sends to `factory` to create the first series.
    function firstSeriesCall(address oracle, bytes32 termsHash) external view returns (bytes memory data) {
        checkOracle(oracle);
        data = abi.encodeCall(ExposureFactoryV1.createSeries, (firstSeriesTerms(oracle, termsHash)));
        console.logBytes(data);
    }

    /// @notice The calldata the Safe sends to `factory` to create the Monday series.
    function mondaySeriesCall(address oracle, bytes32 termsHash) external view returns (bytes memory data) {
        checkOracle(oracle);
        data = abi.encodeCall(ExposureFactoryV1.createSeries, (mondaySeriesTerms(oracle, termsHash)));
        console.logBytes(data);
    }

    /// @dev The oracle must be on the phase the proxy serves now, and the recording window must leave
    ///      room after the oracle's one-hour wait.
    function checkOracle(address oracle) internal view {
        ChainlinkPrintOracleV2 printOracle = ChainlinkPrintOracleV2(oracle);
        require(printOracle.phase() == IAggregatorProxy(AMZN_FEED).phaseId(), "oracle is on a retiring feed phase");
        require(MAX_REPORT_DELAY > printOracle.RECORD_DELAY(), "recording window shorter than the oracle's wait");
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
            feedId: ChainlinkPrintOracleV2(oracle).feedId(),
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

    /// @notice Monday 2 Nov 2026 16:00 New York (21:00 UTC), then each 09:30 and 16:00 New York from
    ///         Tuesday 3 to Friday 6 November (14:30 and 21:00 UTC). No market holidays that week.
    function mondaySeriesTerms(address oracle, bytes32 termsHash)
        public
        view
        returns (ExposureSeriesV1.Terms memory terms)
    {
        uint64[] memory boundaries = new uint64[](9);
        boundaries[0] = 1793653200; // Mon 2 Nov 21:00 UTC
        for (uint64 day; day < 4; ++day) {
            uint64 open = 1793716200 + day * 1 days; // Tue 3 Nov 14:30 UTC
            boundaries[1 + 2 * day] = open;
            boundaries[2 + 2 * day] = open + 6.5 hours;
        }
        terms = ExposureSeriesV1.Terms({
            asset: AMZNC,
            oracle: oracle,
            feedId: ChainlinkPrintOracleV2(oracle).feedId(),
            termsHash: termsHash,
            maxReportDelay: MAX_REPORT_DELAY,
            depositCap: MONDAY_DEPOSIT_CAP,
            boundaries: boundaries,
            overnightName: "AMZNc After-hours 2 to 6 Nov 2026",
            overnightSymbol: "AMZNc-AH-1102",
            sessionName: "AMZNc Market-hours 2 to 6 Nov 2026",
            sessionSymbol: "AMZNc-MH-1102"
        });
    }
}
