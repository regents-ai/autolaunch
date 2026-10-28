// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {DeployAfterHours} from "../../script/DeployAfterHours.s.sol";
import {ChainlinkPrintOracleV1, IAggregatorV3} from "../../src/ChainlinkPrintOracleV1.sol";
import {ExposureFactoryV1} from "../../src/ExposureFactoryV1.sol";
import {ExposureSeriesV1} from "../../src/ExposureSeriesV1.sol";

/// @notice Rehearses the first After-hours series on a Base fork: the deploy script's contracts, the
///         Safe's `createSeries` call exactly as the script prints it, then the whole week run through
///         with the feed's value in force at each moment (the fork has no later rounds, so every
///         print is the last real one and no move is counted).
contract DeployAfterHoursForkTest is Test {
    address internal constant SAFE = 0x9fa152B0EAdbFe9A7c5C0a8e1D11784f22669a3e;
    address internal constant AMZNC = 0xb200000000000000000000d9192b6B456483C2E8;
    address internal constant AMZN_FEED = 0x06A8E4b3aBB3B7543d8396FB2B763d22820cB295;
    address internal constant AMZNC_POOL = 0x532e0F46d1e528507FC9454d5847C231f23bDDf6;

    function test_fork_firstSeriesRehearsal() public {
        DeployAfterHours script = new DeployAfterHours();
        (ChainlinkPrintOracleV1 oracle, ExposureFactoryV1 factory) = script.run();
        assertEq(factory.owner(), SAFE);
        assertEq(address(oracle.feed()), AMZN_FEED);

        bytes32 termsHash = keccak256("approved terms");
        bytes memory data = script.firstSeriesCall(address(oracle), termsHash);
        vm.prank(SAFE);
        (bool ok, bytes memory result) = address(factory).call(data);
        assertTrue(ok);
        ExposureSeriesV1 series = abi.decode(result, (ExposureSeriesV1));
        assertTrue(factory.isSeries(address(series)));
        assertEq(series.termsHash(), termsHash);
        assertEq(series.depositCap(), 40e8);
        assertEq(series.session().symbol(), "AMZNc-MH-1106");

        // New York 16:00 EDT on Fri 30 Oct, then 09:30 and 16:00 EST Mon 2 to Fri 6 Nov.
        uint64[11] memory expected = [
            uint64(1793390400),
            1793629800,
            1793653200,
            1793716200,
            1793739600,
            1793802600,
            1793826000,
            1793889000,
            1793912400,
            1793975400,
            1793998800
        ];
        assertEq(series.boundaryCount(), 11);
        for (uint256 i; i < 11; ++i) {
            assertEq(series.boundaries(i), expected[i]);
        }

        address holder = makeAddr("holder");
        vm.prank(AMZNC_POOL);
        IERC20(AMZNC).transfer(holder, 41e8);
        vm.prank(holder);
        IERC20(AMZNC).approve(address(series), type(uint256).max);

        (uint80 latest, int256 answer,,,) = IAggregatorV3(AMZN_FEED).latestRoundData();
        for (uint256 i; i < 11; ++i) {
            vm.warp(expected[i] + 1 hours);
            oracle.record(expected[i], i % 2 == 1, latest);
            series.settle();
            if (i == 0) {
                vm.prank(holder);
                vm.expectRevert(abi.encodeWithSelector(ExposureSeriesV1.CapReached.selector, 40e8));
                series.mint(41e8);
                vm.prank(holder);
                series.mint(40e8);
            }
        }
        assertEq(series.lastPriceWad(), uint256(answer) * 1e10);
        assertEq(series.overnightLedgerWad(), uint256(answer) * 1e10 / 2);
        assertEq(uint8(series.endReason()), uint8(ExposureSeriesV1.EndReason.Maturity));
        vm.prank(holder);
        assertEq(series.redeem(40e8, 40e8), 40e8);
    }
}
