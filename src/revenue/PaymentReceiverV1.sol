// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {SubjectSplitterV1} from "./SubjectSplitterV1.sol";
import {Initializable} from "solady/utils/Initializable.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/// @title PaymentReceiverV1
/// @notice The fixed, implementation-locked clone target that accepts a payment in one of its
///         splitter's three assets, pays the immutable referral first, and hands the remainder to
///         the splitter in the same transaction.
/// @dev The caller supplies only the splitter, the beneficiary, the referral share, the note
///      editor, and whether this is the launch's canonical receiver. Treasury, recovery admin, and
///      the three recognized tokens are read from the splitter's own getters, so a receiver can
///      never disagree with its splitter about them. Nothing here is settable afterwards: there is
///      no upgrade path, no reinitializer, no role change, no referral change, no destination
///      change, no arbitrary recipient, no pause, and no receiver disablement.
///
///      Named invariants: `C1-I5` receiver conservation, `C1-I6` fixed authority, `C1-I7` atomic
///      failure.
contract PaymentReceiverV1 is Initializable, ReentrancyGuard {
    using SafeTransferLib for address;

    /// @notice Basis-point denominator for the referral share.
    uint256 public constant BPS_DENOMINATOR = 10_000;

    /// @notice The inclusive maximum referral share, 2.5%.
    uint16 public constant MAX_REFERRAL_BPS = 250;

    /// @notice The splitter every routed net payment is recognized by.
    address public splitter;

    /// @notice The only account the referral share is ever paid to.
    address public beneficiary;

    /// @notice The immutable referral share of every gross payment, in basis points.
    uint16 public referralBps;

    /// @notice The only account allowed to edit this receiver's note.
    address public noteEditor;

    /// @notice The recovery destination, read from the splitter at initialization.
    address public treasury;

    /// @notice The only account allowed to recover, read from the splitter at initialization.
    address public recoveryAdmin;

    /// @notice The USDC binding, read from the splitter at initialization.
    address public usdc;

    /// @notice The REGENT binding, read from the splitter at initialization.
    address public regent;

    /// @notice The launch's SUBJECT binding, read from the splitter at initialization.
    address public subject;

    /// @notice Free-form label carried in every route event. Defaults to this receiver's address.
    bytes32 public receiverNote;

    event ReceiverInitialized(
        address indexed splitter, address indexed beneficiary, uint16 referralBps, address indexed noteEditor
    );
    event ReceiverNoteUpdated(bytes32 previousNote, bytes32 newNote);
    event PaymentRouted(
        bytes32 indexed paymentRef,
        bytes32 indexed receiverNote,
        address indexed token,
        uint256 gross,
        uint256 referral,
        uint256 net
    );
    event UnsupportedTokenRecovered(address indexed token, address indexed treasury, uint256 amount);
    event ForcedEthRecovered(address indexed treasury, uint256 amount);

    error ZeroAddress();
    error SelfAddress();
    error ReferralTooHigh(uint16 found);
    error CanonicalRequiresZeroReferral(uint16 found);
    error CanonicalRequiresTreasuryBeneficiary(address found);
    error CanonicalRequiresTreasuryNoteEditor(address found);
    error ZeroAmount();
    error UnsupportedToken(address token);
    error ProtectedToken(address token);
    error NotNoteEditor(address caller);
    error NotRecoveryAdmin(address caller);
    error InexactTransfer(uint256 expected, uint256 found);

    /// @dev The implementation is permanently uninitializable, so only clones accept payments.
    constructor() {
        _disableInitializers();
    }

    modifier onlyRecoveryAdmin() {
        if (msg.sender != recoveryAdmin) revert NotRecoveryAdmin(msg.sender);
        _;
    }

    /// @notice Fix this clone's bindings. Runs exactly once. `C1-I6`.
    /// @param canonical True for the launch's canonical receiver, which must carry zero referral
    ///        and name the treasury as both beneficiary and note editor. The flag validates
    ///        initialization only; canonical provenance is recorded by the factory.
    function initialize(
        address splitter_,
        address beneficiary_,
        uint16 referralBps_,
        address noteEditor_,
        bool canonical
    ) external initializer {
        _requireBindable(splitter_);
        _requireBindable(beneficiary_);
        _requireBindable(noteEditor_);
        if (referralBps_ > MAX_REFERRAL_BPS) revert ReferralTooHigh(referralBps_);

        address treasury_ = SubjectSplitterV1(splitter_).treasury();
        if (canonical) {
            if (referralBps_ != 0) revert CanonicalRequiresZeroReferral(referralBps_);
            if (beneficiary_ != treasury_) revert CanonicalRequiresTreasuryBeneficiary(beneficiary_);
            if (noteEditor_ != treasury_) revert CanonicalRequiresTreasuryNoteEditor(noteEditor_);
        }

        // slither-disable-next-line missing-zero-check
        splitter = splitter_;
        beneficiary = beneficiary_;
        referralBps = referralBps_;
        noteEditor = noteEditor_;
        treasury = treasury_;
        recoveryAdmin = SubjectSplitterV1(splitter_).recoveryAdmin();
        usdc = SubjectSplitterV1(splitter_).usdc();
        regent = SubjectSplitterV1(splitter_).regent();
        subject = SubjectSplitterV1(splitter_).subject();
        receiverNote = bytes32(uint256(uint160(address(this))));

        emit ReceiverInitialized(splitter_, beneficiary_, referralBps_, noteEditor_);
    }

    /// @notice Replace this receiver's note. Fixed note editor only.
    function setReceiverNote(bytes32 note) external {
        if (msg.sender != noteEditor) revert NotNoteEditor(msg.sender);

        bytes32 previousNote = receiverNote;
        receiverNote = note;

        emit ReceiverNoteUpdated(previousNote, note);
    }

    /// @notice Pay exactly `amount` of `token` and route it in the same transaction.
    /// @dev Only the payer's own amount is processed, so an unrelated bare balance sitting here is
    ///      left untouched for a later explicit `sweep`.
    function pay(address token, uint256 amount, bytes32 paymentRef) external nonReentrant {
        _requireSupported(token);
        if (amount == 0) revert ZeroAmount();

        uint256 before = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = token.balanceOf(address(this)) - before;
        if (received != amount) revert InexactTransfer(amount, received);

        _route(token, amount, paymentRef);
    }

    /// @notice Route this receiver's entire bare balance of `token`.
    function sweep(address token, bytes32 paymentRef) external nonReentrant {
        _requireSupported(token);

        uint256 amount = token.balanceOf(address(this));
        if (amount == 0) revert ZeroAmount();

        _route(token, amount, paymentRef);
    }

    /// @notice Send an unsupported ERC20 to the fixed treasury. Recovery admin only.
    /// @dev One guarded transfer and nothing else, so a hostile token can fail only this call.
    function recoverUnsupportedToken(address token, uint256 amount) external nonReentrant onlyRecoveryAdmin {
        if (token == usdc || token == regent || token == subject) revert ProtectedToken(token);
        if (amount == 0) revert ZeroAmount();

        emit UnsupportedTokenRecovered(token, treasury, amount);
        token.safeTransfer(treasury, amount);
    }

    /// @notice Send forced ETH to the fixed treasury. Recovery admin only.
    /// @dev This contract has no receive or fallback function, so an ordinary ETH transfer reverts
    ///      and only EVM force-send behavior can ever leave ETH here.
    function recoverForcedETH(uint256 amount) external nonReentrant onlyRecoveryAdmin {
        if (amount == 0) revert ZeroAmount();

        emit ForcedEthRecovered(treasury, amount);
        treasury.safeTransferETH(amount);
    }

    // -------------------------------------------------------------------------
    // internals
    // -------------------------------------------------------------------------

    function _requireBindable(address value) private view {
        if (value == address(0)) revert ZeroAddress();
        if (value == address(this)) revert SelfAddress();
    }

    function _requireSupported(address token) private view {
        if (token != usdc && token != regent && token != subject) revert UnsupportedToken(token);
    }

    /// @dev The one route both `pay` and `sweep` use. Floors the referral, pays only the immutable
    ///      beneficiary, exact-approves the remainder to the splitter, proves the splitter consumed
    ///      exactly that remainder, and clears the allowance — all atomically. A zero referral makes
    ///      no transfer at all. `C1-I5`, `C1-I7`.
    function _route(address token, uint256 gross, bytes32 paymentRef) private {
        uint256 referral = (gross * referralBps) / BPS_DENOMINATOR;
        uint256 net = gross - referral;

        if (referral != 0) {
            uint256 beforeReferral = token.balanceOf(address(this));
            token.safeTransfer(beneficiary, referral);
            uint256 paid = beforeReferral - token.balanceOf(address(this));
            if (paid != referral) revert InexactTransfer(referral, paid);
        }

        address splitter_ = splitter;
        uint256 beforeNet = token.balanceOf(address(this));

        token.safeApprove(splitter_, net);
        SubjectSplitterV1(splitter_).depositRecognizedRevenue(token, net, paymentRef);

        uint256 consumed = beforeNet - token.balanceOf(address(this));
        if (consumed != net) revert InexactTransfer(net, consumed);
        token.safeApprove(splitter_, 0);

        emit PaymentRouted(paymentRef, receiverNote, token, gross, referral, net);
    }
}
