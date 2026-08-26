// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {BaseBindings} from "../../src/bindings/BaseBindings.sol";
import {ConditionalVestingEscrowV1} from "../../src/escrow/ConditionalVestingEscrowV1.sol";
import {RegentFeeHook} from "../../src/hook/RegentFeeHook.sol";
import {PaymentReceiverV1} from "../../src/revenue/PaymentReceiverV1.sol";
import {SubjectSplitterV1} from "../../src/revenue/SubjectSplitterV1.sol";
import {RegentLBPStrategy} from "../../src/strategy/RegentLBPStrategy.sol";
import {IContinuousClearingAuction} from "continuous-clearing-auction/interfaces/IContinuousClearingAuction.sol";
import {MaxBidPriceLib} from "continuous-clearing-auction/libraries/MaxBidPriceLib.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PositionInfo, PositionInfoLibrary} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {ContinuousClearingAuctionFactory} from "continuous-clearing-auction/ContinuousClearingAuctionFactory.sol";
import {AuctionParameters} from "continuous-clearing-auction/interfaces/IContinuousClearingAuction.sol";
import {StrategyFixture} from "./StrategyFixture.sol";
import {StagedERC20} from "./doubles/StagedERC20.sol";

/// @notice The C3 authority, canonical-auction, isolation and terminal-decision claims, proved
///         against the real pinned CCA, PoolManager and PositionManager through the production
///         caller shape.
contract RegentLBPStrategyTest is StrategyFixture {
    using StateLibrary for IPoolManager;
    using PositionInfoLibrary for PositionInfo;

    function setUp() public {
        _deployC3();
    }

    // -------------------------------------------------------------------------
    // C3-I1 — exact one-time authority
    // -------------------------------------------------------------------------

    /// @notice `C3-I1`: the factory and the three clone implementations are immutable, and the hook
    ///         is bound exactly once and never replaced.
    function test_STR_001_FactoryAndHookBindingIsIrreversible() public {
        assertEq(strategy.factory(), address(factory), "factory binding");
        assertEq(strategy.hook(), HOOK_ADDRESS, "hook binding");

        vm.prank(address(factory));
        vm.expectRevert(abi.encodeWithSelector(RegentLBPStrategy.HookAlreadyBound.selector, HOOK_ADDRESS));
        strategy.bindHook(HOOK_ADDRESS);

        address rival = address(uint160(uint256(0x5555) << 144) | HOOK_FLAGS);
        _constructAt(
            rival,
            abi.encodePacked(type(RegentFeeHook).creationCode, abi.encode(BaseBindings.POOL_MANAGER, address(strategy)))
        );
        vm.prank(address(factory));
        vm.expectRevert(abi.encodeWithSelector(RegentLBPStrategy.HookAlreadyBound.selector, HOOK_ADDRESS));
        strategy.bindHook(rival);

        assertEq(strategy.hook(), HOOK_ADDRESS, "hook binding survived both attempts");
    }

    /// @notice `C3-I1`: only the bound factory may bind, and only a deployed hook whose own immutable
    ///         bindings point back at this strategy and at the frozen PoolManager is accepted.
    function test_STR_001_BindHookRejectsCodelessOrMismatchedHooks() public {
        // A second strategy, still unbound, is the subject of every rejection below.
        RegentLBPStrategy fresh = new RegentLBPStrategy(
            address(this),
            address(escrowImplementation),
            address(splitterImplementation),
            address(receiverImplementation)
        );

        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(RegentLBPStrategy.NotFactory.selector, outsider));
        fresh.bindHook(HOOK_ADDRESS);

        address codeless = address(uint160(uint256(0x6666) << 144) | HOOK_FLAGS);
        vm.expectRevert(abi.encodeWithSelector(RegentLBPStrategy.HookHasNoCode.selector, codeless));
        fresh.bindHook(codeless);

        // A real hook, but bound to a different strategy.
        vm.expectRevert(
            abi.encodeWithSelector(RegentLBPStrategy.HookBindingMismatch.selector, address(fresh), address(strategy))
        );
        fresh.bindHook(HOOK_ADDRESS);

        // A real hook bound to `fresh`, but carrying a foreign PoolManager.
        address foreignManager = address(uint160(uint256(0x7777) << 144) | HOOK_FLAGS);
        _constructAt(
            foreignManager,
            abi.encodePacked(type(RegentFeeHook).creationCode, abi.encode(address(this), address(fresh)))
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                RegentLBPStrategy.HookBindingMismatch.selector, BaseBindings.POOL_MANAGER, address(this)
            )
        );
        fresh.bindHook(foreignManager);

        assertEq(fresh.hook(), address(0), "no rejected hook was ever bound");
    }

    /// @notice `C3-I1`: the canonical factory binds the hook from inside its own constructor, when it
    ///         still has no code. That is why the strategy constructor cannot demand factory code.
    function test_STR_001_FactoryBindsWhileStillConstructing() public {
        assertGt(address(factory).code.length, 0, "the factory has code now");
        assertEq(strategy.hook(), HOOK_ADDRESS, "the hook was bound during that construction");

        // The same ordering, proved directly: a fresh strategy bound to an address that has no code
        // at construction time, and a factory that binds from its own constructor body.
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        assertEq(predicted.code.length, 0, "the future factory has no code yet");

        RegentLBPStrategy fresh = new RegentLBPStrategy(
            predicted, address(escrowImplementation), address(splitterImplementation), address(receiverImplementation)
        );
        address freshHook = address(uint160(uint256(0x8888) << 144) | HOOK_FLAGS);
        _constructAt(
            freshHook,
            abi.encodePacked(type(RegentFeeHook).creationCode, abi.encode(BaseBindings.POOL_MANAGER, address(fresh)))
        );

        assertEq(address(new ConstructorBinder(address(fresh), freshHook)), predicted, "predicted factory address");
        assertEq(fresh.hook(), freshHook, "the constructing factory bound the hook");
    }

    /// @notice `C3-I1`: every constructor binding is validated once and then permanent.
    function test_STR_001_ImmutableBindingsAreFixedAtConstruction() public {
        assertEq(strategy.escrowImplementation(), address(escrowImplementation), "escrow implementation");
        assertEq(strategy.splitterImplementation(), address(splitterImplementation), "splitter implementation");
        assertEq(strategy.receiverImplementation(), address(receiverImplementation), "receiver implementation");

        vm.expectRevert(RegentLBPStrategy.ZeroAddress.selector);
        new RegentLBPStrategy(
            address(0), address(escrowImplementation), address(splitterImplementation), address(receiverImplementation)
        );

        vm.expectRevert(abi.encodeWithSelector(RegentLBPStrategy.ImplementationHasNoCode.selector, outsider));
        new RegentLBPStrategy(
            address(factory), outsider, address(splitterImplementation), address(receiverImplementation)
        );

        vm.expectRevert(abi.encodeWithSelector(RegentLBPStrategy.ImplementationHasNoCode.selector, outsider));
        new RegentLBPStrategy(
            address(factory), address(escrowImplementation), outsider, address(receiverImplementation)
        );

        vm.expectRevert(abi.encodeWithSelector(RegentLBPStrategy.ImplementationHasNoCode.selector, outsider));
        new RegentLBPStrategy(
            address(factory), address(escrowImplementation), address(splitterImplementation), outsider
        );
    }

    /// @notice `C3-I1`: distribution creation is factory-only.
    function test_STR_002_OnlyTheBoundFactoryInitializesDistributions() public {
        StagedERC20 subject = _etchToken(SUBJECT_LOW);
        subject.mint(address(factory), TOTAL_SUPPLY);
        address escrow = factory.fundedEscrow(SUBJECT_LOW, treasury);

        RegentLBPStrategy.DistributionParams memory params =
            RegentLBPStrategy.DistributionParams({launchId: 1, escrow: escrow, requiredRegentRaised: 1_000e18});

        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(RegentLBPStrategy.NotFactory.selector, outsider));
        strategy.initializeDistribution(params);

        // The escrow's own funding is untouched and the launch is still creatable by the factory.
        assertEq(subject.balanceOf(escrow), PENDING_ALLOCATION, "escrow custody untouched");
        address auction = factory.initialize(SUBJECT_LOW, escrow, 1, 1_000e18);
        assertEq(strategy.auctionOfSubject(SUBJECT_LOW), auction, "the bound factory succeeds");
    }

    /// @notice `C3-I1`: no distribution can exist before the hook is bound.
    function test_STR_002_InitializationIsImpossibleBeforeHookBinding() public {
        RegentLBPStrategy fresh = new RegentLBPStrategy(
            address(this),
            address(escrowImplementation),
            address(splitterImplementation),
            address(receiverImplementation)
        );
        assertEq(fresh.hook(), address(0), "unbound");

        vm.expectRevert(RegentLBPStrategy.HookNotBound.selector);
        fresh.initializeDistribution(
            RegentLBPStrategy.DistributionParams({
                launchId: 1, escrow: address(escrowImplementation), requiredRegentRaised: 1_000e18
            })
        );
    }

    /// @notice `C3-I1`: migration is permissionless — an unrelated account drives a real launch to
    ///         graduation and no privileged account is involved anywhere in the path.
    function test_STR_003_MigrateIsPermissionless() public {
        Launch memory launch = _defaultLaunch();
        _bidToGraduation(launch, 2_000e18);

        vm.prank(outsider);
        strategy.migrate(address(launch.auction));

        RegentLBPStrategy.Distribution memory d = strategy.distribution(address(launch.auction));
        assertEq(uint8(d.lifecycle), uint8(RegentLBPStrategy.Lifecycle.Graduated), "graduated by an outsider");
    }

    // -------------------------------------------------------------------------
    // C3-I2 — canonical fixed auction
    // -------------------------------------------------------------------------

    function test_STR_005_AuctionDurationIs86401Blocks() public {
        Launch memory launch = _defaultLaunch();
        assertEq(strategy.AUCTION_DURATION_BLOCKS(), 86_401, "frozen duration constant");
        assertEq(
            uint256(launch.auction.endBlock()) - launch.auction.startBlock(), 86_401, "the created auction's duration"
        );
        assertEq(
            uint256(strategy.distribution(address(launch.auction)).endBlock),
            uint256(launch.auction.endBlock()),
            "recorded end block"
        );
    }

    function test_STR_006_ClaimDelayIs64Blocks() public {
        Launch memory launch = _defaultLaunch();
        assertEq(strategy.CLAIM_DELAY_BLOCKS(), 64, "frozen claim delay constant");
        assertEq(
            uint256(launch.auction.claimBlock()) - launch.auction.endBlock(), 64, "the created auction's claim delay"
        );
        assertEq(
            uint256(strategy.distribution(address(launch.auction)).claimBlock),
            uint256(launch.auction.claimBlock()),
            "recorded claim block"
        );
    }

    function test_STR_007_MigrationEligibilityIsEndPlus128Blocks() public {
        Launch memory launch = _defaultLaunch();
        assertEq(strategy.MIGRATION_DELAY_BLOCKS(), 128, "frozen migration delay constant");

        RegentLBPStrategy.Distribution memory d = strategy.distribution(address(launch.auction));
        assertEq(uint256(d.migrationBlock), uint256(launch.auction.endBlock()) + 128, "recorded migration block");

        _bidToGraduation(launch, 2_000e18);
        vm.roll(uint256(d.migrationBlock) - 1);
        vm.expectRevert(
            abi.encodeWithSelector(RegentLBPStrategy.MigrationNotYetAllowed.selector, d.migrationBlock, block.number)
        );
        strategy.migrate(address(launch.auction));

        vm.roll(d.migrationBlock);
        strategy.migrate(address(launch.auction));
        assertEq(
            uint8(strategy.distribution(address(launch.auction)).lifecycle),
            uint8(RegentLBPStrategy.Lifecycle.Graduated),
            "eligible exactly at end plus 128"
        );
    }

    /// @notice `C3-I2`: the schedule the strategy hands the CCA is the founder-frozen 104-byte,
    ///         thirteen-step vector byte for byte, and the auction the CCA builds from it spans the
    ///         frozen duration and issues the whole supply.
    /// @dev The vector below is the fixed economics — the manifest's `auction.schedule_bytes` and the
    ///      archived `AutolaunchFactoryV1._schedule` — restated here so this test fails on any single
    ///      changed byte, not merely on a schedule that happens to share its length and its sums.
    function test_STR_008_ScheduleIsTheFrozen104ByteThirteenStepSchedule() public {
        bytes memory frozen = hex"0000360000002a8e" hex"0000440000002145" hex"00004b0000001e7b" hex"00004f0000001ccd"
            hex"0000530000001b9c" hex"0000550000001ab3" hex"00005800000019f7" hex"00005a000000195a"
            hex"00005c00000018d4" hex"00005e000000185e" hex"00005f00000017f8" hex"000061000000179b"
            hex"2d97e60000000001";

        bytes memory steps = strategy.AUCTION_STEPS();
        assertEq(steps, frozen, "the schedule is the frozen vector, byte for byte");
        assertEq(steps.length, 104, "104 bytes");
        assertEq(steps.length / 8, 13, "thirteen eight-byte steps");

        // The same vector read as the pinned `StepLib` reads it, so its shape is proved and not
        // merely restated: twelve scheduled steps and one terminal single-block step.
        uint256 totalMps;
        uint256 totalBlocks;
        for (uint256 offset; offset < steps.length; offset += 8) {
            (uint24 mps, uint40 blockDelta) = _readStep(steps, offset);
            assertGt(mps, 0, "no step issues nothing");
            assertGt(blockDelta, 0, "no step has a zero block delta");
            totalMps += uint256(mps) * blockDelta;
            totalBlocks += blockDelta;
        }
        assertEq(totalMps, 1e7, "the schedule issues exactly the whole supply");
        assertEq(totalBlocks, strategy.AUCTION_DURATION_BLOCKS(), "the schedule spans exactly the frozen duration");

        (uint24 firstMps, uint40 firstBlocks) = _readStep(steps, 0);
        assertEq(firstMps, 54, "the first step's rate");
        assertEq(firstBlocks, 10_894, "the first step's window");
        (uint24 lastMps, uint40 lastBlocks) = _readStep(steps, 96);
        assertEq(lastMps, 2_988_006, "the terminal step's rate");
        assertEq(lastBlocks, 1, "the terminal step is one block");

        // The pinned `StepStorage` constructor validates the same two sums; a real auction exists.
        Launch memory launch = _defaultLaunch();
        assertGt(address(launch.auction).code.length, 0, "the pinned CCA accepted the frozen schedule");
    }

    function test_STR_009_FloorPriceIsTheFrozenQ96Value() public {
        Launch memory launch = _defaultLaunch();
        assertEq(strategy.FLOOR_PRICE_Q96(), 79_228_162_514_264_337_593_543_900, "frozen floor constant");
        assertEq(launch.auction.floorPrice(), strategy.FLOOR_PRICE_Q96(), "the created auction's floor");
        assertEq(launch.auction.clearingPrice(), strategy.FLOOR_PRICE_Q96(), "the auction opens at the floor");
    }

    function test_STR_010_BidTickIsTheFrozenQ96Value() public {
        Launch memory launch = _defaultLaunch();
        assertEq(strategy.BID_TICK_Q96(), 792_281_625_142_643_375_935_439, "frozen bid tick constant");
        assertEq(launch.auction.tickSpacing(), strategy.BID_TICK_Q96(), "the created auction's tick spacing");
        assertEq(strategy.FLOOR_PRICE_Q96() % strategy.BID_TICK_Q96(), 0, "the floor sits on a tick boundary");
    }

    function test_STR_011_AuctionProtocolFeeIsZero() public {
        assertEq(address(ccaFactory.protocolFeeController()), address(0), "the bound CCA factory takes no fee");

        Launch memory launch = _defaultLaunch();
        _bidToGraduation(launch, 2_000e18);

        strategy.migrate(address(launch.auction));

        // After the final checkpoint the auction reports both numbers, and they are equal because
        // the bound factory's protocol fee controller is the zero address.
        uint256 grossRaised = launch.auction.currencyRaised();
        assertEq(_raisedOf(launch), grossRaised, "the fee-adjusted raise equals the whole raise");

        RegentLBPStrategy.Distribution memory d = strategy.distribution(address(launch.auction));
        assertEq(regent.balanceOf(address(launch.auction)), 0, "the auction kept no REGENT for a fee");
        assertEq(
            regent.balanceOf(treasury) + d.lpRegentUsed, grossRaised, "every raised unit reached LP or the treasury"
        );
    }

    /// @notice `C3-I2`: a CCA factory that reports a non-zero protocol fee controller is refused
    ///         before any value moves.
    function test_STR_011_NonZeroProtocolFeeControllerIsRejected() public {
        StagedERC20 subject = _etchToken(SUBJECT_LOW);
        subject.mint(address(factory), TOTAL_SUPPLY);
        address escrow = factory.fundedEscrow(SUBJECT_LOW, treasury);

        // Rebuild the frozen CCA factory binding with a non-zero controller.
        _constructAt(
            BaseBindings.CCA_FACTORY,
            abi.encodePacked(type(ContinuousClearingAuctionFactory).creationCode, abi.encode(outsider))
        );

        vm.expectRevert(abi.encodeWithSelector(RegentLBPStrategy.ProtocolFeeControllerNotZero.selector, outsider));
        factory.initialize(SUBJECT_LOW, escrow, 1, 1_000e18);

        assertEq(subject.balanceOf(address(strategy)), 0, "no reserve was pulled");
        assertEq(strategy.auctionOfSubject(SUBJECT_LOW), address(0), "no launch was recorded");
    }

    // -------------------------------------------------------------------------
    // C3-I3 — launch isolation
    // -------------------------------------------------------------------------

    /// @notice `C3-I3`: two simultaneous launches sharing this strategy keep separate reserves, and
    ///         neither launch's terminal path can consume the other's.
    function test_STR_012_ReserveIsIsolatedPerAuction() public {
        Launch memory a = _newLaunch(SUBJECT_LOW, 1, 1_000e18);
        Launch memory b = _newLaunch(SUBJECT_HIGH, 2, 1_000e18);

        assertEq(a.subject.balanceOf(address(strategy)), RESERVE_ALLOCATION, "launch A reserve");
        assertEq(b.subject.balanceOf(address(strategy)), RESERVE_ALLOCATION, "launch B reserve");
        assertEq(strategy.distribution(address(a.auction)).reserve, RESERVE_ALLOCATION, "recorded reserve A");
        assertEq(strategy.distribution(address(b.auction)).reserve, RESERVE_ALLOCATION, "recorded reserve B");

        // A fails; B's reserve is untouched.
        _rollToStart(a);
        _rollToMigration(a);
        strategy.migrate(address(a.auction));

        assertEq(a.subject.balanceOf(address(strategy)), 0, "launch A reserve left for its own escrow");
        assertEq(b.subject.balanceOf(address(strategy)), RESERVE_ALLOCATION, "launch B reserve untouched");
        assertEq(a.subject.balanceOf(BaseBindings.DEAD_ADDRESS), TOTAL_SUPPLY, "launch A retired its whole supply");

        // B then graduates on its own reserve.
        _bidToGraduation(b, 2_000e18);
        strategy.migrate(address(b.auction));
        assertEq(
            uint8(strategy.distribution(address(b.auction)).lifecycle),
            uint8(RegentLBPStrategy.Lifecycle.Graduated),
            "launch B graduated"
        );
        assertEq(a.subject.balanceOf(address(strategy)), 0, "launch B never touched launch A's SUBJECT");
    }

    /// @notice `C3-I3`: one SUBJECT maps to exactly one auction, forever.
    function test_STR_012_SimultaneousLaunchesCannotShareAReserve() public {
        Launch memory a = _newLaunch(SUBJECT_LOW, 1, 1_000e18);

        // The one escrow that a second launch could reuse is this launch's own: it is authentic, it
        // is still pending, and it still holds the exact 85%. A second auction over the same SUBJECT
        // is refused before any second reserve can be pulled.
        vm.expectRevert(
            abi.encodeWithSelector(RegentLBPStrategy.SubjectAlreadyLaunched.selector, SUBJECT_LOW, address(a.auction))
        );
        factory.initialize(SUBJECT_LOW, address(a.escrow), 2, 1_000e18);

        assertEq(strategy.auctionOfSubject(SUBJECT_LOW), address(a.auction), "the first auction still owns it");
        assertEq(a.subject.balanceOf(address(strategy)), RESERVE_ALLOCATION, "exactly one reserve");
        assertEq(a.subject.totalSupply(), TOTAL_SUPPLY, "one launch, one hundred billion");
    }

    // -------------------------------------------------------------------------
    // C3-I2 — canonical initialization admits only the frozen set
    // -------------------------------------------------------------------------

    /// @notice `C3-I2`: every field of the created auction is the frozen one, read back from the
    ///         auction itself, and the 10/5 split lands exactly.
    function test_STR_013_CanonicalInitializationAdmitsOnlyTheFrozenParameterSet() public {
        uint64 expectedStart = uint64(block.number) + strategy.START_DELAY_BLOCKS();
        Launch memory launch = _newLaunch(SUBJECT_LOW, 7, 4_000e18);
        IContinuousClearingAuction auction = launch.auction;

        assertEq(auction.token(), address(launch.subject), "token");
        assertEq(auction.currency(), BaseBindings.REGENT, "currency");
        assertEq(uint256(auction.totalSupply()), AUCTION_ALLOCATION, "auction supply");
        assertEq(auction.tokensRecipient(), address(launch.escrow), "tokens recipient is escrow");
        assertEq(auction.fundsRecipient(), address(strategy), "funds recipient is the strategy");
        assertEq(uint256(auction.startBlock()), expectedStart, "start block");
        assertEq(uint256(auction.endBlock()), expectedStart + 86_401, "end block");
        assertEq(uint256(auction.claimBlock()), expectedStart + 86_401 + 64, "claim block");
        assertEq(address(auction.validationHook()), address(0), "no validation hook");
        assertEq(auction.floorPrice(), strategy.FLOOR_PRICE_Q96(), "floor price");
        assertEq(auction.tickSpacing(), strategy.BID_TICK_Q96(), "bid tick");

        assertEq(launch.subject.balanceOf(address(auction)), AUCTION_ALLOCATION, "exactly 10% at the auction");
        assertEq(launch.subject.balanceOf(address(strategy)), RESERVE_ALLOCATION, "exactly 5% at the strategy");
        assertEq(launch.subject.balanceOf(address(launch.escrow)), PENDING_ALLOCATION, "exactly 85% at escrow");
        assertEq(launch.subject.balanceOf(address(factory)), 0, "the factory kept nothing");

        RegentLBPStrategy.Distribution memory d = strategy.distribution(address(auction));
        assertEq(d.launchId, 7, "recorded launch id");
        assertEq(d.subject, address(launch.subject), "recorded subject");
        assertEq(d.escrow, address(launch.escrow), "recorded escrow");
        assertEq(d.treasury, treasury, "treasury derived from escrow");
        assertEq(d.requiredRegentRaised, 4_000e18, "recorded required raise");
        assertEq(uint8(d.lifecycle), uint8(RegentLBPStrategy.Lifecycle.Active), "active");
    }

    function test_STR_013_StartIsAlwaysCurrentBlockPlus1800() public {
        assertEq(strategy.START_DELAY_BLOCKS(), 1_800, "frozen start delay");

        vm.roll(2_500_000);
        Launch memory launch = _newLaunch(SUBJECT_LOW, 1, 1_000e18);
        assertEq(uint256(launch.auction.startBlock()), 2_500_000 + 1_800, "start is derived from the current block");
        assertEq(uint256(strategy.distribution(address(launch.auction)).startBlock), 2_500_000 + 1_800, "recorded");
    }

    /// @notice `C3-I2`: only an authentic, still-pending, correctly funded clone of the bound escrow
    ///         implementation can drive a launch.
    function test_STR_013_InauthenticEscrowIsRejected() public {
        StagedERC20 subject = _etchToken(SUBJECT_LOW);
        subject.mint(address(factory), TOTAL_SUPPLY);

        // A hand-rolled impostor that answers every escrow getter correctly is still not a clone.
        EscrowImpostor impostor = new EscrowImpostor(SUBJECT_LOW, treasury, address(strategy));
        vm.expectRevert(abi.encodeWithSelector(RegentLBPStrategy.NotAuthenticEscrow.selector, address(impostor)));
        factory.initialize(SUBJECT_LOW, address(impostor), 1, 1_000e18);

        // A clone of a different escrow implementation is not a clone of the bound one.
        ConditionalVestingEscrowV1 rivalImplementation = new ConditionalVestingEscrowV1();
        address rival = _clone(address(rivalImplementation));
        vm.expectRevert(abi.encodeWithSelector(RegentLBPStrategy.NotAuthenticEscrow.selector, rival));
        factory.initialize(SUBJECT_LOW, rival, 1, 1_000e18);

        // An authentic, correctly funded clone bound to a foreign strategy is refused too. It gets
        // its own SUBJECT so its 85% custody is genuine.
        StagedERC20 other = _etchToken(SUBJECT_LOW_ALT);
        other.mint(address(this), TOTAL_SUPPLY);
        address foreign = _clone(address(escrowImplementation));
        other.approve(foreign, PENDING_ALLOCATION);
        ConditionalVestingEscrowV1(foreign).initialize(SUBJECT_LOW_ALT, treasury, outsider);
        vm.expectRevert(abi.encodeWithSelector(RegentLBPStrategy.EscrowStrategyMismatch.selector, outsider));
        factory.initialize(SUBJECT_LOW_ALT, foreign, 1, 1_000e18);

        assertEq(subject.balanceOf(address(strategy)), 0, "no reserve was pulled by any rejected path");
        assertEq(other.balanceOf(address(strategy)), 0, "and none by the foreign-strategy path either");
    }

    /// @notice `C3-I2`: a required raise of zero, or one the fixed auction can never reach, is
    ///         refused at initialization rather than guaranteeing a failed launch.
    function test_STR_013_UnreachableRequiredRaiseIsRejected() public {
        StagedERC20 subject = _etchToken(SUBJECT_LOW);
        subject.mint(address(factory), TOTAL_SUPPLY);
        address escrow = factory.fundedEscrow(SUBJECT_LOW, treasury);

        vm.expectRevert(abi.encodeWithSelector(RegentLBPStrategy.UnreachableRequiredRaise.selector, uint128(0)));
        factory.initialize(SUBJECT_LOW, escrow, 1, 0);

        uint128 tooHigh = strategy.MAX_REACHABLE_RAISE() + 1;
        vm.expectRevert(abi.encodeWithSelector(RegentLBPStrategy.UnreachableRequiredRaise.selector, tooHigh));
        factory.initialize(SUBJECT_LOW, escrow, 1, tooHigh);

        // Both rejections happen before the auction exists at all.
        assertEq(strategy.auctionOfSubject(SUBJECT_LOW), address(0), "no auction was created for a rejected raise");
        assertEq(subject.balanceOf(address(strategy)), 0, "and no reserve was pulled");

        // The exact boundary is admitted.
        address auction = factory.initialize(SUBJECT_LOW, escrow, 1, strategy.MAX_REACHABLE_RAISE());
        assertEq(strategy.auctionOfSubject(SUBJECT_LOW), auction, "the reachable boundary is a valid launch");
    }

    /// @notice `C3-I2`: the admitted maximum required raise is the raise the fixed auction can
    ///         actually settle on, not the pinned library's raw structural ceiling.
    /// @dev The two are different numbers. `MaxBidPriceLib.maxBidPrice` is a structural ceiling on a
    ///      bid price and is not a multiple of `BID_TICK_Q96`, and the pinned `TickStorage` admits a
    ///      bid only at an exact tick boundary, so no bid and no clearing price ever reaches it. The
    ///      highest admitted price is the greatest multiple of the tick at or below it, and the
    ///      admitted maximum raise is the whole fixed supply at that price.
    ///
    ///      The bound is proved tight, not merely safe. A real pinned auction opened at exactly
    ///      `MAX_REACHABLE_RAISE` and given a single on-grid bid of one wei more than that raise
    ///      carries exactly the demand the CCA's own integer accounting needs to clear the whole
    ///      supply at the highest admitted price: `demand * Q96 * remainingMps` then just exceeds
    ///      `remainingSupplyQ96X7 * price`, the final checkpoint settles there, and the raise it
    ///      records is the boundary itself with nothing to spare.
    function test_STR_013_AdmittedMaximumRaiseIsReachedByRealOnGridBidding() public {
        uint256 structuralMax = MaxBidPriceLib.maxBidPrice(uint128(AUCTION_ALLOCATION));
        uint256 offGrid = structuralMax % strategy.BID_TICK_Q96();
        assertGt(offGrid, 0, "the raw structural ceiling is off the frozen bid-tick grid");

        uint256 reachableMax = structuralMax - offGrid;
        uint128 boundaryRaise = strategy.MAX_REACHABLE_RAISE();
        assertEq(
            uint256(boundaryRaise),
            FullMath.mulDiv(AUCTION_ALLOCATION, reachableMax, 1 << 96),
            "the admitted maximum is the fixed supply at the highest admitted price"
        );

        Launch memory launch = _newLaunch(SUBJECT_LOW, 1, boundaryRaise);
        _rollToStart(launch);
        _bid(launch, bidder, boundaryRaise + 1, reachableMax);
        _rollToMigration(launch);

        strategy.migrate(address(launch.auction));

        assertTrue(launch.auction.isGraduated(), "the boundary auction met its required raise");
        assertEq(launch.auction.clearingPrice(), reachableMax, "settling at the highest admitted price");
        assertEq(uint256(launch.auction.currencyRaised()), uint256(boundaryRaise), "for exactly the boundary raise");
        assertEq(
            uint8(strategy.distribution(address(launch.auction)).lifecycle),
            uint8(RegentLBPStrategy.Lifecycle.Graduated),
            "so the launch admitted at the boundary graduates"
        );
    }

    /// @notice `C3-I2`: the 15% pull and the 10% delivery are exact, and a token that moves anything
    ///         else rolls the whole initialization back.
    function test_STR_013_UnexpectedTokenBehaviourRollsInitializationBack() public {
        StagedERC20 subject = _etchToken(SUBJECT_LOW);
        subject.mint(address(factory), TOTAL_SUPPLY);
        address escrow = factory.fundedEscrow(SUBJECT_LOW, treasury);

        // Movement 1 after escrow funding is the strategy's own 15% pull.
        subject.resetMovements();
        subject.arm(1, StagedERC20.Fault.ShortTransfer);
        vm.expectRevert(
            abi.encodeWithSelector(RegentLBPStrategy.InexactTransfer.selector, DISTRIBUTION_PULL, DISTRIBUTION_PULL - 1)
        );
        factory.initialize(SUBJECT_LOW, escrow, 1, 1_000e18);

        // Movement 2 is the exact 10% delivery to the auction.
        subject.resetMovements();
        subject.arm(2, StagedERC20.Fault.ShortTransfer);
        vm.expectRevert(
            abi.encodeWithSelector(
                RegentLBPStrategy.InexactTransfer.selector, AUCTION_ALLOCATION, AUCTION_ALLOCATION - 1
            )
        );
        factory.initialize(SUBJECT_LOW, escrow, 1, 1_000e18);

        subject.arm(0, StagedERC20.Fault.None);
        assertEq(subject.balanceOf(address(strategy)), 0, "no reserve survived a rolled-back initialization");
        assertEq(strategy.auctionOfSubject(SUBJECT_LOW), address(0), "no launch survived either");

        subject.resetMovements();
        address auction = factory.initialize(SUBJECT_LOW, escrow, 1, 1_000e18);
        assertEq(subject.balanceOf(address(strategy)), RESERVE_ALLOCATION, "the clean path still works");
        assertEq(subject.balanceOf(auction), AUCTION_ALLOCATION, "and delivers the exact auction supply");
    }

    // -------------------------------------------------------------------------
    // C3-I2 — launch-time treasury admission
    // -------------------------------------------------------------------------

    /// @notice `STR-019`: the closed refusal set is exactly six shared-system destinations, proved
    ///         one by one before any auction exists.
    /// @dev Every arm is an exact address: the bound factory, the shared strategy, the bound fee
    ///      hook, the frozen PoolManager, the frozen PositionManager and the frozen live staking
    ///      contract. There is no seventh arm, because there is no seventh rule — no `code.length`
    ///      test, no clone fingerprint, no predicted address. Each arm gets its own SUBJECT and its
    ///      own funded escrow, so every refusal is reached through the real authentication path
    ///      rather than short-circuited by a funding failure.
    function test_STR_019_RefusedTreasuryClassesAreRejectedBeforeTheAuctionExists() public {
        address[6] memory refused = [
            address(factory),
            address(strategy),
            strategy.hook(),
            BaseBindings.POOL_MANAGER,
            BaseBindings.POSITION_MANAGER,
            BaseBindings.LIVE_STAKING
        ];

        for (uint256 i; i < refused.length; ++i) {
            _assertTreasuryRefused(refused[i], i + 1);
        }
    }

    /// @notice `STR-019`: everything outside those six addresses stays admissible, with no code test.
    /// @dev The dead address, an ordinary EOA that has never existed, an arbitrary deployed contract,
    ///      the Governance and Regent Safe, a live CCA auction, and — deliberately — an already
    ///      deployed authentic Autolaunch escrow, splitter and canonical receiver are all accepted.
    ///      Those last three are the C6 fingerprint rule this correction deletes: admission judges
    ///      exact addresses and nothing else, so an existing Autolaunch artifact is an ordinary
    ///      launcher-selected destination whose consequences are `FAC-015`'s, not a refusal.
    ///
    ///      Each clone here is really deployed rather than fingerprinted, so what is proved is that a
    ///      real artifact is admitted — not that some code shape is. Admission is a closed list of
    ///      six addresses; it is not a registry, a denylist, or a code-length rule.
    function test_STR_019_AdmissibleTreasuryClassesAreAccepted() public {
        Launch memory live = _defaultLaunch();

        address[8] memory admitted = [
            BaseBindings.DEAD_ADDRESS,
            outsider,
            address(new EscrowImpostor(SUBJECT_LOW, treasury, address(strategy))),
            BaseBindings.GOVERNANCE_AND_REGENT_SAFE,
            address(live.auction),
            _clone(address(escrowImplementation)),
            _clone(address(splitterImplementation)),
            _clone(address(receiverImplementation))
        ];

        for (uint256 i; i < admitted.length; ++i) {
            _assertTreasuryAdmitted(admitted[i], i);
        }
    }

    /// @dev One launch attempt whose escrow is authentic, pending and exactly funded, and whose only
    ///      defect is its treasury. Nothing may survive the refusal.
    function _assertTreasuryRefused(address candidate, uint256 launchId) private {
        (StagedERC20 subject, address escrow) = _fundedEscrowFor(candidate, launchId);

        vm.expectRevert(abi.encodeWithSelector(RegentLBPStrategy.RefusedTreasury.selector, candidate));
        factory.initialize(address(subject), escrow, launchId, 1_000e18);

        assertEq(subject.balanceOf(address(strategy)), 0, "a refused treasury still pulled a reserve");
        assertEq(strategy.auctionOfSubject(address(subject)), address(0), "a refused treasury still created an auction");
        assertEq(subject.balanceOf(escrow), PENDING_ALLOCATION, "a refused treasury moved the pending allocation");
    }

    /// @dev One complete launch on an admitted treasury, recorded and funded exactly as usual.
    function _assertTreasuryAdmitted(address candidate, uint256 index) private {
        uint256 launchId = index + 100;
        (StagedERC20 subject, address escrow) = _fundedEscrowFor(candidate, launchId);

        address auction = factory.initialize(address(subject), escrow, launchId, 1_000e18);

        assertEq(strategy.distribution(auction).treasury, candidate, "the admitted treasury was not recorded");
        assertEq(subject.balanceOf(address(strategy)), RESERVE_ALLOCATION, "the admitted launch pulled no reserve");
        assertEq(subject.balanceOf(auction), AUCTION_ALLOCATION, "the admitted launch delivered no auction supply");
    }

    /// @dev A fresh SUBJECT at this launch id's own address, fully held by the factory double, and an
    ///      authentic escrow clone bound to `candidate` and holding the exact 85%.
    function _fundedEscrowFor(address candidate, uint256 launchId)
        private
        returns (StagedERC20 subject, address escrow)
    {
        address subjectAt = _subjectAddress(launchId);
        subject = _etchToken(subjectAt);
        subject.mint(address(factory), TOTAL_SUPPLY);
        escrow = factory.fundedEscrow(subjectAt, candidate);
    }

    /// @dev The address this test's launch id stages its SUBJECT at. One SUBJECT per launch id, so
    ///      no two arms ever contend for the same `auctionOfSubject` entry.
    function _subjectAddress(uint256 launchId) private pure returns (address) {
        return address(uint160(0x5000 + launchId));
    }

    // -------------------------------------------------------------------------
    // C3-I5 — atomic final-price graduation
    // -------------------------------------------------------------------------

    /// @notice `C3-I5`: graduation runs the complete terminal order in one transaction and records
    ///         every terminal fact.
    function test_STR_015_GraduationExecutesTheCompleteTerminalOrder() public {
        Launch memory launch = _defaultLaunch();
        _bidToGraduation(launch, 2_000e18);

        uint256 nextTokenIdBefore = positionManager.nextTokenId();

        strategy.migrate(address(launch.auction));

        uint256 unsold = launch.auction.remainingSupply();

        RegentLBPStrategy.Distribution memory d = strategy.distribution(address(launch.auction));
        assertEq(uint8(d.lifecycle), uint8(RegentLBPStrategy.Lifecycle.Graduated), "1. graduated");

        PoolKey memory key = strategy.poolKeyOf(address(launch.subject));
        assertEq(PoolId.unwrap(d.poolId), PoolId.unwrap(key.toId()), "2. the recorded PoolId is the derived one");
        assertEq(key.fee, 3000, "static 0.30%");
        assertEq(key.tickSpacing, 60, "tick spacing 60");
        assertEq(address(key.hooks), HOOK_ADDRESS, "the integrated hook");

        // 3. an authentic splitter clone, correctly bound.
        assertEq(d.splitter.codehash, _cloneCodehash(address(splitterImplementation)), "3. authentic splitter clone");
        assertEq(SubjectSplitterV1(d.splitter).subject(), address(launch.subject), "splitter subject");
        assertEq(SubjectSplitterV1(d.splitter).treasury(), treasury, "splitter treasury");

        // 4. registered once in the hook.
        assertEq(hook.splitterOf(d.poolId), d.splitter, "4. the pool is registered to that splitter");

        // 5. the pool opened at the converted final price.
        (uint160 sqrtPriceX96,,,) = IPoolManager(BaseBindings.POOL_MANAGER).getSlot0(d.poolId);
        assertEq(sqrtPriceX96, d.finalSqrtPriceX96, "5. the pool carries the recorded final price");
        assertGt(sqrtPriceX96, TickMath.MIN_SQRT_PRICE, "inside the v4 range");
        assertLt(sqrtPriceX96, TickMath.MAX_SQRT_PRICE, "inside the v4 range");

        // 6. exactly one full-range LP NFT, owned by the dead address.
        assertEq(d.lpTokenId, nextTokenIdBefore, "6. the recorded LP token id");
        assertEq(positionManager.nextTokenId(), nextTokenIdBefore + 1, "exactly one NFT minted");
        assertEq(IERC721Owner(BaseBindings.POSITION_MANAGER).ownerOf(d.lpTokenId), BaseBindings.DEAD_ADDRESS, "dead");
        (PoolKey memory mintedKey, PositionInfo info) = positionManager.getPoolAndPositionInfo(d.lpTokenId);
        assertEq(PoolId.unwrap(mintedKey.toId()), PoolId.unwrap(d.poolId), "the NFT belongs to the official pool");
        assertEq(info.tickLower(), TickMath.minUsableTick(60), "full-range lower tick");
        assertEq(info.tickUpper(), TickMath.maxUsableTick(60), "full-range upper tick");
        assertGt(positionManager.getPositionLiquidity(d.lpTokenId), 0, "the position carries real liquidity");

        // 7/8. only this launch's deltas left, and every remaining SUBJECT unit went to escrow.
        assertEq(regent.balanceOf(address(strategy)), 0, "no REGENT stranded at the strategy");
        assertEq(launch.subject.balanceOf(address(strategy)), 0, "no SUBJECT stranded at the strategy");

        // 9. escrow swept the graduated auction's unsold SUBJECT; only cleared tokens stay for claims.
        assertGt(unsold, 0, "this auction did not sell out");
        assertEq(
            launch.subject.balanceOf(address(launch.auction)),
            AUCTION_ALLOCATION - unsold,
            "the auction keeps exactly the cleared tokens"
        );
        assertTrue(launch.escrow.graduatedSweepDone(), "9. escrow ran its graduated sweep");

        // 10. the canonical zero-referral receiver.
        assertEq(d.receiver.codehash, _cloneCodehash(address(receiverImplementation)), "10. authentic receiver clone");
        assertEq(PaymentReceiverV1(d.receiver).referralBps(), 0, "zero referral");
        assertEq(PaymentReceiverV1(d.receiver).beneficiary(), treasury, "treasury beneficiary");
        assertEq(PaymentReceiverV1(d.receiver).noteEditor(), treasury, "treasury note editor");
        assertEq(PaymentReceiverV1(d.receiver).splitter(), d.splitter, "bound to this launch's splitter");

        // 11. vesting is active from this timestamp.
        assertEq(
            uint8(launch.escrow.lifecycle()), uint8(ConditionalVestingEscrowV1.Lifecycle.Graduated), "11. graduated"
        );
        assertEq(launch.escrow.vestingStart(), uint64(block.timestamp), "vesting started now");
    }

    /// @notice `C3-I5`: the recorded LP use is what the position actually consumed, not the offered
    ///         maxima, and the remainder is routed to the exact recipients.
    function test_STR_015_ActualLpConsumptionIsRecorded() public {
        Launch memory launch = _defaultLaunch();
        _bidToGraduationAt(launch, 20_000_000e18, 500);

        uint256 escrowBefore = launch.subject.balanceOf(address(launch.escrow));

        strategy.migrate(address(launch.auction));
        RegentLBPStrategy.Distribution memory d = strategy.distribution(address(launch.auction));
        uint256 raised = _raisedOf(launch);
        uint256 unsold = launch.auction.remainingSupply();

        assertGt(d.lpRegentUsed, 0, "the position consumed REGENT");
        assertGt(d.lpSubjectUsed, 0, "the position consumed SUBJECT");
        assertLe(uint256(d.lpSubjectUsed), RESERVE_ALLOCATION, "at most the offered reserve maximum");
        assertLt(uint256(d.lpRegentUsed), raised, "strictly less than the offered raise maximum");
        assertGt(regent.balanceOf(treasury), 0, "this launch really did have unused raised REGENT");

        assertEq(regent.balanceOf(treasury), raised - d.lpRegentUsed, "unused raised REGENT reached the treasury");
        assertEq(
            launch.subject.balanceOf(address(launch.escrow)),
            escrowBefore + (RESERVE_ALLOCATION - d.lpSubjectUsed) + unsold,
            "unused reserve plus swept unsold SUBJECT reached escrow"
        );
        assertEq(
            regent.balanceOf(BaseBindings.POOL_MANAGER), d.lpRegentUsed, "the pool holds exactly the consumed REGENT"
        );
        assertEq(
            launch.subject.balanceOf(BaseBindings.POOL_MANAGER),
            d.lpSubjectUsed,
            "the pool holds exactly the consumed SUBJECT"
        );
    }

    /// @notice `C3-I5`: unrelated REGENT already sitting at the shared strategy is deliberately not
    ///         treated as this launch's residue, and gifted SUBJECT is routed to escrow.
    function test_STR_015_UnrelatedStrategyRegentIsPreserved() public {
        Launch memory launch = _defaultLaunch();
        regent.mint(address(strategy), 777e18);

        _bidToGraduation(launch, 2_000e18);

        strategy.migrate(address(launch.auction));
        RegentLBPStrategy.Distribution memory d = strategy.distribution(address(launch.auction));
        uint256 raised = _raisedOf(launch);

        assertEq(regent.balanceOf(address(strategy)), 777e18, "the unrelated REGENT is untouched");
        assertEq(regent.balanceOf(treasury), raised - d.lpRegentUsed, "only this launch's delta reached the treasury");
    }

    /// @notice `C3-I5`: a voluntary SUBJECT gift to the shared strategy joins the launch it belongs
    ///         to and reaches escrow; only the recorded reserve is ever budgeted for LP.
    function test_STR_015_GiftedSubjectIsRoutedToEscrow() public {
        Launch memory launch = _defaultLaunch();
        launch.subject.mint(address(strategy), 3_000e18);

        _bidToGraduation(launch, 2_000e18);
        uint256 escrowBefore = launch.subject.balanceOf(address(launch.escrow));

        strategy.migrate(address(launch.auction));
        RegentLBPStrategy.Distribution memory d = strategy.distribution(address(launch.auction));
        uint256 unsold = launch.auction.remainingSupply();

        assertLe(uint256(d.lpSubjectUsed), RESERVE_ALLOCATION, "the gift was never budgeted for LP");
        assertEq(launch.subject.balanceOf(address(strategy)), 0, "the gift did not stay at the strategy");
        assertEq(
            launch.subject.balanceOf(address(launch.escrow)),
            escrowBefore + (RESERVE_ALLOCATION - d.lpSubjectUsed) + 3_000e18 + unsold,
            "the gift reached this launch's escrow"
        );
    }

    /// @notice `C3-I3`: migration before the fixed eligibility block is refused, and classification
    ///         happens only from the completed end checkpoint.
    function test_STR_015_MigrationBeforeEligibilityIsRejected() public {
        Launch memory launch = _defaultLaunch();
        _rollToStart(launch);
        _bid(launch, bidder, 2_000e18, _bidPrice(10));

        uint64 migrationBlock = strategy.distribution(address(launch.auction)).migrationBlock;

        vm.roll(launch.auction.endBlock());
        vm.expectRevert(
            abi.encodeWithSelector(RegentLBPStrategy.MigrationNotYetAllowed.selector, migrationBlock, block.number)
        );
        strategy.migrate(address(launch.auction));

        vm.roll(uint256(launch.auction.endBlock()) + 127);
        vm.expectRevert(
            abi.encodeWithSelector(RegentLBPStrategy.MigrationNotYetAllowed.selector, migrationBlock, block.number)
        );
        strategy.migrate(address(launch.auction));

        assertEq(
            uint8(strategy.distribution(address(launch.auction)).lifecycle),
            uint8(RegentLBPStrategy.Lifecycle.Active),
            "still active"
        );
    }

    /// @notice `C3-I5`: graduation is proved from the auction's own finalized state. An auction whose
    ///         raise fell short reports it, and the strategy retires that launch instead.
    function test_STR_015_FinalizationProvesGraduationBeforeCommitting() public {
        Launch memory launch = _newLaunch(SUBJECT_LOW, 1, 5_000e18);
        _rollToStart(launch);
        _bid(launch, bidder, 1_000e18, _bidPrice(10));
        _rollToMigration(launch);

        // Before any migration the auction is not finalized, so its own proof refuses to answer.
        vm.expectRevert(IContinuousClearingAuction.AuctionIsNotFinalized.selector);
        launch.auction.lbpInitializationParams();

        strategy.migrate(address(launch.auction));

        assertFalse(launch.auction.isGraduated(), "the checkpointed auction did not graduate");
        assertEq(
            uint8(strategy.distribution(address(launch.auction)).lifecycle),
            uint8(RegentLBPStrategy.Lifecycle.Failed),
            "and the strategy classified it as failed"
        );
        assertEq(hook.splitterOf(_poolId(launch)), address(0), "no pool was registered");
    }

    // -------------------------------------------------------------------------
    // C3-I3 / C3-I4 — unknown auctions and one terminal decision
    // -------------------------------------------------------------------------

    function test_STR_016_UnknownAuctionIsRejected() public {
        Launch memory launch = _defaultLaunch();

        vm.expectRevert(abi.encodeWithSelector(RegentLBPStrategy.UnknownAuction.selector, outsider));
        strategy.migrate(outsider);

        // A real, foreign CCA auction over the same SUBJECT, created outside this strategy.
        address foreign = _foreignAuction(address(launch.subject));
        vm.expectRevert(abi.encodeWithSelector(RegentLBPStrategy.UnknownAuction.selector, foreign));
        strategy.migrate(foreign);

        RegentLBPStrategy.Distribution memory unknown = strategy.distribution(foreign);
        assertEq(uint8(unknown.lifecycle), uint8(RegentLBPStrategy.Lifecycle.None), "nothing was recorded for it");
    }

    function test_STR_018_FinalizationIsOneShot() public {
        Launch memory launch = _defaultLaunch();
        _bidToGraduation(launch, 2_000e18);
        strategy.migrate(address(launch.auction));

        Ledger memory before = _ledger(launch);

        vm.expectRevert(
            abi.encodeWithSelector(RegentLBPStrategy.LaunchNotActive.selector, RegentLBPStrategy.Lifecycle.Graduated)
        );
        strategy.migrate(address(launch.auction));

        vm.prank(outsider);
        vm.expectRevert(
            abi.encodeWithSelector(RegentLBPStrategy.LaunchNotActive.selector, RegentLBPStrategy.Lifecycle.Graduated)
        );
        strategy.migrate(address(launch.auction));

        _assertLedgerUnchanged(before, _ledger(launch), "repeated graduation");
    }

    function test_STR_018_RepeatedFailureMigrationIsRejected() public {
        Launch memory launch = _defaultLaunch();
        _rollToStart(launch);
        _rollToMigration(launch);
        strategy.migrate(address(launch.auction));

        Ledger memory before = _ledger(launch);

        vm.expectRevert(
            abi.encodeWithSelector(RegentLBPStrategy.LaunchNotActive.selector, RegentLBPStrategy.Lifecycle.Failed)
        );
        strategy.migrate(address(launch.auction));

        _assertLedgerUnchanged(before, _ledger(launch), "repeated retirement");
    }

    // -------------------------------------------------------------------------
    // C3-I4 — ordinary-revert failure
    // -------------------------------------------------------------------------

    /// @notice `ESC-003`: economic failure sends exactly the isolated 5% reserve to escrow and lets
    ///         that escrow retire the whole 100 billion.
    function test_ESC_003_FailureSendsTheIsolatedReserveToEscrow() public {
        Launch memory launch = _newLaunch(SUBJECT_LOW, 1, 5_000e18);
        _rollToStart(launch);
        _bid(launch, bidder, 1_000e18, _bidPrice(10));
        _rollToMigration(launch);

        assertEq(launch.subject.balanceOf(address(strategy)), RESERVE_ALLOCATION, "the reserve before failure");

        strategy.migrate(address(launch.auction));

        assertEq(launch.subject.balanceOf(address(strategy)), 0, "the strategy kept nothing");
        assertEq(launch.subject.balanceOf(BaseBindings.DEAD_ADDRESS), TOTAL_SUPPLY, "exactly 100 billion retired");
        assertEq(uint8(launch.escrow.lifecycle()), uint8(ConditionalVestingEscrowV1.Lifecycle.Failed), "failed");

        // Bidder REGENT is untouched and still refundable from the auction.
        assertEq(regent.balanceOf(address(launch.auction)), 1_000e18, "bidder REGENT stayed in the auction");
        vm.prank(bidder);
        launch.auction.exitBid(0);
        assertEq(regent.balanceOf(bidder), 1_000e18, "the bidder was fully refunded");
    }

    function test_ESC_003_ZeroBidFailureRetiresTheCompleteSupply() public {
        Launch memory launch = _defaultLaunch();
        _rollToStart(launch);
        _rollToMigration(launch);

        strategy.migrate(address(launch.auction));

        assertEq(launch.subject.balanceOf(BaseBindings.DEAD_ADDRESS), TOTAL_SUPPLY, "the whole supply retired");
        assertEq(launch.subject.balanceOf(address(launch.auction)), 0, "the auction kept nothing");
        assertEq(launch.subject.balanceOf(address(launch.escrow)), 0, "escrow kept nothing");
        assertEq(regent.balanceOf(address(strategy)), 0, "no REGENT was ever swept on failure");
    }

    function test_ESC_003_FailedLaunchCreatesNoGraduatedArtifacts() public {
        Launch memory launch = _defaultLaunch();
        _rollToStart(launch);
        _rollToMigration(launch);

        uint256 nextTokenIdBefore = positionManager.nextTokenId();
        strategy.migrate(address(launch.auction));

        RegentLBPStrategy.Distribution memory d = strategy.distribution(address(launch.auction));
        assertEq(d.splitter, address(0), "no splitter");
        assertEq(d.receiver, address(0), "no receiver");
        assertEq(PoolId.unwrap(d.poolId), bytes32(0), "no PoolId recorded");
        assertEq(d.finalSqrtPriceX96, 0, "no final price");
        assertEq(d.lpTokenId, 0, "no LP position");
        assertEq(hook.splitterOf(_poolId(launch)), address(0), "the hook has no registration for it");
        assertEq(positionManager.nextTokenId(), nextTokenIdBefore, "no NFT was minted");
        (uint160 sqrtPriceX96,,,) = IPoolManager(BaseBindings.POOL_MANAGER).getSlot0(_poolId(launch));
        assertEq(sqrtPriceX96, 0, "no pool was initialized");
        assertEq(launch.escrow.vestingStart(), 0, "no vesting started");
    }

    // -------------------------------------------------------------------------
    // helpers
    // -------------------------------------------------------------------------

    function _raisedOf(Launch memory launch) internal view returns (uint256) {
        return launch.auction.lbpInitializationParams().currencyRaised;
    }

    function _readStep(bytes memory data, uint256 offset) internal pure returns (uint24 mps, uint40 blockDelta) {
        uint64 packed;
        for (uint256 i; i < 8; ++i) {
            packed = (packed << 8) | uint8(data[offset + i]);
        }
        mps = uint24(packed >> 40);
        blockDelta = uint40(packed);
    }

    function _clone(address implementation) internal returns (address instance) {
        bytes memory initcode = abi.encodePacked(
            hex"602c3d8160093d39f33d3d3d3d363d3d37363d73", implementation, hex"5af43d3d93803e602a57fd5bf3"
        );
        assembly {
            instance := create(0, add(initcode, 0x20), mload(initcode))
        }
        require(instance != address(0), "clone failed");
    }

    function _cloneCodehash(address implementation) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(hex"3d3d3d3d363d3d37363d73", implementation, hex"5af43d3d93803e602a57fd5bf3"));
    }

    /// @dev A real CCA auction over the same SUBJECT that this strategy never created or recorded.
    function _foreignAuction(address subject) internal returns (address) {
        return address(
            ccaFactory.create(
                subject,
                AUCTION_ALLOCATION,
                abi.encode(
                    AuctionParameters({
                        currency: BaseBindings.REGENT,
                        tokensRecipient: outsider,
                        fundsRecipient: address(strategy),
                        startBlock: uint64(block.number) + 10,
                        endBlock: uint64(block.number) + 10 + 86_401,
                        claimBlock: uint64(block.number) + 10 + 86_401 + 64,
                        tickSpacing: strategy.BID_TICK_Q96(),
                        validationHook: address(0),
                        floorPrice: strategy.FLOOR_PRICE_Q96(),
                        requiredCurrencyRaised: 1_000e18,
                        auctionStepsData: strategy.AUCTION_STEPS()
                    })
                ),
                bytes32(uint256(0xf0f0))
            )
        );
    }
}

/// @notice A factory whose whole job is to bind the hook from inside its own constructor.
contract ConstructorBinder {
    constructor(address strategy, address hook) {
        RegentLBPStrategy(strategy).bindHook(hook);
    }
}

/// @notice A contract that answers every escrow getter correctly but is not a clone of the bound
///         implementation, so a fake-clone substitution can be proved to fail on identity alone.
contract EscrowImpostor {
    address public immutable subject;
    address public immutable treasury;
    address public immutable strategy;

    constructor(address subject_, address treasury_, address strategy_) {
        subject = subject_;
        treasury = treasury_;
        strategy = strategy_;
    }

    function lifecycle() external pure returns (uint8) {
        return 0;
    }
}

/// @notice The one ERC721 read the LP-ownership claim needs; `IPositionManager` does not declare it.
interface IERC721Owner {
    function ownerOf(uint256 tokenId) external view returns (address);
}
