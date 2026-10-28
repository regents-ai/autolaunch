// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {AfterHoursDemo} from "../../script/AfterHoursDemo.s.sol";
import {DeployAfterHours} from "../../script/DeployAfterHours.s.sol";
import {ChainlinkPrintOracleV1, IAggregatorV3} from "../../src/ChainlinkPrintOracleV1.sol";
import {ExposureFactoryV1} from "../../src/ExposureFactoryV1.sol";
import {ExposureSeriesV1} from "../../src/ExposureSeriesV1.sol";

/// @notice Rehearses the $100 live demo on a Base fork: the deploy script's contracts, the Safe's
///         `createSeries` call exactly as the script prints it, the Friday sitting (record the first
///         close, mint the demo pair, open both Aerodrome pools) and the closing sitting (record the
///         other ten prints). The fork has no later feed rounds, so every print is the last real one
///         and no move is counted.
contract DeployAfterHoursForkTest is Test {
    address internal constant SAFE = 0x9fa152B0EAdbFe9A7c5C0a8e1D11784f22669a3e;
    address internal constant AMZNC = 0xb200000000000000000000d9192b6B456483C2E8;
    address internal constant AMZN_FEED = 0x06A8E4b3aBB3B7543d8396FB2B763d22820cB295;
    address internal constant AMZNC_POOL = 0x532e0F46d1e528507FC9454d5847C231f23bDDf6;
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant AERODROME_FACTORY = 0x420DD381b31aEf6683db6B902084cB0FFECe40Da;

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
        assertEq(series.depositCap(), 0.4e8);
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

        // The signer the demo scripts broadcast from (Foundry's default sender in a test).
        address signer = DEFAULT_SENDER;
        vm.prank(AMZNC_POOL);
        IERC20(AMZNC).transfer(signer, 0.2e8);
        deal(USDC, signer, 55e6);
        AfterHoursDemo demo = new AfterHoursDemo();

        // Friday sitting, an hour after the close.
        vm.warp(expected[0] + 1 hours);
        demo.recordAndSettle(series);
        assertEq(series.settled(), 1);
        assertEq(uint8(series.status()), uint8(ExposureSeriesV1.Status.Active));
        demo.seed(series);
        assertEq(IERC20(AMZNC).balanceOf(address(series)), 0.2e8);
        (, int256 answer,,,) = IAggregatorV3(AMZN_FEED).latestRoundData();
        uint256 legUsdc = 0.2e8 * (uint256(answer) * 1e10 / 2) / 1e8 / 1e12;
        _assertPool(address(series.overnight()), legUsdc);
        _assertPool(address(series.session()), legUsdc);
        assertEq(IERC20(USDC).balanceOf(signer), 55e6 - 2 * legUsdc);

        // Closing sitting, after next Friday's close: the other ten prints in one go.
        vm.warp(expected[10] + 1 hours);
        demo.recordAndSettle(series);
        assertEq(series.settled(), 11);
        assertEq(uint8(series.endReason()), uint8(ExposureSeriesV1.EndReason.Maturity));
        assertEq(series.lastPriceWad(), uint256(answer) * 1e10);
    }

    function _assertPool(address leg, uint256 usdc) internal view {
        (bool ok, bytes memory data) =
            AERODROME_FACTORY.staticcall(abi.encodeWithSignature("getPool(address,address,bool)", leg, USDC, false));
        address pool = abi.decode(data, (address));
        assertTrue(ok && pool != address(0), "pool opened");
        assertEq(IERC20(leg).balanceOf(pool), 0.2e8);
        assertEq(IERC20(USDC).balanceOf(pool), usdc);
    }
}
