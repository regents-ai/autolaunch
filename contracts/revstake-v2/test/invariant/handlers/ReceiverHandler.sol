// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {PaymentReceiverV1} from "../../../src/revenue/PaymentReceiverV1.sol";
import {CommonBase} from "forge-std/Base.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";

/// @notice Drives three real receivers — zero referral, one basis point, and the inclusive 2.5%
///         maximum — through both routed paths and through bare transfers.
/// @dev The model records only the specified rule: floor the referral out of the gross, and the
///      remainder is the net. It never reads those numbers back out of the receiver.
contract ReceiverHandler is CommonBase, StdUtils {
    uint256 internal constant BPS_DENOMINATOR = 10_000;
    uint256 internal constant MAX_PAYMENT = 1_000e18;

    PaymentReceiverV1[3] public receivers;
    uint16[3] public referralBps;
    address[3] public beneficiaries;

    MockERC20 public immutable usdc;
    MockERC20 public immutable regent;
    MockERC20 public immutable subject;
    address public immutable payer;

    /// @notice Everything ever handed to any receiver, per token, by whichever route.
    mapping(address token => uint256 amount) public handedIn;
    /// @notice The referral this model says was owed, per receiver index and token.
    mapping(uint256 receiverIndex => mapping(address token => uint256 amount)) public referralOwed;
    /// @notice Tokens transferred bare and not yet swept, per token.
    mapping(address token => uint256 amount) public unswept;

    uint256 public calls;

    constructor(
        PaymentReceiverV1[3] memory receivers_,
        uint16[3] memory referralBps_,
        address[3] memory beneficiaries_,
        MockERC20 usdc_,
        MockERC20 regent_,
        MockERC20 subject_,
        address payer_
    ) {
        receivers = receivers_;
        referralBps = referralBps_;
        beneficiaries = beneficiaries_;
        usdc = usdc_;
        regent = regent_;
        subject = subject_;
        payer = payer_;
    }

    // -------------------------------------------------------------------------
    // actions
    // -------------------------------------------------------------------------

    function pay(uint256 receiverSeed, uint256 tokenSeed, uint256 amount) external {
        calls += 1;
        uint256 index = bound(receiverSeed, 0, 2);
        MockERC20 token = _token(tokenSeed);

        uint256 available = token.balanceOf(payer);
        if (available == 0) return;
        amount = bound(amount, 1, available < MAX_PAYMENT ? available : MAX_PAYMENT);

        vm.startPrank(payer);
        token.approve(address(receivers[index]), amount);
        receivers[index].pay(address(token), amount, bytes32(calls));
        vm.stopPrank();

        _record(index, address(token), amount);
    }

    /// @dev A bare transfer is not a payment until somebody sweeps it, and only the whole balance
    ///      is ever swept.
    function giftBare(uint256 receiverSeed, uint256 tokenSeed, uint256 amount) external {
        calls += 1;
        uint256 index = bound(receiverSeed, 0, 2);
        MockERC20 token = _token(tokenSeed);

        uint256 available = token.balanceOf(payer);
        if (available == 0) return;
        amount = bound(amount, 1, available < MAX_PAYMENT ? available : MAX_PAYMENT);

        vm.prank(payer);
        token.transfer(address(receivers[index]), amount);
        unswept[address(token)] += amount;
    }

    function sweep(uint256 receiverSeed, uint256 tokenSeed) external {
        calls += 1;
        uint256 index = bound(receiverSeed, 0, 2);
        MockERC20 token = _token(tokenSeed);

        uint256 sitting = token.balanceOf(address(receivers[index]));
        if (sitting == 0) return;

        vm.prank(payer);
        receivers[index].sweep(address(token));

        unswept[address(token)] -= sitting;
        _record(index, address(token), sitting);
    }

    function editNote(uint256 receiverSeed, bytes32 note) external {
        calls += 1;
        uint256 index = bound(receiverSeed, 0, 2);

        vm.prank(receivers[index].noteEditor());
        receivers[index].setReceiverNote(note);
    }

    // -------------------------------------------------------------------------

    function _record(uint256 index, address token, uint256 gross) private {
        handedIn[token] += gross;
        referralOwed[index][token] += (gross * referralBps[index]) / BPS_DENOMINATOR;
    }

    function _token(uint256 seed) private view returns (MockERC20) {
        uint256 index = bound(seed, 0, 2);
        if (index == 0) return usdc;
        if (index == 1) return regent;
        return subject;
    }

    function receiverAt(uint256 index) external view returns (address) {
        return address(receivers[index]);
    }

    function beneficiaryAt(uint256 index) external view returns (address) {
        return beneficiaries[index];
    }
}
