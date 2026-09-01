// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {BaseBindings} from "../bindings/BaseBindings.sol";
import {ConditionalVestingEscrowV1} from "../escrow/ConditionalVestingEscrowV1.sol";
import {RegentFeeHook} from "../hook/RegentFeeHook.sol";
import {IERC20Minimal} from "../interfaces/IERC20Minimal.sol";
import {PaymentReceiverV1} from "../revenue/PaymentReceiverV1.sol";
import {RegentLBPStrategy} from "../strategy/RegentLBPStrategy.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {LibClone} from "solady/utils/LibClone.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {IUERC20Factory} from "uerc20-factory/interfaces/IUERC20Factory.sol";
import {UERC20Metadata} from "uerc20-factory/libraries/UERC20MetadataLibrary.sol";
import {UERC20} from "uerc20-factory/tokens/UERC20.sol";

/// @title RegentsAutolaunchFactoryV1
/// @notice The one Autolaunch factory. It deploys and permanently binds the one shared
///         `RegentLBPStrategy` and the one correctly mined `RegentFeeHook`, and it is the only
///         account that may create an admitted SUBJECT, its pending escrow, and its canonical CCA
///         auction — always together, in one transaction.
/// @dev Authority here is deliberately tiny. Governance — the frozen Regent Safe — may change the
///      launch fee and may pause or unpause new launches, and that is the complete mutable surface.
///      There is no owner, no authority transfer, no implementation setter, no token-factory setter,
///      no strategy or hook setter, no upgrade, no arbitrary call, and no post-deployment binding
///      operation. A launcher is recorded for provenance only and gains nothing.
///
///      Construction is the only moment an identity is admitted. The UERC20 factory and the three
///      C1 clone implementations must present the exact runtime code hashes this repository's frozen
///      build produces; the strategy and the hook are not accepted from the deployer at all but
///      deployed here, and the strategy's own one-shot `bindHook` performs the reciprocal
///      strategy/PoolManager readback from inside this constructor.
///
///      The four expected runtime hashes are literal constants rather than `type(X).runtimeCode`
///      expressions: embedding roughly 25.8 KB of otherwise unused bytecode would push this
///      contract's initcode past EIP-3860. `test_DEP_060_*` reconciles each literal against the
///      compiled artifact it was derived from, and against the exact Solady 44-byte clone shape.
///
///      `launch` and `createPaymentReceiver` reach only the pinned UERC20 factory, the frozen
///      REGENT binding, this factory's own strategy, and clones of the three admitted C1
///      implementations. None of those can hand control to an attacker-supplied address, so no
///      reentrancy guard exists or is needed; `docs/security/threat-model.md` records that
///      reachability argument in full.
///
///      Named invariants: `C4-I1` exact construction and immutable authority, `C4-I2` exact fee and
///      validation before effects, `C4-I3` one canonical token, escrow and auction, `C4-I4` isolated
///      simultaneous launches, `C4-I5` permissionless custom receivers, `C4-I6` complete terminal
///      integration under ordinary EVM atomicity.
contract RegentsAutolaunchFactoryV1 {
    using SafeTransferLib for address;

    /// @notice The exact SUBJECT supply every launch creates.
    uint256 public constant TOTAL_SUPPLY = 100_000_000_000e18;

    /// @notice The exact 85% the launch escrow custodies while the launch is pending.
    uint256 public constant PENDING_ALLOCATION = 85_000_000_000e18;

    /// @notice The exact 15% the strategy pulls to fund the auction's 10% and its own 5% reserve.
    uint256 public constant DISTRIBUTION_PULL = 15_000_000_000e18;

    /// @notice The only decimals an admitted SUBJECT carries.
    uint8 public constant SUBJECT_DECIMALS = 18;

    /// @notice The launch fee this factory is born with, in REGENT.
    uint256 public constant INITIAL_LAUNCH_FEE = 1_000_000e18;

    /// @notice Exact inclusive byte caps on the five metadata strings. Each must also be nonempty.
    uint256 public constant MAX_NAME_BYTES = 64;
    uint256 public constant MAX_SYMBOL_BYTES = 16;
    uint256 public constant MAX_DESCRIPTION_BYTES = 512;
    uint256 public constant MAX_WEBSITE_BYTES = 256;
    uint256 public constant MAX_IMAGE_BYTES = 256;

    /// @notice The runtime code hash the pinned UERC20 factory must present to be admitted.
    /// @dev The pinned factory (`09ae130f7a10f7c1b96e0dc7d9724d567080c4ef`) has fixed runtime code
    ///      and no immutables, so one instance built from that source under this repository's frozen
    ///      build always hashes to this value regardless of where it is deployed.
    bytes32 public constant UERC20_FACTORY_RUNTIME_CODE_HASH =
        0x47a5ee559aa5c815a6a350486a1de3beb868d238ba5b2d46e62db5128645195f;

    /// @notice The runtime code hash the `ConditionalVestingEscrowV1` implementation must present.
    bytes32 public constant ESCROW_IMPLEMENTATION_RUNTIME_CODE_HASH =
        0x462e3b12b73402b61b3561345880a5b6eeed4f13d2088f156712fe1b293f1545;

    /// @notice The runtime code hash the `SubjectSplitterV1` implementation must present.
    bytes32 public constant SPLITTER_IMPLEMENTATION_RUNTIME_CODE_HASH =
        0x51f75aa1524323c76b393e14aa236909badf323187512949d4356163316f749e;

    /// @notice The runtime code hash the `PaymentReceiverV1` implementation must present.
    bytes32 public constant RECEIVER_IMPLEMENTATION_RUNTIME_CODE_HASH =
        0x98088902bc81f8472949dad00e0670d1427cff0ae1bed025120993c9b0c9dfbc;

    /// @notice Everything a launcher supplies, in exactly this order.
    /// @dev There is deliberately no start block, floor price, hook, pool setting, Safe,
    ///      ERC-8004 identity, salt, supply, allocation or schedule here. Every one of those is
    ///      fixed by this factory or by the shared strategy.
    struct LaunchParams {
        string name;
        string symbol;
        string description;
        string website;
        string image;
        address treasury;
        uint128 requiredRegentRaised;
        uint256 expectedLaunchFee;
    }

    /// @notice One recorded launch. Provenance and identity only; it carries no authority.
    struct Launch {
        address launcher;
        address subject;
        address auction;
        address escrow;
        address treasury;
    }

    /// @notice The pinned UERC20 factory every admitted SUBJECT is created by.
    address public immutable uerc20Factory;

    /// @notice The one shared strategy this factory deployed and is permanently bound to.
    RegentLBPStrategy public immutable strategy;

    /// @notice The one shared fee hook this factory mined, deployed, and bound to that strategy.
    RegentFeeHook public immutable hook;

    /// @notice The next launch ID. IDs start at one, so zero is the absent sentinel.
    uint256 public nextLaunchId = 1;

    /// @notice The REGENT a launch currently costs. Governance may set it to any value, zero included.
    uint256 public launchFee;

    /// @notice Whether new launches are paused. Nothing else in the system is ever paused.
    /// @dev Every factory is born paused, so putting the graph on chain and opening it to launchers
    ///      are two separate acts by two different accounts: the deployer's five creations leave
    ///      this `true`, and only the frozen Governance and Regent Safe can ever turn it off. The
    ///      constructor writes it and announces nothing, so anything deciding whether launches are
    ///      admitted reads this getter rather than waiting for an event that was never emitted.
    bool public launchesPaused = true;

    /// @notice The launch a SUBJECT belongs to, or zero if this factory never created it.
    mapping(address subject => uint256 launchId) public launchIdOfSubject;

    /// @notice The launch a payment receiver belongs to, or zero if this factory never registered it.
    /// @dev This is non-enumerable provenance only. The strategy's graduated distribution remains
    ///      the sole authority for which one receiver is canonical.
    mapping(address receiver => uint256 launchId) public launchIdOfPaymentReceiver;

    mapping(uint256 launchId => Launch) private _launches;

    event LaunchCreated(
        uint256 indexed launchId,
        address indexed launcher,
        address indexed subject,
        address auction,
        address escrow,
        address treasury,
        uint128 requiredRegentRaised,
        uint64 startBlock,
        uint64 endBlock
    );
    event LaunchFeeUpdated(uint256 previousFee, uint256 newFee);
    event LaunchFeeCollected(uint256 indexed launchId, address indexed payer, address regentSafe, uint256 amount);
    event LaunchesPaused();
    event LaunchesUnpaused();

    /// @notice One custom receiver. The strategy's `LaunchGraduated` remains the canonical-receiver
    ///         authority; nothing emitted here can ever denote a canonical receiver.
    event PaymentReceiverCreated(
        uint256 indexed launchId,
        address indexed receiver,
        address indexed creator,
        address beneficiary,
        uint16 referralBps
    );

    error UnexpectedRuntimeCodeHash(address account, bytes32 expected, bytes32 found);
    error NotGovernance(address caller);
    error LaunchesAlreadyPaused();
    error LaunchesNotPaused();
    error LaunchesArePaused();
    error StaleLaunchFee(uint256 current, uint256 expected);
    error LaunchFeeAllowanceMismatch(uint256 expected, uint256 found);
    error LaunchFeeAllowanceNotConsumed(uint256 remaining);
    error EmptyMetadataField(uint256 field);
    error MetadataFieldTooLong(uint256 field, uint256 maximum, uint256 found);
    error SubjectHasNoCode(address subject);
    error SubjectCreatorMismatch(address found);
    error SubjectGraffitiMismatch(bytes32 found);
    error InexactTransfer(uint256 expected, uint256 found);
    error AllowanceNotConsumed(address spender, uint256 remaining);
    error SubjectNotFullyDistributed(uint256 remaining);
    error LaunchRecordMismatch(uint256 field, uint256 expected, uint256 found);
    error UnknownLaunch(uint256 launchId);
    error LaunchNotGraduated(uint256 launchId);
    error NotStrategy(address caller);

    /// @dev Deploys and binds the whole shared graph. Every admitted identity is checked before any
    ///      deployment happens, and the strategy's own `bindHook` is what proves the freshly mined
    ///      hook points back at this strategy and at the frozen PoolManager. `C4-I1`.
    /// @param hookSalt The deployment-only pre-mined CREATE2 salt that gives the hook the exact
    ///        permission bits Uniswap v4 encodes in a hook address. It is not stored, is not a launch
    ///        parameter, and grants no runtime authority: a wrong salt simply fails construction.
    constructor(
        address uerc20Factory_,
        address escrowImplementation_,
        address splitterImplementation_,
        address receiverImplementation_,
        bytes32 hookSalt
    ) {
        _requireRuntimeCodeHash(uerc20Factory_, UERC20_FACTORY_RUNTIME_CODE_HASH);
        _requireRuntimeCodeHash(escrowImplementation_, ESCROW_IMPLEMENTATION_RUNTIME_CODE_HASH);
        _requireRuntimeCodeHash(splitterImplementation_, SPLITTER_IMPLEMENTATION_RUNTIME_CODE_HASH);
        _requireRuntimeCodeHash(receiverImplementation_, RECEIVER_IMPLEMENTATION_RUNTIME_CODE_HASH);

        RegentLBPStrategy strategy_ = new RegentLBPStrategy(
            address(this), escrowImplementation_, splitterImplementation_, receiverImplementation_
        );
        RegentFeeHook hook_ =
            new RegentFeeHook{salt: hookSalt}(IPoolManager(BaseBindings.POOL_MANAGER), address(strategy_));
        strategy_.bindHook(address(hook_));

        // slither-disable-next-line missing-zero-check
        uerc20Factory = uerc20Factory_;
        strategy = strategy_;
        hook = hook_;
        launchFee = INITIAL_LAUNCH_FEE;
    }

    modifier onlyGovernance() {
        if (msg.sender != BaseBindings.GOVERNANCE_AND_REGENT_SAFE) revert NotGovernance(msg.sender);
        _;
    }

    /// @notice Create one launch: its SUBJECT, its pending escrow, and its canonical CCA auction.
    /// @dev Ordinary EVM atomicity is the whole failure design. Any revert anywhere below — in this
    ///      factory, in the pinned UERC20 factory, in the escrow, in the strategy, or in the pinned
    ///      CCA — undoes the fee movement, the deployments, the records and the events together.
    ///      There is no retry counter, no progress state and no partially created launch. `C4-I3`.
    function launch(LaunchParams calldata params)
        external
        returns (uint256 launchId, address subject, address auction, address escrow)
    {
        if (launchesPaused) revert LaunchesArePaused();

        uint256 fee = launchFee;
        if (fee != params.expectedLaunchFee) revert StaleLaunchFee(fee, params.expectedLaunchFee);

        // Solidity strings are bytes. A nonempty field within its exact byte cap is accepted as-is:
        // no normalization, no character policy, no URL validation, no content moderation.
        _requireBytes(0, bytes(params.name).length, MAX_NAME_BYTES);
        _requireBytes(1, bytes(params.symbol).length, MAX_SYMBOL_BYTES);
        _requireBytes(2, bytes(params.description).length, MAX_DESCRIPTION_BYTES);
        _requireBytes(3, bytes(params.website).length, MAX_WEBSITE_BYTES);
        _requireBytes(4, bytes(params.image).length, MAX_IMAGE_BYTES);

        launchId = nextLaunchId;
        nextLaunchId = launchId + 1;

        _collectLaunchFee(launchId, fee);

        subject = _createSubject(params, launchId);
        escrow = _fundEscrow(subject, params.treasury);
        auction = _initializeDistribution(subject, escrow, params, launchId);

        _launches[launchId] = Launch(msg.sender, subject, auction, escrow, params.treasury);
        launchIdOfSubject[subject] = launchId;
    }

    /// @notice Set the REGENT a new launch costs. Governance only; zero is a valid fee.
    function setLaunchFee(uint256 newFee) external onlyGovernance {
        uint256 previousFee = launchFee;
        launchFee = newFee;
        emit LaunchFeeUpdated(previousFee, newFee);
    }

    /// @notice Stop admitting new launches. Governance only.
    /// @dev This gates `launch` and nothing else. Existing auctions, migration, refunds, staking,
    ///      claims, swaps, payments, vesting, recovery and custom receivers are all untouched by it.
    ///      A factory that has never been opened is already paused, so this is the second half of
    ///      the ordinary order — open, then close, then open again — and not the first.
    function pauseLaunches() external onlyGovernance {
        if (launchesPaused) revert LaunchesAlreadyPaused();
        launchesPaused = true;
        emit LaunchesPaused();
    }

    /// @notice Admit new launches. Governance only, and on a newly deployed factory this is the one
    ///         call that opens it for the first time.
    function unpauseLaunches() external onlyGovernance {
        if (!launchesPaused) revert LaunchesNotPaused();
        launchesPaused = false;
        emit LaunchesUnpaused();
    }

    /// @notice Create one custom payment receiver for a graduated launch. Anyone may pay the gas.
    /// @dev The only launch state that can produce a receiver is a nonzero canonical splitter, which
    ///      the strategy records exactly once, at graduation. A pending or failed launch has none and
    ///      is refused here. The clone binds `msg.sender` as its note editor and is never canonical:
    ///      canonical identity is only the address the strategy recorded, never a receiver's own
    ///      state shape. The factory keeps no receiver list. `C4-I5`.
    function createPaymentReceiver(uint256 launchId, address beneficiary, uint16 referralBps)
        external
        returns (address receiver)
    {
        address auction = _launches[launchId].auction;
        if (auction == address(0)) revert UnknownLaunch(launchId);

        address splitter = strategy.distribution(auction).splitter;
        if (splitter == address(0)) revert LaunchNotGraduated(launchId);

        receiver = LibClone.clone(strategy.receiverImplementation());
        PaymentReceiverV1(payable(receiver)).initialize(splitter, beneficiary, referralBps, msg.sender, false);

        launchIdOfPaymentReceiver[receiver] = launchId;

        emit PaymentReceiverCreated(launchId, receiver, msg.sender, beneficiary, referralBps);
    }

    /// @notice Register the canonical receiver recorded by the strategy for one graduated auction.
    /// @dev Strategy only. The complete terminal distribution must already exist, and every launch
    ///      identity is checked against this factory's own record before provenance is written.
    function registerCanonicalPaymentReceiver(address auction) external {
        if (msg.sender != address(strategy)) revert NotStrategy(msg.sender);

        RegentLBPStrategy.Distribution memory recorded = strategy.distribution(auction);
        _requireRecorded(5, uint256(uint8(RegentLBPStrategy.Lifecycle.Graduated)), uint256(uint8(recorded.lifecycle)));
        _requireRecorded(6, 1, recorded.launchId == 0 ? 0 : 1);
        _requireRecorded(7, 1, recorded.receiver == address(0) ? 0 : 1);

        Launch storage launch_ = _launches[recorded.launchId];
        _requireRecorded(8, uint256(uint160(auction)), uint256(uint160(launch_.auction)));
        _requireRecorded(9, uint256(uint160(launch_.subject)), uint256(uint160(recorded.subject)));
        _requireRecorded(10, uint256(uint160(launch_.escrow)), uint256(uint160(recorded.escrow)));
        _requireRecorded(11, uint256(uint160(launch_.treasury)), uint256(uint160(recorded.treasury)));

        launchIdOfPaymentReceiver[recorded.receiver] = recorded.launchId;
    }

    /// @notice One recorded launch's complete identity, or an all-zero record for an unknown ID.
    function launches(uint256 launchId) external view returns (Launch memory) {
        return _launches[launchId];
    }

    // -------------------------------------------------------------------------
    // internals
    // -------------------------------------------------------------------------

    /// @dev The launcher's factory allowance must equal the current fee exactly — no more, no less —
    ///      and a positive fee moves that exact amount straight to the Regent Safe, proved by the
    ///      Safe's own balance delta rather than by a return value. A zero fee moves nothing and
    ///      still requires a zero allowance, so no launcher ever leaves standing spend authority
    ///      behind. This factory's absolute REGENT balance is deliberately never asserted: an
    ///      unrelated gift must not be able to brick launches. `C4-I2`.
    function _collectLaunchFee(uint256 launchId, uint256 fee) private {
        address regent = BaseBindings.REGENT;
        uint256 allowed = IERC20Minimal(regent).allowance(msg.sender, address(this));
        if (allowed != fee) revert LaunchFeeAllowanceMismatch(fee, allowed);
        if (fee == 0) return;

        address regentSafe = BaseBindings.GOVERNANCE_AND_REGENT_SAFE;
        uint256 before = regent.balanceOf(regentSafe);
        regent.safeTransferFrom(msg.sender, regentSafe, fee);
        uint256 received = regent.balanceOf(regentSafe) - before;
        if (received != fee) revert InexactTransfer(fee, received);

        uint256 remaining = IERC20Minimal(regent).allowance(msg.sender, address(this));
        if (remaining != 0) revert LaunchFeeAllowanceNotConsumed(remaining);

        emit LaunchFeeCollected(launchId, msg.sender, regentSafe, fee);
    }

    /// @dev The one canonical SUBJECT. The only launch-specific entropy this factory supplies is
    ///      `bytes32(launchId)`, used as the UERC20 graffiti; the pinned factory hashes its own
    ///      documented identity fields around it and the pinned CCA hashes its caller with the same
    ///      value. There is no public or creator-selected salt anywhere.
    ///
    ///      Only the cheap admission facts are read back here — code, `creator` and `graffiti` — and
    ///      they are exactly what makes this token an admitted SUBJECT. Supply, decimals, name,
    ///      symbol and metadata are proved by `TOK-001`, `TOK-002` and `TOK-004`. `C4-I3`.
    function _createSubject(LaunchParams calldata params, uint256 launchId) private returns (address subject) {
        bytes32 graffiti = bytes32(launchId);
        subject = IUERC20Factory(uerc20Factory)
            .createToken(
                params.name,
                params.symbol,
                SUBJECT_DECIMALS,
                TOTAL_SUPPLY,
                address(this),
                abi.encode(
                    UERC20Metadata({description: params.description, website: params.website, image: params.image})
                ),
                graffiti
            );

        if (subject.code.length == 0) revert SubjectHasNoCode(subject);
        address creator = UERC20(subject).creator();
        if (creator != address(this)) revert SubjectCreatorMismatch(creator);
        bytes32 found = UERC20(subject).graffiti();
        if (found != graffiti) revert SubjectGraffitiMismatch(found);
    }

    /// @dev The escrow clone is its own funding caller: `initialize` pulls the exact 85% from this
    ///      factory inside the same call, so a bound-but-unfunded escrow cannot exist. The exact
    ///      approval is fully consumed, leaving the escrow no standing spend authority. `C4-I3`.
    function _fundEscrow(address subject, address treasury) private returns (address escrow) {
        escrow = LibClone.clone(strategy.escrowImplementation());

        subject.safeApprove(escrow, PENDING_ALLOCATION);
        ConditionalVestingEscrowV1(escrow).initialize(subject, treasury, address(strategy));

        uint256 remaining = IERC20Minimal(subject).allowance(address(this), escrow);
        if (remaining != 0) revert AllowanceNotConsumed(escrow, remaining);
    }

    /// @dev Hands the remaining 15% to the strategy, which creates the launch's canonical auction,
    ///      delivers the 10% into it and keeps the 5% as this launch's isolated reserve. Afterwards
    ///      the strategy holds no allowance and this factory holds none of the new SUBJECT, so the
    ///      whole 100 billion sits exactly where `FAC-004` says it does. The recorded identities and
    ///      the fixed schedule are read back from the strategy — the canonical owner of both — and
    ///      only then does the launch exist. `C4-I3`.
    function _initializeDistribution(address subject, address escrow, LaunchParams calldata params, uint256 launchId)
        private
        returns (address auction)
    {
        subject.safeApprove(address(strategy), DISTRIBUTION_PULL);
        auction = strategy.initializeDistribution(
            RegentLBPStrategy.DistributionParams({
                launchId: launchId, escrow: escrow, requiredRegentRaised: params.requiredRegentRaised
            })
        );

        uint256 remaining = IERC20Minimal(subject).allowance(address(this), address(strategy));
        if (remaining != 0) revert AllowanceNotConsumed(address(strategy), remaining);
        uint256 held = subject.balanceOf(address(this));
        if (held != 0) revert SubjectNotFullyDistributed(held);

        RegentLBPStrategy.Distribution memory recorded = strategy.distribution(auction);
        _requireRecorded(0, launchId, recorded.launchId);
        _requireRecorded(1, uint256(uint160(subject)), uint256(uint160(recorded.subject)));
        _requireRecorded(2, uint256(uint160(escrow)), uint256(uint160(recorded.escrow)));
        _requireRecorded(3, uint256(uint160(params.treasury)), uint256(uint160(recorded.treasury)));
        _requireRecorded(4, params.requiredRegentRaised, recorded.requiredRegentRaised);

        emit LaunchCreated(
            launchId,
            msg.sender,
            subject,
            auction,
            escrow,
            params.treasury,
            params.requiredRegentRaised,
            recorded.startBlock,
            recorded.endBlock
        );
    }

    function _requireRuntimeCodeHash(address account, bytes32 expected) private view {
        bytes32 found = account.codehash;
        if (found != expected) revert UnexpectedRuntimeCodeHash(account, expected, found);
    }

    function _requireBytes(uint256 field, uint256 length, uint256 maximum) private pure {
        if (length == 0) revert EmptyMetadataField(field);
        if (length > maximum) revert MetadataFieldTooLong(field, maximum, length);
    }

    function _requireRecorded(uint256 field, uint256 expected, uint256 found) private pure {
        if (expected != found) revert LaunchRecordMismatch(field, expected, found);
    }
}
