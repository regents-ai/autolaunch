// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {BaseBindings} from "../../src/bindings/BaseBindings.sol";
import {ConditionalVestingEscrowV1} from "../../src/escrow/ConditionalVestingEscrowV1.sol";
import {RegentFeeHook} from "../../src/hook/RegentFeeHook.sol";
import {PaymentReceiverV1} from "../../src/revenue/PaymentReceiverV1.sol";
import {SubjectSplitterV1} from "../../src/revenue/SubjectSplitterV1.sol";
import {RegentLBPStrategy} from "../../src/strategy/RegentLBPStrategy.sol";
import {ContinuousClearingAuction} from "continuous-clearing-auction/ContinuousClearingAuction.sol";
import {ContinuousClearingAuctionFactory} from "continuous-clearing-auction/ContinuousClearingAuctionFactory.sol";
import {IContinuousClearingAuction} from "continuous-clearing-auction/interfaces/IContinuousClearingAuction.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IPositionDescriptor} from "@uniswap/v4-periphery/src/interfaces/IPositionDescriptor.sol";
import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";
import {PositionManager} from "@uniswap/v4-periphery/src/PositionManager.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {MockLiveStaking} from "../mocks/MockLiveStaking.sol";
import {LaunchFactoryDouble} from "./doubles/LaunchFactoryDouble.sol";
import {Permit2Double} from "./doubles/Permit2Double.sol";
import {StagedERC20} from "./doubles/StagedERC20.sol";

