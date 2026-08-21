// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {BaseBindings} from "../../src/bindings/BaseBindings.sol";
import {ConditionalVestingEscrowV1} from "../../src/escrow/ConditionalVestingEscrowV1.sol";
import {PaymentReceiverV1} from "../../src/revenue/PaymentReceiverV1.sol";
import {RegentFeeHook} from "../../src/hook/RegentFeeHook.sol";
import {SubjectSplitterV1} from "../../src/revenue/SubjectSplitterV1.sol";
import {RegentLBPStrategy} from "../../src/strategy/RegentLBPStrategy.sol";
import {LBPInitializationParams} from "liquidity-launcher/src/interfaces/ILBPInitializer.sol";
import {TokenPricing} from "liquidity-launcher/src/libraries/TokenPricing.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {PositionInfo} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {AutolaunchFixture} from "./AutolaunchFixture.sol";
import {Permit2Double} from "../strategy/doubles/Permit2Double.sol";
import {Vm} from "forge-std/Vm.sol";

/// @notice `C4-I6`: a graduated launch performs the twelve fixed steps in order, in one transaction,
///         against the real pinned CCA, PoolManager, PositionManager and `PositionPlanner`, and ends
///         with an exactly accounted ledger and no stranded inventory.
contract AutolaunchGraduationTest is AutolaunchFixture {
    using StateLibrary for IPoolManager;

    function setUp() public {
        _deployAutolaunch();
    }

    /// @notice `MIG-001`: nothing happens before the auction is checkpointed at its end and proved
    ///         graduated from that completed state.
    function test_MIG_001_CheckpointAndProofComeFirst() public {
        Launched memory launched = _defaultLaunch();

        vm.expectRevert(abi.encodeWithSelector(RegentLBPStrategy.UnknownAuction.selector, outsider));
        strategy.migrate(outsider);

        _rollToStart(launched);
        _bid(launched, bidder, 2_000e18, _bidPrice(10));

        // Eligibility is the auction's end plus the fixed migration delay, and not one block sooner.
        uint64 migrationBlock = _distribution(launched).migrationBlock;
        vm.roll(migrationBlock - 1);
        Ledger memory before = _ledger(launched);
        vm.expectRevert(
            abi.encodeWithSelector(
                RegentLBPStrategy.MigrationNotYetAllowed.selector, migrationBlock, uint256(migrationBlock - 1)
            )
        );
        strategy.migrate(address(launched.auction));
        _assertLedgerUnchanged(before, _ledger(launched), "early migration");

        // The auction has not been finally checkpointed yet: migration is what does that, and the
        // graduation proof is read from the completed checkpoint, before any terminal work.
        vm.roll(migrationBlock);
        assertFalse(launched.auction.isGraduated(), "the auction was already settled before migration");

        strategy.migrate(address(launched.auction));

        assertTrue(launched.auction.isGraduated(), "migration did not checkpoint the auction to its end");
        assertEq(
            uint8(_distribution(launched).lifecycle),
            uint8(RegentLBPStrategy.Lifecycle.Graduated),
            "the proved-graduated auction did not graduate"
        );
    }

    /// @notice `MIG-002`: the official pool key and ID come from the launch's own currencies and the
    ///         auction's own settled price, in whichever order the two token addresses fall.
    function test_MIG_002_DerivesFinalPricePoolKeyAndPoolId() public {
        _assertPoolKeyDerivation(true);
        _assertPoolKeyDerivation(false);
    }

    /// @notice `MIG-003`: graduation deploys this launch's splitter as an exact clone bound to the
    ///         launch's own SUBJECT, treasury and recovery admin.
    function test_MIG_003_DeploysTheSplitterClone() public {
        Launched memory launched = _defaultLaunch();
        _bidToGraduation(launched, 2_000e18);

        address predicted = vm.computeCreateAddress(address(strategy), vm.getNonce(address(strategy)));
        strategy.migrate(address(launched.auction));

        SubjectSplitterV1 splitter = SubjectSplitterV1(_distribution(launched).splitter);
        assertEq(address(splitter), predicted, "the splitter is not the strategy's next clone");
        assertEq(splitter.subject(), address(launched.subject), "the splitter bound another SUBJECT");
        assertEq(splitter.regent(), BaseBindings.REGENT, "splitter REGENT binding");
        assertEq(splitter.usdc(), BaseBindings.USDC, "splitter USDC binding");
        assertEq(splitter.liveStaking(), BaseBindings.LIVE_STAKING, "splitter live staking binding");
        assertEq(splitter.regentSafe(), BaseBindings.GOVERNANCE_AND_REGENT_SAFE, "splitter Regent Safe binding");
        assertEq(splitter.treasury(), treasury, "splitter treasury binding");
        assertEq(splitter.recoveryAdmin(), address(recoveryAdmin), "splitter recovery admin binding");
    }

    /// @notice `MIG-004`: the launch's PoolId is registered in the shared hook exactly once, by the
    ///         strategy, and nobody else can register anything.
    function test_MIG_004_RegistersThePoolIdOnceInTheHook() public {
        Launched memory launched = _defaultLaunch();
        PoolId poolId = _poolId(launched);
        assertEq(hook.splitterOf(poolId), address(0), "the pool was registered before graduation");

        _bidToGraduation(launched, 2_000e18);
        strategy.migrate(address(launched.auction));

        address splitter = _distribution(launched).splitter;
        assertEq(hook.splitterOf(poolId), splitter, "the pool is not registered to this launch's splitter");

        PoolKey memory key = strategy.poolKeyOf(address(launched.subject));
        vm.expectRevert(abi.encodeWithSelector(RegentFeeHook.NotStrategy.selector, outsider));
        vm.prank(outsider);
        hook.registerPool(key, splitter);

        vm.expectRevert(abi.encodeWithSelector(RegentFeeHook.PoolAlreadyRegistered.selector, poolId));
        vm.prank(address(strategy));
        hook.registerPool(key, splitter);

        // A second graduation cannot happen at all, so the write-once registration is never retried.
        vm.expectRevert(
            abi.encodeWithSelector(RegentLBPStrategy.LaunchNotActive.selector, RegentLBPStrategy.Lifecycle.Graduated)
        );
        strategy.migrate(address(launched.auction));
    }

    /// @notice `MIG-005`: the raised REGENT is swept out of the auction and the pool opens at exactly
    ///         the price that auction settled on.
    function test_MIG_005_InitializesThePoolAtTheExactFinalPrice() public {
        Launched memory launched = _defaultLaunch();
        _bidToGraduation(launched, 2_000e18);

        uint256 strategyRegentBefore = regent.balanceOf(address(strategy));
        strategy.migrate(address(launched.auction));

        LBPInitializationParams memory lbp = launched.auction.lbpInitializationParams();
        assertEq(regent.balanceOf(address(launched.auction)), 0, "the auction kept raised REGENT");

        PoolKey memory key = strategy.poolKeyOf(address(launched.subject));
        bool regentIsCurrency0 = Currency.unwrap(key.currency0) == BaseBindings.REGENT;
        uint160 expected =
            TokenPricing.convertToSqrtPriceX96(TokenPricing.convertToPriceX192(lbp.initialPriceX96, regentIsCurrency0));

        (uint160 slotPrice,,,) = IPoolManager(BaseBindings.POOL_MANAGER).getSlot0(_poolId(launched));
        assertEq(slotPrice, expected, "the pool did not open at the settled final price");
        assertEq(_distribution(launched).finalSqrtPriceX96, expected, "the recorded final price disagrees");

        // Every unit of raised REGENT is accounted for: it either backs the position or reached the
        // treasury, and none of it stayed with the shared strategy.
        RegentLBPStrategy.Distribution memory d = _distribution(launched);
        assertEq(
            uint256(d.lpRegentUsed) + regent.balanceOf(treasury),
            lbp.currencyRaised,
            "the raised REGENT is not exactly the position plus the treasury payout"
        );
        assertEq(regent.balanceOf(address(strategy)), strategyRegentBefore, "the strategy kept raised REGENT");
    }

    /// @notice `MIG-006`: exactly one full-range position is minted and its NFT goes to the dead
    ///         address, so nobody can ever withdraw the official liquidity.
    function test_MIG_006_MintsOneFullRangePositionToTheDeadAddress() public {
        Launched memory launched = _defaultLaunch();
        _bidToGraduation(launched, 2_000e18);

        uint256 nextTokenIdBefore = positionManager.nextTokenId();
        strategy.migrate(address(launched.auction));

        RegentLBPStrategy.Distribution memory d = _distribution(launched);
        assertEq(positionManager.nextTokenId(), nextTokenIdBefore + 1, "graduation minted other than one position");
        assertEq(d.lpTokenId, nextTokenIdBefore, "the recorded token ID is not the minted one");
        assertEq(IERC721(BaseBindings.POSITION_MANAGER).ownerOf(d.lpTokenId), BaseBindings.DEAD_ADDRESS, "NFT owner");
        assertGt(positionManager.getPositionLiquidity(d.lpTokenId), 0, "the managed position holds no liquidity");

        (PoolKey memory key, PositionInfo info) = positionManager.getPoolAndPositionInfo(d.lpTokenId);
        assertEq(PoolId.unwrap(key.toId()), PoolId.unwrap(_poolId(launched)), "the position is in another pool");
        assertEq(info.tickLower(), TickMath.minUsableTick(60), "the position is not full range below");
        assertEq(info.tickUpper(), TickMath.maxUsableTick(60), "the position is not full range above");
    }

    /// @notice `MIG-007`: REGENT the position did not consume goes to the launch's immutable
    ///         treasury and nowhere else.
    function test_MIG_007_UnusedRegentGoesToTheImmutableTreasury() public {
        // A raise far larger than the fixed 5% reserve can absorb, so the residue is real.
        Launched memory launched = _defaultLaunch();
        _bidToGraduationAt(launched, 20_000_000e18, 500);

        uint256 treasuryBefore = regent.balanceOf(treasury);
        strategy.migrate(address(launched.auction));

        RegentLBPStrategy.Distribution memory d = _distribution(launched);
        uint256 raised = launched.auction.lbpInitializationParams().currencyRaised;
        uint256 residue = raised - d.lpRegentUsed;

        assertGt(residue, 0, "this raise left no REGENT residue to route");
        assertEq(regent.balanceOf(treasury) - treasuryBefore, residue, "the treasury did not receive the residue");
        assertEq(regent.balanceOf(address(strategy)), 0, "the strategy kept REGENT");
        assertEq(regent.balanceOf(BaseBindings.POSITION_MANAGER), 0, "the PositionManager kept REGENT");
    }

    /// @notice `MIG-008`: SUBJECT the position did not consume returns to this launch's escrow.
    function test_MIG_008_UnusedSubjectReserveGoesToEscrow() public {
        // A small raise, so the raise and not the reserve limits the position and the SUBJECT
        // residue is large.
        Launched memory launched = _defaultLaunch();
        _bidToGraduation(launched, 2_000e18);

        uint256 escrowBefore = launched.subject.balanceOf(address(launched.escrow));
        strategy.migrate(address(launched.auction));

        // The terminal unsold supply is the checkpointed one, which migration itself produced.
        uint256 auctionUnsold = launched.auction.remainingSupply();
        RegentLBPStrategy.Distribution memory d = _distribution(launched);
        uint256 reserveResidue = RESERVE_ALLOCATION - d.lpSubjectUsed;
        assertGt(reserveResidue, 0, "this raise consumed the whole reserve");
        assertEq(
            launched.subject.balanceOf(address(launched.escrow)) - escrowBefore,
            reserveResidue + auctionUnsold,
            "escrow did not receive the reserve residue plus the unsold supply"
        );
        assertEq(launched.subject.balanceOf(address(strategy)), 0, "the strategy kept SUBJECT");
    }

    /// @notice `MIG-009`: a graduated auction's unsold SUBJECT is swept into escrow, exactly once,
    ///         and the auction is left holding none of it.
    function test_MIG_009_UnsoldSubjectIsSweptIntoEscrow() public {
        Launched memory launched = _defaultLaunch();
        _bidToGraduation(launched, 2_000e18);

        uint256 escrowBefore = launched.subject.balanceOf(address(launched.escrow));

        vm.recordLogs();
        strategy.migrate(address(launched.auction));

        uint256 unsold = launched.auction.remainingSupply();
        assertGt(unsold, 0, "this auction sold out, so there is no sweep to prove");
        assertTrue(launched.escrow.graduatedSweepDone(), "the graduated sweep did not run");
        assertEq(
            launched.subject.balanceOf(address(launched.auction)),
            AUCTION_ALLOCATION - unsold,
            "the auction kept other than exactly what its bidders may still claim"
        );
        assertGe(
            launched.subject.balanceOf(address(launched.escrow)) - escrowBefore,
            unsold,
            "escrow did not receive at least the swept unsold supply"
        );

        // Exactly one sweep, announced once, for exactly the auction's own remaining supply.
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = keccak256("GraduatedUnsoldSubjectSwept(address,uint256)");
        uint256 seen;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] != topic) continue;
            seen += 1;
            assertEq(abi.decode(logs[i].data, (uint256)), unsold, "the sweep amount is not the unsold supply");
        }
        assertEq(seen, 1, "the graduated sweep did not run exactly once");

        // The escrow is terminal after graduation, so the sweep cannot be driven a second time.
        vm.expectRevert(
            abi.encodeWithSelector(
                ConditionalVestingEscrowV1.NotPending.selector, ConditionalVestingEscrowV1.Lifecycle.Graduated
            )
        );
        vm.prank(address(strategy));
        launched.escrow.sweepGraduatedUnsoldSubject(address(launched.auction));
    }

    /// @notice `MIG-010`: the canonical receiver is created by graduation with zero referral and the
    ///         treasury as both beneficiary and note editor.
    function test_MIG_010_DeploysTheCanonicalZeroReferralReceiver() public {
        Launched memory launched = _defaultLaunch();
        _bidToGraduation(launched, 2_000e18);
        strategy.migrate(address(launched.auction));

        RegentLBPStrategy.Distribution memory d = _distribution(launched);
        PaymentReceiverV1 canonical = PaymentReceiverV1(payable(d.receiver));

        assertTrue(d.receiver != address(0), "graduation recorded no canonical receiver");
        assertEq(canonical.referralBps(), 0, "the canonical receiver charges a referral");
        assertEq(canonical.beneficiary(), treasury, "the canonical beneficiary is not the treasury");
        assertEq(canonical.noteEditor(), treasury, "the canonical note editor is not the treasury");
        assertEq(canonical.splitter(), d.splitter, "the canonical receiver bound another splitter");
        assertEq(canonical.subject(), address(launched.subject), "the canonical receiver bound another SUBJECT");
    }

    /// @notice `MIG-011`: vesting opens at the graduation timestamp, over the launch's whole final
    ///         escrow inventory, releasing only to the immutable treasury.
    function test_MIG_011_ActivatesVestingFromTheGraduationTimestamp() public {
        Launched memory launched = _defaultLaunch();
        _bidToGraduation(launched, 2_000e18);

        vm.warp(1_700_000_000);
        strategy.migrate(address(launched.auction));

        assertEq(launched.escrow.vestingStart(), 1_700_000_000, "vesting did not start at the graduation timestamp");
        assertEq(
            uint8(launched.escrow.lifecycle()),
            uint8(ConditionalVestingEscrowV1.Lifecycle.Graduated),
            "the escrow is not graduated"
        );
        assertEq(launched.escrow.VESTING_DURATION(), 365 days, "the vesting duration is not 365 days");

        uint256 held = launched.subject.balanceOf(address(launched.escrow));
        vm.warp(1_700_000_000 + 365 days / 2);
        launched.escrow.release();
        assertApproxEqAbs(launched.subject.balanceOf(treasury), held / 2, 1, "half the schedule did not release half");

        vm.warp(1_700_000_000 + 365 days);
        launched.escrow.release();
        assertEq(launched.subject.balanceOf(treasury), held, "the full schedule did not release everything");
        assertEq(launched.subject.balanceOf(address(launched.escrow)), 0, "escrow retained vested SUBJECT");
    }

    /// @notice `MIG-012`: every graduation fact is recorded in the one transaction that produces it,
    ///         and announced once, with each recorded address actually existing.
    function test_MIG_012_RecordsGraduationAtomically() public {
        Launched memory launched = _defaultLaunch();
        _bidToGraduation(launched, 2_000e18);

        vm.recordLogs();
        strategy.migrate(address(launched.auction));
        RegentLBPStrategy.Distribution memory d = _distribution(launched);

        assertEq(uint8(d.lifecycle), uint8(RegentLBPStrategy.Lifecycle.Graduated), "lifecycle");
        assertTrue(d.splitter.code.length != 0, "the recorded splitter has no code");
        assertTrue(d.receiver.code.length != 0, "the recorded receiver has no code");
        assertGt(d.lpTokenId, 0, "no LP token was recorded");
        assertGt(d.finalSqrtPriceX96, 0, "no final price was recorded");
        assertGt(d.lpSubjectUsed, 0, "no SUBJECT consumption was recorded");
        assertGt(d.lpRegentUsed, 0, "no REGENT consumption was recorded");
        assertEq(PoolId.unwrap(d.poolId), PoolId.unwrap(_poolId(launched)), "the recorded PoolId is not the pool's");

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic =
            keccak256("LaunchGraduated(address,address,bytes32,address,address,uint160,uint256,uint128,uint128)");
        uint256 seen;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(strategy) || logs[i].topics[0] != topic) continue;
            seen += 1;
            (
                address loggedSplitter,
                address loggedReceiver,
                uint160 loggedPrice,
                uint256 loggedTokenId,
                uint128 loggedRegent,
                uint128 loggedSubject
            ) = abi.decode(logs[i].data, (address, address, uint160, uint256, uint128, uint128));
            assertEq(loggedSplitter, d.splitter, "event splitter");
            assertEq(loggedReceiver, d.receiver, "event receiver");
            assertEq(loggedPrice, d.finalSqrtPriceX96, "event final price");
            assertEq(loggedTokenId, d.lpTokenId, "event LP token");
            assertEq(loggedRegent, d.lpRegentUsed, "event REGENT consumption");
            assertEq(loggedSubject, d.lpSubjectUsed, "event SUBJECT consumption");
        }
        assertEq(seen, 1, "graduation announced itself other than once");
    }

    /// @notice `MIG-013`: the twelve steps run in exactly the specified order.
    /// @dev The proof is the real log stream of one graduation. Each step that touches state emits
    ///      its own event, so the first occurrence of each of those topics must appear in the fixed
    ///      order. Steps one and two — the final checkpoint and the pure PoolKey derivation — are
    ///      proved by `MIG-001` and `MIG-002`; the checkpoint's own event is asserted here to be
    ///      ahead of every terminal step.
    function test_MIG_013_TwelveStepsExecuteInTheSpecifiedOrder() public {
        Launched memory launched = _defaultLaunch();
        _bidToGraduationAt(launched, 20_000_000e18, 500);

        vm.recordLogs();
        strategy.migrate(address(launched.auction));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256[8] memory order = [
            _firstLog(logs, keccak256("CheckpointUpdated(uint256,uint256,uint24)")),
            _firstLog(logs, keccak256("SplitterInitialized(address,address,address,address,address,address,address)")),
            _firstLog(logs, keccak256("PoolRegistered(bytes32,address,address)")),
            _firstLog(logs, keccak256("Initialize(bytes32,address,address,uint24,int24,address,uint160,int24)")),
            _firstLog(logs, keccak256("ModifyLiquidity(bytes32,address,int24,int24,int256,bytes32)")),
            _firstLog(logs, keccak256("GraduatedUnsoldSubjectSwept(address,uint256)")),
            _firstLog(logs, keccak256("VestingActivated(uint64,uint256)")),
            _firstLog(
                logs,
                keccak256("LaunchGraduated(address,address,bytes32,address,address,uint160,uint256,uint128,uint128)")
            )
        ];
        string[8] memory names = [
            "1 final checkpoint",
            "3 splitter clone",
            "4 hook registration",
            "5 pool initialization",
            "6 full-range mint",
            "9 escrow sweep",
            "11 vesting activation",
            "12 graduation record"
        ];
        for (uint256 i; i < order.length; ++i) {
            assertLt(order[i], type(uint256).max, string.concat(names[i], " never happened"));
            if (i > 0) {
                assertLt(order[i - 1], order[i], string.concat(names[i], " ran before ", names[i - 1]));
            }
        }

        // Steps 7, 8 and 10 sit between the mint and the sweep, and between the sweep and vesting.
        uint256 treasuryPayout = _firstTransfer(logs, BaseBindings.REGENT, address(strategy), treasury);
        uint256 escrowPayout =
            _firstTransfer(logs, address(launched.subject), address(strategy), address(launched.escrow));
        uint256 receiverInit = _firstLog(logs, keccak256("ReceiverInitialized(address,address,uint16,address)"));

        assertLt(order[4], treasuryPayout, "7 treasury payout ran before the mint");
        assertLt(treasuryPayout, escrowPayout, "8 escrow payout ran before the treasury payout");
        assertLt(escrowPayout, order[5], "9 escrow sweep ran before the escrow payout");
        assertLt(order[5], receiverInit, "10 canonical receiver ran before the sweep");
        assertLt(receiverInit, order[6], "11 vesting ran before the canonical receiver");
    }

    /// @notice `MIG-014`: the official pool is static 0.30% with tick spacing 60 and carries exactly
    ///         one managed position.
    function test_MIG_014_OfficialPoolIsStaticThirtyBipsTickSpacingSixty() public {
        Launched memory launched = _defaultLaunch();
        _bidToGraduation(launched, 2_000e18);
        uint256 nextTokenIdBefore = positionManager.nextTokenId();
        strategy.migrate(address(launched.auction));

        PoolKey memory key = strategy.poolKeyOf(address(launched.subject));
        assertEq(key.fee, 3000, "the pool fee is not 0.30%");
        assertEq(key.tickSpacing, int24(60), "the pool tick spacing is not 60");

        (,, uint24 protocolFee, uint24 lpFee) = IPoolManager(BaseBindings.POOL_MANAGER).getSlot0(_poolId(launched));
        assertEq(lpFee, 3000, "the live LP fee is not the static 0.30%");
        assertEq(protocolFee, 0, "the pool carries a protocol fee");

        assertEq(positionManager.nextTokenId(), nextTokenIdBefore + 1, "more than one managed position exists");
        assertEq(strategy.POOL_FEE(), 3000, "the strategy's fee constant");
        assertEq(strategy.POOL_TICK_SPACING(), int24(60), "the strategy's tick spacing constant");
        assertEq(hook.POOL_FEE(), 3000, "the hook admits another fee");
        assertEq(hook.POOL_TICK_SPACING(), int24(60), "the hook admits another tick spacing");
    }

    /// @notice `MIG-015`: a third party may add its own position to the official pool without
    ///         touching the dead-owned managed one.
    function test_MIG_015_ThirdPartyPositionsDoNotAffectTheManagedPosition() public {
        Launched memory launched = _defaultLaunch();
        _bidToGraduationAt(launched, 20_000_000e18, 500);
        strategy.migrate(address(launched.auction));

        RegentLBPStrategy.Distribution memory d = _distribution(launched);
        uint128 managedBefore = positionManager.getPositionLiquidity(d.lpTokenId);
        uint256 thirdPartyTokenId = positionManager.nextTokenId();

        _mintThirdPartyPosition(launched, 1_000_000);

        assertEq(
            positionManager.getPositionLiquidity(d.lpTokenId), managedBefore, "the managed position's liquidity moved"
        );
        assertEq(
            IERC721(BaseBindings.POSITION_MANAGER).ownerOf(d.lpTokenId),
            BaseBindings.DEAD_ADDRESS,
            "the managed NFT changed hands"
        );
        assertEq(
            IERC721(BaseBindings.POSITION_MANAGER).ownerOf(thirdPartyTokenId),
            outsider,
            "the third party does not own its own position"
        );
        assertGt(positionManager.getPositionLiquidity(thirdPartyTokenId), 0, "the third-party position is empty");
        assertEq(_distribution(launched).lpTokenId, d.lpTokenId, "the recorded managed position changed");
    }

    /// @notice `MIG-016`: after graduation every unit of the launch's SUBJECT and of its raised
    ///         REGENT is in a named place, and no intermediate contract strands any of it.
    function test_MIG_016_TokenUseAndResiduesMatchExactly() public {
        Launched memory launched = _defaultLaunch();
        _bidToGraduationAt(launched, 20_000_000e18, 500);

        uint256 raised = 0;
        strategy.migrate(address(launched.auction));
        RegentLBPStrategy.Distribution memory d = _distribution(launched);
        raised = launched.auction.lbpInitializationParams().currencyRaised;

        // SUBJECT: the pool position, escrow, and whatever the auction actually sold, and nothing
        // anywhere else. Bidders claim their fill from the auction after the claim block.
        uint256 sold = AUCTION_ALLOCATION - launched.auction.remainingSupply();
        assertEq(
            launched.subject.balanceOf(BaseBindings.POOL_MANAGER) + launched.subject.balanceOf(address(launched.escrow))
                + launched.subject.balanceOf(address(launched.auction)),
            TOTAL_SUPPLY,
            "the whole supply is not in the three named places"
        );
        assertEq(launched.subject.balanceOf(BaseBindings.POOL_MANAGER), d.lpSubjectUsed, "pool SUBJECT");
        assertEq(
            launched.subject.balanceOf(address(launched.auction)), sold, "the auction holds other than the sold supply"
        );
        assertEq(launched.subject.balanceOf(address(strategy)), 0, "the strategy stranded SUBJECT");
        assertEq(launched.subject.balanceOf(BaseBindings.POSITION_MANAGER), 0, "the PositionManager stranded SUBJECT");
        assertEq(launched.subject.balanceOf(address(factory)), 0, "the factory stranded SUBJECT");
        assertEq(launched.subject.balanceOf(d.splitter), 0, "the splitter stranded SUBJECT");
        assertEq(launched.subject.balanceOf(d.receiver), 0, "the receiver stranded SUBJECT");
        assertEq(launched.subject.balanceOf(BaseBindings.DEAD_ADDRESS), 0, "a graduated launch retired SUBJECT");

        // REGENT: the pool position plus the treasury payout, exactly.
        assertEq(regent.balanceOf(BaseBindings.POOL_MANAGER), d.lpRegentUsed, "pool REGENT");
        assertEq(uint256(d.lpRegentUsed) + regent.balanceOf(treasury), raised, "the raise is not fully accounted for");
        assertEq(regent.balanceOf(address(strategy)), 0, "the strategy stranded REGENT");
        assertEq(regent.balanceOf(BaseBindings.POSITION_MANAGER), 0, "the PositionManager stranded REGENT");
        assertEq(regent.balanceOf(d.splitter), 0, "the splitter stranded REGENT");
    }

    // -------------------------------------------------------------------------
    // helpers
    // -------------------------------------------------------------------------

    function _assertPoolKeyDerivation(bool subjectBelowRegent) private {
        uint256 snap = vm.snapshotState();
        Launched memory launched = _launchSorted(subjectBelowRegent, _params());
        _bidToGraduation(launched, 2_000e18);
        strategy.migrate(address(launched.auction));

        PoolKey memory key = strategy.poolKeyOf(address(launched.subject));
        address expected0 = subjectBelowRegent ? address(launched.subject) : BaseBindings.REGENT;
        address expected1 = subjectBelowRegent ? BaseBindings.REGENT : address(launched.subject);
        assertEq(Currency.unwrap(key.currency0), expected0, "currency0 is not the lower address");
        assertEq(Currency.unwrap(key.currency1), expected1, "currency1 is not the higher address");
        assertEq(address(key.hooks), address(hook), "the key does not carry the shared hook");

        RegentLBPStrategy.Distribution memory d = _distribution(launched);
        assertEq(PoolId.unwrap(d.poolId), PoolId.unwrap(key.toId()), "the recorded PoolId is not the key's");

        LBPInitializationParams memory lbp = launched.auction.lbpInitializationParams();
        uint160 expectedPrice = TokenPricing.convertToSqrtPriceX96(
            TokenPricing.convertToPriceX192(lbp.initialPriceX96, !subjectBelowRegent)
        );
        assertEq(d.finalSqrtPriceX96, expectedPrice, "the final price conversion is wrong for this ordering");

        (uint160 slotPrice,,,) = IPoolManager(BaseBindings.POOL_MANAGER).getSlot0(d.poolId);
        assertEq(slotPrice, expectedPrice, "the pool did not open at the derived price");
        require(vm.revertToState(snap), "revert to snapshot failed");
    }

    /// @dev An ordinary independent position, minted by a stranger through the real PositionManager.
    function _mintThirdPartyPosition(Launched memory launched, uint128 liquidity) private {
        PoolKey memory key = strategy.poolKeyOf(address(launched.subject));
        (, int24 tick,,) = IPoolManager(BaseBindings.POOL_MANAGER).getSlot0(_poolId(launched));
        int24 lower = (tick / 60) * 60 - 6_000;
        int24 upper = (tick / 60) * 60 + 6_000;

        regent.mint(outsider, 1_000_000e18);
        vm.prank(address(launched.escrow));
        launched.subject.transfer(outsider, 1_000_000e18);

        vm.startPrank(outsider);
        regent.approve(PERMIT2, type(uint256).max);
        launched.subject.approve(PERMIT2, type(uint256).max);
        Permit2Double(PERMIT2)
            .approve(address(regent), BaseBindings.POSITION_MANAGER, type(uint160).max, type(uint48).max);
        Permit2Double(PERMIT2)
            .approve(address(launched.subject), BaseBindings.POSITION_MANAGER, type(uint160).max, type(uint48).max);

        bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(key, lower, upper, liquidity, type(uint128).max, type(uint128).max, outsider, bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1);
        positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp);
        vm.stopPrank();
    }

    function _firstLog(Vm.Log[] memory logs, bytes32 topic) private pure returns (uint256) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == topic) return i;
        }
        return type(uint256).max;
    }

    function _firstTransfer(Vm.Log[] memory logs, address token, address from, address to)
        private
        pure
        returns (uint256)
    {
        bytes32 topic = keccak256("Transfer(address,address,uint256)");
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory log = logs[i];
            if (log.emitter != token || log.topics.length != 3 || log.topics[0] != topic) continue;
            if (address(uint160(uint256(log.topics[1]))) != from) continue;
            if (address(uint160(uint256(log.topics[2]))) != to) continue;
            return i;
        }
        return type(uint256).max;
    }
}
