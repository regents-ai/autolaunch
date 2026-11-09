// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {IERC20Views} from "./interfaces/IERC20Views.sol";
import {IRegentRevenueStakingMinimal} from "./interfaces/IRegentRevenueStakingMinimal.sol";
import {MemestockSplitterCore} from "./MemestockSplitterCore.sol";
import {StocksBindings} from "./StocksBindings.sol";

/// @title MemestockSplitterV1
/// @notice The implementation-locked clone target behind every Base Stocks launch. MEMESTOCK holders
///         stake here and divide, pro rata, everything recognized in USDC, MEMESTOCK and the paired
///         STOCK after the 2% protocol share.
/// @dev The protocol share follows the Agent splitter's routing: USDC is deposited straight into the
///      live REGENT staking contract, MEMESTOCK and STOCK go to the Regent Safe. USDC, live staking
///      and the Safe are the frozen `StocksBindings`; only the launch's two tokens are bound here.
contract MemestockSplitterV1 is MemestockSplitterCore {
    using SafeTransferLib for address;

    event SplitterInitialized(address indexed memestock, address indexed stock);

    error StakingDepositMismatch(uint256 expected, uint256 reported);
    error StakingAllowanceNotCleared(uint256 found);

    /// @notice Fix this clone's MEMESTOCK and STOCK. Runs exactly once.
    function initialize(address memestock_, address stock_) external initializer {
        _bindTokens(StocksBindings.USDC, memestock_, stock_);
        emit SplitterInitialized(memestock_, stock_);
    }

    /// @inheritdoc MemestockSplitterCore
    function protocolTreasury() public pure override returns (address) {
        return StocksBindings.GOVERNANCE_AND_REGENT_SAFE;
    }

    function _routeProtocolShare(address token, uint256 amount, bytes32 revenueRef) internal override {
        if (token == StocksBindings.USDC) {
            _depositToLiveStaking(amount, revenueRef);
        } else {
            _pushExact(token, StocksBindings.GOVERNANCE_AND_REGENT_SAFE, amount);
        }
    }

    /// @dev Exact approval, the pinned live-staking deposit, three independent behavior checks, and
    ///      allowance cleanup. A paused or reverting live staking contract fails this call and rolls
    ///      the whole recognition back.
    function _depositToLiveStaking(uint256 amount, bytes32 revenueRef) private {
        address token = StocksBindings.USDC;
        address staking = StocksBindings.LIVE_STAKING;

        uint256 splitterBefore = token.balanceOf(address(this));
        uint256 stakingBefore = token.balanceOf(staking);

        token.safeApprove(staking, amount);
        uint256 reported =
            IRegentRevenueStakingMinimal(staking).depositUSDC(amount, bytes32(uint256(uint160(memestock))), revenueRef);
        if (reported != amount) revert StakingDepositMismatch(amount, reported);

        uint256 sent = splitterBefore - token.balanceOf(address(this));
        if (sent != amount) revert InexactTransfer(amount, sent);

        uint256 landed = token.balanceOf(staking) - stakingBefore;
        if (landed != amount) revert InexactTransfer(amount, landed);

        token.safeApprove(staking, 0);
        uint256 residual = IERC20Views(token).allowance(address(this), staking);
        if (residual != 0) revert StakingAllowanceNotCleared(residual);
    }
}
