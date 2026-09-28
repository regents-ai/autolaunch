// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {BaseBindings} from "../bindings/BaseBindings.sol";
import {ConditionalVestingEscrowV2} from "../escrow/ConditionalVestingEscrowV2.sol";
import {RegentFeeHook} from "../hook/RegentFeeHook.sol";
import {BidFillLib} from "../libraries/BidFillLib.sol";
import {PaymentReceiverV1} from "../revenue/PaymentReceiverV1.sol";
import {RevstakeLPLocker} from "../revenue/RevstakeLPLocker.sol";
import {SubjectSplitterV1} from "../revenue/SubjectSplitterV1.sol";
import {
    AuctionParameters,
    IContinuousClearingAuction
} from "continuous-clearing-auction/interfaces/IContinuousClearingAuction.sol";
import {
    IContinuousClearingAuctionFactory
} from "continuous-clearing-auction/interfaces/IContinuousClearingAuctionFactory.sol";
import {ConstantsLib} from "continuous-clearing-auction/libraries/ConstantsLib.sol";
import {MaxBidPriceLib} from "continuous-clearing-auction/libraries/MaxBidPriceLib.sol";
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
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {ActionConstants} from "@uniswap/v4-periphery/src/libraries/ActionConstants.sol";
import {LibClone} from "solady/utils/LibClone.sol";
import {ReentrancyGuardTransient} from "solady/utils/ReentrancyGuardTransient.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/// @title RegentLBPStrategyV2
/// @notice The one shared strategy behind every Revstake launch. It is permanently bound to one
///         Autolaunch factory and to the three C1 clone implementations, binds exactly one authentic
///         C2 hook once, creates each launch's CCA auction at the launcher's floor price, custodies
///         that launch's isolated 15% LP reserve, and finally drives the launch to exactly one
///         terminal state.
/// @notice Version 2 (founder decisions, 27 September 2026): the auction sells 20% and a graduated
///         launch gives its bidders that whole 20%. The auction pays each bid what it won, and this
///         strategy holds the SUBJECT the auction did not sell for the bids to claim pro rata
///         (`claimUnsoldShare`). The official pool opens at the raise divided by the sale allocation
///         and one full-range position pairs the whole reserve with three quarters of the raise; the
///         other quarter goes to the treasury. The required raise is the whole sale allocation at the
///         floor price, rounded up, or the launcher's own higher minimum, so an auction nobody bid in
///         never graduates.
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
contract RegentLBPStrategyV2 is ReentrancyGuardTransient {
    using SafeTransferLib for address;

    /// @notice The exact 65% escrow holds while a launch is pending.
    uint256 public constant PENDING_ALLOCATION = 65_000_000_000e18;

    /// @notice The exact 20% the auction sells.
    uint128 public constant AUCTION_ALLOCATION = 20_000_000_000e18;

    /// @notice The exact 15% this strategy custodies as one launch's isolated LP reserve.
    uint128 public constant RESERVE_ALLOCATION = 15_000_000_000e18;

    /// @notice The exact 35% one initialization pulls from the bound factory.
    uint256 public constant DISTRIBUTION_PULL = 35_000_000_000e18;

    /// @notice Every auction starts exactly this many blocks after its initializing block.
    uint64 public constant START_DELAY_BLOCKS = 300;

    /// @notice The fixed auction duration in blocks.
    uint64 public constant AUCTION_DURATION_BLOCKS = 86_401;

    /// @notice The fixed delay between the auction end and the claim block.
    uint64 public constant CLAIM_DELAY_BLOCKS = 64;

    /// @notice The fixed delay between the auction end and migration eligibility.
    uint64 public constant MIGRATION_DELAY_BLOCKS = 128;

    /// @notice A floor price is a whole number of bid ticks: the tick spacing is the floor divided by
    ///         this, so bids move in steps of one hundredth of the floor.
    uint256 public constant BID_TICK_DIVISOR = 100;

    /// @notice The frozen 104-byte, thirteen-step issuance schedule, byte for byte.
    /// @dev This vector is founder-frozen economics, not a value this ticket may choose. It is the
    ///      schedule the Autolaunch economics manifest records as `auction.schedule_bytes` and the
    ///      archived `AutolaunchFactoryV1` test builds in `_schedule`, transcribed unchanged.
    ///
    ///      Each step is one `uint24 mps | uint40 blockDelta` word. The twelve scheduled steps run
    ///      from 10,894 blocks at 54 mps down to 6,043 blocks at 97 mps — shortening windows at
    ///      rising per-block rates, each releasing about 5.8% of the auction supply — and the
    ///      thirteenth step is a single terminal block carrying the remaining 2,988,006 mps. The
    ///      block deltas therefore sum to `AUCTION_DURATION_BLOCKS` and the `mps * blockDelta`
    ///      products to exactly `1e7`, which is what the pinned `StepStorage` constructor requires
    ///      and what `test_STR_008_*` asserts against this exact vector.
    bytes public constant AUCTION_STEPS = hex"0000360000002a8e" hex"0000440000002145" hex"00004b0000001e7b"
        hex"00004f0000001ccd" hex"0000530000001b9c" hex"0000550000001ab3" hex"00005800000019f7" hex"00005a000000195a"
        hex"00005c00000018d4" hex"00005e000000185e" hex"00005f00000017f8" hex"000061000000179b" hex"2d97e60000000001";

    /// @notice The only static LP fee an official pool carries, 0.30%.
    uint24 public constant POOL_FEE = 3000;

    /// @notice The only tick spacing an official pool carries.
    int24 public constant POOL_TICK_SPACING = 60;

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
    ///      `minimumRegentRaised` is the launcher's own minimum raise, zero for none; the auction's
    ///      required raise is the larger of it and the floor minimum (`requiredRegentRaisedFor`).
    struct DistributionParams {
        uint256 launchId;
        address escrow;
        uint256 floorPriceQ96;
        uint128 minimumRegentRaised;
    }

    /// @notice One launch's complete recorded state.
    /// @dev `subjectSold` is the SUBJECT the auction kept for its bids' claims and `subjectShared` the
    ///      SUBJECT this strategy holds for them on top (see `claimUnsoldShare`); both are set at
    ///      graduation.
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
        uint256 floorPriceQ96;
        uint256 subjectSold;
        uint256 subjectShared;
        uint256 launchId;
        address subject;
        address escrow;
        address treasury;
        address splitter;
        address receiver;
        PoolId poolId;
        uint256 lpTokenId;
    }

    /// @notice The only account that may bind the hook or create a distribution.
    address public immutable factory;

    /// @notice The permanent `ConditionalVestingEscrowV2` clone target every launch escrow must be.
    address public immutable escrowImplementation;

    /// @notice The permanent `SubjectSplitterV1` clone target every graduated splitter is cloned from.
    address public immutable splitterImplementation;

    /// @notice The permanent `PaymentReceiverV1` clone target every canonical receiver is cloned from.
    address public immutable receiverImplementation;

    /// @notice The immutable fee-only owner of every launch-funded LP position.
    RevstakeLPLocker public immutable lpLocker;

    /// @notice The runtime code hash an authentic escrow clone of `escrowImplementation` must present.
    bytes32 public immutable escrowCloneCodehash;

    /// @notice The one authentic `RegentFeeHook`. Zero until the factory binds it, permanent after.
    address public hook;

    /// @notice The auction created for one launch's SUBJECT. One SUBJECT, one auction, forever.
    mapping(address subject => address auction) public auctionOfSubject;

    mapping(address auction => Distribution) private _distributions;

    mapping(address auction => mapping(uint256 bidId => bool)) private _unsoldShareClaimed;

    event HookBound(address indexed hook);
    event DistributionCreated(
        uint256 indexed launchId,
        address indexed auction,
        address indexed subject,
        address escrow,
        address treasury,
        uint64 startBlock,
        uint64 endBlock,
        uint256 floorPriceQ96,
        uint128 requiredRegentRaised,
        uint128 reserve
    );
    event LaunchRetired(address indexed auction, address indexed subject, uint256 subjectReturned);
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
    /// @notice What a graduation raised and how its SUBJECT was assigned.
    event LaunchSettled(
        address indexed auction,
        uint256 regentRaised,
        uint256 regentToTreasury,
        uint256 subjectSold,
        uint256 subjectShared
    );
    /// @notice One bid's share of the SUBJECT the auction did not sell, paid to the bid's owner.
    event UnsoldShareClaimed(
        address indexed auction, uint256 indexed bidId, address indexed owner, uint256 tokensFilled, uint256 share
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
    error FloorPriceTooLow(uint256 floorPriceQ96);
    error FloorPriceNotOnGrid(uint256 floorPriceQ96);
    error TickSpacingTooSmall(uint256 tickSpacingQ96);
    error UnreachableRequiredRaise(uint128 requiredRegentRaised);
    error RefusedTreasury(address treasury);
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
    error LaunchNotGraduated(Lifecycle found);
    error UnsoldShareAlreadyClaimed(address auction, uint256 bidId);

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
        lpLocker = new RevstakeLPLocker(address(this));
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

    /// @notice Create one launch's canonical CCA auction and take custody of its isolated 15% reserve.
    /// @dev Factory only, impossible before the hook is bound. Every economic input except the launch
    ///      id, the escrow, the floor price and the launcher's own minimum raise is fixed here; SUBJECT,
    ///      treasury and the start block come from the authenticated escrow and the current block, and
    ///      the tick spacing and the required raise are derived from the floor. `C3-I2`.
    ///
    ///      `_requireAdmissibleTreasury` is the system's only launch-time treasury admission, and it
    ///      runs here — after the escrow is authenticated, so the treasury being judged is the one
    ///      the escrow really bound, and before the auction exists, so a refusal costs nothing. It
    ///      names six shared-system destinations and nothing else.
    // slither-disable-next-line reentrancy-no-eth,reentrancy-benign
    function initializeDistribution(DistributionParams calldata params)
        external
        nonReentrant
        onlyFactory
        returns (address auction)
    {
        if (hook == address(0)) revert HookNotBound();

        (address subject, address treasury) = _authenticateEscrow(params.escrow);
        _requireAdmissibleTreasury(treasury);
        uint256 tickSpacing = bidTickSpacingFor(params.floorPriceQ96);
        uint128 requiredRegentRaised = requiredRegentRaisedFor(params.floorPriceQ96, params.minimumRegentRaised);

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
                            tokensRecipient: address(this),
                            fundsRecipient: address(this),
                            startBlock: startBlock,
                            endBlock: endBlock,
                            claimBlock: endBlock + CLAIM_DELAY_BLOCKS,
                            tickSpacing: tickSpacing,
                            validationHook: address(0),
                            floorPrice: params.floorPriceQ96,
                            requiredCurrencyRaised: requiredRegentRaised,
                            auctionStepsData: AUCTION_STEPS
                        })
                    ),
                    bytes32(params.launchId)
                )
        );

        _verifyAuction(auction, subject, startBlock, endBlock, params.floorPriceQ96, tickSpacing);

        Distribution storage d = _distributions[auction];
        d.lifecycle = Lifecycle.Active;
        d.startBlock = startBlock;
        d.endBlock = endBlock;
        d.claimBlock = endBlock + CLAIM_DELAY_BLOCKS;
        d.migrationBlock = endBlock + MIGRATION_DELAY_BLOCKS;
        d.requiredRegentRaised = requiredRegentRaised;
        d.reserve = RESERVE_ALLOCATION;
        d.floorPriceQ96 = params.floorPriceQ96;
        d.launchId = params.launchId;
        d.subject = subject;
        d.escrow = params.escrow;
        d.treasury = treasury;
        auctionOfSubject[subject] = auction;

        emit DistributionCreated(
            params.launchId,
            auction,
            subject,
            params.escrow,
            treasury,
            startBlock,
            endBlock,
            params.floorPriceQ96,
            requiredRegentRaised,
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

    /// @notice Pay one bid of a graduated launch its share of the SUBJECT the auction did not sell:
    ///         `subjectShared * tokensFilled / subjectSold`, rounded down, to the bid's owner.
    /// @dev Anyone may call, once per bid, before or after the bid's own exit and claim at the
    ///      auction. The claimed mark is written before the transfer.
    /// @param lastFullyFilledCheckpointBlock, outbidBlock The hints the auction's
    ///        `exitPartiallyFilledBid` takes; ignored for a bid priced above the final clearing price.
    function claimUnsoldShare(address auction, uint256 bidId, uint64 lastFullyFilledCheckpointBlock, uint64 outbidBlock)
        external
        nonReentrant
    {
        (address owner, uint256 filled, uint256 share, bool claimed) =
            _unsoldShare(auction, bidId, lastFullyFilledCheckpointBlock, outbidBlock);
        if (claimed) revert UnsoldShareAlreadyClaimed(auction, bidId);

        _unsoldShareClaimed[auction][bidId] = true;
        emit UnsoldShareClaimed(auction, bidId, owner, filled, share);
        if (share != 0) _distributions[auction].subject.safeTransfer(owner, share);
    }

    /// @notice One launch's complete recorded state.
    function distribution(address auction) external view returns (Distribution memory) {
        return _distributions[auction];
    }

    /// @notice What `claimUnsoldShare` would pay one bid of a graduated launch, and whether it was
    ///         already paid.
    function unsoldShareOf(address auction, uint256 bidId, uint64 lastFullyFilledCheckpointBlock, uint64 outbidBlock)
        external
        view
        returns (address owner, uint256 share, bool claimed)
    {
        (owner,, share, claimed) = _unsoldShare(auction, bidId, lastFullyFilledCheckpointBlock, outbidBlock);
    }

    /// @notice The bid tick spacing (Q96) an auction at this floor price is created with.
    /// @dev The floor must be at least the pinned CCA's minimum, a whole number of `BID_TICK_DIVISOR`
    ///      ticks, and give a tick at least the pinned CCA's minimum spacing.
    function bidTickSpacingFor(uint256 floorPriceQ96) public pure returns (uint256 tickSpacing) {
        if (floorPriceQ96 < ConstantsLib.MIN_FLOOR_PRICE) revert FloorPriceTooLow(floorPriceQ96);
        if (floorPriceQ96 % BID_TICK_DIVISOR != 0) revert FloorPriceNotOnGrid(floorPriceQ96);
        tickSpacing = floorPriceQ96 / BID_TICK_DIVISOR;
        if (tickSpacing < ConstantsLib.MIN_TICK_SPACING) revert TickSpacingTooSmall(tickSpacing);
    }

    /// @notice The REGENT an auction at this floor must raise to graduate: the whole sale allocation at
    ///         the floor price, rounded up, or the launcher's own minimum when that is higher.
    /// @dev The launcher's minimum must be reachable: no more than the whole sale allocation at the
    ///      highest price the auction admits a bid at (`maxReachableRaiseFor`).
    function requiredRegentRaisedFor(uint256 floorPriceQ96, uint128 minimumRegentRaised)
        public
        pure
        returns (uint128 requiredRegentRaised)
    {
        uint256 tickSpacing = bidTickSpacingFor(floorPriceQ96);
        uint128 floorMinimum =
            SafeCastLib.toUint128(FullMath.mulDivRoundingUp(AUCTION_ALLOCATION, floorPriceQ96, FixedPoint96.Q96));
        if (minimumRegentRaised > maxReachableRaiseFor(tickSpacing)) {
            revert UnreachableRequiredRaise(minimumRegentRaised);
        }
        requiredRegentRaised = minimumRegentRaised > floorMinimum ? minimumRegentRaised : floorMinimum;
    }

    /// @notice The largest REGENT raise an auction with this tick spacing can actually reach.
    /// @dev `MaxBidPriceLib.maxBidPrice(AUCTION_ALLOCATION)` is the pinned CCA's structural ceiling on
    ///      a bid price, and the pinned `TickStorage` admits a bid only at an exact multiple of the tick
    ///      spacing, so the highest admitted, and therefore highest clearing, price is the last multiple
    ///      at or below that ceiling. A graduated auction sells at most `AUCTION_ALLOCATION` tokens and
    ///      never clears above that price, so the raise never exceeds this value.
    function maxReachableRaiseFor(uint256 tickSpacing) public pure returns (uint256) {
        uint256 ceiling = MaxBidPriceLib.maxBidPrice(AUCTION_ALLOCATION);
        return FullMath.mulDiv(AUCTION_ALLOCATION, ceiling - ceiling % tickSpacing, FixedPoint96.Q96);
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

    /// @dev Economic failure. This strategy, the auction's unsold-token recipient, sweeps the failed
    ///      auction's whole 20% back and sends it with the isolated reserve to escrow; that authentic
    ///      escrow then runs its own canonical retirement, which proves the whole 100 billion before
    ///      retiring it. Bidder REGENT is never touched and no graduated artifact is created.
    ///      `C3-I4`, `ESC-003`.
    // slither-disable-next-line reentrancy-no-eth
    function _retire(Distribution storage d, address auction) private {
        d.lifecycle = Lifecycle.Failed;

        address subject = d.subject;
        address escrow = d.escrow;

        IContinuousClearingAuction(auction).sweepUnsoldTokens();
        uint256 returned = subject.balanceOf(address(this));

        emit LaunchRetired(auction, subject, returned);

        subject.safeTransfer(escrow, returned);
        ConditionalVestingEscrowV2(escrow).resolveFailure(auction);
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
        // actually graduated, and it returns the fee-adjusted raise.
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
                d.treasury
            );

        RegentFeeHook(hook).registerPool(key, splitter);

        address regent = BaseBindings.REGENT;
        uint256 regentBefore = regent.balanceOf(address(this));
        IContinuousClearingAuction(auction).sweepCurrency();
        uint256 raised = regent.balanceOf(address(this)) - regentBefore;
        if (raised != lbp.currencyRaised) revert CurrencyRaisedMismatch(lbp.currencyRaised, raised);

        // What the sweep delivers is what the auction did not sell; the rest of the sale allocation
        // stays in the auction for its bids. Measured as a delta, because a bidder may already hold
        // claimed SUBJECT and send some here before migration.
        uint256 subjectBefore = subject.balanceOf(address(this));
        IContinuousClearingAuction(auction).sweepUnsoldTokens();
        uint256 subjectSold = AUCTION_ALLOCATION - (subject.balanceOf(address(this)) - subjectBefore);

        // The pool opens at the raise divided by the whole sale allocation (REGENT per SUBJECT, Q96),
        // the price every bidder paid on average once the share-out is counted.
        bool regentIsCurrency0 = Currency.unwrap(key.currency0) == regent;
        uint256 priceX96 = FullMath.mulDiv(raised, FixedPoint96.Q96, AUCTION_ALLOCATION);
        uint160 sqrtPriceX96 =
            TokenPricing.convertToSqrtPriceX96(TokenPricing.convertToPriceX192(priceX96, regentIsCurrency0));
        // slither-disable-next-line unused-return
        IPoolManager(BaseBindings.POOL_MANAGER).initialize(key, sqrtPriceX96);

        (uint128 lpRegentUsed, uint128 lpSubjectUsed, uint256 lpTokenId) = _mintFullRangePosition(
            key, sqrtPriceX96, regentIsCurrency0, subject, SafeCastLib.toUint128(raised), d.reserve
        );
        lpLocker.register(lpTokenId, key, splitter);

        // At the pool price the whole reserve pairs with three quarters of the raise; the rest of this
        // launch's own delta goes to the treasury. Unrelated REGENT already held by the shared strategy
        // is preserved by construction, because `regentBefore` is subtracted out.
        uint256 regentToTreasury = regent.balanceOf(address(this)) - regentBefore;
        if (regentToTreasury != 0) regent.safeTransfer(d.treasury, regentToTreasury);

        // Every unit of this launch's SUBJECT still here — the unsold sale allocation, the reserve the
        // position did not pair and anything sent here — is held for the bids (`claimUnsoldShare`).
        uint256 subjectShared = subject.balanceOf(address(this));

        address receiver = LibClone.clone(receiverImplementation);
        PaymentReceiverV1(payable(receiver)).initialize(splitter, d.treasury, 0, d.treasury, true);

        ConditionalVestingEscrowV2(escrow).activateVesting();

        d.splitter = splitter;
        d.receiver = receiver;
        d.poolId = poolId;
        d.finalSqrtPriceX96 = sqrtPriceX96;
        d.lpTokenId = lpTokenId;
        d.lpRegentUsed = lpRegentUsed;
        d.lpSubjectUsed = lpSubjectUsed;
        d.subjectSold = subjectSold;
        d.subjectShared = subjectShared;

        (bool registered, bytes memory reason) =
            factory.call(abi.encodeWithSignature("registerCanonicalPaymentReceiver(address)", auction));
        if (!registered) {
            assembly ("memory-safe") {
                revert(add(reason, 0x20), mload(reason))
            }
        }

        emit LaunchGraduated(
            auction, subject, poolId, splitter, receiver, sqrtPriceX96, lpTokenId, lpRegentUsed, lpSubjectUsed
        );
        emit LaunchSettled(auction, raised, regentToTreasury, subjectSold, subjectShared);
    }

    /// @dev One bid's share of a graduated launch's unsold SUBJECT, from the tokens the bid won
    ///      (`BidFillLib`). The auction keeps `subjectSold` for its bids' claims, so the tokens its
    ///      bids won never add up to more than it, and the shares never add up to more than
    ///      `subjectShared`.
    function _unsoldShare(address auction, uint256 bidId, uint64 lastFullyFilledCheckpointBlock, uint64 outbidBlock)
        private
        view
        returns (address owner, uint256 filled, uint256 share, bool claimed)
    {
        Distribution storage d = _distributions[auction];
        if (d.lifecycle != Lifecycle.Graduated) revert LaunchNotGraduated(d.lifecycle);
        (owner, filled) = BidFillLib.tokensFilled(
            IContinuousClearingAuction(auction), bidId, lastFullyFilledCheckpointBlock, outbidBlock
        );
        share = FullMath.mulDiv(d.subjectShared, filled, d.subjectSold);
        claimed = _unsoldShareClaimed[auction][bidId];
    }

    /// @dev Resolves exactly one full-range position from the raised REGENT and the recorded reserve,
    ///      which at the pool price binds on the reserve,
    ///      mints its NFT straight to the permanent fee-only locker, and returns the amounts the position actually
    ///      consumed — never the offered maxima. This launch's own plan dust returns here through
    ///      `TAKE_PAIR`, and nothing else does: the two settlement amounts are rewritten from the
    ///      pinned planner's `CONTRACT_BALANCE` sentinel to the exact two amounts this launch
    ///      transfers, so REGENT or SUBJECT already sitting at the shared PositionManager is never
    ///      settled, never becomes this launch's credit, and never reaches its treasury or escrow.
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
            address(lpLocker)
        );
        if (positions.length != 1) revert NoFullRangePosition();

        // `Position.amount0/amount1` are the exact amounts v4 charges for this liquidity, quoted with
        // the same rounding PoolManager uses when adding it, so they are the consumption record.
        (lpRegentUsed, lpSubjectUsed) = regentIsCurrency0
            ? (SafeCastLib.toUint128(positions[0].amount0), SafeCastLib.toUint128(positions[0].amount1))
            : (SafeCastLib.toUint128(positions[0].amount1), SafeCastLib.toUint128(positions[0].amount0));

        Plan memory plan = _exactlyFundedPlan(
            positions,
            key,
            regentIsCurrency0 ? lpRegentUsed : lpSubjectUsed,
            regentIsCurrency0 ? lpSubjectUsed : lpRegentUsed
        );

        address positionManager = BaseBindings.POSITION_MANAGER;
        lpTokenId = IPositionManager(positionManager).nextTokenId();

        BaseBindings.REGENT.safeTransfer(positionManager, lpRegentUsed);
        subject.safeTransfer(positionManager, lpSubjectUsed);
        IPositionManager(positionManager).modifyLiquidities(abi.encode(plan.actions, plan.params), block.timestamp);

        uint256 minted = IPositionManager(positionManager).nextTokenId();
        if (minted != lpTokenId + 1) revert UnexpectedPositionMintCount(lpTokenId + 1, minted);
    }

    /// @dev The pinned plan for these positions, with its two settlement amounts pinned to what this
    ///      launch actually funds. The pinned planner closes every plan with
    ///      `SETTLE(currency0, CONTRACT_BALANCE)`, `SETTLE(currency1, CONTRACT_BALANCE)`,
    ///      `TAKE_PAIR(currency0, currency1, MSG_SENDER)`. That sentinel resolves to the
    ///      PositionManager's *whole* balance of each currency, and the PositionManager is a shared
    ///      contract, so it would settle inventory this launch never funded and hand the resulting
    ///      credit back to this strategy as if it were this launch's unused budget. The pinned action
    ///      sequence is kept exactly as it is and every mint parameter is untouched; only the two
    ///      settlement amounts are replaced with `amount0` and `amount1`, the exact two amounts this
    ///      graduation transfers in. `C6-I8`.
    function _exactlyFundedPlan(Position[] memory positions, PoolKey memory key, uint128 amount0, uint128 amount1)
        private
        pure
        returns (Plan memory plan)
    {
        plan = PositionPlanner.toPlan(positions, key, ActionConstants.MSG_SENDER);

        uint256 settleOffset = positions.length;
        plan.params[settleOffset] = abi.encode(key.currency0, uint256(amount0), false);
        plan.params[settleOffset + 1] = abi.encode(key.currency1, uint256(amount1), false);
    }

    /// @dev Every exposed binding of the freshly created auction, read back before any value moves.
    function _verifyAuction(
        address auction,
        address subject,
        uint64 startBlock,
        uint64 endBlock,
        uint256 floorPriceQ96,
        uint256 tickSpacing
    ) private view {
        // slither-disable-next-line incorrect-equality
        if (auction.code.length == 0) revert AuctionHasNoCode(auction);
        IContinuousClearingAuction cca = IContinuousClearingAuction(auction);
        _requireBinding(0, uint256(uint160(subject)), uint256(uint160(cca.token())));
        _requireBinding(1, uint256(uint160(BaseBindings.REGENT)), uint256(uint160(cca.currency())));
        _requireBinding(2, AUCTION_ALLOCATION, cca.totalSupply());
        _requireBinding(3, uint256(uint160(address(this))), uint256(uint160(cca.tokensRecipient())));
        _requireBinding(4, uint256(uint160(address(this))), uint256(uint160(cca.fundsRecipient())));
        _requireBinding(5, startBlock, cca.startBlock());
        _requireBinding(6, endBlock, cca.endBlock());
        _requireBinding(7, endBlock + CLAIM_DELAY_BLOCKS, cca.claimBlock());
        _requireBinding(8, 0, uint256(uint160(address(cca.validationHook()))));
        _requireBinding(9, floorPriceQ96, cca.floorPrice());
        _requireBinding(10, tickSpacing, cca.tickSpacing());
    }

    /// @dev The escrow must be an authentic clone of the bound implementation, bound to this strategy,
    ///      still pending, and holding exactly the 65% its own initializer pulled.
    function _authenticateEscrow(address escrow) private view returns (address subject, address treasury) {
        if (escrow.codehash != escrowCloneCodehash) revert NotAuthenticEscrow(escrow);

        ConditionalVestingEscrowV2 vault = ConditionalVestingEscrowV2(escrow);
        address boundStrategy = vault.strategy();
        if (boundStrategy != address(this)) revert EscrowStrategyMismatch(boundStrategy);
        if (vault.lifecycle() != ConditionalVestingEscrowV2.Lifecycle.Pending) revert EscrowNotPending();

        subject = vault.subject();
        treasury = vault.treasury();

        uint256 custody = subject.balanceOf(escrow);
        if (custody != PENDING_ALLOCATION) revert EscrowCustodyMismatch(custody);

        address existing = auctionOfSubject[subject];
        if (existing != address(0)) revert SubjectAlreadyLaunched(subject, existing);
    }

    /// @dev The exact, closed launch-time treasury refusal: the seven shared-system destinations a
    ///      launch's payouts must never land on — this factory, this strategy, the bound hook, the
    ///      frozen PoolManager, the frozen PositionManager, the frozen live staking contract and
    ///      the LP locker. A splitter treasury payout back to the locker would prevent fee forwarding.
    ///      Sending a launch's payouts to any of them would either strand them in an account with no
    ///      path back out or feed them into accounting that was never told about them.
    ///
    ///      Nothing else is judged. There is no `code.length` test, no `codehash` fingerprint, no
    ///      interface probe, no registry, no generalized denylist, and no predicted-address rule; the
    ///      list is seven exact addresses. The dead address, an
    ///      ordinary EOA, an arbitrary contract, a live CCA auction, the Governance and Regent Safe,
    ///      an already-deployed Autolaunch escrow, splitter or receiver, and an address a later
    ///      ordinary-CREATE clone of this strategy will occupy are all admitted.
    ///
    ///      The consequences of that admission are the launcher's, and they are named rather than
    ///      prevented. A treasury that cannot move what it receives strands its own launch's payouts.
    ///      A treasury that is another launch's artifact delivers this launch's payouts into that
    ///      artifact's ordinary accounting (`FAC-015`). A treasury that collides with an address this
    ///      strategy's current CREATE nonce would later produce makes that graduation's clone
    ///      initializer revert, which rolls the whole migration back — including the nonce advance —
    ///      so the launch stalls until an intervening graduation moves the nonce past it (`STR-019`).
    ///      None of those touches another launch's lifecycle, custody ledger or isolated reserve.
    ///
    ///      The escrow's own `treasury_ == address(this)` and zero-treasury refusals already ran, one
    ///      call earlier, on this launch's own escrow; they are preserved and not repeated here.
    function _requireAdmissibleTreasury(address treasury) private view {
        if (
            treasury == factory || treasury == address(this) || treasury == hook
                || treasury == BaseBindings.POOL_MANAGER || treasury == BaseBindings.POSITION_MANAGER
                || treasury == BaseBindings.LIVE_STAKING || treasury == address(lpLocker)
        ) revert RefusedTreasury(treasury);
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
