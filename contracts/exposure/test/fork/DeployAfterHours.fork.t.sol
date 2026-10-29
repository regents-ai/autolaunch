// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {AfterHoursDemo} from "../../script/AfterHoursDemo.s.sol";
import {DeployAfterHours} from "../../script/DeployAfterHours.s.sol";
import {ChainlinkPrintOracleV2, IAggregatorProxy} from "../../src/ChainlinkPrintOracleV2.sol";
import {ExposureFactoryV1} from "../../src/ExposureFactoryV1.sol";
import {ExposureSeriesV1} from "../../src/ExposureSeriesV1.sol";

/// @notice Rehearses the $100 live demo on a Base fork: the deploy script's contracts, the Safe's
///         `createSeries` call exactly as the script prints it, the Friday sitting (record the first
///         close, mint the demo pair, open both Aerodrome pools) and the closing sitting (record the
///         other ten prints). The fork ends on 28 Oct, so the feed's rounds for the series' week are
///         stood in through the proxy (one round a minute before each open and close, on the pinned
///         phase); everything else is the real feed, token, Safe and Aerodrome.
interface IAerodromeRouterFork {
    function addLiquidity(address, address, bool, uint256, uint256, uint256, uint256, address, uint256)
        external
        returns (uint256, uint256, uint256);
}

contract DeployAfterHoursForkTest is Test {
    address internal constant SAFE = 0x9fa152B0EAdbFe9A7c5C0a8e1D11784f22669a3e;
    address internal constant AMZNC = 0xb200000000000000000000d9192b6B456483C2E8;
    address internal constant AMZN_FEED = 0x06A8E4b3aBB3B7543d8396FB2B763d22820cB295;
    address internal constant AMZNC_POOL = 0x532e0F46d1e528507FC9454d5847C231f23bDDf6;
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant AERODROME_FACTORY = 0x420DD381b31aEf6683db6B902084cB0FFECe40Da;
    address internal constant AERODROME_ROUTER = 0xcF77a3Ba9A5CA399B7c97c74d54e5b1Beb874E43;

    function test_fork_firstSeriesRehearsal() public {
        DeployAfterHours script = new DeployAfterHours();
        ChainlinkPrintOracleV2 oracle = script.run();
        assertEq(oracle.phase(), 2);
        // The fork predates the factory's deployment (28 Oct, block 53,219,733), so the same code is
        // placed at its address here; the live factory equals the build byte for byte.
        deployCodeTo("ExposureFactoryV1.sol:ExposureFactoryV1", abi.encode(SAFE), script.FACTORY());
        ExposureFactoryV1 factory = ExposureFactoryV1(script.FACTORY());
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

        // The week's feed rounds, continuing the pinned phase after its last real round.
        uint64 last = demo.roundInForce(oracle, uint64(block.timestamp));
        uint256 fridayClose = _lastRealAnswer(oracle, last);
        int256[10] memory path = [int256(255e8), 253e8, 256e8, 257e8, 254e8, 255e8, 258e8, 256e8, 259e8, 257e8];
        for (uint64 i; i < 10; ++i) {
            _standInRound(oracle, last + 1 + i, path[i], expected[i + 1] - 1 minutes);
        }

        // Friday sitting, an hour after the close: the first print is the last real round.
        vm.warp(expected[0] + 1 hours);
        demo.recordAndSettle(series);
        assertEq(series.settled(), 1);
        assertEq(series.lastPriceWad(), fridayClose * 1e10);
        assertEq(uint8(series.status()), uint8(ExposureSeriesV1.Status.Active));

        // The pool transactions carry a deadline an hour after simulation: landing 50 minutes late
        // still works, landing after the deadline is refused.
        uint256 deadline = block.timestamp + 1 hours;
        vm.warp(block.timestamp + 50 minutes);
        demo.seedBy(series, deadline);
        address overnightLeg = address(series.overnight());
        vm.warp(deadline + 1);
        vm.prank(signer);
        vm.expectRevert(bytes4(keccak256("Expired()")));
        IAerodromeRouterFork(AERODROME_ROUTER).addLiquidity(overnightLeg, USDC, false, 1, 1, 0, 0, signer, deadline);
        vm.warp(deadline - 1 hours + 50 minutes);
        assertEq(IERC20(AMZNC).balanceOf(address(series)), 0.2e8);
        uint256 legUsdc = 0.2e8 * (fridayClose * 1e10 / 2) / 1e8 / 1e12;
        _assertPool(address(series.overnight()), legUsdc);
        _assertPool(address(series.session()), legUsdc);
        assertEq(IERC20(USDC).balanceOf(signer), 55e6 - 2 * legUsdc);

        // Closing sitting, after next Friday's close: the other ten prints in one go.
        vm.warp(expected[10] + 1 hours);
        demo.recordAndSettle(series);
        assertEq(series.settled(), 11);
        assertEq(uint8(series.endReason()), uint8(ExposureSeriesV1.EndReason.Maturity));
        assertEq(series.lastPriceWad(), 257e18);
        assertEq(series.overnightLedgerWad() + series.sessionLedgerWad(), 257e18);
        assertEq(oracle.sourceOf(expected[10], false).roundId, oracle.roundIdOf(last + 10));
    }

    function _lastRealAnswer(ChainlinkPrintOracleV2 oracle, uint64 round) internal view returns (uint256) {
        (, int256 answer,,,) = IAggregatorProxy(AMZN_FEED).getRoundData(oracle.roundIdOf(round));
        return uint256(answer);
    }

    function _standInRound(ChainlinkPrintOracleV2 oracle, uint64 round, int256 answer, uint256 updatedAt) internal {
        uint80 id = oracle.roundIdOf(round);
        vm.mockCall(
            AMZN_FEED,
            abi.encodeWithSelector(IAggregatorProxy.getRoundData.selector, id),
            abi.encode(id, answer, updatedAt, updatedAt, id)
        );
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
