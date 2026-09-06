// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface ITransferFromToken {
    function allowance(address owner, address spender) external view returns (uint256);

    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

interface IReentrantInbox {
    function sweep(uint256 maxFee) external returns (uint256);
}

contract MockTokenMessengerV2 {
    enum Mode {
        NORMAL,
        REVERT_BEFORE_CONSUMPTION,
        CONSUME_THEN_REVERT,
        UNDER_CONSUME,
        REENTER_CAUGHT,
        REENTER_UNCAUGHT
    }

    Mode public mode;
    bool public reentryRejected;
    uint256 public observedAllowance;
    uint256 public amount;
    uint32 public destinationDomain;
    bytes32 public mintRecipient;
    address public burnToken;
    bytes32 public destinationCaller;
    uint256 public maxFee;
    uint32 public minFinalityThreshold;

    function setMode(Mode mode_) external {
        mode = mode_;
        reentryRejected = false;
    }

    function depositForBurn(
        uint256 amount_,
        uint32 destinationDomain_,
        bytes32 mintRecipient_,
        address burnToken_,
        bytes32 destinationCaller_,
        uint256 maxFee_,
        uint32 minFinalityThreshold_
    ) external {
        if (mode == Mode.REVERT_BEFORE_CONSUMPTION) revert("MESSENGER_BEFORE");

        amount = amount_;
        destinationDomain = destinationDomain_;
        mintRecipient = mintRecipient_;
        burnToken = burnToken_;
        destinationCaller = destinationCaller_;
        maxFee = maxFee_;
        minFinalityThreshold = minFinalityThreshold_;
        observedAllowance = ITransferFromToken(burnToken_).allowance(msg.sender, address(this));

        if (mode == Mode.REENTER_CAUGHT) {
            try IReentrantInbox(msg.sender).sweep(maxFee_) returns (uint256) {
                revert("REENTRY_SUCCEEDED");
            } catch {
                reentryRejected = true;
            }
        } else if (mode == Mode.REENTER_UNCAUGHT) {
            IReentrantInbox(msg.sender).sweep(maxFee_);
        }

        uint256 consumed = mode == Mode.UNDER_CONSUME ? amount_ - 1 : amount_;
        require(ITransferFromToken(burnToken_).transferFrom(msg.sender, address(this), consumed), "TRANSFER_FALSE");

        if (mode == Mode.CONSUME_THEN_REVERT) revert("MESSENGER_AFTER");
    }
}
