// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {C1Fixture} from "../mocks/C1Fixture.sol";
import {ForceEthSender} from "../mocks/ForceEthSender.sol";
import {HostileSplitter} from "../mocks/HostileSplitter.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {PaymentReceiverV1} from "../../src/revenue/PaymentReceiverV1.sol";
import {SubjectSplitterV1} from "../../src/revenue/SubjectSplitterV1.sol";
import {Initializable} from "solady/utils/Initializable.sol";
import {LibClone} from "solady/utils/LibClone.sol";

/// @notice Claim-level proof for `PaymentReceiverV1`.
/// @dev Every selector drives the production receiver against a production splitter. Only the
///      tokens, the live staking contract, the calling account, and — where the claim is about a
///      hostile counterparty — the splitter are mocked. `RCV-001` is the permissionless factory
///      creation claim and belongs to C4; nothing here exposes a receiver-creation API.
contract PaymentReceiverV1Test is C1Fixture {
    SubjectSplitterV1 internal splitter;
    PaymentReceiverV1 internal canonical;

    address internal payer = makeAddr("payer");
    address internal referrer = makeAddr("referrer");
    address internal editor = makeAddr("editor");

    function setUp() public {
        _deployC1();
        splitter = _newSplitter();
        canonical = _newReceiver(address(splitter), treasury, 0, treasury, true);
    }

    // ------------------------------------------------------------------ RCV-002

    /// @notice RCV-002: the referral share is immutable for the life of a receiver.
    function test_RCV_002_ReferralShareIsImmutable() public {
        PaymentReceiverV1 receiver = _newReceiver(address(splitter), referrer, 250, editor, false);
        assertEq(receiver.referralBps(), 250, "fixed at initialization");

        bytes[3] memory attempts = [
            abi.encodeWithSignature("setReferralBps(uint16)", uint16(0)),
            abi.encodeWithSignature("setReferral(uint16)", uint16(1)),
            abi.encodeWithSignature("updateReferralBps(uint16)", uint16(10))
        ];
        for (uint256 i; i < attempts.length; ++i) {
            vm.prank(editor);
            assertFalse(_callSucceeds(address(receiver), attempts[i]), "no referral setter exists");
        }

        // Re-initialization cannot move it either.
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        receiver.initialize(address(splitter), referrer, 0, editor, false);

        _pay(receiver, usdc, 1_000_000);
        assertEq(receiver.referralBps(), 250, "unchanged after a payment");
    }

    // ------------------------------------------------------------------ RCV-003

    /// @notice RCV-003: referral boundary values 0, 1, 249, 250, and 251 behave exactly.
    function test_RCV_003_ReferralBoundaryValuesBehaveExactly() public {
        uint16[4] memory admitted = [uint16(0), 1, 249, 250];
        for (uint256 i; i < admitted.length; ++i) {
            PaymentReceiverV1 receiver = _newReceiver(address(splitter), referrer, admitted[i], editor, false);
            assertEq(receiver.referralBps(), admitted[i], "admitted referral share");

            uint256 before = usdc.balanceOf(referrer);
            _pay(receiver, usdc, 1_000_000);
            assertEq(
                usdc.balanceOf(referrer) - before, (uint256(1_000_000) * admitted[i]) / 10_000, "exact floored referral"
            );
        }

        // One basis point above the cap is rejected, and so is anything higher.
        PaymentReceiverV1 blocked = PaymentReceiverV1(LibClone.clone(address(receiverImplementation)));
        vm.expectRevert(abi.encodeWithSelector(PaymentReceiverV1.ReferralTooHigh.selector, uint16(251)));
        blocked.initialize(address(splitter), referrer, 251, editor, false);
        vm.expectRevert(abi.encodeWithSelector(PaymentReceiverV1.ReferralTooHigh.selector, type(uint16).max));
        blocked.initialize(address(splitter), referrer, type(uint16).max, editor, false);

        // Amounts that floor the referral to zero and to exactly one unit.
        PaymentReceiverV1 oneBps = _newReceiver(address(splitter), referrer, 1, editor, false);
        uint256 refBefore = usdc.balanceOf(referrer);
        _pay(oneBps, usdc, 9_999);
        assertEq(usdc.balanceOf(referrer) - refBefore, 0, "9,999 at 1 bp floors to zero");
        _pay(oneBps, usdc, 10_000);
        assertEq(usdc.balanceOf(referrer) - refBefore, 1, "10,000 at 1 bp floors to exactly one");
    }

    // ------------------------------------------------------------------ RCV-004

    /// @notice RCV-004: the referral is paid before the splitter sees anything.
    function test_RCV_004_ReferralRunsBeforeSplitterProcessing() public {
        PaymentReceiverV1 receiver = _newReceiver(address(splitter), referrer, 250, editor, false);

        _pay(receiver, usdc, 1_000_000);

        // The splitter's 2% is charged on the post-referral net, not on the gross.
        assertEq(usdc.balanceOf(referrer), 25_000, "referral is 2.5% of the gross");
        assertEq(usdc.balanceOf(address(liveStaking)), 19_500, "the skim is 2% of the net, not of the gross");
        assertEq(usdc.balanceOf(treasury), 955_500, "the treasury receives the remainder of the net");
        assertEq(
            usdc.balanceOf(referrer) + usdc.balanceOf(address(liveStaking)) + usdc.balanceOf(treasury),
            uint256(1_000_000),
            "gross equals referral plus skim plus net"
        );
        assertEq(usdc.balanceOf(address(receiver)), 0, "and the receiver kept nothing");
    }

    // ------------------------------------------------------------------ RCV-005

    /// @notice RCV-005: the canonical receiver has zero referral and a treasury-edited note.
    function test_RCV_005_CanonicalReceiverHasZeroReferralAndTreasuryNote() public {
        assertEq(canonical.referralBps(), 0, "zero referral");
        assertEq(canonical.beneficiary(), treasury, "treasury beneficiary");
        assertEq(canonical.noteEditor(), treasury, "treasury note editor");

        vm.prank(treasury);
        canonical.setReceiverNote(bytes32("canonical"));
        assertEq(canonical.receiverNote(), bytes32("canonical"), "the treasury edits the canonical note");

        // Canonical initialization rejects anything else.
        PaymentReceiverV1 blocked = PaymentReceiverV1(LibClone.clone(address(receiverImplementation)));
        vm.expectRevert(abi.encodeWithSelector(PaymentReceiverV1.CanonicalRequiresZeroReferral.selector, uint16(1)));
        blocked.initialize(address(splitter), treasury, 1, treasury, true);
        vm.expectRevert(
            abi.encodeWithSelector(PaymentReceiverV1.CanonicalRequiresTreasuryBeneficiary.selector, referrer)
        );
        blocked.initialize(address(splitter), referrer, 0, treasury, true);
        vm.expectRevert(abi.encodeWithSelector(PaymentReceiverV1.CanonicalRequiresTreasuryNoteEditor.selector, editor));
        blocked.initialize(address(splitter), treasury, 0, editor, true);

        // A canonical payment routes its whole gross to the splitter.
        _pay(canonical, usdc, 1_000_000);
        assertEq(usdc.balanceOf(address(liveStaking)), 20_000, "the skim is 2% of the whole gross");
        assertEq(usdc.balanceOf(treasury), 980_000, "no referral was taken");
    }

    // ------------------------------------------------------------------ RCV-006

    /// @notice RCV-006: the note defaults to the receiver address and rides every route event.
    function test_RCV_006_NoteDefaultsToTheReceiverAddressAndIsEmitted() public {
        PaymentReceiverV1 receiver = _newReceiver(address(splitter), referrer, 100, editor, false);
        assertEq(receiver.receiverNote(), bytes32(uint256(uint160(address(receiver)))), "default note");

        usdc.mint(payer, 1_000_000);
        vm.startPrank(payer);
        usdc.approve(address(receiver), 1_000_000);
        vm.expectEmit(true, true, true, true, address(receiver));
        emit PaymentReceiverV1.PaymentRouted(
            bytes32("ref-a"), bytes32(uint256(uint160(address(receiver)))), address(usdc), 1_000_000, 10_000, 990_000
        );
        receiver.pay(address(usdc), 1_000_000, bytes32("ref-a"));
        vm.stopPrank();

        // After an edit, the new note rides the next event.
        vm.expectEmit(true, true, true, true, address(receiver));
        emit PaymentReceiverV1.ReceiverNoteUpdated(bytes32(uint256(uint160(address(receiver)))), bytes32("desk-7"));
        vm.prank(editor);
        receiver.setReceiverNote(bytes32("desk-7"));

        usdc.mint(payer, 1_000_000);
        vm.startPrank(payer);
        usdc.approve(address(receiver), 1_000_000);
        vm.expectEmit(true, true, true, true, address(receiver));
        emit PaymentReceiverV1.PaymentRouted(
            bytes32("ref-b"), bytes32("desk-7"), address(usdc), 1_000_000, 10_000, 990_000
        );
        receiver.pay(address(usdc), 1_000_000, bytes32("ref-b"));
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ RCV-007

    /// @notice RCV-007: pay and sweep share the same atomic referral-before-splitter route.
    function test_RCV_007_PayAndSweepShareTheSameAtomicRoute() public {
        PaymentReceiverV1 receiver = _newReceiver(address(splitter), referrer, 100, editor, false);

        // An unrelated bare balance is already sitting here and must survive an exact `pay`.
        usdc.mint(address(receiver), 500_000);

        _pay(receiver, usdc, 1_000_000);

        assertEq(usdc.balanceOf(referrer), 10_000, "referral on the paid amount only");
        assertEq(usdc.balanceOf(address(receiver)), 500_000, "the bare balance was left untouched");
        assertEq(usdc.allowance(address(receiver), address(splitter)), 0, "allowance cleared");

        uint256 referralBefore = usdc.balanceOf(referrer);
        uint256 treasuryBefore = usdc.balanceOf(treasury);
        uint256 skimBefore = usdc.balanceOf(address(liveStaking));

        vm.expectEmit(true, true, true, true, address(receiver));
        emit PaymentReceiverV1.PaymentRouted(
            bytes32(0), receiver.receiverNote(), address(usdc), 500_000, 5_000, 495_000
        );
        vm.prank(outsider);
        receiver.sweep(address(usdc));

        // The sweep took the identical route over the bare balance.
        assertEq(usdc.balanceOf(referrer) - referralBefore, 5_000, "same floored referral rule");
        assertEq(usdc.balanceOf(address(liveStaking)) - skimBefore, 9_900, "same 2% on the same net");
        assertEq(usdc.balanceOf(treasury) - treasuryBefore, 485_100, "same net destination");
        assertEq(usdc.balanceOf(address(receiver)), 0, "no attributable balance is retained");
        assertEq(usdc.allowance(address(receiver), address(splitter)), 0, "no allowance is retained");

        // An empty sweep is rejected rather than emitting an empty route.
        vm.expectRevert(PaymentReceiverV1.ZeroAmount.selector);
        receiver.sweep(address(usdc));
        vm.expectRevert(PaymentReceiverV1.ZeroAmount.selector);
        receiver.pay(address(usdc), 0, bytes32("pay-0"));
    }

    // ------------------------------------------------------------------ RCV-008

    /// @notice RCV-008: ordinary ETH transfers to a receiver revert.
    function test_RCV_008_OrdinaryEthTransfersRevert() public {
        vm.deal(address(this), 3 ether);

        (bool plain,) = address(canonical).call{value: 1 ether}("");
        assertFalse(plain, "a plain ETH transfer reverts");
        (bool withData,) = address(canonical).call{value: 1 ether}(hex"c0ffee");
        assertFalse(withData, "an unknown payable call reverts");
        assertEq(address(canonical).balance, 0, "no ETH accumulated");

        new ForceEthSender{value: 1 ether}(address(canonical));
        assertEq(address(canonical).balance, 1 ether, "only forced ETH can arrive");

        uint256 treasuryEth = treasury.balance;
        vm.prank(outsider);
        canonical.recoverForcedETH();
        assertEq(treasury.balance - treasuryEth, 1 ether, "forced ETH is recoverable to the treasury");
    }

    // ------------------------------------------------------------------ RCV-009

    /// @notice RCV-009: receiver recovery is permissionless, moves the complete balance, and can
    ///         only ever reach the immutable treasury. A zero balance fails and mutates nothing.
    function test_RCV_009_RecoveryIsPermissionlessWholeBalanceToTheTreasury() public {
        MockERC20 other = new MockERC20("Other", "OTH", 18);

        // Nothing to recover: every caller is refused and nothing moves.
        address[4] memory callers = [address(this), treasury, referrer, outsider];
        for (uint256 i; i < callers.length; ++i) {
            vm.startPrank(callers[i]);
            vm.expectRevert(PaymentReceiverV1.ZeroAmount.selector);
            canonical.recoverUnsupportedToken(address(other));
            vm.expectRevert(PaymentReceiverV1.ZeroAmount.selector);
            canonical.recoverForcedETH();
            vm.stopPrank();
        }
        assertEq(other.balanceOf(treasury), 0, "a failed recovery moved value");

        // Each caller in turn takes the complete balance to the fixed treasury and keeps nothing.
        for (uint256 i; i < callers.length; ++i) {
            other.mint(address(canonical), 500e18);
            uint256 treasuryBefore = other.balanceOf(treasury);

            vm.prank(callers[i]);
            vm.expectEmit(true, true, true, true, address(canonical));
            emit PaymentReceiverV1.UnsupportedTokenRecovered(address(other), treasury, 500e18);
            canonical.recoverUnsupportedToken(address(other));

            assertEq(other.balanceOf(treasury) - treasuryBefore, 500e18, "the whole balance reached the treasury");
            assertEq(other.balanceOf(address(canonical)), 0, "the receiver kept a remainder");
            if (callers[i] != treasury) assertEq(other.balanceOf(callers[i]), 0, "the caller was paid for calling");
        }

        vm.deal(address(this), 1 ether);
        new ForceEthSender{value: 1 ether}(address(canonical));
        uint256 treasuryEth = treasury.balance;
        vm.prank(outsider);
        vm.expectEmit(true, true, true, true, address(canonical));
        emit PaymentReceiverV1.ForcedEthRecovered(treasury, 1 ether);
        canonical.recoverForcedETH();
        assertEq(treasury.balance - treasuryEth, 1 ether, "the ETH reached the fixed treasury");
        assertEq(address(canonical).balance, 0, "no ETH remains");

        // Neither an amount nor a destination can be named any more.
        assertFalse(
            _callSucceeds(
                address(canonical),
                abi.encodeWithSignature("recoverUnsupportedToken(address,uint256)", address(other), uint256(1))
            ),
            "an amount-taking recovery selector still exists"
        );
        assertFalse(
            _callSucceeds(address(canonical), abi.encodeWithSignature("recoverForcedETH(uint256)", uint256(1))),
            "an amount-taking ETH recovery selector still exists"
        );
    }

    // ------------------------------------------------------------------ RCV-010

    /// @notice RCV-010: USDC, REGENT, and SUBJECT are permanently outside receiver recovery.
    function test_RCV_010_RecoveryCanNeverReachSupportedTokens() public {
        usdc.mint(address(canonical), 1_000_000);
        regent.mint(address(canonical), 1_000e18);
        subject.mint(address(canonical), 1_000e18);

        address[3] memory supported = [address(usdc), address(regent), address(subject)];
        vm.startPrank(outsider);
        for (uint256 i; i < supported.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(PaymentReceiverV1.ProtectedToken.selector, supported[i]));
            canonical.recoverUnsupportedToken(supported[i]);
        }
        vm.stopPrank();

        assertEq(usdc.balanceOf(address(canonical)), 1_000_000, "USDC untouched");
        assertEq(regent.balanceOf(address(canonical)), 1_000e18, "REGENT untouched");
        assertEq(subject.balanceOf(address(canonical)), 1_000e18, "SUBJECT untouched");

        // A supported balance leaves only through the ordinary route.
        vm.prank(outsider);
        canonical.sweep(address(usdc));
        assertEq(usdc.balanceOf(address(canonical)), 0, "swept through the route, never through recovery");
        assertEq(usdc.balanceOf(treasury), 980_000, "and it reached the splitter's destinations");
    }

    // ------------------------------------------------------------------ RCV-011

    /// @notice RCV-011: a malicious token can fail only its own recovery call.
    function test_RCV_011_MaliciousTokenFailsOnlyItsOwnRecoveryCall() public {
        MockERC20 malicious = new MockERC20("Malicious", "MAL", 18);
        malicious.mint(address(canonical), 100e18);
        malicious.setReverts(true);

        vm.prank(outsider);
        vm.expectRevert();
        canonical.recoverUnsupportedToken(address(malicious));

        // Nothing enumerates it, so no other path ever touches it.
        assertFalse(
            _callSucceeds(address(canonical), abi.encodeWithSignature("recoverAll()")), "no enumeration surface"
        );
        assertFalse(_callSucceeds(address(canonical), abi.encodeWithSignature("tokenCount()")), "no token registry");

        // Every ordinary path still works.
        _pay(canonical, usdc, 1_000_000);
        assertEq(usdc.balanceOf(treasury), 980_000, "payments are unaffected");

        MockERC20 honest = new MockERC20("Honest", "HON", 18);
        honest.mint(address(canonical), 50e18);
        vm.prank(outsider);
        canonical.recoverUnsupportedToken(address(honest));
        assertEq(honest.balanceOf(treasury), 50e18, "another token's recovery is unaffected");
        assertEq(malicious.balanceOf(address(canonical)), 100e18, "the malicious token simply stays put");
    }

    // ------------------------------------------------------------------ RCV-012

    /// @notice RCV-012: pay and sweep accept only the splitter's three tokens.
    function test_RCV_012_PayAndSweepValidateSupportedTokens() public {
        MockERC20 other = new MockERC20("Other", "OTH", 18);
        other.mint(address(canonical), 100e18);
        other.mint(payer, 100e18);

        vm.startPrank(payer);
        other.approve(address(canonical), 100e18);
        vm.expectRevert(abi.encodeWithSelector(PaymentReceiverV1.UnsupportedToken.selector, address(other)));
        canonical.pay(address(other), 1e18, bytes32("bad"));
        vm.expectRevert(abi.encodeWithSelector(PaymentReceiverV1.UnsupportedToken.selector, address(other)));
        canonical.sweep(address(other));
        vm.stopPrank();

        assertEq(other.balanceOf(address(canonical)), 100e18, "the unsupported balance did not move");

        // All three supported tokens route.
        _pay(canonical, usdc, 1_000_000);
        _pay(canonical, regent, 1_000e18);
        _pay(canonical, subject, 1_000e18);
        assertEq(usdc.balanceOf(treasury), 980_000, "USDC routed");
        assertEq(regent.balanceOf(treasury), 980e18, "REGENT routed");
        assertEq(subject.balanceOf(treasury), 980e18, "SUBJECT routed");
    }

    // ------------------------------------------------------------------ RCV-013

    /// @notice RCV-013: the beneficiary and the splitter binding are immutable, and the rest of the
    ///         bindings are derived from the splitter rather than supplied twice.
    function test_RCV_013_BeneficiaryAndSplitterBindingsAreImmutable() public {
        PaymentReceiverV1 receiver = _newReceiver(address(splitter), referrer, 100, editor, false);

        assertEq(receiver.splitter(), address(splitter), "splitter bound");
        assertEq(receiver.beneficiary(), referrer, "beneficiary bound");
        assertEq(receiver.treasury(), splitter.treasury(), "treasury derived from the splitter");
        assertEq(receiver.usdc(), splitter.usdc(), "USDC derived");
        assertEq(receiver.regent(), splitter.regent(), "REGENT derived");
        assertEq(receiver.subject(), splitter.subject(), "SUBJECT derived");

        // The implementation can never accept a payment, and a clone binds exactly once.
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        receiverImplementation.initialize(address(splitter), referrer, 0, editor, false);
        vm.prank(outsider);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        receiver.initialize(address(splitter), outsider, 250, outsider, false);

        // Zero and self bindings are rejected.
        PaymentReceiverV1 fresh = PaymentReceiverV1(LibClone.clone(address(receiverImplementation)));
        vm.expectRevert(PaymentReceiverV1.ZeroAddress.selector);
        fresh.initialize(address(0), referrer, 0, editor, false);
        vm.expectRevert(PaymentReceiverV1.ZeroAddress.selector);
        fresh.initialize(address(splitter), address(0), 0, editor, false);
        vm.expectRevert(PaymentReceiverV1.ZeroAddress.selector);
        fresh.initialize(address(splitter), referrer, 0, address(0), false);
        vm.expectRevert(PaymentReceiverV1.SelfAddress.selector);
        fresh.initialize(address(fresh), referrer, 0, editor, false);
        vm.expectRevert(PaymentReceiverV1.SelfAddress.selector);
        fresh.initialize(address(splitter), address(fresh), 0, editor, false);
        vm.expectRevert(PaymentReceiverV1.SelfAddress.selector);
        fresh.initialize(address(splitter), referrer, 0, address(fresh), false);

        // No setter exists for either binding.
        bytes[3] memory attempts = [
            abi.encodeWithSignature("setBeneficiary(address)", outsider),
            abi.encodeWithSignature("setSplitter(address)", outsider),
            abi.encodeWithSignature(
                "pay(address,uint256,bytes32,address)", address(usdc), uint256(1), bytes32(0), outsider
            )
        ];
        for (uint256 i; i < attempts.length; ++i) {
            vm.prank(editor);
            assertFalse(_callSucceeds(address(receiver), attempts[i]), "no rebinding surface exists");
        }

        _pay(receiver, usdc, 1_000_000);
        assertEq(receiver.beneficiary(), referrer, "beneficiary unchanged by a payment");
        assertEq(receiver.splitter(), address(splitter), "splitter unchanged by a payment");
        assertEq(usdc.balanceOf(referrer), 10_000, "and the referral still went only there");
    }

    // ------------------------------------------------------------------ RCV-014

    /// @notice RCV-014: the referral is the exact floored share, paid only to the beneficiary.
    function test_RCV_014_ReferralPaymentIsExactlyFlooredToTheImmutableBeneficiary() public {
        PaymentReceiverV1 receiver = _newReceiver(address(splitter), referrer, 250, editor, false);

        uint256[5] memory grossInputs = [uint256(1), 39, 40, 10_000, 1_234_567];
        uint256 expected;
        for (uint256 i; i < grossInputs.length; ++i) {
            uint256 gross = grossInputs[i];
            uint256 referral = (gross * 250) / 10_000;
            expected += referral;

            _pay(receiver, usdc, gross);

            assertEq(usdc.balanceOf(referrer), expected, "exact floored referral, to the unit");
            assertEq(usdc.balanceOf(address(receiver)), 0, "the receiver retains nothing");
        }

        // Nobody but the beneficiary is ever paid a referral.
        assertEq(usdc.balanceOf(editor), 0, "the note editor is not a referral recipient");
        assertEq(usdc.balanceOf(payer), 0, "the payer is not a referral recipient");
        assertEq(usdc.balanceOf(outsider), 0, "no third party is");
    }

    // ------------------------------------------------------------------ RCV-015

    /// @notice RCV-015: reentrancy from pay, sweep, or recovery changes nothing and moves nothing twice.
    function test_RCV_015_PaySweepAndRecoveryReentrancyCannotChangeAccounting() public {
        PaymentReceiverV1 receiver = _newReceiver(address(splitter), referrer, 100, editor, false);

        // The paid token re-enters `pay` while its own transfer is in flight.
        usdc.setReentry(
            address(receiver), abi.encodeCall(PaymentReceiverV1.pay, (address(usdc), 1_000, bytes32("reenter")))
        );
        _pay(receiver, usdc, 1_000_000);

        assertGt(usdc.reentryAttempts(), 0, "the token did try to re-enter");
        assertFalse(usdc.lastReentrySucceeded(), "the re-entrant payment was rejected");
        assertEq(usdc.balanceOf(referrer), 10_000, "the referral was paid exactly once");
        assertEq(usdc.balanceOf(treasury), 970_200, "the net was recognized exactly once");
        assertEq(usdc.balanceOf(address(receiver)), 0, "nothing was retained");
        usdc.setReentry(address(0), "");

        // A recovery token re-enters `sweep` from inside its own recovery transfer.
        MockERC20 hostile = new MockERC20("Hostile", "HOS", 18);
        hostile.mint(address(receiver), 100e18);
        usdc.mint(address(receiver), 500_000);
        hostile.setReentry(address(receiver), abi.encodeCall(PaymentReceiverV1.sweep, (address(usdc))));
        vm.prank(outsider);
        receiver.recoverUnsupportedToken(address(hostile));

        assertFalse(hostile.lastReentrySucceeded(), "the re-entrant sweep was rejected");
        assertEq(usdc.balanceOf(address(receiver)), 500_000, "the bare balance was not routed by the attacker");
        assertEq(hostile.balanceOf(treasury), 100e18, "the honest recovery still completed");

        // A hostile splitter attacking mid-route: the whole route rolls back and no value moves.
        HostileSplitter hostileSplitter =
            new HostileSplitter(treasury, address(usdc), address(regent), address(subject));
        PaymentReceiverV1 exposed = _newReceiver(address(hostileSplitter), referrer, 100, editor, false);
        hostileSplitter.setReentry(address(exposed), abi.encodeCall(PaymentReceiverV1.sweep, (address(usdc))));

        usdc.mint(payer, 1_000_000);
        uint256 payerBefore = usdc.balanceOf(payer);
        uint256 referrerBefore = usdc.balanceOf(referrer);
        vm.startPrank(payer);
        usdc.approve(address(exposed), 1_000_000);
        exposed.pay(address(usdc), 1_000_000, bytes32("attacked"));
        vm.stopPrank();

        assertFalse(hostileSplitter.lastReentrySucceeded(), "the re-entrant sweep was rejected");
        assertEq(usdc.balanceOf(referrer) - referrerBefore, 10_000, "exactly one referral");
        assertEq(payerBefore - usdc.balanceOf(payer), 1_000_000, "exactly one gross was taken");
        assertEq(usdc.balanceOf(address(exposed)), 0, "the receiver retained nothing");
        assertEq(usdc.allowance(address(exposed), address(hostileSplitter)), 0, "no allowance survived");

        // A splitter that consumes less than the exact net fails the route closed.
        hostileSplitter.setReentry(address(0), "");
        hostileSplitter.setConsumesPartially(true);
        usdc.mint(payer, 1_000_000);
        vm.startPrank(payer);
        usdc.approve(address(exposed), 1_000_000);
        vm.expectRevert(abi.encodeWithSelector(PaymentReceiverV1.InexactTransfer.selector, 990_000, 495_000));
        exposed.pay(address(usdc), 1_000_000, bytes32("partial"));
        vm.stopPrank();
        assertEq(usdc.balanceOf(address(exposed)), 0, "the failed route committed nothing");
    }

    // ------------------------------------------------------------------ RCV-016

    /// @notice RCV-016: a receiver's note editor is fixed at initialization and nobody else edits.
    function test_RCV_016_NoteEditorIsFixedAtInitialization() public {
        PaymentReceiverV1 receiver = _newReceiver(address(splitter), referrer, 100, editor, false);
        assertEq(receiver.noteEditor(), editor, "the supplied editor is fixed at initialization");

        vm.prank(editor);
        receiver.setReceiverNote(bytes32("desk-1"));
        assertEq(receiver.receiverNote(), bytes32("desk-1"), "the fixed editor edits");

        // Every other caller is rejected, including the beneficiary and the treasury.
        address[4] memory rejected = [address(this), referrer, treasury, outsider];
        for (uint256 i; i < rejected.length; ++i) {
            vm.prank(rejected[i]);
            vm.expectRevert(abi.encodeWithSelector(PaymentReceiverV1.NotNoteEditor.selector, rejected[i]));
            receiver.setReceiverNote(bytes32("hijacked"));
        }
        assertEq(receiver.receiverNote(), bytes32("desk-1"), "the note is unchanged");

        // The editor binding itself has no setter and cannot be re-initialized.
        vm.prank(editor);
        assertFalse(
            _callSucceeds(address(receiver), abi.encodeWithSignature("setNoteEditor(address)", outsider)),
            "no editor setter exists"
        );
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        receiver.initialize(address(splitter), referrer, 100, outsider, false);
        assertEq(receiver.noteEditor(), editor, "the editor never moves");

        // The canonical receiver's editor is the treasury, fixed the same way.
        assertEq(canonical.noteEditor(), treasury, "canonical editor is the treasury");
        vm.prank(editor);
        vm.expectRevert(abi.encodeWithSelector(PaymentReceiverV1.NotNoteEditor.selector, editor));
        canonical.setReceiverNote(bytes32("hijacked"));
    }

    // ------------------------------------------------------------------ helpers

    function _pay(PaymentReceiverV1 receiver, MockERC20 token, uint256 amount) private {
        token.mint(payer, amount);
        vm.startPrank(payer);
        token.approve(address(receiver), amount);
        receiver.pay(address(token), amount, bytes32("pay"));
        vm.stopPrank();
    }

    function _callSucceeds(address target, bytes memory data) private returns (bool ok) {
        (ok,) = target.call(data);
    }
}
