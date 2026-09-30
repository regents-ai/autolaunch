// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {RobinhoodFeeHookV1} from "./RobinhoodFeeHookV1.sol";

/// @title RobinhoodFeeHookFactory
/// @notice Deploys one `RobinhoodFeeHookV1` per launchpad at a mined CREATE2 address. The launchpad
///         calls this from its own constructor, so the hook is bound to `msg.sender`, the launchpad
///         under construction, and the launchpad reads every binding back before recording it.
/// @dev The hook's creation code lives here rather than inside the launchpad so that the launchpad
///      does not carry it at runtime (EIP-170). Anyone may call `deploy`; a hook bound to a caller
///      that is not a launchpad registers no pool and is inert.
contract RobinhoodFeeHookFactory {
    address public immutable poolManager;

    event HookDeployed(address indexed launchpad, address indexed hook, bytes32 salt);

    error ZeroAddress();
    error NoCode(address account);

    constructor(address poolManager_) {
        if (poolManager_ == address(0)) revert ZeroAddress();
        if (poolManager_.code.length == 0) revert NoCode(poolManager_);
        poolManager = poolManager_;
    }

    /// @notice Deploy the hook for the calling launchpad.
    /// @param salt The pre-mined salt giving the hook the exact permission bits v4 encodes in its address.
    function deploy(bytes32 salt, address usdg, address inbox, address adminSafe) external returns (address hook) {
        hook =
            address(new RobinhoodFeeHookV1{salt: salt}(IPoolManager(poolManager), msg.sender, usdg, inbox, adminSafe));
        emit HookDeployed(msg.sender, hook, salt);
    }

    /// @notice The address `deploy` produces for a launchpad and salt; the salt miner's target.
    function predict(bytes32 salt, address launchpad, address usdg, address inbox, address adminSafe)
        external
        view
        returns (address)
    {
        bytes32 initCodeHash = keccak256(
            abi.encodePacked(
                type(RobinhoodFeeHookV1).creationCode, abi.encode(poolManager, launchpad, usdg, inbox, adminSafe)
            )
        );
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initCodeHash)))));
    }
}
