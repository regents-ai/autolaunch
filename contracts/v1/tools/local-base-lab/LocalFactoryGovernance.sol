// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

interface ILocalFactoryGovernance {
    function setLaunchFee(uint256 newFee) external;

    function pauseLaunches() external;

    function unpauseLaunches() external;
}

/// @notice Fork-only adapter granting one exact EOA the factory's three governance calls.
/// @dev This contract is storage-free. Its runtime is installed only at the compiled Safe address
///      inside an active loopback Anvil lab.
contract LocalFactoryGovernance is ILocalFactoryGovernance {
    address private constant FOUNDER_LOCAL_ADMIN = 0x0cb27e883E207905AD2A94F9B6eF0C7A99223C37;

    address public immutable admin;
    address public immutable factory;

    error InvalidAdmin(address admin);
    error InvalidFactory();
    error NotAdmin(address caller);

    constructor(address admin_, address factory_) {
        if (admin_ != FOUNDER_LOCAL_ADMIN) revert InvalidAdmin(admin_);
        if (factory_ == address(0)) revert InvalidFactory();
        admin = admin_;
        factory = factory_;
    }

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin(msg.sender);
        _;
    }

    function setLaunchFee(uint256 newFee) external override onlyAdmin {
        ILocalFactoryGovernance(factory).setLaunchFee(newFee);
    }

    function pauseLaunches() external override onlyAdmin {
        ILocalFactoryGovernance(factory).pauseLaunches();
    }

    function unpauseLaunches() external override onlyAdmin {
        ILocalFactoryGovernance(factory).unpauseLaunches();
    }
}
