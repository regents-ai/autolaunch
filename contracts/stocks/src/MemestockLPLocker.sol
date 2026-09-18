// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {ReentrancyGuardTransient} from "solady/utils/ReentrancyGuardTransient.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {IERC20Minimal} from "./interfaces/IERC20Minimal.sol";
import {IMemestockSplitterMinimal} from "./interfaces/IMemestockSplitterMinimal.sol";

/// @title MemestockLPLocker
/// @notice Permanently owns the launch-funded LP NFTs of one launchpad and deposits their fees in kind
///         into each launch's memestock splitter. Anyone may collect; no caller receives the proceeds.
/// @dev The Agent `RevstakeLPLocker` technique with the registrar and the PositionManager bound at
///      construction, so the Base and Robinhood launchpads share this one contract. The immutable
///      launchpad registers each position once, during graduation. There is no NFT transfer, approval,
///      permit-signature, principal withdrawal, upgrade, administrator, arbitrary call or recovery
///      path. The only PositionManager operation decreases liquidity by exactly zero. Only the balances
///      received by that collection are deposited, so one launch cannot appropriate another launch's
///      assets or unsolicited transfers. Tokens or NFTs sent here outside the launchpad's
///      mint/registration path are stranded by design; do not donate here.
contract MemestockLPLocker is ReentrancyGuardTransient {
    using SafeTransferLib for address;

    address public immutable launchpad;
    address public immutable positionManager;

    /// @notice Write-once destination for a registered position; zero means unregistered.
    mapping(uint256 tokenId => address splitter) public splitterOf;

    event PositionLocked(uint256 indexed tokenId, PoolId indexed poolId, address indexed splitter);
    event FeesDeposited(
        uint256 indexed tokenId,
        address indexed splitter,
        address currency0,
        address currency1,
        uint256 amount0,
        uint256 amount1
    );

    error ZeroAddress();
    error NotLaunchpad(address caller);
    error AlreadyRegistered(uint256 tokenId);
    error UnregisteredPosition(uint256 tokenId);
    error PositionNotOwned(uint256 tokenId);
    error PoolMismatch();
    error SplitterMismatch();
    error EmptyPosition();
    error BalanceNotRestored(address token, uint256 expected, uint256 found);
    error AllowanceNotCleared(address token, uint256 found);

    constructor(address launchpad_, address positionManager_) {
        if (launchpad_ == address(0) || positionManager_ == address(0)) revert ZeroAddress();
        launchpad = launchpad_;
        positionManager = positionManager_;
    }

    /// @notice Bind an already-minted launch position to its splitter, once and forever.
    /// @dev The launchpad has no reassignment or unregistration operation. A failed registration
    ///      reverts the launchpad's entire graduation, including the position mint.
    function register(uint256 tokenId, PoolKey calldata expectedKey, address splitter) external {
        if (msg.sender != launchpad) revert NotLaunchpad(msg.sender);
        if (splitterOf[tokenId] != address(0)) revert AlreadyRegistered(tokenId);
        if (IERC721(positionManager).ownerOf(tokenId) != address(this)) revert PositionNotOwned(tokenId);

        IPositionManager manager = IPositionManager(positionManager);
        // PositionInfo is tick/subscriber metadata, not a success flag. Validate the key and liquidity below.
        // slither-disable-next-line unused-return
        (PoolKey memory key,) = manager.getPoolAndPositionInfo(tokenId);
        if (PoolId.unwrap(key.toId()) != PoolId.unwrap(expectedKey.toId())) revert PoolMismatch();
        if (manager.getPositionLiquidity(tokenId) == 0) revert EmptyPosition();

        address currency0 = Currency.unwrap(key.currency0);
        address currency1 = Currency.unwrap(key.currency1);
        if (splitter.code.length == 0) revert SplitterMismatch();
        address memestock = IMemestockSplitterMinimal(splitter).memestock();
        address stock = IMemestockSplitterMinimal(splitter).stock();
        if (!(currency0 == memestock && currency1 == stock) && !(currency0 == stock && currency1 == memestock)) {
            revert SplitterMismatch();
        }

        splitterOf[tokenId] = splitter;
        emit PositionLocked(tokenId, key.toId(), splitter);
    }

    /// @notice Collect only this position's fees and recognize both assets at its immutable splitter.
    /// @return amount0 Collected currency0 deposited as revenue before the splitter's protocol share.
    /// @return amount1 Collected currency1 deposited as revenue before the splitter's protocol share.
    /// @dev Zero fees are a no-op. The caller supplies no recipient, currency, liquidity, amount,
    ///      approval target or hook data. Collection and both deposits succeed or revert together.
    function collect(uint256 tokenId) external nonReentrant returns (uint256 amount0, uint256 amount1) {
        address splitter = splitterOf[tokenId];
        if (splitter == address(0)) revert UnregisteredPosition(tokenId);

        IPositionManager manager = IPositionManager(positionManager);
        // Collection needs the registered position's currencies, not its tick/subscriber metadata.
        // slither-disable-next-line unused-return
        (PoolKey memory key,) = manager.getPoolAndPositionInfo(tokenId);
        address currency0 = Currency.unwrap(key.currency0);
        address currency1 = Currency.unwrap(key.currency1);
        uint256 before0 = currency0.balanceOf(address(this));
        uint256 before1 = currency1.balanceOf(address(this));

        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, uint256(0), uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1, address(this));
        manager.modifyLiquidities(
            abi.encode(abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR)), params),
            block.timestamp
        );

        amount0 = currency0.balanceOf(address(this)) - before0;
        amount1 = currency1.balanceOf(address(this)) - before1;
        _deposit(currency0, splitter, amount0, tokenId);
        _deposit(currency1, splitter, amount1, tokenId);
        _requireBalance(currency0, before0);
        _requireBalance(currency1, before1);

        emit FeesDeposited(tokenId, splitter, currency0, currency1, amount0, amount1);
    }

    function _deposit(address token, address splitter, uint256 amount, uint256 tokenId) private {
        if (amount == 0) return;
        token.safeApprove(splitter, amount);
        IMemestockSplitterMinimal(splitter).depositRecognizedRevenue(token, amount, bytes32(tokenId));
        uint256 remaining = IERC20Minimal(token).allowance(address(this), splitter);
        if (remaining != 0) revert AllowanceNotCleared(token, remaining);
    }

    function _requireBalance(address token, uint256 expected) private view {
        uint256 found = token.balanceOf(address(this));
        if (found != expected) revert BalanceNotRestored(token, expected, found);
    }
}
