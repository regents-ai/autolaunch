// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {BaseBindings} from "../src/bindings/BaseBindings.sol";
import {RegentLBPStrategy} from "../src/strategy/RegentLBPStrategy.sol";
import {ForkAutolaunch} from "./ForkAutolaunch.sol";

/// @notice `GAS-003` through `GAS-006` at both committed headers: the complete outer transaction
///         cost of a direct-wallet launch, a successful migration, and a failed retirement.
/// @dev What is measured is the whole transaction, not an inner call. Execution gas is measured
///      around the real external call a wallet makes; the intrinsic and calldata components are
///      then added from the Base transaction gas schedule active at that exact header, which the
///      committed observation record carries. Post-Prague chains price calldata as a *floor* rather
///      than a per-byte addition, so the total is the applicable maximum of
///
///          intrinsic + calldata-bytes + execution      and      the calldata-token floor,
///
///      never a naive sum of the two. Refunds are deliberately not applied: gross-of-refund usage
///      is the conservative figure, because a refund is capped and cannot be relied on to bring a
///      transaction back under a limit it exceeded.
///
///      Every measurement runs against cold deployed external state — a freshly created fork, the
///      worst admitted metadata, and the worst valid raise — with a warm repetition as the control
///      that proves the cold figure really was cold.
contract TransactionGasForkTest is ForkAutolaunch {
    /// @notice The complete-transaction ceiling every envelope must stay at or below.
    uint256 internal constant TRANSACTION_GAS_CEILING = 14_000_000;

    struct Envelope {
        uint256 execution;
        uint256 intrinsic;
        uint256 calldataGas;
        uint256 calldataFloor;
        uint256 total;
        uint256 calldataLength;
        bytes32 calldataHash;
    }

    function setUp() public {
        _loadObservations();
    }

    // -------------------------------------------------------------------------
    // GAS-003 — the complete launch transaction
    // -------------------------------------------------------------------------

    function test_GAS_003_ForkPinnedCompleteLaunchStaysUnderFourteenMillion() public {
        _checkLaunchEnvelope(Header.Pinned);
    }

    function test_GAS_003_ForkLatestCompleteLaunchStaysUnderFourteenMillion() public {
        _checkLaunchEnvelope(Header.Later);
    }

    function _checkLaunchEnvelope(Header header) private {
        _selectFork(header);
        _deployOnFork();

        (, uint256 execution, bytes memory payload) = _launchAsWallet(_worstCaseParams(strategy.MAX_REACHABLE_RAISE()));
        Envelope memory envelope = _envelope(execution, payload);

        _report("launch", envelope);
        assertLe(envelope.total, TRANSACTION_GAS_CEILING, "the complete launch transaction exceeds 14,000,000 gas");
        _emitVerdict("GAS-003", header, "complete-launch<=14M");
    }

    // -------------------------------------------------------------------------
    // GAS-004 — the complete successful migration transaction
    // -------------------------------------------------------------------------

    function test_GAS_004_ForkPinnedCompleteGraduationStaysUnderFourteenMillion() public {
        _checkGraduationEnvelope(Header.Pinned);
    }

    function test_GAS_004_ForkLatestCompleteGraduationStaysUnderFourteenMillion() public {
        _checkGraduationEnvelope(Header.Later);
    }

    function _checkGraduationEnvelope(Header header) private {
        _selectFork(header);
        _deployOnFork();

        (ForkLaunch memory launched,,) = _launchAsWallet(_worstCaseParams(1_000e18));
        _bidToGraduation(launched, 4_000e18);

        bytes memory payload = abi.encodeCall(RegentLBPStrategy.migrate, (address(launched.auction)));
        address caller = makeAddr("fork-migrator");
        vm.prank(caller);
        uint256 before = gasleft();
        (bool ok,) = address(strategy).call(payload);
        uint256 execution = before - gasleft();
        require(ok, "fork graduation reverted");

        RegentLBPStrategy.Distribution memory d = strategy.distribution(address(launched.auction));
        assertEq(uint8(d.lifecycle), uint8(RegentLBPStrategy.Lifecycle.Graduated), "the launch did not graduate");

        Envelope memory envelope = _envelope(execution, payload);
        _report("graduation", envelope);
        assertLe(envelope.total, TRANSACTION_GAS_CEILING, "the complete graduation transaction exceeds 14,000,000 gas");
        _emitVerdict("GAS-004", header, "complete-graduation<=14M");
    }

    // -------------------------------------------------------------------------
    // GAS-005 — the complete failed migration transaction
    // -------------------------------------------------------------------------

    function test_GAS_005_ForkPinnedCompleteFailureRetirementStaysUnderFourteenMillion() public {
        _checkFailureEnvelope(Header.Pinned);
    }

    function test_GAS_005_ForkLatestCompleteFailureRetirementStaysUnderFourteenMillion() public {
        _checkFailureEnvelope(Header.Later);
    }

    /// @dev The worst failed retirement is a partially bid auction, not an unbid one: it carries a
    ///      real tick book, real bidder inventory to leave refundable, and the largest unsold sweep.
    function _checkFailureEnvelope(Header header) private {
        _selectFork(header);
        _deployOnFork();

        (ForkLaunch memory launched,,) = _launchAsWallet(_worstCaseParams(50_000_000e18));
        vm.roll(launched.auction.startBlock());
        _bid(launched, 4_000e18, 10);
        vm.roll(uint256(launched.auction.endBlock()) + strategy.MIGRATION_DELAY_BLOCKS());

        bytes memory payload = abi.encodeCall(RegentLBPStrategy.migrate, (address(launched.auction)));
        address caller = makeAddr("fork-retirer");
        vm.prank(caller);
        uint256 before = gasleft();
        (bool ok,) = address(strategy).call(payload);
        uint256 execution = before - gasleft();
        require(ok, "fork retirement reverted");

        RegentLBPStrategy.Distribution memory d = strategy.distribution(address(launched.auction));
        assertEq(uint8(d.lifecycle), uint8(RegentLBPStrategy.Lifecycle.Failed), "the launch did not fail");

        Envelope memory envelope = _envelope(execution, payload);
        _report("failure retirement", envelope);
        assertLe(envelope.total, TRANSACTION_GAS_CEILING, "the complete failed migration exceeds 14,000,000 gas");
        _emitVerdict("GAS-005", header, "complete-failure<=14M");
    }

    // -------------------------------------------------------------------------
    // GAS-006 — the measurement itself
    // -------------------------------------------------------------------------

    function test_GAS_006_ForkPinnedMeasurementCoversTheFullOuterTransaction() public {
        _checkMeasurementShape(Header.Pinned);
    }

    function test_GAS_006_ForkLatestMeasurementCoversTheFullOuterTransaction() public {
        _checkMeasurementShape(Header.Later);
    }

    /// @dev The claim here is about the *figure*, not the limit: every complete-transaction total
    ///      must carry the intrinsic cost and the calldata cost of the exact calldata a wallet
    ///      sends, must be the applicable maximum rather than a naive sum, and must be strictly
    ///      larger than the inner execution snapshot it is built from. The cold/warm control proves
    ///      the cold figure was measured against genuinely cold external state.
    function _checkMeasurementShape(Header header) private {
        _selectFork(header);
        _deployOnFork();

        (, uint256 coldExecution, bytes memory payload) = _launchAsWallet(_worstCaseParams(1_000e18));
        Envelope memory cold = _envelope(coldExecution, payload);

        // The warm control: a second identical-shape launch, with every shared external account and
        // slot now touched. It must be cheaper, or the cold figure was never cold.
        (, uint256 warmExecution,) = _launchAsWallet(_worstCaseParams(1_000e18));
        assertLt(warmExecution, coldExecution, "the cold/warm control shows no cold external state at all");

        assertEq(cold.calldataLength, payload.length, "the recorded calldata length is not the payload's");
        assertEq(cold.calldataHash, keccak256(payload), "the recorded calldata hash is not the payload's");
        assertGt(cold.intrinsic, 0, "no intrinsic transaction cost was applied");
        assertGt(cold.total, cold.execution, "the total is not larger than the inner execution snapshot");
        assertEq(
            cold.total,
            _maximum(cold.intrinsic + cold.calldataGas + cold.execution, cold.calldataFloor),
            "the total is not the applicable maximum of the schedule's two rules"
        );

        emit log_named_uint("cold execution (gas)", coldExecution);
        emit log_named_uint("warm execution (gas)", warmExecution);
        _report("launch measurement", cold);
        _emitVerdict("GAS-006", header, "total=max(intrinsic+calldata+execution, calldata-floor)");
    }

    // -------------------------------------------------------------------------
    // helpers
    // -------------------------------------------------------------------------

    /// @dev The complete outer transaction, under the Base gas schedule active at this header.
    function _envelope(uint256 execution, bytes memory payload) private view returns (Envelope memory envelope) {
        uint256 intrinsic = _observedUint(".transaction_gas_schedule.intrinsic_gas");
        uint256 zeroByteGas = _observedUint(".transaction_gas_schedule.calldata_zero_byte_gas");
        uint256 nonZeroByteGas = _observedUint(".transaction_gas_schedule.calldata_nonzero_byte_gas");
        uint256 floorPerToken = _observedUint(".transaction_gas_schedule.floor_per_calldata_token");

        uint256 zeroBytes;
        for (uint256 i; i < payload.length; ++i) {
            if (payload[i] == 0) zeroBytes += 1;
        }
        uint256 nonZeroBytes = payload.length - zeroBytes;

        envelope.execution = execution;
        envelope.intrinsic = intrinsic;
        envelope.calldataGas = zeroBytes * zeroByteGas + nonZeroBytes * nonZeroByteGas;
        // A calldata token is one zero byte or four gas-equivalent units of a non-zero byte, which
        // is how the post-Prague floor counts them.
        envelope.calldataFloor = intrinsic + (zeroBytes + nonZeroBytes * 4) * floorPerToken;
        envelope.calldataLength = payload.length;
        envelope.calldataHash = keccak256(payload);
        envelope.total = _maximum(intrinsic + envelope.calldataGas + execution, envelope.calldataFloor);
    }

    function _maximum(uint256 a, uint256 b) private pure returns (uint256) {
        return a > b ? a : b;
    }

    function _report(string memory what, Envelope memory envelope) private {
        emit log_named_string("envelope", what);
        emit log_named_uint("  calldata length (bytes)", envelope.calldataLength);
        emit log_named_bytes32("  calldata hash", envelope.calldataHash);
        emit log_named_uint("  intrinsic (gas)", envelope.intrinsic);
        emit log_named_uint("  calldata (gas)", envelope.calldataGas);
        emit log_named_uint("  calldata floor (gas)", envelope.calldataFloor);
        emit log_named_uint("  execution, gross of refund (gas)", envelope.execution);
        emit log_named_uint("  complete transaction total (gas)", envelope.total);
        // Reported in whichever direction the total actually falls. A plain subtraction would
        // underflow on exactly the envelope this claim exists to catch, turning the stop-report
        // into an unexplained arithmetic panic instead of the named ceiling assertion below.
        if (envelope.total <= TRANSACTION_GAS_CEILING) {
            emit log_named_uint("  margin to the 14,000,000 ceiling (gas)", TRANSACTION_GAS_CEILING - envelope.total);
        } else {
            emit log_named_uint("  OVER the 14,000,000 ceiling by (gas)", envelope.total - TRANSACTION_GAS_CEILING);
        }
    }

    function _bidToGraduation(ForkLaunch memory launched, uint128 amount) private {
        vm.roll(launched.auction.startBlock());
        _bid(launched, amount, 10);
        vm.roll(uint256(launched.auction.endBlock()) + strategy.MIGRATION_DELAY_BLOCKS());
    }
}
