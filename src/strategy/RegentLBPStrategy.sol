// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {BaseBindings} from "../bindings/BaseBindings.sol";
import {ConditionalVestingEscrowV1} from "../escrow/ConditionalVestingEscrowV1.sol";
import {RegentFeeHook} from "../hook/RegentFeeHook.sol";
import {PaymentReceiverV1} from "../revenue/PaymentReceiverV1.sol";
import {SubjectSplitterV1} from "../revenue/SubjectSplitterV1.sol";
import {
    AuctionParameters,
    IContinuousClearingAuction
} from "continuous-clearing-auction/interfaces/IContinuousClearingAuction.sol";
import {
    IContinuousClearingAuctionFactory
} from "continuous-clearing-auction/interfaces/IContinuousClearingAuctionFactory.sol";
import {LBPInitializationParams} from "liquidity-launcher/src/interfaces/ILBPInitializer.sol";
import {PositionPlanner} from "liquidity-launcher/src/libraries/PositionPlanner.sol";
import {TokenPricing} from "liquidity-launcher/src/libraries/TokenPricing.sol";
import {
    CurrencyAmounts,
    Plan,
    Position,
    PositionDefinition
} from "liquidity-launcher/src/types/PositionPlannerTypes.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {ActionConstants} from "@uniswap/v4-periphery/src/libraries/ActionConstants.sol";
import {LibClone} from "solady/utils/LibClone.sol";
import {ReentrancyGuardTransient} from "solady/utils/ReentrancyGuardTransient.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/// @title RegentLBPStrategy
/// @notice The one shared strategy behind every Autolaunch launch. It is permanently bound to one
///         Autolaunch factory and to the three C1 clone implementations, binds exactly one authentic
///         C2 hook once, creates each launch's fixed CCA auction, custodies that launch's isolated 5%
///         LP reserve, and finally drives the launch to exactly one terminal state.
/// @dev This is a hard-cut fork of the pinned Liquidity Launcher `LBPStrategy`
///      (`3a3103543f50a13a0ae52a253bb98a925d72146f`). The preserved behaviour is the CCA creation and
///      readback discipline, the final-price conversion through `TokenPricing`, the full-range
///      `PositionPlanner` plan, the exact balance-delta accounting, and the PoolManager /
///      PositionManager call semantics. Everything configurable upstream is deleted here: there is no
///      `MigratorParameters`, no caller-supplied pool, hook, salt, position plan or allocation
///      schedule, no hookless fallback, no `tryMigrate`, no caught failure, no reserve recovery, no
///      retry state and no alternate migration. `docs/security/regent-lbp-strategy-fork-diff.yaml`
///      records that diff line by line.
///
///      A technical problem anywhere in `initializeDistribution` or `migrate` is an ordinary EVM
///      revert. Nothing is caught, nothing is remembered, and the next call starts from the same
///      state the failed one started from.
///
///      Named invariants: `C3-I1` exact one-time authority, `C3-I2` canonical fixed auction,
///      `C3-I3` launch isolation and one terminal decision, `C3-I4` ordinary-revert failure,
///      `C3-I5` atomic final-price graduation, `C3-I6` security and surface minimality.
contract RegentLBPStrategy is ReentrancyGuardTransient {
    using SafeTransferLib for address;

    /// @notice The exact 85% escrow holds while a launch is pending.
    uint256 public constant PENDING_ALLOCATION = 85_000_000_000e18;

    /// @notice The exact 10% the auction sells.
    uint128 public constant AUCTION_ALLOCATION = 10_000_000_000e18;

    /// @notice The exact 5% this strategy custodies as one launch's isolated LP reserve.
    uint128 public constant RESERVE_ALLOCATION = 5_000_000_000e18;

    /// @notice The exact 15% one initialization pulls from the bound factory.
    uint256 public constant DISTRIBUTION_PULL = 15_000_000_000e18;

    /// @notice Every auction starts exactly this many blocks after its initializing block.
    uint64 public constant START_DELAY_BLOCKS = 1_800;

    /// @notice The fixed auction duration in blocks.
    uint64 public constant AUCTION_DURATION_BLOCKS = 86_401;

    /// @notice The fixed delay between the auction end and the claim block.
    uint64 public constant CLAIM_DELAY_BLOCKS = 64;

    /// @notice The fixed delay between the auction end and migration eligibility.
    uint64 public constant MIGRATION_DELAY_BLOCKS = 128;

    /// @notice The frozen Q96 auction floor price.
    uint256 public constant FLOOR_PRICE_Q96 = 79_228_162_514_264_337_593_543_900;

    /// @notice The frozen Q96 bid tick spacing.
    uint256 public constant BID_TICK_Q96 = 792_281_625_142_643_375_935_439;

    /// @notice The frozen issuance schedule: 104 bytes, thirteen `uint24 mps | uint40 blockDelta`
    ///         steps. One opening block carries the exact residual that uniform integer issuance
    ///         cannot express, then twelve equal 7,200-block steps (four hours each on Base's
    ///         two-second blocks, forty-eight hours in total) issue the rest as evenly as integer
    ///         `mps` allows. The step block deltas sum to `AUCTION_DURATION_BLOCKS` and the
    ///         `mps * blockDelta` products sum to exactly `1e7`, which is what the pinned
    ///         `StepStorage` constructor requires.
    bytes public constant AUCTION_STEPS = hex"0019000000000001" hex"0000740000001c20" hex"0000740000001c20"
        hex"0000740000001c20" hex"0000740000001c20" hex"0000740000001c20" hex"0000740000001c20" hex"0000740000001c20"
        hex"0000740000001c20" hex"0000730000001c20" hex"0000730000001c20" hex"0000730000001c20" hex"0000730000001c20";

    /// @notice The only static LP fee an official pool carries, 0.30%.
    uint24 public constant POOL_FEE = 3000;

    /// @notice The only tick spacing an official pool carries.
    int24 public constant POOL_TICK_SPACING = 60;

    /// @notice The largest REGENT raise the fixed 10-billion-SUBJECT auction can mathematically reach.
    /// @dev `AUCTION_ALLOCATION * MaxBidPriceLib.maxBidPrice(AUCTION_ALLOCATION) / 2**96`. A required
    ///      raise above this can never be met, so the launch could only ever fail.
    uint128 public constant MAX_REACHABLE_RAISE = 658_201_822_928_482_416_462_351_903_564_741_590;

    /// @notice The only lifecycle a recorded launch can occupy.
    enum Lifecycle {
        None,
        Active,
        Graduated,
        Failed
    }

    /// @notice Everything the bound factory supplies for one launch.
    /// @dev SUBJECT, treasury and the fixed start are derived from the authenticated escrow and the
    ///      current block; they are deliberately not redundant caller-supplied copies.
    struct DistributionParams {
        uint256 launchId;
        address escrow;
        address recoveryAdmin;
        uint128 requiredRegentRaised;
    }

    /// @notice One launch's complete recorded state.
    struct Distribution {
        Lifecycle lifecycle;
        uint64 startBlock;
        uint64 endBlock;
        uint64 claimBlock;
        uint64 migrationBlock;
        uint128 requiredRegentRaised;
        uint128 reserve;
        uint128 lpRegentUsed;
        uint128 lpSubjectUsed;
        uint160 finalSqrtPriceX96;
        uint256 launchId;
        address subject;
        address escrow;
        address treasury;
        address recoveryAdmin;
        address splitter;
        address receiver;
        PoolId poolId;
        uint256 lpTokenId;
    }

    /// @notice The only account that may bind the hook or create a distribution.
    address public immutable factory;

    /// @notice The permanent `ConditionalVestingEscrowV1` clone target every launch escrow must be.
    address public immutable escrowImplementation;

    /// @notice The permanent `SubjectSplitterV1` clone target every graduated splitter is cloned from.
    address public immutable splitterImplementation;

    /// @notice The permanent `PaymentReceiverV1` clone target every canonical receiver is cloned from.
    address public immutable receiverImplementation;

    /// @notice The runtime code hash an authentic escrow clone of `escrowImplementation` must present.
    bytes32 public immutable escrowCloneCodehash;

    /// @notice The one authentic `RegentFeeHook`. Zero until the factory binds it, permanent after.
    address public hook;

    /// @notice The auction created for one launch's SUBJECT. One SUBJECT, one auction, forever.
    mapping(address subject => address auction) public auctionOfSubject;

    mapping(address auction => Distribution) private _distributions;

    event HookBound(address indexed hook);
    event DistributionCreated(
        uint256 indexed launchId,
        address indexed auction,
        address indexed subject,
        address escrow,
        address treasury,
        uint64 startBlock,
        uint64 endBlock,
        uint128 requiredRegentRaised,
        uint128 reserve
    );
    event LaunchRetired(address indexed auction, address indexed subject, uint128 reserveReturned);
    event LaunchGraduated(
        address indexed auction,
        address indexed subject,
        PoolId indexed poolId,
        address splitter,
        address receiver,
        uint160 finalSqrtPriceX96,
        uint256 lpTokenId,
        uint128 lpRegentUsed,
        uint128 lpSubjectUsed
    );

    error ZeroAddress();
    error SelfAddress();
    error ImplementationHasNoCode(address implementation);
    error NotFactory(address caller);
    error HookAlreadyBound(address bound);
    error HookNotBound();
    error HookHasNoCode(address hook);
    error HookBindingMismatch(address expected, address found);
    error NotAuthenticEscrow(address escrow);
    error EscrowStrategyMismatch(address found);
    error EscrowNotPending();
    error EscrowCustodyMismatch(uint256 found);
    error SubjectAlreadyLaunched(address subject, address auction);
    error UnreachableRequiredRaise(uint128 requiredRegentRaised);
    error RecoveryAdminHasNoCode(address recoveryAdmin);
    error ProtocolFeeControllerNotZero(address controller);
    error AuctionHasNoCode(address auction);
    error AuctionBindingMismatch(uint256 field, uint256 expected, uint256 found);
    error InexactTransfer(uint256 expected, uint256 found);
    error UnknownAuction(address auction);
    error LaunchNotActive(Lifecycle found);
    error MigrationNotYetAllowed(uint64 migrationBlock, uint256 currentBlock);
    error CurrencyRaisedMismatch(uint256 expected, uint256 found);
    error NoFullRangePosition();
    error UnexpectedPositionMintCount(uint256 expected, uint256 found);

    /// @dev The factory is deliberately not required to carry code: the canonical Autolaunch factory
    ///      binds the hook from inside its own constructor, when it has none yet. The three clone
    ///      implementations are required to carry code, because a codeless clone target would produce
    ///      escrows, splitters and receivers that silently accept every call.
    constructor(
        address factory_,
        address escrowImplementation_,
        address splitterImplementation_,
        address receiverImplementation_
    ) {
        _requireBindable(factory_);
        _requireImplementation(escrowImplementation_);
        _requireImplementation(splitterImplementation_);
        _requireImplementation(receiverImplementation_);

        // slither-disable-next-line missing-zero-check
        factory = factory_;
        // slither-disable-next-line missing-zero-check
        escrowImplementation = escrowImplementation_;
        // slither-disable-next-line missing-zero-check
        splitterImplementation = splitterImplementation_;
        // slither-disable-next-line missing-zero-check
        receiverImplementation = receiverImplementation_;
        escrowCloneCodehash = keccak256(
            abi.encodePacked(hex"3d3d3d3d363d3d37363d73", escrowImplementation_, hex"5af43d3d93803e602a57fd5bf3")
        );
    }

    modifier onlyFactory() {
        if (msg.sender != factory) revert NotFactory(msg.sender);
        _;
    }

    /// @notice Bind the one authentic `RegentFeeHook`. Factory only, once ever.
    /// @dev Authenticity is the hook's own immutable bindings — it must already point back at this
    ///      strategy and at the frozen Base PoolManager — not a runtime-code fingerprint, so the hook
    ///      can be mined to any address carrying the permission bits v4 requires. `C3-I1`.
    function bindHook(address hook_) external onlyFactory {
        address bound = hook;
        if (bound != address(0)) revert HookAlreadyBound(bound);
        if (hook_.code.length == 0) revert HookHasNoCode(hook_);

        address hookStrategy = RegentFeeHook(hook_).strategy();
        if (hookStrategy != address(this)) revert HookBindingMismatch(address(this), hookStrategy);

        address hookPoolManager = address(RegentFeeHook(hook_).poolManager());
        if (hookPoolManager != BaseBindings.POOL_MANAGER) {
            revert HookBindingMismatch(BaseBindings.POOL_MANAGER, hookPoolManager);
        }

        hook = hook_;
        emit HookBound(hook_);
    }

    /// @notice Create one launch's canonical CCA auction and take custody of its isolated 5% reserve.
    /// @dev Factory only, impossible before the hook is bound. Every economic input except the launch
    ///      id, the escrow, the recovery admin and the required raise is fixed here; SUBJECT, treasury
    ///      and the start block come from the authenticated escrow and the current block. `C3-I2`.
    // slither-disable-next-line reentrancy-no-eth,reentrancy-benign
    function initializeDistribution(DistributionParams calldata params)
        external
        nonReentrant
        onlyFactory
        returns (address auction)
    {
        if (hook == address(0)) revert HookNotBound();

        (address subject, address treasury) = _authenticateEscrow(params.escrow);
        if (params.requiredRegentRaised == 0 || params.requiredRegentRaised > MAX_REACHABLE_RAISE) {
            revert UnreachableRequiredRaise(params.requiredRegentRaised);
        }
        if (params.recoveryAdmin == address(this)) revert SelfAddress();
        if (params.recoveryAdmin.code.length == 0) revert RecoveryAdminHasNoCode(params.recoveryAdmin);

        address auctionFactory = BaseBindings.CCA_FACTORY;
        address controller = address(IContinuousClearingAuctionFactory(auctionFactory).protocolFeeController());
        if (controller != address(0)) revert ProtocolFeeControllerNotZero(controller);

        uint64 startBlock = uint64(block.number) + START_DELAY_BLOCKS;
        uint64 endBlock = startBlock + AUCTION_DURATION_BLOCKS;

        auction = address(
            IContinuousClearingAuctionFactory(auctionFactory)
                .create(
                    subject,
                    AUCTION_ALLOCATION,
                    abi.encode(
                        AuctionParameters({
                            currency: BaseBindings.REGENT,
                            tokensRecipient: params.escrow,
                            fundsRecipient: address(this),
                            startBlock: startBlock,
                            endBlock: endBlock,
                            claimBlock: endBlock + CLAIM_DELAY_BLOCKS,
                            tickSpacing: BID_TICK_Q96,
                            validationHook: address(0),
                            floorPrice: FLOOR_PRICE_Q96,
                            requiredCurrencyRaised: params.requiredRegentRaised,
                            auctionStepsData: AUCTION_STEPS
                        })
                    ),
                    bytes32(params.launchId)
                )
        );

        _verifyAuction(auction, subject, params.escrow, startBlock, endBlock);

        Distribution storage d = _distributions[auction];
        d.lifecycle = Lifecycle.Active;
        d.startBlock = startBlock;
        d.endBlock = endBlock;
        d.claimBlock = endBlock + CLAIM_DELAY_BLOCKS;
        d.migrationBlock = endBlock + MIGRATION_DELAY_BLOCKS;
        d.requiredRegentRaised = params.requiredRegentRaised;
        d.reserve = RESERVE_ALLOCATION;
        d.launchId = params.launchId;
        d.subject = subject;
        d.escrow = params.escrow;
        d.treasury = treasury;
        d.recoveryAdmin = params.recoveryAdmin;
        auctionOfSubject[subject] = auction;

        emit DistributionCreated(
            params.launchId,
            auction,
            subject,
            params.escrow,
            treasury,
            startBlock,
            endBlock,
            params.requiredRegentRaised,
            RESERVE_ALLOCATION
        );

        uint256 held = subject.balanceOf(address(this));
        subject.safeTransferFrom(msg.sender, address(this), DISTRIBUTION_PULL);
        uint256 received = subject.balanceOf(address(this)) - held;
        if (received != DISTRIBUTION_PULL) revert InexactTransfer(DISTRIBUTION_PULL, received);

        uint256 auctionHeld = subject.balanceOf(auction);
        subject.safeTransfer(auction, AUCTION_ALLOCATION);
        uint256 delivered = subject.balanceOf(auction) - auctionHeld;
        if (delivered != AUCTION_ALLOCATION) revert InexactTransfer(AUCTION_ALLOCATION, delivered);

        IContinuousClearingAuction(auction).onTokensReceived();
    }

    /// @notice Drive one recorded launch to its single terminal state. Anyone may call it.
    /// @dev The auction is checkpointed to its exact end and classified from that completed state
    ///      before any terminal work. A launch that is already terminal reverts and commits nothing.
    ///      `C3-I3`.
    // slither-disable-next-line reentrancy-no-eth
    function migrate(address auction) external nonReentrant {
        Distribution storage d = _distributions[auction];
        Lifecycle lifecycle = d.lifecycle;
        if (lifecycle == Lifecycle.None) revert UnknownAuction(auction);
        if (lifecycle != Lifecycle.Active) revert LaunchNotActive(lifecycle);

        uint64 migrationBlock = d.migrationBlock;
        if (block.number < migrationBlock) revert MigrationNotYetAllowed(migrationBlock, block.number);

        // The final checkpoint is the whole classification. It is the same call the escrow and the
        // auction's own accounting rely on, and it can revert for ordinary upstream liveness reasons —
        // an unbounded tick book, for instance — in which case this migration simply did not happen.
        // slither-disable-next-line unused-return
        IContinuousClearingAuction(auction).checkpoint();

        if (IContinuousClearingAuction(auction).isGraduated()) {
            _graduate(d, auction);
        } else {
            _retire(d, auction);
        }
    }

    /// @notice One launch's complete recorded state.
    function distribution(address auction) external view returns (Distribution memory) {
        return _distributions[auction];
    }

    /// @notice The official pool key one launch's SUBJECT graduates into.
    function poolKeyOf(address subject) public view returns (PoolKey memory key) {
        bool regentIsCurrency0 = BaseBindings.REGENT < subject;
        key = PoolKey({
            currency0: Currency.wrap(regentIsCurrency0 ? BaseBindings.REGENT : subject),
            currency1: Currency.wrap(regentIsCurrency0 ? subject : BaseBindings.REGENT),
            fee: POOL_FEE,
            tickSpacing: POOL_TICK_SPACING,
            hooks: IHooks(hook)
        });
    }

    /// @dev Economic failure. The isolated reserve goes to escrow, then that authentic escrow runs its
    ///      own canonical retirement, which sweeps the failed 10% and proves the whole 100 billion
    ///      before retiring it. Bidder REGENT is never touched and no graduated artifact is created.
    ///      `C3-I4`, `ESC-003`.
    function _retire(Distribution storage d, address auction) private {
        d.lifecycle = Lifecycle.Failed;

        address subject = d.subject;
        address escrow = d.escrow;
        uint128 reserve = d.reserve;

        emit LaunchRetired(auction, subject, reserve);

        subject.safeTransfer(escrow, reserve);
        ConditionalVestingEscrowV1(escrow).resolveFailure(auction);
    }

    /// @dev Graduation, in exactly the order `C3-I5` fixes. The terminal lifecycle is written before
    ///      the first external call, so a re-entrant dependency meets a launch that is no longer
    ///      active, and every later revert rolls the whole transaction — state, balances, clones,
    ///      registration, pool and position alike — back together.
    // slither-disable-next-line reentrancy-no-eth
    function _graduate(Distribution storage d, address auction) private {
        address subject = d.subject;
        address escrow = d.escrow;

        // Load-bearing: this reverts unless the auction is checkpointed at its exact end block and
        // actually graduated, and it returns the settled final price and the fee-adjusted raise.
        LBPInitializationParams memory lbp = IContinuousClearingAuction(auction).lbpInitializationParams();

        d.lifecycle = Lifecycle.Graduated;

        PoolKey memory key = poolKeyOf(subject);
        PoolId poolId = key.toId();

        address splitter = LibClone.clone(splitterImplementation);
        SubjectSplitterV1(splitter)
            .initialize(
                BaseBindings.USDC,
                BaseBindings.REGENT,
                subject,
                BaseBindings.LIVE_STAKING,
                BaseBindings.GOVERNANCE_AND_REGENT_SAFE,
                d.treasury,
                d.recoveryAdmin
            );

        RegentFeeHook(hook).registerPool(key, splitter);

        address regent = BaseBindings.REGENT;
        uint256 regentBefore = regent.balanceOf(address(this));
        IContinuousClearingAuction(auction).sweepCurrency();
        uint256 raised = regent.balanceOf(address(this)) - regentBefore;
        if (raised != lbp.currencyRaised) revert CurrencyRaisedMismatch(lbp.currencyRaised, raised);

        bool regentIsCurrency0 = Currency.unwrap(key.currency0) == regent;
        uint160 sqrtPriceX96 =
            TokenPricing.convertToSqrtPriceX96(TokenPricing.convertToPriceX192(lbp.initialPriceX96, regentIsCurrency0));
        // slither-disable-next-line unused-return
        IPoolManager(BaseBindings.POOL_MANAGER).initialize(key, sqrtPriceX96);

        (uint128 lpRegentUsed, uint128 lpSubjectUsed, uint256 lpTokenId) = _mintFullRangePosition(
            key, sqrtPriceX96, regentIsCurrency0, subject, SafeCastLib.toUint128(raised), d.reserve
        );

        // Only this launch's own delta leaves. Unrelated REGENT already held by the shared strategy is
        // preserved by construction, because `regentBefore` is subtracted out.
        uint256 unusedRegent = regent.balanceOf(address(this)) - regentBefore;
        if (unusedRegent != 0) regent.safeTransfer(d.treasury, unusedRegent);

        // Every remaining unit of this launch's SUBJECT, including anything gifted to the strategy,
        // belongs to the launch and goes to escrow. The reserve was the only LP budget.
        uint256 unusedSubject = subject.balanceOf(address(this));
        if (unusedSubject != 0) subject.safeTransfer(escrow, unusedSubject);

        ConditionalVestingEscrowV1(escrow).sweepGraduatedUnsoldSubject(auction);

        address receiver = LibClone.clone(receiverImplementation);
        PaymentReceiverV1(payable(receiver)).initialize(splitter, d.treasury, 0, d.treasury, true);

        ConditionalVestingEscrowV1(escrow).activateVesting();

        d.splitter = splitter;
        d.receiver = receiver;
        d.poolId = poolId;
        d.finalSqrtPriceX96 = sqrtPriceX96;
        d.lpTokenId = lpTokenId;
        d.lpRegentUsed = lpRegentUsed;
        d.lpSubjectUsed = lpSubjectUsed;

        emit LaunchGraduated(
            auction, subject, poolId, splitter, receiver, sqrtPriceX96, lpTokenId, lpRegentUsed, lpSubjectUsed
        );
    }

    /// @dev Resolves exactly one full-range position from the raised REGENT and the recorded reserve,
    ///      mints its NFT straight to the dead address, and returns the amounts the position actually
    ///      consumed — never the offered maxima. Plan dust returns here through `TAKE_PAIR`.
    function _mintFullRangePosition(
        PoolKey memory key,
        uint160 sqrtPriceX96,
        bool regentIsCurrency0,
        address subject,
        uint128 regentBudget,
        uint128 reserve
    ) private returns (uint128 lpRegentUsed, uint128 lpSubjectUsed, uint256 lpTokenId) {
        // slither-disable-next-line unused-return
        (Position[] memory positions,) = PositionPlanner.resolve(
            new PositionDefinition[](0),
            sqrtPriceX96,
            POOL_TICK_SPACING,
            CurrencyAmounts({
                amount0: regentIsCurrency0 ? regentBudget : reserve, amount1: regentIsCurrency0 ? reserve : regentBudget
            }),
            BaseBindings.DEAD_ADDRESS
        );
        if (positions.length != 1) revert NoFullRangePosition();

        // `Position.amount0/amount1` are the exact amounts v4 charges for this liquidity, quoted with
        // the same rounding PoolManager uses when adding it, so they are the consumption record.
        (lpRegentUsed, lpSubjectUsed) = regentIsCurrency0
            ? (SafeCastLib.toUint128(positions[0].amount0), SafeCastLib.toUint128(positions[0].amount1))
            : (SafeCastLib.toUint128(positions[0].amount1), SafeCastLib.toUint128(positions[0].amount0));

        Plan memory plan = PositionPlanner.toPlan(positions, key, ActionConstants.MSG_SENDER);

        address positionManager = BaseBindings.POSITION_MANAGER;
        lpTokenId = IPositionManager(positionManager).nextTokenId();

        BaseBindings.REGENT.safeTransfer(positionManager, lpRegentUsed);
        subject.safeTransfer(positionManager, lpSubjectUsed);
        IPositionManager(positionManager).modifyLiquidities(abi.encode(plan.actions, plan.params), block.timestamp);

        uint256 minted = IPositionManager(positionManager).nextTokenId();
        if (minted != lpTokenId + 1) revert UnexpectedPositionMintCount(lpTokenId + 1, minted);
    }

    /// @dev Every exposed binding of the freshly created auction, read back before any value moves.
    function _verifyAuction(address auction, address subject, address escrow, uint64 startBlock, uint64 endBlock)
        private
        view
    {
        // slither-disable-next-line incorrect-equality
        if (auction.code.length == 0) revert AuctionHasNoCode(auction);
        IContinuousClearingAuction cca = IContinuousClearingAuction(auction);
        _requireBinding(0, uint256(uint160(subject)), uint256(uint160(cca.token())));
        _requireBinding(1, uint256(uint160(BaseBindings.REGENT)), uint256(uint160(cca.currency())));
        _requireBinding(2, AUCTION_ALLOCATION, cca.totalSupply());
        _requireBinding(3, uint256(uint160(escrow)), uint256(uint160(cca.tokensRecipient())));
        _requireBinding(4, uint256(uint160(address(this))), uint256(uint160(cca.fundsRecipient())));
        _requireBinding(5, startBlock, cca.startBlock());
        _requireBinding(6, endBlock, cca.endBlock());
        _requireBinding(7, endBlock + CLAIM_DELAY_BLOCKS, cca.claimBlock());
        _requireBinding(8, 0, uint256(uint160(address(cca.validationHook()))));
        _requireBinding(9, FLOOR_PRICE_Q96, cca.floorPrice());
        _requireBinding(10, BID_TICK_Q96, cca.tickSpacing());
    }

    /// @dev The escrow must be an authentic clone of the bound implementation, bound to this strategy,
    ///      still pending, and holding exactly the 85% its own initializer pulled.
    function _authenticateEscrow(address escrow) private view returns (address subject, address treasury) {
        if (escrow.codehash != escrowCloneCodehash) revert NotAuthenticEscrow(escrow);

        ConditionalVestingEscrowV1 vault = ConditionalVestingEscrowV1(escrow);
        address boundStrategy = vault.strategy();
        if (boundStrategy != address(this)) revert EscrowStrategyMismatch(boundStrategy);
        if (vault.lifecycle() != ConditionalVestingEscrowV1.Lifecycle.Pending) revert EscrowNotPending();

        subject = vault.subject();
        treasury = vault.treasury();

        uint256 custody = subject.balanceOf(escrow);
        if (custody != PENDING_ALLOCATION) revert EscrowCustodyMismatch(custody);

        address existing = auctionOfSubject[subject];
        if (existing != address(0)) revert SubjectAlreadyLaunched(subject, existing);
    }

    function _requireBinding(uint256 field, uint256 expected, uint256 found) private pure {
        if (expected != found) revert AuctionBindingMismatch(field, expected, found);
    }

    function _requireBindable(address account) private view {
        if (account == address(0)) revert ZeroAddress();
        if (account == address(this)) revert SelfAddress();
    }

    function _requireImplementation(address implementation) private view {
        _requireBindable(implementation);
        if (implementation.code.length == 0) revert ImplementationHasNoCode(implementation);
    }
}
