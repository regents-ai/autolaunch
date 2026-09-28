// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {ConditionalVestingEscrowV2} from "../../../src/escrow/ConditionalVestingEscrowV2.sol";
import {RegentsAutolaunchFactoryV2} from "../../../src/factory/RegentsAutolaunchFactoryV2.sol";
import {RegentLBPStrategyV2} from "../../../src/strategy/RegentLBPStrategyV2.sol";
import {IContinuousClearingAuction} from "continuous-clearing-auction/interfaces/IContinuousClearingAuction.sol";
import {CommonBase} from "forge-std/Base.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {UERC20} from "uerc20-factory/tokens/UERC20.sol";
import {Permit2Double} from "../../strategy/doubles/Permit2Double.sol";
import {StagedERC20} from "../../strategy/doubles/StagedERC20.sol";

/// @notice Drives three simultaneous launches through every reachable ordering of bidding, block
///         movement, terminal migration, vesting release, late retirement, and external gifts.
/// @dev Two disciplines make this evidence rather than a script.
///
///      The timeline is monotone in both clocks. `rollForward` advances the block height and the
///      block timestamp together, at Base's fixed two-second block time, so no sequence this
///      handler produces is one a real chain could not have produced — and the branches that need
///      wall-clock time rather than block height are genuinely reachable. Vesting is measured in
///      seconds, so a handler that moved only the height would leave `release` a permanent no-op,
///      the treasury permanently empty, and every gift branch below it dead. Nothing is
///      impersonated: every call is made by an ordinary account through the real production entry
///      point, and the only prank is to act *as* the account that legitimately owns the operation —
///      a bidder bidding, a treasury spending its own vested SUBJECT.
///
///      Every action is bounded to a precondition production itself enforces and returns instead of
///      reverting when there is nothing to do, so `fail_on_revert = true` keeps its full strength.
contract LifecycleHandler is CommonBase, StdUtils {
    uint256 internal constant LAUNCHES = 3;
    uint128 internal constant RESERVE_ALLOCATION = 15_000_000_000e18;

    /// @notice Base's fixed block time. One block forward is two seconds forward, always.
    uint256 internal constant SECONDS_PER_BLOCK = 2;

    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    RegentsAutolaunchFactoryV2 public immutable factory;
    RegentLBPStrategyV2 public immutable strategy;
    address public immutable hook;
    StagedERC20 public immutable regent;
    StagedERC20 public immutable usdc;
    address public immutable bidder;
    address public immutable treasury;

    address[LAUNCHES] public auctions;
    address[LAUNCHES] public subjects;
    address[LAUNCHES] public escrows;

    /// @notice SUBJECT gifted to the shared strategy and not yet absorbed by a graduation.
    mapping(uint256 launchIndex => uint256 amount) public strategySubjectGifts;
    /// @notice SUBJECT gifted to the factory and to the hook, which never move it on.
    mapping(uint256 launchIndex => uint256 amount) public factorySubjectGifts;
    mapping(uint256 launchIndex => uint256 amount) public hookSubjectGifts;

    /// @notice REGENT and USDC gifted to each shared contract.
    uint256 public factoryRegentGifts;
    uint256 public strategyRegentGifts;
    uint256 public hookRegentGifts;
    uint256 public factoryUsdcGifts;
    uint256 public strategyUsdcGifts;
    uint256 public hookUsdcGifts;

    /// @notice The first terminal lifecycle each launch reached, so a later change is visible.
    mapping(uint256 launchIndex => uint8 lifecycle) public firstTerminalLifecycle;

    /// @notice The exact LP SUBJECT a graduation consumed, read from the strategy's own record.
    mapping(uint256 launchIndex => uint256 amount) public graduationLpSubjectUsed;
    /// @notice The unsold SUBJECT a graduation swept out of the auction, measured as the auction's
    ///         own outflow across the migration.
    mapping(uint256 launchIndex => uint256 amount) public graduationUnsoldSwept;
    /// @notice The gifted SUBJECT a graduation absorbed and sent to the launch's escrow.
    mapping(uint256 launchIndex => uint256 amount) public graduationGiftsAbsorbed;
    /// @notice The exact SUBJECT a graduation moved from the strategy to that launch's own escrow.
    mapping(uint256 launchIndex => uint256 amount) public graduationSentToEscrow;
    /// @notice The exact SUBJECT a retirement moved from the strategy to that launch's own escrow.
    mapping(uint256 launchIndex => uint256 amount) public retirementSentToEscrow;
    uint256 public calls;

    /// @notice Branch reachability counters, so a dead action is visible rather than silent.
    /// @dev A handler action that always returns early looks identical to one that works: both
    ///      report a call and no revert. These count the branches that actually did something.
    uint256 public vestingReleases;
    uint256 public subjectGifts;
    uint256 public graduations;
    uint256 public retirements;

    constructor(
        RegentsAutolaunchFactoryV2 factory_,
        RegentLBPStrategyV2 strategy_,
        address hook_,
        StagedERC20 regent_,
        StagedERC20 usdc_,
        address bidder_,
        address treasury_,
        address[LAUNCHES] memory auctions_,
        address[LAUNCHES] memory subjects_,
        address[LAUNCHES] memory escrows_
    ) {
        factory = factory_;
        strategy = strategy_;
        hook = hook_;
        regent = regent_;
        usdc = usdc_;
        bidder = bidder_;
        treasury = treasury_;
        auctions = auctions_;
        subjects = subjects_;
        escrows = escrows_;
    }

    // -------------------------------------------------------------------------
    // actions
    // -------------------------------------------------------------------------

    /// @dev Time only moves forward, exactly as it does on chain, and both clocks move together.
    function rollForward(uint256 blocks) external {
        calls += 1;
        uint256 forward = bound(blocks, 1, 30_000);
        vm.roll(block.number + forward);
        vm.warp(block.timestamp + forward * SECONDS_PER_BLOCK);
    }

    /// @dev A real bidder, funding a real Permit2 allowance and submitting a real bid at an
    ///      on-grid price, inside the auction's own open window.
    function bid(uint256 launchSeed, uint256 amount, uint256 ticksAboveFloor) external {
        calls += 1;
        uint256 index = _index(launchSeed);
        IContinuousClearingAuction auction = IContinuousClearingAuction(auctions[index]);

        if (block.number < auction.startBlock() || block.number >= auction.endBlock()) return;
        if (strategy.distribution(auctions[index]).lifecycle != RegentLBPStrategyV2.Lifecycle.Active) return;

        uint128 bidAmount = uint128(bound(amount, 2_000e18, 12_000e18));

        // The pinned CCA refuses a bid at or below the live clearing price, so the bid is placed
        // strictly above it, on the frozen tick grid. Checkpointing first is the same permissionless
        // call the auction's own accounting uses, so the price read here is the current one.
        auction.checkpoint();
        uint256 tick = auction.tickSpacing();
        uint256 base = auction.clearingPrice();
        if (base < auction.floorPrice()) base = auction.floorPrice();
        uint256 remainder = base % tick;
        uint256 priceQ96 = base - remainder + (bound(ticksAboveFloor, 1, 20) + (remainder == 0 ? 0 : 1)) * tick;

        regent.mint(bidder, bidAmount);
        vm.startPrank(bidder);
        regent.approve(PERMIT2, type(uint256).max);
        Permit2Double(PERMIT2).approve(address(regent), address(auction), type(uint160).max, type(uint48).max);
        auction.submitBid(priceQ96, bidAmount, bidder, "");
        vm.stopPrank();
    }

    /// @dev Anyone may migrate, and only once the launch's own migration block has passed.
    ///      The balances captured either side of the call are what makes `INV-006` an exact
    ///      conservation statement rather than a bound: they separate the SUBJECT the auction's own
    ///      unsold sweep moved into the strategy from what the strategy itself moved on.
    function migrate(uint256 launchSeed) external {
        calls += 1;
        uint256 index = _index(launchSeed);
        RegentLBPStrategyV2.Distribution memory d = strategy.distribution(auctions[index]);

        if (d.lifecycle != RegentLBPStrategyV2.Lifecycle.Active) return;
        if (block.number < d.migrationBlock) return;

        UERC20 subject = UERC20(subjects[index]);
        uint256 strategyBefore = subject.balanceOf(address(strategy));
        uint256 auctionBefore = subject.balanceOf(auctions[index]);
        uint256 escrowBefore = subject.balanceOf(escrows[index]);

        strategy.migrate(auctions[index]);

        uint8 reached = uint8(strategy.distribution(auctions[index]).lifecycle);
        firstTerminalLifecycle[index] = reached;
        uint256 swept = auctionBefore - subject.balanceOf(auctions[index]);

        if (reached == uint8(RegentLBPStrategyV2.Lifecycle.Graduated)) {
            graduationLpSubjectUsed[index] = strategy.distribution(auctions[index]).lpSubjectUsed;
            graduationUnsoldSwept[index] = swept;
            graduationGiftsAbsorbed[index] = strategySubjectGifts[index];
            graduationSentToEscrow[index] = subject.balanceOf(escrows[index]) - escrowBefore;
            graduations += 1;

            // Graduation sends every unit of this launch's SUBJECT the strategy holds to the escrow,
            // gifted units included, so a gift made before it is no longer a separate balance.
            strategySubjectGifts[index] = 0;
        } else {
            // Retirement sends the swept sale allocation and the recorded reserve on to escrow, and
            // nothing else. The escrow's own balance is not usable here — it takes custody of the
            // whole supply and retires it inside the same call, so it ends below where it started.
            retirementSentToEscrow[index] = strategyBefore + swept - subject.balanceOf(address(strategy));
            retirements += 1;
        }
    }

    /// @dev Permissionless, and a no-op before anything has vested.
    function releaseVesting(uint256 launchSeed) external {
        calls += 1;
        uint256 index = _index(launchSeed);
        ConditionalVestingEscrowV2 escrow = ConditionalVestingEscrowV2(escrows[index]);
        if (escrow.lifecycle() != ConditionalVestingEscrowV2.Lifecycle.Graduated) return;

        uint256 before = escrow.totalReleased();
        escrow.release();
        if (escrow.totalReleased() != before) vestingReleases += 1;
    }

    /// @dev Permissionless, terminal-only, and a no-op with nothing to retire.
    function retireLate(uint256 launchSeed) external {
        calls += 1;
        uint256 index = _index(launchSeed);
        ConditionalVestingEscrowV2 escrow = ConditionalVestingEscrowV2(escrows[index]);
        if (escrow.lifecycle() != ConditionalVestingEscrowV2.Lifecycle.Failed) return;
        escrow.retireLateFailedSubject();
    }

    /// @dev Vesting hands SUBJECT to the treasury; the treasury may then send some of its own
    ///      SUBJECT anywhere, including at a shared contract that has no business holding it.
    function giftSubject(uint256 launchSeed, uint256 targetSeed, uint256 amount) external {
        calls += 1;
        uint256 index = _index(launchSeed);
        UERC20 subject = UERC20(subjects[index]);

        uint256 available = subject.balanceOf(treasury);
        if (available == 0) return;
        amount = bound(amount, 1, available);

        uint256 target = bound(targetSeed, 0, 2);
        vm.prank(treasury);
        if (target == 0) {
            subject.transfer(address(factory), amount);
            factorySubjectGifts[index] += amount;
        } else if (target == 1) {
            subject.transfer(address(strategy), amount);
            strategySubjectGifts[index] += amount;
        } else {
            subject.transfer(hook, amount);
            hookSubjectGifts[index] += amount;
        }
        subjectGifts += 1;
    }

    /// @dev An unrelated stranger gifting REGENT or USDC to a shared contract.
    function giftCurrency(uint256 targetSeed, uint256 amount, bool giftUsdc) external {
        calls += 1;
        amount = bound(amount, 1, 1_000e18);
        StagedERC20 token = giftUsdc ? usdc : regent;
        token.mint(address(this), amount);

        uint256 target = bound(targetSeed, 0, 2);
        if (target == 0) {
            token.transfer(address(factory), amount);
            if (giftUsdc) factoryUsdcGifts += amount;
            else factoryRegentGifts += amount;
        } else if (target == 1) {
            token.transfer(address(strategy), amount);
            if (giftUsdc) strategyUsdcGifts += amount;
            else strategyRegentGifts += amount;
        } else {
            token.transfer(hook, amount);
            if (giftUsdc) hookUsdcGifts += amount;
            else hookRegentGifts += amount;
        }
    }

    // -------------------------------------------------------------------------

    function _index(uint256 seed) private pure returns (uint256) {
        return seed % LAUNCHES;
    }

    function launchCount() external pure returns (uint256) {
        return LAUNCHES;
    }

    function auctionAt(uint256 index) external view returns (address) {
        return auctions[index];
    }

    function subjectAt(uint256 index) external view returns (address) {
        return subjects[index];
    }

    function escrowAt(uint256 index) external view returns (address) {
        return escrows[index];
    }
}
