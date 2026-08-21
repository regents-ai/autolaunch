// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {ConditionalVestingEscrowV1} from "../../../src/escrow/ConditionalVestingEscrowV1.sol";
import {RegentsAutolaunchFactoryV1} from "../../../src/factory/RegentsAutolaunchFactoryV1.sol";
import {RegentLBPStrategy} from "../../../src/strategy/RegentLBPStrategy.sol";
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
///      The timeline is monotone. `vm.roll` only ever moves forward, so no sequence this handler
///      produces is one a real chain could not have produced. Nothing is impersonated: every call
///      is made by an ordinary account through the real production entry point, and the only prank
///      is to act *as* the account that legitimately owns the operation — a bidder bidding, a
///      treasury spending its own vested SUBJECT.
///
///      Every action is bounded to a precondition production itself enforces and returns instead of
///      reverting when there is nothing to do, so `fail_on_revert = true` keeps its full strength.
contract LifecycleHandler is CommonBase, StdUtils {
    uint256 internal constant LAUNCHES = 3;
    uint128 internal constant RESERVE_ALLOCATION = 5_000_000_000e18;

    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    RegentsAutolaunchFactoryV1 public immutable factory;
    RegentLBPStrategy public immutable strategy;
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

    uint256 public calls;

    constructor(
        RegentsAutolaunchFactoryV1 factory_,
        RegentLBPStrategy strategy_,
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

    /// @dev Time only moves forward, exactly as it does on chain.
    function rollForward(uint256 blocks) external {
        calls += 1;
        vm.roll(block.number + bound(blocks, 1, 30_000));
    }

    /// @dev A real bidder, funding a real Permit2 allowance and submitting a real bid at an
    ///      on-grid price, inside the auction's own open window.
    function bid(uint256 launchSeed, uint256 amount, uint256 ticksAboveFloor) external {
        calls += 1;
        uint256 index = _index(launchSeed);
        IContinuousClearingAuction auction = IContinuousClearingAuction(auctions[index]);

        if (block.number < auction.startBlock() || block.number >= auction.endBlock()) return;
        if (strategy.distribution(auctions[index]).lifecycle != RegentLBPStrategy.Lifecycle.Active) return;

        uint128 bidAmount = uint128(bound(amount, 1e18, 5_000e18));

        // The pinned CCA refuses a bid at or below the live clearing price, so the bid is placed
        // strictly above it, on the frozen tick grid. Checkpointing first is the same permissionless
        // call the auction's own accounting uses, so the price read here is the current one.
        auction.checkpoint();
        uint256 tick = strategy.BID_TICK_Q96();
        uint256 base = auction.clearingPrice();
        if (base < strategy.FLOOR_PRICE_Q96()) base = strategy.FLOOR_PRICE_Q96();
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
    function migrate(uint256 launchSeed) external {
        calls += 1;
        uint256 index = _index(launchSeed);
        RegentLBPStrategy.Distribution memory d = strategy.distribution(auctions[index]);

        if (d.lifecycle != RegentLBPStrategy.Lifecycle.Active) return;
        if (block.number < d.migrationBlock) return;

        strategy.migrate(auctions[index]);

        uint8 reached = uint8(strategy.distribution(auctions[index]).lifecycle);
        firstTerminalLifecycle[index] = reached;
        // Graduation sweeps every unit of this launch's SUBJECT the strategy holds into escrow,
        // gifted units included, so nothing gifted before it survives at the strategy.
        if (reached == uint8(RegentLBPStrategy.Lifecycle.Graduated)) strategySubjectGifts[index] = 0;
    }

    /// @dev Permissionless, and a no-op before anything has vested.
    function releaseVesting(uint256 launchSeed) external {
        calls += 1;
        uint256 index = _index(launchSeed);
        ConditionalVestingEscrowV1 escrow = ConditionalVestingEscrowV1(escrows[index]);
        if (escrow.lifecycle() != ConditionalVestingEscrowV1.Lifecycle.Graduated) return;
        escrow.release();
    }

    /// @dev Permissionless, terminal-only, and a no-op with nothing to retire.
    function retireLate(uint256 launchSeed) external {
        calls += 1;
        uint256 index = _index(launchSeed);
        ConditionalVestingEscrowV1 escrow = ConditionalVestingEscrowV1(escrows[index]);
        if (escrow.lifecycle() != ConditionalVestingEscrowV1.Lifecycle.Failed) return;
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
