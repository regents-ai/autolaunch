// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {PaymentReceiverV1} from "../../src/revenue/PaymentReceiverV1.sol";
import {SubjectSplitterV1} from "../../src/revenue/SubjectSplitterV1.sol";
import {LibClone} from "solady/utils/LibClone.sol";
import {Test} from "forge-std/Test.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockLiveStaking} from "../mocks/MockLiveStaking.sol";
import {ReceiverHandler} from "./handlers/ReceiverHandler.sol";

/// @notice `INV-008`: receiver accounting conserves referral, skim, and net for every payment
///         sequence, across all three supported assets and the whole admitted referral range.
/// @dev Three receivers run side by side at the referral boundaries — zero, one basis point, and
///      the inclusive 2.5% maximum — so the flooring rule is exercised at both ends at once. The
///      model is the specified rule and nothing else: referral is floored out of gross, the rest is
///      net, and nothing may stay behind in the receiver except a bare transfer nobody has swept.
contract ReceiverInvariantsTest is Test {
    uint256 internal constant PAYER_FUNDING = 1_000_000_000e18;

    SubjectSplitterV1 internal splitter;
    MockERC20 internal usdc;
    MockERC20 internal regent;
    MockERC20 internal subject;
    MockLiveStaking internal liveStaking;
    ReceiverHandler internal handler;

    address internal regentSafe = makeAddr("regentSafe");
    address internal treasury = makeAddr("treasury");
    address internal payer = makeAddr("payer");

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        regent = new MockERC20("Regent", "REGENT", 18);
        subject = new MockERC20("Subject", "SUBJ", 18);
        liveStaking = new MockLiveStaking(address(usdc));

        splitter = SubjectSplitterV1(LibClone.clone(address(new SubjectSplitterV1())));
        splitter.initialize(
            address(usdc), address(regent), address(subject), address(liveStaking), regentSafe, treasury
        );

        PaymentReceiverV1 implementation = new PaymentReceiverV1();
        uint16[3] memory bps = [uint16(0), 1, 250];
        address[3] memory beneficiaries =
            [makeAddr("beneficiary-zero"), makeAddr("beneficiary-one"), makeAddr("beneficiary-max")];
        PaymentReceiverV1[3] memory receivers;
        for (uint256 i; i < receivers.length; ++i) {
            receivers[i] = PaymentReceiverV1(payable(LibClone.clone(address(implementation))));
            // This contract is the note editor; the handler edits notes by pranking whoever the
            // receiver itself names, so no cheatcode ever substitutes for the real authority.
            receivers[i].initialize(address(splitter), beneficiaries[i], bps[i], address(this), false);
        }

        usdc.mint(payer, PAYER_FUNDING);
        regent.mint(payer, PAYER_FUNDING);
        subject.mint(payer, PAYER_FUNDING);

        handler = new ReceiverHandler(receivers, bps, beneficiaries, usdc, regent, subject, payer);
        targetContract(address(handler));
    }

    /// @notice `INV-008`: every unit handed to a receiver ends up in exactly one of the specified
    ///         destinations, the referral is exactly the floored share of gross for that receiver,
    ///         and a receiver retains nothing but an unswept bare transfer.
    function invariant_INV_008_ReceiverAccountingIsConserved() public view {
        address[3] memory tokens = [address(usdc), address(regent), address(subject)];

        for (uint256 t; t < tokens.length; ++t) {
            address token = tokens[t];

            uint256 referralTotal;
            uint256 retained;
            for (uint256 i; i < 3; ++i) {
                assertEq(
                    MockERC20(token).balanceOf(handler.beneficiaryAt(i)),
                    handler.referralOwed(i, token),
                    "a beneficiary holds something other than its exact floored referral"
                );
                assertEq(
                    MockERC20(token).allowance(handler.receiverAt(i), address(splitter)),
                    0,
                    "a receiver left a standing splitter allowance behind"
                );
                referralTotal += handler.referralOwed(i, token);
                retained += MockERC20(token).balanceOf(handler.receiverAt(i));
            }

            // A receiver holds exactly the bare transfers nobody has swept yet, never a routed unit.
            assertEq(retained, handler.unswept(token), "a receiver retained a routed payment");

            // Conservation: gross handed in equals referral plus everything the splitter routed on.
            uint256 skimDestination = token == address(usdc)
                ? MockERC20(token).balanceOf(address(liveStaking))
                : MockERC20(token).balanceOf(regentSafe);
            assertEq(
                handler.handedIn(token) + handler.unswept(token),
                referralTotal + skimDestination + MockERC20(token).balanceOf(treasury) + retained
                    + MockERC20(token).balanceOf(address(splitter)),
                "receiver inflow is not referral plus skim plus net"
            );
        }
    }
}
