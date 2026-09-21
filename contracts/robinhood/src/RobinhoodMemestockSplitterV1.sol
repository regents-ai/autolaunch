// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {IERC20Views} from "autolaunch-stocks/interfaces/IERC20Views.sol";
import {MemestockSplitterCore} from "autolaunch-stocks/MemestockSplitterCore.sol";
import {IRobinhoodProtocolRevenueInboxV1} from "./interfaces/IRobinhoodProtocolRevenueInboxV1.sol";

/// @title RobinhoodMemestockSplitterV1
/// @notice The implementation-locked clone target behind every Robinhood stock-pair launch. MEMESTOCK
///         holders stake here and divide, pro rata, everything recognized in USDG, MEMESTOCK and the
///         paired STOCK after the 2% protocol share.
/// @dev The Base `MemestockSplitterV1` with the Robinhood chain's destinations: the USDG share is
///      deposited straight into the protocol revenue inbox, MEMESTOCK and STOCK go to the Robinhood
///      Safe. USDG, the inbox and the Safe are fixed for every clone by the implementation the
///      launchpad deployed; only the launch's two tokens are bound per clone.
contract RobinhoodMemestockSplitterV1 is MemestockSplitterCore {
    using SafeTransferLib for address;

    /// @notice The `sourceTag` every USDG protocol share carries into the inbox.
    // forge-lint: disable-next-line(unsafe-typecast)
    bytes32 public constant PROTOCOL_SOURCE_TAG = bytes32("robinhood-splitter");

    address public immutable usdg;
    address public immutable inbox;
    address public immutable adminSafe;

    event SplitterInitialized(address indexed memestock, address indexed stock);

    error InboxDepositMismatch(uint256 expected, uint256 reported);
    error InboxAllowanceNotCleared(uint256 found);

    constructor(address usdg_, address inbox_, address adminSafe_) {
        if (usdg_ == address(0) || inbox_ == address(0) || adminSafe_ == address(0)) revert ZeroAddress();
        usdg = usdg_;
        inbox = inbox_;
        adminSafe = adminSafe_;
    }

    /// @notice Fix this clone's MEMESTOCK and STOCK. Runs exactly once.
    function initialize(address memestock_, address stock_) external initializer {
        _bindTokens(usdg, memestock_, stock_);
        emit SplitterInitialized(memestock_, stock_);
    }

    /// @inheritdoc MemestockSplitterCore
    function protocolTreasury() public view override returns (address) {
        return adminSafe;
    }

    function _routeProtocolShare(address token, uint256 amount, bytes32 revenueRef) internal override {
        if (token == usdg) {
            _depositToInbox(amount, revenueRef);
        } else {
            _pushExact(token, adminSafe, amount);
        }
    }

    /// @dev Exact approval, the inbox deposit, three independent behavior checks, and allowance
    ///      cleanup. A reverting inbox fails this call and rolls the whole recognition back.
    function _depositToInbox(uint256 amount, bytes32 revenueRef) private {
        address token = usdg;
        address destination = inbox;

        uint256 splitterBefore = token.balanceOf(address(this));
        uint256 inboxBefore = token.balanceOf(destination);

        token.safeApprove(destination, amount);
        uint256 reported =
            IRobinhoodProtocolRevenueInboxV1(destination).deposit(amount, PROTOCOL_SOURCE_TAG, revenueRef);
        if (reported != amount) revert InboxDepositMismatch(amount, reported);

        uint256 sent = splitterBefore - token.balanceOf(address(this));
        if (sent != amount) revert InexactTransfer(amount, sent);

        uint256 landed = token.balanceOf(destination) - inboxBefore;
        if (landed != amount) revert InexactTransfer(amount, landed);

        token.safeApprove(destination, 0);
        uint256 residual = IERC20Views(token).allowance(address(this), destination);
        if (residual != 0) revert InboxAllowanceNotCleared(residual);
    }
}
