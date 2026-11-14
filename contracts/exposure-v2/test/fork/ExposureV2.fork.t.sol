// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

import {ExposureFactoryV2} from "../../src/ExposureFactoryV2.sol";
import {ExposureSeriesV2} from "../../src/ExposureSeriesV2.sol";
import {IAggregatorProxy} from "../../src/interfaces/IExposureV2.sol";
import {DeployExposureV2} from "../../script/DeployExposureV2.s.sol";

interface IB20AssetFork {
    function multiplier() external view returns (uint256);
    function grantRole(bytes32 role, address account) external;
    function updateMultiplier(uint256 newMultiplier) external;
    function pause(uint8[] calldata features) external;
    function unpause(uint8[] calldata features) external;
}

/// @notice Forge's gas record of the last call (its newer name; this forge-std predates it).
interface IVmFrameGas {
    struct Gas {
        uint64 gasLimit;
        uint64 gasTotalUsed;
        uint64 gasMemoryUsed;
        int64 gasRefunded;
        uint64 gasRemaining;
    }

    function lastFrameGas() external view returns (Gas memory);
}

interface IPolicyRegistryFork {
    function updateBlocklist(uint64 policyId, bool blocked, address[] calldata accounts) external;
}

/// @notice Reads one round through the proxy and keeps the gas it took. It is called as its own
///         transaction, so the proxy and the aggregator start cold, as in a real settle.
contract ProbeMeter {
    uint256 public used;

    function measure(address feed, uint80 roundId) external {
        uint256 start = gasleft();
        IAggregatorProxy(feed).getRoundData(roundId);
        used = start - gasleft();
    }
}

