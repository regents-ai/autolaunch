// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {RegentsAutolaunchFactoryV1} from "../../src/factory/RegentsAutolaunchFactoryV1.sol";
import {PaymentReceiverV1} from "../../src/revenue/PaymentReceiverV1.sol";
import {RegentLBPStrategy} from "../../src/strategy/RegentLBPStrategy.sol";
import {AutolaunchFixture} from "../integration/AutolaunchFixture.sol";

/// @notice `C4-I5`: anyone may pay the gas to create a custom payment receiver for a graduated
///         launch, that receiver always binds to the launch's canonical splitter, and nothing about
///         it can displace or imitate the canonical receiver the strategy recorded.
contract AutolaunchFactoryReceiversTest is AutolaunchFixture {
    event PaymentReceiverCreated(
        uint256 indexed launchId,
        address indexed receiver,
        address indexed creator,
        address beneficiary,
        uint16 referralBps
    );

    function setUp() public {
        _deployAutolaunch();
    }

    /// @notice `FAC-024`: the entry point is permissionless but strictly scoped — only a recorded
    ///         launch that has actually graduated has the canonical splitter a receiver needs — and
    ///         everything it makes is a custom receiver.
    function test_FAC_024_CreatePaymentReceiverIsPermissionlessAndCustomOnly() public {
        vm.expectRevert(abi.encodeWithSelector(RegentsAutolaunchFactoryV1.UnknownLaunch.selector, uint256(0)));
        factory.createPaymentReceiver(0, outsider, 0);
        vm.expectRevert(abi.encodeWithSelector(RegentsAutolaunchFactoryV1.UnknownLaunch.selector, uint256(99)));
        factory.createPaymentReceiver(99, outsider, 0);

        // A pending launch has no splitter yet.
        Launched memory pending = _launchAs(launcher, _params());
        vm.expectRevert(
            abi.encodeWithSelector(RegentsAutolaunchFactoryV1.LaunchNotGraduated.selector, pending.launchId)
        );
        factory.createPaymentReceiver(pending.launchId, outsider, 0);

        // A failed launch never gets one.
        Launched memory failed = _launchAs(launcher, _params());
        _rollToMigration(failed);
        strategy.migrate(address(failed.auction));
        assertEq(uint8(_distribution(failed).lifecycle), uint8(RegentLBPStrategy.Lifecycle.Failed), "not failed");
        vm.expectRevert(abi.encodeWithSelector(RegentsAutolaunchFactoryV1.LaunchNotGraduated.selector, failed.launchId));
        factory.createPaymentReceiver(failed.launchId, outsider, 0);

        // The pending launch, once graduated, does.
        _bidToGraduation(pending, 2_000e18);
        strategy.migrate(address(pending.auction));
        RegentLBPStrategy.Distribution memory d = _distribution(pending);
        address canonical = d.receiver;

        vm.prank(outsider);
        address custom = factory.createPaymentReceiver(pending.launchId, bidder, 100);

        assertTrue(custom != canonical, "the custom receiver displaced the canonical one");
        assertEq(
            PaymentReceiverV1(payable(custom)).splitter(), d.splitter, "the custom receiver bound another splitter"
        );
        assertEq(PaymentReceiverV1(payable(custom)).beneficiary(), bidder, "the supplied beneficiary was not fixed");
        assertEq(PaymentReceiverV1(payable(custom)).referralBps(), 100, "the supplied referral was not fixed");
        assertEq(PaymentReceiverV1(payable(custom)).noteEditor(), outsider, "the creator is not the note editor");
        assertEq(PaymentReceiverV1(payable(custom)).treasury(), treasury, "the receiver disagrees with its splitter");
        assertEq(_distribution(pending).receiver, canonical, "the strategy's canonical receiver moved");

        // A custom receiver may legitimately look exactly like a canonical one. Canonical identity
        // is only the address the strategy recorded, never a receiver's own state shape.
        vm.prank(bidder);
        address lookalike = factory.createPaymentReceiver(pending.launchId, treasury, 0);
        assertEq(PaymentReceiverV1(payable(lookalike)).referralBps(), 0, "lookalike referral");
        assertEq(PaymentReceiverV1(payable(lookalike)).beneficiary(), treasury, "lookalike beneficiary");
        assertTrue(lookalike != canonical, "a lookalike became the canonical receiver");
        assertEq(_distribution(pending).receiver, canonical, "the canonical receiver moved");

        // A factory pause gates new launches and nothing else.
        vm.prank(governance);
        factory.pauseLaunches();
        vm.prank(outsider);
        address whilePaused = factory.createPaymentReceiver(pending.launchId, bidder, 250);
        assertEq(PaymentReceiverV1(payable(whilePaused)).referralBps(), 250, "a paused factory refused a receiver");
        vm.prank(governance);
        factory.unpauseLaunches();

        // The referral boundary is the receiver's own, and a rejected creation leaves nothing.
        uint16[4] memory accepted = [uint16(0), 1, 249, 250];
        for (uint256 i; i < accepted.length; ++i) {
            address made = factory.createPaymentReceiver(pending.launchId, bidder, accepted[i]);
            assertEq(PaymentReceiverV1(payable(made)).referralBps(), accepted[i], "an admitted referral was refused");
        }

        uint64 nonceBefore = vm.getNonce(address(factory));
        address predicted = vm.computeCreateAddress(address(factory), nonceBefore);
        vm.expectRevert(abi.encodeWithSelector(PaymentReceiverV1.ReferralTooHigh.selector, uint16(251)));
        factory.createPaymentReceiver(pending.launchId, bidder, 251);
        vm.expectRevert(PaymentReceiverV1.ZeroAddress.selector);
        factory.createPaymentReceiver(pending.launchId, address(0), 0);
        assertEq(vm.getNonce(address(factory)), nonceBefore, "a rejected creation left a clone behind");
        assertEq(predicted.code.length, 0, "a rejected creation left code behind");

        // The factory keeps no receiver list; the event is the record.
        bytes memory runtime = address(factory).code;
        string[3] memory forbidden = ["receiversOf(uint256)", "receiverCount(uint256)", "receivers(uint256,uint256)"];
        for (uint256 i; i < forbidden.length; ++i) {
            assertFalse(
                _carriesSelector(runtime, bytes4(keccak256(bytes(forbidden[i])))),
                string.concat("the factory enumerates receivers: ", forbidden[i])
            );
        }
    }

    /// @notice `RCV-001`: creation costs nothing but gas, whoever pays it becomes that receiver's
    ///         note editor, and the receiver really does route payments through the launch splitter.
    function test_RCV_001_CustomReceiverCreationIsPermissionless() public {
        Launched memory launched = _defaultLaunch();
        _bidToGraduation(launched, 2_000e18);
        strategy.migrate(address(launched.auction));

        address[3] memory creators = [outsider, bidder, treasury];
        address[3] memory receivers;
        for (uint256 i; i < creators.length; ++i) {
            vm.expectEmit(true, false, true, false, address(factory));
            emit PaymentReceiverCreated(launched.launchId, address(0), creators[i], creators[i], 50);
            vm.prank(creators[i]);
            receivers[i] = factory.createPaymentReceiver(launched.launchId, creators[i], 50);

            PaymentReceiverV1 receiver = PaymentReceiverV1(payable(receivers[i]));
            assertEq(receiver.noteEditor(), creators[i], "the payer of the gas is not the note editor");
            assertEq(
                receiver.receiverNote(),
                bytes32(uint256(uint160(receivers[i]))),
                "the note does not default to the receiver address"
            );
        }

        // Each creator edits only their own note.
        for (uint256 i; i < creators.length; ++i) {
            PaymentReceiverV1 receiver = PaymentReceiverV1(payable(receivers[i]));
            vm.prank(creators[i]);
            receiver.setReceiverNote(bytes32(uint256(0xC0FFEE + i)));
            assertEq(receiver.receiverNote(), bytes32(uint256(0xC0FFEE + i)), "the creator could not edit its note");

            vm.expectRevert(abi.encodeWithSelector(PaymentReceiverV1.NotNoteEditor.selector, launcher));
            vm.prank(launcher);
            receiver.setReceiverNote(bytes32(0));
        }

        // And the receiver a stranger created routes real value the ordinary way: referral first,
        // then the launch's own splitter.
        PaymentReceiverV1 custom = PaymentReceiverV1(payable(receivers[0]));
        regent.mint(launcher, 10_000e18);
        vm.startPrank(launcher);
        regent.approve(address(custom), 10_000e18);
        custom.pay(address(regent), 10_000e18, bytes32("ref"));
        vm.stopPrank();

        assertEq(regent.balanceOf(outsider), 50e18, "the referral did not reach the beneficiary");
        assertEq(regent.balanceOf(address(custom)), 0, "the receiver retained value");
        assertEq(regent.allowance(address(custom), custom.splitter()), 0, "the receiver left an allowance behind");
    }
}