/// @notice The C3 harness: the real pinned CCA factory, PoolManager and PositionManager placed at
///         their frozen Base bindings, the real C1 implementations, the real C2 hook, and the real
///         `RegentLBPStrategy` reached only through the production caller shape.
/// @dev Four deliberate choices keep this honest.
///
///      1. Every frozen binding is *constructed at its own address*: the creation code is etched
///         there and then called, so each constructor runs with `address(this)` equal to the frozen
///         address and every constructor storage write and immutable lands where production expects
///         it. Nothing about the dependency is stubbed, weakened or re-implemented.
///      2. The strategy is deployed against the address its factory will occupy, and that factory
///         binds the hook from inside its own constructor. That is the real Autolaunch ordering and
///         the reason the strategy constructor cannot require `factory.code.length > 0`.
///      3. Auctions are real `ContinuousClearingAuction` deployments created by the real factory,
///         driven by real bids, real checkpoints and the real final-price accounting.
///      4. Permit2 is the one dependency that cannot be built here — it pins `=0.8.17` against this
///         repository's frozen `0.8.26` compiler — so its allowance-transfer slice is a named C3
///         double and `SPEC.md` section 10 leaves real Permit2 runtime to the fork gate.
abstract contract StrategyFixture is Test {
    using StateLibrary for IPoolManager;

    uint256 internal constant TOTAL_SUPPLY = 100_000_000_000e18;
    uint256 internal constant PENDING_ALLOCATION = 85_000_000_000e18;
    uint256 internal constant AUCTION_ALLOCATION = 10_000_000_000e18;
    uint256 internal constant RESERVE_ALLOCATION = 5_000_000_000e18;
    uint256 internal constant DISTRIBUTION_PULL = 15_000_000_000e18;

    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    /// @dev Exactly the three permission bits `RegentFeeHook` declares.
    uint160 internal constant HOOK_FLAGS =
        uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG);
    address internal constant HOOK_ADDRESS = address(uint160(uint256(0x3333) << 144) | HOOK_FLAGS);

    /// @dev Chosen so `SUBJECT_LOW < REGENT < SUBJECT_HIGH`, giving both PoolKey orderings.
    address internal constant SUBJECT_LOW = 0x1111111111111111111111111111111111111111;
    address internal constant SUBJECT_HIGH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    address internal constant SUBJECT_LOW_ALT = 0x2222222222222222222222222222222222222222;

    struct Launch {
        StagedERC20 subject;
        ConditionalVestingEscrowV1 escrow;
        IContinuousClearingAuction auction;
    }

    RegentLBPStrategy internal strategy;
    RegentFeeHook internal hook;
    LaunchFactoryDouble internal factory;

    ConditionalVestingEscrowV1 internal escrowImplementation;
    SubjectSplitterV1 internal splitterImplementation;
    PaymentReceiverV1 internal receiverImplementation;

    StagedERC20 internal regent;
    PoolManager internal poolManager;
    IPositionManager internal positionManager;
    ContinuousClearingAuctionFactory internal ccaFactory;

    address internal treasury = makeAddr("treasury");
    address internal outsider = makeAddr("outsider");
    address internal bidder = makeAddr("bidder");

    // -------------------------------------------------------------------------
    // deployment
    // -------------------------------------------------------------------------

    function _deployC3() internal {
        vm.roll(1_000_000);

        regent = _etchToken(BaseBindings.REGENT);
        _etchToken(BaseBindings.USDC);
        _constructAt(PERMIT2, type(Permit2Double).creationCode);
        _constructAt(
            BaseBindings.LIVE_STAKING,
            abi.encodePacked(type(MockLiveStaking).creationCode, abi.encode(BaseBindings.USDC))
        );
        _constructAt(
            BaseBindings.POOL_MANAGER, abi.encodePacked(type(PoolManager).creationCode, abi.encode(address(this)))
        );
        _constructAt(
            BaseBindings.CCA_FACTORY,
            abi.encodePacked(type(ContinuousClearingAuctionFactory).creationCode, abi.encode(address(0)))
        );
        _constructAt(
            BaseBindings.POSITION_MANAGER,
            abi.encodePacked(
                type(PositionManager).creationCode,
                abi.encode(
                    IPoolManager(BaseBindings.POOL_MANAGER),
                    IAllowanceTransfer(PERMIT2),
                    uint256(300_000),
                    IPositionDescriptor(address(0)),
                    IWETH9(payable(address(0)))
                )
            )
        );

        poolManager = PoolManager(BaseBindings.POOL_MANAGER);
        positionManager = IPositionManager(BaseBindings.POSITION_MANAGER);
        ccaFactory = ContinuousClearingAuctionFactory(BaseBindings.CCA_FACTORY);

        escrowImplementation = new ConditionalVestingEscrowV1();
        splitterImplementation = new SubjectSplitterV1();
        receiverImplementation = new PaymentReceiverV1();

        address predictedFactory = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        strategy = new RegentLBPStrategy(
            predictedFactory,
            address(escrowImplementation),
            address(splitterImplementation),
            address(receiverImplementation)
        );

        _constructAt(
            HOOK_ADDRESS,
            abi.encodePacked(type(RegentFeeHook).creationCode, abi.encode(BaseBindings.POOL_MANAGER, address(strategy)))
        );
        hook = RegentFeeHook(HOOK_ADDRESS);

        factory = new LaunchFactoryDouble(address(strategy), HOOK_ADDRESS);
        require(address(factory) == predictedFactory, "StrategyFixture: factory address prediction failed");
    }

    /// @dev Run a real constructor at an exact address, so its storage writes and immutables land
    ///      where production expects them. Reverts loudly rather than leaving a half-built binding.
    function _constructAt(address where, bytes memory initcode) internal {
        vm.etch(where, initcode);
        // solhint-disable-next-line avoid-low-level-calls
        (bool ok, bytes memory runtime) = where.call("");
        require(ok && runtime.length != 0, "StrategyFixture: construction at address failed");
        vm.etch(where, runtime);
    }

    function _etchToken(address where) internal returns (StagedERC20 token) {
        StagedERC20 template = new StagedERC20();
        vm.etch(where, address(template).code);
        token = StagedERC20(where);
    }

    // -------------------------------------------------------------------------
    // launches
    // -------------------------------------------------------------------------

    function _newLaunch(address subjectAt, uint256 launchId, uint128 requiredRegentRaised)
        internal
        returns (Launch memory launch)
    {
        launch.subject = _etchToken(subjectAt);
        launch.subject.mint(address(factory), TOTAL_SUPPLY);

        (address escrow, address auction) = factory.launch(subjectAt, treasury, launchId, requiredRegentRaised);
        launch.escrow = ConditionalVestingEscrowV1(escrow);
        launch.auction = IContinuousClearingAuction(auction);
    }

    /// @dev The default launch: SUBJECT sorts below REGENT, so REGENT is the pool's currency1.
    function _defaultLaunch() internal returns (Launch memory launch) {
        launch = _newLaunch(SUBJECT_LOW, 1, 1_000e18);
    }

    /// @notice The two addresses the strategy's next two ordinary `CREATE` clones will occupy.
    /// @dev Graduation deploys the splitter and then the canonical receiver with `LibClone.clone`, so
    ///      both addresses are functions of the strategy's *current* nonce and of nothing a launch
    ///      chose. They are therefore facts only for as long as that nonce stands: any successful
    ///      graduation moves them. Production never derives them; a test may, to observe them.
    function _nextCloneAddresses() internal view returns (address splitter, address receiver) {
        uint64 nonce = vm.getNonce(address(strategy));
        splitter = vm.computeCreateAddress(address(strategy), nonce);
        receiver = vm.computeCreateAddress(address(strategy), nonce + 1);
    }

    // -------------------------------------------------------------------------
    // auction driving
    // -------------------------------------------------------------------------

    function _bidPrice(uint256 ticksAboveFloor) internal view returns (uint256) {
        return strategy.FLOOR_PRICE_Q96() + ticksAboveFloor * strategy.BID_TICK_Q96();
    }

    function _bid(Launch memory launch, address account, uint128 amount, uint256 priceQ96) internal {
        regent.mint(account, amount);
        vm.startPrank(account);
        regent.approve(PERMIT2, type(uint256).max);
        Permit2Double(PERMIT2).approve(address(regent), address(launch.auction), uint160(amount), type(uint48).max);
        launch.auction.submitBid(priceQ96, amount, account, strategy.FLOOR_PRICE_Q96(), "");
        vm.stopPrank();
    }

    function _rollToStart(Launch memory launch) internal {
        vm.roll(launch.auction.startBlock());
    }

    function _rollToMigration(Launch memory launch) internal {
        vm.roll(uint256(launch.auction.endBlock()) + strategy.MIGRATION_DELAY_BLOCKS());
    }

    /// @dev One economically successful launch: a single bid above the floor, comfortably above the
    ///      required raise, then time to migration eligibility.
    function _bidToGraduation(Launch memory launch, uint128 amount) internal {
        _bidToGraduationAt(launch, amount, 10);
    }

    /// @dev A raise large enough that the fixed 5% reserve, not the raise, limits the position, so
    ///      graduation really does have unused REGENT to route to the treasury.
    function _bidToGraduationAt(Launch memory launch, uint128 amount, uint256 ticksAboveFloor) internal {
        _rollToStart(launch);
        _bid(launch, bidder, amount, _bidPrice(ticksAboveFloor));
        _rollToMigration(launch);
    }

    // -------------------------------------------------------------------------
    // observation
    // -------------------------------------------------------------------------

    struct Ledger {
        uint8 lifecycle;
        address recordedSplitter;
        address recordedReceiver;
        uint256 recordedLpTokenId;
        uint160 recordedFinalSqrtPrice;
        uint64 strategyNonce;
        uint256 strategyRegent;
        uint256 strategySubject;
        uint256 treasuryRegent;
        uint256 escrowSubject;
        uint256 auctionRegent;
        uint256 auctionSubject;
        uint256 auctionSweepCurrencyBlock;
        uint256 auctionSweepUnsoldTokensBlock;
        uint256 deadSubject;
        uint256 poolManagerRegent;
        uint256 poolManagerSubject;
        uint256 positionManagerRegent;
        uint256 positionManagerSubject;
        uint256 nextTokenId;
        uint160 poolSqrtPrice;
        address registeredSplitter;
        uint8 escrowLifecycle;
        bool escrowSweepDone;
        uint64 escrowVestingStart;
        address registeredCanonicalAuction;
    }

    function _ledger(Launch memory launch) internal view returns (Ledger memory snapshot) {
        RegentLBPStrategy.Distribution memory d = strategy.distribution(address(launch.auction));
        snapshot.lifecycle = uint8(d.lifecycle);
        snapshot.recordedSplitter = d.splitter;
        snapshot.recordedReceiver = d.receiver;
        snapshot.recordedLpTokenId = d.lpTokenId;
        snapshot.recordedFinalSqrtPrice = d.finalSqrtPriceX96;
        // A clone the strategy created and then rolled back would leave this incremented.
        snapshot.strategyNonce = vm.getNonce(address(strategy));
        snapshot.strategyRegent = regent.balanceOf(address(strategy));
        snapshot.strategySubject = launch.subject.balanceOf(address(strategy));
        snapshot.treasuryRegent = regent.balanceOf(treasury);
        snapshot.escrowSubject = launch.subject.balanceOf(address(launch.escrow));
        snapshot.auctionRegent = regent.balanceOf(address(launch.auction));
        snapshot.auctionSubject = launch.subject.balanceOf(address(launch.auction));
        // The sweep records are public state on the pinned auction but not on its interface.
        ContinuousClearingAuction auction = ContinuousClearingAuction(address(launch.auction));
        snapshot.auctionSweepCurrencyBlock = auction.sweepCurrencyBlock();
        snapshot.auctionSweepUnsoldTokensBlock = auction.sweepUnsoldTokensBlock();
        snapshot.deadSubject = launch.subject.balanceOf(BaseBindings.DEAD_ADDRESS);
        snapshot.poolManagerRegent = regent.balanceOf(BaseBindings.POOL_MANAGER);
        snapshot.poolManagerSubject = launch.subject.balanceOf(BaseBindings.POOL_MANAGER);
        snapshot.positionManagerRegent = regent.balanceOf(BaseBindings.POSITION_MANAGER);
        snapshot.positionManagerSubject = launch.subject.balanceOf(BaseBindings.POSITION_MANAGER);
        snapshot.nextTokenId = positionManager.nextTokenId();
        (snapshot.poolSqrtPrice,,,) = IPoolManager(BaseBindings.POOL_MANAGER).getSlot0(_poolId(launch));
        snapshot.registeredSplitter = hook.splitterOf(_poolId(launch));
        snapshot.escrowLifecycle = uint8(launch.escrow.lifecycle());
        snapshot.escrowSweepDone = launch.escrow.graduatedSweepDone();
        snapshot.escrowVestingStart = launch.escrow.vestingStart();
        snapshot.registeredCanonicalAuction = factory.registeredCanonicalAuction();
    }

    function _poolId(Launch memory launch) internal view returns (PoolId) {
        return strategy.poolKeyOf(address(launch.subject)).toId();
    }

    function _assertLedgerUnchanged(Ledger memory before, Ledger memory found, string memory stage) internal pure {
        assertEq(found.lifecycle, before.lifecycle, string.concat(stage, ": lifecycle moved"));
        assertEq(found.recordedSplitter, before.recordedSplitter, string.concat(stage, ": a splitter was recorded"));
        assertEq(found.recordedReceiver, before.recordedReceiver, string.concat(stage, ": a receiver was recorded"));
        assertEq(found.recordedLpTokenId, before.recordedLpTokenId, string.concat(stage, ": an LP token was recorded"));
        assertEq(
            found.recordedFinalSqrtPrice,
            before.recordedFinalSqrtPrice,
            string.concat(stage, ": a final price was recorded")
        );
        assertEq(found.strategyNonce, before.strategyNonce, string.concat(stage, ": a clone survived"));
        assertEq(found.strategyRegent, before.strategyRegent, string.concat(stage, ": strategy REGENT moved"));
        assertEq(found.strategySubject, before.strategySubject, string.concat(stage, ": strategy SUBJECT moved"));
        assertEq(found.treasuryRegent, before.treasuryRegent, string.concat(stage, ": treasury REGENT moved"));
        assertEq(found.escrowSubject, before.escrowSubject, string.concat(stage, ": escrow SUBJECT moved"));
        assertEq(found.auctionRegent, before.auctionRegent, string.concat(stage, ": auction REGENT moved"));
        assertEq(found.auctionSubject, before.auctionSubject, string.concat(stage, ": auction SUBJECT moved"));
        assertEq(
            found.auctionSweepCurrencyBlock,
            before.auctionSweepCurrencyBlock,
            string.concat(stage, ": the auction's currency sweep ran")
        );
        assertEq(
            found.auctionSweepUnsoldTokensBlock,
            before.auctionSweepUnsoldTokensBlock,
            string.concat(stage, ": the auction's token sweep ran")
        );
        assertEq(found.deadSubject, before.deadSubject, string.concat(stage, ": dead-address SUBJECT moved"));
        assertEq(found.poolManagerRegent, before.poolManagerRegent, string.concat(stage, ": PoolManager REGENT moved"));
        assertEq(
            found.poolManagerSubject, before.poolManagerSubject, string.concat(stage, ": PoolManager SUBJECT moved")
        );
        assertEq(
            found.positionManagerRegent,
            before.positionManagerRegent,
            string.concat(stage, ": PositionManager REGENT moved")
        );
        assertEq(
            found.positionManagerSubject,
            before.positionManagerSubject,
            string.concat(stage, ": PositionManager SUBJECT moved")
        );
        assertEq(found.nextTokenId, before.nextTokenId, string.concat(stage, ": an LP NFT was minted"));
        assertEq(found.poolSqrtPrice, before.poolSqrtPrice, string.concat(stage, ": the pool was initialized"));
        assertEq(found.registeredSplitter, before.registeredSplitter, string.concat(stage, ": the pool was registered"));
        assertEq(found.escrowLifecycle, before.escrowLifecycle, string.concat(stage, ": escrow lifecycle moved"));
        assertEq(found.escrowSweepDone, before.escrowSweepDone, string.concat(stage, ": escrow sweep ran"));
        assertEq(found.escrowVestingStart, before.escrowVestingStart, string.concat(stage, ": vesting started"));
        assertEq(
            found.registeredCanonicalAuction,
            before.registeredCanonicalAuction,
            string.concat(stage, ": canonical receiver registration survived")
        );
    }
}