/// @notice Version 2 on the real AMZNc B20 token and the real Coinbase AMZN Chainlink feed, replaying
///         the weeks of 26-30 October, 2-6 November (the clocks went back on 1 November) and 9-13
///         November 2026 from the feed's own history, with the factory exactly as the deploy script
///         builds it. Expected prices come from the feed's rounds 400-832 read at the fork block and
///         run through the same rules in Python.
///
///         FOUNDRY_PROFILE=fork forge test --network base --fork-url <Base RPC> \
///             --fork-block-number 57228000 --isolate
///
///         The block is Saturday 14 November 2026 06:00 UTC. Tests go back in time to open a past
///         week's series (only the current week opens) and forward again; the feed's history is
///         fixed, so this replays exactly what the series would have done. `--isolate` makes every
///         call its own transaction so the gas figures are real. The issuer's accounts are
///         impersonated only to stage a split, a blocklisting and a transfer pause.
contract ExposureV2ForkTest is Test {
    address internal constant AMZNC = 0xb200000000000000000000d9192b6B456483C2E8;
    address internal constant AMZN_FEED = 0x06A8E4b3aBB3B7543d8396FB2B763d22820cB295;
    /// The deepest AMZNc/USDC pool, used only as a holder to take stock from.
    address internal constant AMZNC_POOL = 0x532e0F46d1e528507FC9454d5847C231f23bDDf6;
    address internal constant TOKEN_ADMIN = 0x38467bE00970af18076fd08F6b4Cf38Ba91572B1;
    address internal constant POLICY_ADMIN = 0xEC0F05C174e54FBf0Fe16ad930a8AFEbCe612812;
    address internal constant POLICY_REGISTRY = 0x8453000000000000000000000000000000000002;
    uint64 internal constant TRANSFER_POLICY = 5;
    bytes32 internal constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 internal constant PAUSE_ROLE = keccak256("PAUSE_ROLE");
    bytes32 internal constant UNPAUSE_ROLE = keccak256("UNPAUSE_ROLE");
    uint8 internal constant TRANSFER = 0;
    uint256 internal constant TOKEN = 1e8;
    uint256 internal constant OCT_26 = 2965;
    uint256 internal constant NOV_2 = 2966;
    uint256 internal constant NOV_9 = 2967;

    IERC20 internal stock = IERC20(AMZNC);
    DeployExposureV2 internal deployer = new DeployExposureV2();
    ExposureFactoryV2 internal factory;
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal issuerOps = makeAddr("issuerOps");

    function setUp() public {
        factory = deployer.build(keccak256("AMZNc after-hours exposure terms v2"));

        vm.startPrank(AMZNC_POOL);
        stock.transfer(alice, 40 * TOKEN);
        stock.transfer(bob, 40 * TOKEN);
        vm.stopPrank();
        vm.prank(alice);
        stock.approve(address(factory), type(uint256).max);
        vm.prank(bob);
        stock.approve(address(factory), type(uint256).max);

        vm.startPrank(TOKEN_ADMIN);
        IB20AssetFork(AMZNC).grantRole(OPERATOR_ROLE, issuerOps);
        IB20AssetFork(AMZNC).grantRole(PAUSE_ROLE, issuerOps);
        IB20AssetFork(AMZNC).grantRole(UNPAUSE_ROLE, issuerOps);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------------------------------
    // The feed's history, from Python over rounds 400-832
    // ---------------------------------------------------------------------------------------------

    /// @dev The answer and round in force at each boundary of the three weeks.
    function _history(uint256 week) internal pure returns (uint256[11] memory answer, uint64[11] memory round) {
        if (week == OCT_26) {
            answer = [
                uint256(24793375000),
                25039085000,
                24898255000,
                25026999999,
                25428650000,
                25289500000,
                25430625000,
                24690500000,
                24457749999,
                23199160000,
                24027125000
            ];
            round = [uint64(463), 465, 472, 473, 478, 479, 482, 499, 512, 587, 608];
        } else if (week == NOV_2) {
            answer = [
                uint256(24027125000),
                24230000000,
                24533249999,
                24789520000,
                25129252500,
                26511600000,
                26584160000,
                27147080000,
                25937125000,
                25854000000,
                25989500000
            ];
            round = [uint64(608), 612, 625, 631, 640, 667, 683, 693, 717, 738, 747];
        } else {
            answer = [
                uint256(25989500000),
                26905500000,
                26743500000,
                26613500000,
                27146000000,
                27415500000,
                26667500000,
                26843400000,
                26845675000,
                26993500000,
                26692499999
            ];
            round = [uint64(747), 762, 774, 779, 788, 792, 797, 812, 824, 827, 831];
        }
    }

    /// @dev The final ledgers of each week: price, then OVERNIGHT.
    function _final(uint256 week) internal pure returns (uint256 price, uint256 night) {
        if (week == OCT_26) return (240.27125e18, 106.332775e18);
        if (week == NOV_2) return (259.895e18, 143.34850001e18);
        return (266.92499999e18, 143.73975e18);
    }

    // ---------------------------------------------------------------------------------------------
    // Replays
    // ---------------------------------------------------------------------------------------------

    function test_fork_threeWeeksOnTheRealFeed() public {
        uint256[3] memory weeks_ = [OCT_26, NOV_2, NOV_9];
        for (uint256 w; w < weeks_.length; ++w) {
            uint256 week = weeks_[w];
            ExposureSeriesV2 series = _openAndDeposit(week, alice, TOKEN);
            (uint256[11] memory answer, uint64[11] memory round) = _history(week);
            for (uint256 i; i < 11; ++i) {
                _warpTo(uint256(series.boundaries(i)) + 1 hours);
                series.settle();
                assertEq(series.settled(), i + 1);
                assertEq(series.lastPriceWad(), answer[i] * 1e10, "price in force");
                assertEq(series.lastRound(), round[i], "round in force");
            }
            (uint256 price, uint256 night) = _final(week);
            assertEq(uint8(series.endReason()), uint8(ExposureSeriesV2.EndReason.Maturity));
            assertEq(series.lastPriceWad(), price);
            assertEq(series.overnightLedgerWad(), night);

            // The legs part ways and each redeems on its own.
            IERC20 session = IERC20(address(series.session()));
            vm.prank(alice);
            session.transfer(bob, TOKEN);
            uint256 bobBefore = stock.balanceOf(bob);
            vm.prank(alice);
            assertEq(series.redeem(TOKEN, 0), TOKEN * night / price);
            vm.prank(bob);
            assertEq(series.redeem(0, TOKEN), TOKEN * (price - night) / price);
            assertEq(stock.balanceOf(bob) - bobBefore, TOKEN * (price - night) / price);
            // Consecutive weeks join: this one matured at the price the next one starts from.
            if (w + 1 < weeks_.length) assertEq(series.maturityAt(), factory.startOf(weeks_[w + 1]));
        }
    }

    function test_fork_calendarAcrossTheClockChange() public view {
        assertEq(factory.boundariesOf(NOV_2)[0], 1793390400, "Fri 30 Oct 16:00 EDT = 20:00 UTC");
        assertEq(factory.boundariesOf(NOV_2)[1], 1793629800, "Mon 2 Nov 09:30 EST = 14:30 UTC");
        assertEq(factory.boundariesOf(NOV_2)[10], 1793998800, "Fri 6 Nov 16:00 EST = 21:00 UTC");
        assertEq(factory.owner(), 0x9fa152B0EAdbFe9A7c5C0a8e1D11784f22669a3e);
        assertEq(factory.template().phase, 2);
        assertEq(factory.currentWeek(), 2968, "at the fork block the 16-20 Nov series is current");
    }

    /// Nobody touches the October series after the first deposit until a month later. One redemption
    /// applies all ten boundaries, at the same prices as settling each one on time.
    function test_fork_monthOfSilence() public {
        ExposureSeriesV2 series = _openAndDeposit(OCT_26, alice, 2 * TOKEN);
        vm.warp(uint256(series.boundaries(0)) + 30 days);
        vm.prank(alice);
        uint256 paid = series.redeem(2 * TOKEN, 0);
        console.log("gas: single-leg redeem applying 10 boundaries after 30 days", _lastGas());
        (uint256 price, uint256 night) = _final(OCT_26);
        assertEq(series.settled(), 11);
        assertEq(series.overnightLedgerWad(), night);
        assertEq(paid, 2 * TOKEN * night / price);
    }

    /// Two factories, one settled after every boundary, one never until a redemption at the end.
    function test_fork_settleTimingDoesNotMatter() public {
        ExposureFactoryV2 other = deployer.build(keccak256("AMZNc after-hours exposure terms v2"));
        vm.prank(bob);
        stock.approve(address(other), type(uint256).max);
        uint256[2] memory weeks_ = [NOV_2, NOV_9];
        for (uint256 w; w < weeks_.length; ++w) {
            ExposureSeriesV2 eager = _openAndDeposit(weeks_[w], alice, TOKEN);
            vm.prank(bob);
            ExposureSeriesV2 lazy = other.deposit(weeks_[w], TOKEN);
            for (uint256 i = 1; i < 11; ++i) {
                _warpTo(uint256(eager.boundaries(i)) + 1 hours + i * 7 minutes);
                eager.settle();
            }
            vm.prank(bob);
            lazy.redeem(TOKEN, 0);
            assertEq(lazy.lastPriceWad(), eager.lastPriceWad());
            assertEq(lazy.overnightLedgerWad(), eager.overnightLedgerWad());
            assertEq(lazy.lastRound(), eager.lastRound());
            assertEq(lazy.settled(), eager.settled());
        }
    }

    // ---------------------------------------------------------------------------------------------
    // The issuer
    // ---------------------------------------------------------------------------------------------

    function test_fork_blocklistedHolderWaitsUntilUnblocked() public {
        ExposureSeriesV2 series = _openAndDeposit(NOV_9, bob, 2 * TOKEN);
        _blocklist(bob, true);
        vm.prank(bob);
        vm.expectRevert(SafeTransferLib.TransferFailed.selector);
        series.redeem(TOKEN, TOKEN);
        assertEq(series.overnight().balanceOf(bob), 2 * TOKEN, "the refused payout burned nothing");
        // A blocklisted account cannot deposit either: the factory's pull fails.
        vm.prank(bob);
        vm.expectRevert(SafeTransferLib.TransferFromFailed.selector);
        factory.deposit(NOV_9, TOKEN);
        // Others carry on.
        _deposit(NOV_9, alice, TOKEN);

        _blocklist(bob, false);
        vm.prank(bob);
        assertEq(series.redeem(2 * TOKEN, 2 * TOKEN), 2 * TOKEN);
    }

    function test_fork_transferPauseDelaysButNeverLosesStock() public {
        ExposureSeriesV2 series = _openAndDeposit(NOV_9, alice, 2 * TOKEN);
        _pauseTransfers(true);
        vm.prank(alice);
        vm.expectRevert(SafeTransferLib.TransferFailed.selector);
        series.redeem(TOKEN, TOKEN);
        vm.prank(bob);
        vm.expectRevert(SafeTransferLib.TransferFromFailed.selector);
        factory.deposit(NOV_9, TOKEN);
        // Prices keep applying while the stock is paused.
        _warpTo(uint256(series.boundaries(4)) + 1 hours);
        assertEq(series.settle(), 4);

        _pauseTransfers(false);
        vm.prank(alice);
        assertEq(series.redeem(2 * TOKEN, 2 * TOKEN), 2 * TOKEN);
    }

    /// A split changes the shares each raw token stands for, not the raw units the series holds or owes.
    function test_fork_splitLeavesRawBackingAlone() public {
        ExposureSeriesV2 series = _openAndDeposit(NOV_9, alice, 3 * TOKEN);
        vm.prank(issuerOps);
        IB20AssetFork(AMZNC).updateMultiplier(2e18);
        assertEq(IB20AssetFork(AMZNC).multiplier(), 2e18);
        _warpTo(uint256(series.boundaries(1)) + 1 hours);
        series.settle();
        assertEq(stock.balanceOf(address(series)), 3 * TOKEN);
        vm.prank(alice);
        assertEq(series.redeem(3 * TOKEN, 3 * TOKEN), 3 * TOKEN);
    }

    // ---------------------------------------------------------------------------------------------
    // Gas
    // ---------------------------------------------------------------------------------------------

    function test_fork_gas() public {
        ProbeMeter meter = new ProbeMeter();
        meter.measure(AMZN_FEED, (uint80(2) << 64) | 700);
        console.log("gas: one cold round read through the proxy", meter.used());

        // The first deposit of the week opens the series (three contracts) and applies the initial
        // close, searching the phase from round 1.
        _warpTo(uint256(factory.startOf(NOV_2)) + 1 hours);
        vm.prank(alice);
        ExposureSeriesV2 series = factory.deposit(NOV_2, TOKEN);
        console.log("gas: first deposit (opens the series, initial close)", _lastGas());

        _warpTo(uint256(series.boundaries(0)) + 2 hours);
        vm.prank(bob);
        factory.deposit(NOV_2, TOKEN);
        console.log("gas: deposit with nothing to apply", _lastGas());

        // One trading day unsettled: Monday's open and close.
        _warpTo(uint256(series.boundaries(2)) + 1 hours);
        vm.prank(alice);
        factory.deposit(NOV_2, TOKEN);
        console.log("gas: deposit after 1 unsettled day (2 boundaries)", _lastGas());

        vm.prank(alice);
        series.redeem(TOKEN, TOKEN);
        console.log("gas: pair redemption", _lastGas());

        // Each later boundary settled on its own.
        for (uint256 i = 3; i < 11; ++i) {
            _warpTo(uint256(series.boundaries(i)) + 1 hours);
            series.settle();
            console.log("gas: settle one boundary, index", i, _lastGas());
        }
        vm.prank(alice);
        series.redeem(TOKEN, 0);
        console.log("gas: single-leg redemption, nothing to apply", _lastGas());

        // The worst deposit: Friday afternoon, nothing applied since the initial close (9 boundaries).
        ExposureSeriesV2 nov9 = _openAndDeposit(NOV_9, alice, TOKEN);
        _warpTo(uint256(nov9.boundaries(9)) + 1 hours);
        vm.prank(bob);
        factory.deposit(NOV_9, TOKEN);
        console.log("gas: deposit after 5 unsettled days (9 boundaries)", _lastGas());
    }

    // ---------------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------------

    function _openAndDeposit(uint256 week, address who, uint256 assets) internal returns (ExposureSeriesV2) {
        _warpTo(uint256(factory.startOf(week)) + 1 hours);
        return _deposit(week, who, assets);
    }

    function _deposit(uint256 week, address who, uint256 assets) internal returns (ExposureSeriesV2) {
        vm.prank(who);
        return factory.deposit(week, assets);
    }

    function _lastGas() internal view returns (uint256) {
        return IVmFrameGas(address(vm)).lastFrameGas().gasTotalUsed;
    }

    /// @dev Time moves freely, back to open a past week and forward to its boundaries.
    function _warpTo(uint256 t) internal {
        vm.warp(t);
    }

    function _blocklist(address account, bool blocked) internal {
        address[] memory accounts = new address[](1);
        accounts[0] = account;
        vm.prank(POLICY_ADMIN);
        IPolicyRegistryFork(POLICY_REGISTRY).updateBlocklist(TRANSFER_POLICY, blocked, accounts);
    }

    function _pauseTransfers(bool paused) internal {
        uint8[] memory features = new uint8[](1);
        features[0] = TRANSFER;
        vm.prank(issuerOps);
        if (paused) IB20AssetFork(AMZNC).pause(features);
        else IB20AssetFork(AMZNC).unpause(features);
    }
}
