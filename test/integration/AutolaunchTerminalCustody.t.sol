// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {BaseBindings} from "../../src/bindings/BaseBindings.sol";
import {ConditionalVestingEscrowV1} from "../../src/escrow/ConditionalVestingEscrowV1.sol";
import {PaymentReceiverV1} from "../../src/revenue/PaymentReceiverV1.sol";
import {RegentsAutolaunchFactoryV1} from "../../src/factory/RegentsAutolaunchFactoryV1.sol";
import {SubjectSplitterV1} from "../../src/revenue/SubjectSplitterV1.sol";
import {RegentLBPStrategy} from "../../src/strategy/RegentLBPStrategy.sol";
import {UERC20} from "uerc20-factory/tokens/UERC20.sol";
import {IContinuousClearingAuction} from "continuous-clearing-auction/interfaces/IContinuousClearingAuction.sol";
import {AutolaunchFixture} from "./AutolaunchFixture.sol";

/// @notice A recovery admin that carries code when it is admitted and can destroy itself.
/// @dev Under EIP-6780 a `SELFDESTRUCT` erases the account only when that account was created in
///      the same transaction, which is exactly the reachable shape this regression needs: a
///      launcher deploys its own admin, launches with it, and destroys it, all in one transaction.
///      Nothing about it is privileged — the production admission checks only that the address
///      carries code, and the recovery entry points compare `msg.sender` against the bound address.
contract SelfDestructingRecoveryAdmin {
    function role() external pure returns (bytes32) {
        return "recovery-admin";
    }

    /// @notice Erase this account. Reachable only in the transaction that created it.
    function destroy() external {
        selfdestruct(payable(msg.sender));
    }
}

/// @notice `MIG-020`: losing the immutable recovery admin's code after launch never blocks the only
///         migration path a launched auction has.
/// @dev The state is produced the way production produces it, and no cheatcode manufactures it:
///      `setUp` — the earlier Foundry transaction — deploys `SelfDestructingRecoveryAdmin`, runs a
///      complete `launch` through the real factory with that address as the launch's recovery
///      admin, and then calls `destroy()` on it. Because the admin was created in that same
///      transaction, EIP-6780 erases the account, so by the time the test transaction below runs
///      the immutable admin address carries no code at all. No `vm.etch`, `vm.store`, or
///      `vm.mockCall` appears anywhere in this file.
///
///      `FAC-016` continues to prove the other half: a launch whose recovery admin carries no code
///      at admission time is refused outright by `RegentLBPStrategy.initializeDistribution`, which
///      is the one and only place that test exists.
contract AutolaunchTerminalCustodyTest is AutolaunchFixture {
    SelfDestructingRecoveryAdmin internal destroyedAdmin;

    uint256 internal launchId;
    UERC20 internal subject;
    ConditionalVestingEscrowV1 internal escrow;
    IContinuousClearingAuction internal auction;

    /// @dev One transaction: deploy the admin, launch with it, destroy it.
    function setUp() public {
        _deployAutolaunch();

        destroyedAdmin = new SelfDestructingRecoveryAdmin();
        require(address(destroyedAdmin).code.length != 0, "the admin was not deployed with code");

        RegentsAutolaunchFactoryV1.LaunchParams memory params = _params();
        params.recoveryAdmin = address(destroyedAdmin);
        Launched memory launched = _launchSorted(true, params);

        launchId = launched.launchId;
        subject = launched.subject;
        escrow = launched.escrow;
        auction = launched.auction;

        destroyedAdmin.destroy();
    }

    /// @notice `MIG-020`: a graduated launch whose recovery admin was destroyed in the launch
    ///         transaction still migrates, and every graduation artifact is produced and recorded.
    function test_MIG_020_GraduationSurvivesRecoveryAdminDestroyedAtLaunch() public {
        address admin = address(destroyedAdmin);

        // The premise, proved rather than assumed: the immutable admin address is code-less now.
        assertEq(admin.code.length, 0, "the recovery admin still carries code, so nothing is being proved");
        assertEq(
            factory.launches(launchId).recoveryAdmin,
            admin,
            "the launch did not record the admin it was actually launched with"
        );

        _bidToGraduation(_restore(), 2_000e18);
        strategy.migrate(address(auction));

        RegentLBPStrategy.Distribution memory d = strategy.distribution(address(auction));

        // Graduation.
        assertEq(
            uint8(d.lifecycle),
            uint8(RegentLBPStrategy.Lifecycle.Graduated),
            "a code-less recovery admin blocked the only migration path"
        );
        assertGt(d.finalSqrtPriceX96, 0, "graduation recorded no final price");
        assertGt(d.lpTokenId, 0, "graduation minted no full-range position");

        // Splitter initialization, bound to the same immutable admin the launch recorded.
        SubjectSplitterV1 splitter = SubjectSplitterV1(d.splitter);
        assertGt(d.splitter.code.length, 0, "graduation deployed no splitter");
        assertEq(splitter.recoveryAdmin(), admin, "the splitter bound another recovery admin");
        assertEq(splitter.subject(), address(subject), "the splitter bound another SUBJECT");
        assertEq(splitter.treasury(), treasury, "the splitter bound another treasury");
        assertEq(splitter.regentSafe(), BaseBindings.GOVERNANCE_AND_REGENT_SAFE, "the splitter bound another Safe");

        // The canonical zero-referral receiver.
        PaymentReceiverV1 canonical = PaymentReceiverV1(payable(d.receiver));
        assertGt(d.receiver.code.length, 0, "graduation deployed no canonical receiver");
        assertEq(canonical.referralBps(), 0, "the canonical receiver charges a referral");
        assertEq(canonical.beneficiary(), treasury, "the canonical beneficiary is not the treasury");
        assertEq(canonical.splitter(), d.splitter, "the canonical receiver bound another splitter");

        // Vesting.
        assertEq(
            uint8(escrow.lifecycle()),
            uint8(ConditionalVestingEscrowV1.Lifecycle.Graduated),
            "the escrow did not reach its graduated state"
        );
        assertGt(escrow.vestingStart(), 0, "graduation never activated vesting");
        assertTrue(escrow.graduatedSweepDone(), "the graduated unsold sweep did not run");

        // The immutable record, and the factory's own copy of it.
        assertEq(factory.launches(launchId).recoveryAdmin, admin, "the factory record lost the recovery admin");
        assertEq(d.recoveryAdmin, admin, "the strategy record lost the recovery admin");

        // The disclosed consequence, stated as a fact rather than left implicit: recovery is now
        // permanently uncallable on this launch's splitter and on its canonical receiver, because
        // no account can ever again present `msg.sender == admin`. Everything else still works,
        // which the rest of this assertion set has already proved.
        assertEq(splitter.recoveryAdmin().code.length, 0, "the splitter's admin regained code");
        assertEq(canonical.recoveryAdmin().code.length, 0, "the receiver's admin regained code");
    }

    /// @dev Rebuild the fixture's launch view from the fields `setUp` recorded.
    function _restore() private view returns (Launched memory) {
        return Launched({launchId: launchId, subject: subject, escrow: escrow, auction: auction});
    }
}
