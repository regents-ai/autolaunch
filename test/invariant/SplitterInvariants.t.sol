// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {SubjectSplitterV1} from "../../src/revenue/SubjectSplitterV1.sol";
import {LibClone} from "solady/utils/LibClone.sol";
import {Test} from "forge-std/Test.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockLiveStaking} from "../mocks/MockLiveStaking.sol";
import {MockRecoveryAdmin} from "../mocks/MockRecoveryAdmin.sol";
import {SplitterHandler} from "./handlers/SplitterHandler.sol";

/// @notice `INV-002`, `INV-003`, and `INV-005`: three deliberately separate accounting models over
///         one real splitter clone driven through every reachable caller operation.
/// @dev They are not one statement wearing three names.
///
///      `INV-002` is the *solvency* model: an outside summary of everything handed in and paid out
///      must reproduce the splitter's held balance exactly.
///      `INV-003` is the *principal* model: staked SUBJECT measured on its own, against custody and
///      against the per-account sum, saying nothing about reward division.
///      `INV-005` is the *remainder* model: the scaled reward numerator only — the single carry and
///      each account's banked sub-unit dust — neither dropped nor credited twice.
///
///      The splitter's arithmetic is never mirrored. The model records only what a caller can see
///      from outside: gross handed in, the specified 2% skim, where the net was routed, and what
///      was actually claimed.
contract SplitterInvariantsTest is Test {
    uint256 internal constant SCALE = 1e36;
    uint256 internal constant ACTOR_FUNDING = 1_000_000e18;

    SubjectSplitterV1 internal splitter;
    MockERC20 internal usdc;
    MockERC20 internal regent;
    MockERC20 internal subject;
    MockERC20 internal unsupported;
    MockLiveStaking internal liveStaking;
    MockRecoveryAdmin internal recoveryAdmin;
    SplitterHandler internal handler;

    address internal regentSafe = makeAddr("regentSafe");
    address internal treasury = makeAddr("treasury");

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        regent = new MockERC20("Regent", "REGENT", 18);
        subject = new MockERC20("Subject", "SUBJ", 18);
        unsupported = new MockERC20("Unsupported", "UNSUP", 18);
        liveStaking = new MockLiveStaking(address(usdc));
        recoveryAdmin = new MockRecoveryAdmin();

        splitter = SubjectSplitterV1(LibClone.clone(address(new SubjectSplitterV1())));
        splitter.initialize(
            address(usdc),
            address(regent),
            address(subject),
            address(liveStaking),
            regentSafe,
            treasury,
            address(recoveryAdmin)
        );

        address[4] memory actors =
            [makeAddr("staker-a"), makeAddr("staker-b"), makeAddr("payer-c"), makeAddr("payer-d")];
        for (uint256 i; i < actors.length; ++i) {
            usdc.mint(actors[i], ACTOR_FUNDING);
            regent.mint(actors[i], ACTOR_FUNDING);
            subject.mint(actors[i], ACTOR_FUNDING);
            unsupported.mint(actors[i], ACTOR_FUNDING);
        }

        handler = new SplitterHandler(
            splitter, usdc, regent, subject, unsupported, address(recoveryAdmin), regentSafe, treasury, actors
        );

        targetContract(address(handler));
    }

    // -------------------------------------------------------------------------
    // INV-002 — solvency
    // -------------------------------------------------------------------------

    /// @notice `INV-002`: for every recognized token the splitter's held balance is exactly the
    ///         principal it custodies plus the liability it still owes, reproduced from an outside
    ///         summary of every inflow and outflow.
    /// @dev Exact equality, not an inequality: a splitter that held more than it owes would be
    ///      carrying unaccounted inventory, and one that held less would be insolvent.
    function invariant_INV_002_SplitterRemainsSolvent() public view {
        address[3] memory tokens = [address(usdc), address(regent), address(subject)];
        for (uint256 i; i < tokens.length; ++i) {
            address token = tokens[i];

            uint256 principal = token == address(subject) ? splitter.totalStaked() : 0;
            uint256 modelledLiability = handler.creditedToStakers(token) - handler.claimedByStakers(token);

            assertEq(
                splitter.unclaimedLiability(token),
                modelledLiability,
                "recognized liability is not what the outside summary credited minus what was claimed"
            );
            assertEq(
                MockERC20(token).balanceOf(address(splitter)),
                principal + modelledLiability,
                "the splitter's balance is not exactly its custodied principal plus its liability"
            );
            assertEq(
                splitter.protectedBalance(token),
                principal + splitter.unclaimedLiability(token),
                "protected inventory disagrees with principal plus liability"
            );

            // Nothing recognized may still be sitting unaccounted, and nothing unaccounted may be
            // hiding inside protected inventory.
            assertEq(
                MockERC20(token).balanceOf(address(splitter)) - splitter.protectedBalance(token),
                0,
                "an unrecognized surplus survived recognition"
            );
        }
    }

    // -------------------------------------------------------------------------
    // INV-003 — principal
    // -------------------------------------------------------------------------

    /// @notice `INV-003`: staked SUBJECT principal is never spent — custody covers it, the
    ///         per-account sum reproduces it, and only its own owner can reduce it.
    function invariant_INV_003_StakedPrincipalIsNeverSpent() public view {
        uint256 total = splitter.totalStaked();

        uint256 summed;
        for (uint256 i; i < handler.actorCount(); ++i) {
            summed += splitter.stakedOf(handler.actorAt(i));
        }
        assertEq(summed, total, "the per-account principal sum is not totalStaked");
        assertEq(
            total,
            handler.principalStaked() - handler.principalUnstaked(),
            "totalStaked is not everything staked minus everything its owners took back"
        );
        assertLe(total, subject.balanceOf(address(splitter)), "custody no longer covers staked principal");
    }

    // -------------------------------------------------------------------------
    // INV-005 — remainder
    // -------------------------------------------------------------------------

    /// @notice `INV-005`: the staker-owned remainder is never lost and never double-paid.
    /// @dev Two independent bounds. Nothing can be paid twice, because everything currently
    ///      claimable across all accounts fits inside the recognized liability. Nothing is lost,
    ///      because what is not yet claimable is only sub-unit dust: at most one whole unit per
    ///      account, plus the single scaled carry, which is itself below one whole unit.
    function invariant_INV_005_RemainderIsNeverLostOrDoublePaid() public view {
        uint256 actors = handler.actorCount();

        address[3] memory tokens = [address(usdc), address(regent), address(subject)];
        for (uint256 i; i < tokens.length; ++i) {
            address token = tokens[i];

            // The carry is `numerator % totalStaked` at the moment of the division that produced
            // it. A later unstake lowers `totalStaked` without touching the carry, so the ceiling
            // that matters is the stake the carry was actually measured against.
            uint256 ceiling = handler.carryCeiling(token);
            if (ceiling == 0) {
                assertEq(splitter.carriedRemainder(token), 0, "a carry appeared without any division");
            } else {
                assertLt(
                    splitter.carriedRemainder(token),
                    ceiling,
                    "the carried scaled remainder reached a whole distributable unit"
                );
            }

            uint256 claimableTotal;
            for (uint256 a; a < actors; ++a) {
                address actor = handler.actorAt(a);
                assertLt(splitter.claimableDust(token, actor), SCALE, "an account banked a whole unit as dust");
                claimableTotal += splitter.claimable(token, actor);
            }

            uint256 liability = splitter.unclaimedLiability(token);
            assertLe(claimableTotal, liability, "more is claimable than was ever recognized");
            assertLe(
                liability - claimableTotal,
                actors + 1,
                "recognized liability is stranded beyond the sub-unit dust it can be"
            );
        }
    }
}
