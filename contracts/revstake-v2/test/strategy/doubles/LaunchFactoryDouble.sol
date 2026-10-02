// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {ConditionalVestingEscrowV2} from "../../../src/escrow/ConditionalVestingEscrowV2.sol";
import {RegentLBPStrategyV2} from "../../../src/strategy/RegentLBPStrategyV2.sol";
import {LibClone} from "solady/utils/LibClone.sol";

/// @notice The production caller of `RegentLBPStrategyV2`, reduced to exactly the C3 boundary.
/// @dev C4 owns the real Autolaunch factory. This double exists so C3's tests exercise the real
///      caller *shape*: one contract that binds the hook from inside its own constructor — while it
///      still has no code — then, per launch, clones the escrow, funds it with the exact 70%,
///      approves the strategy for the exact 30%, and calls `initializeDistribution`. It holds no
///      authority the strategy grants it beyond being the bound factory, and it closes no `FAC-*`
///      or `STR-017` claim.
contract LaunchFactoryDouble {
    RegentLBPStrategyV2 public immutable strategy;
    address public immutable escrowImplementation;
    address public registeredCanonicalAuction;

    constructor(address strategy_, address hook_) {
        strategy = RegentLBPStrategyV2(strategy_);
        escrowImplementation = RegentLBPStrategyV2(strategy_).escrowImplementation();
        // The canonical factory binds the hook here, with `address(this).code.length == 0`.
        RegentLBPStrategyV2(strategy_).bindHook(hook_);
    }

    function launch(address subject, address treasury, uint256 launchId)
        external
        returns (address escrow, address auction)
    {
        escrow = _fundedEscrow(subject, treasury);
        auction = _initialize(subject, escrow, launchId);
    }

    /// @notice Clone and fund an escrow without ever handing it to the strategy.
    function fundedEscrow(address subject, address treasury) external returns (address escrow) {
        escrow = _fundedEscrow(subject, treasury);
    }

    /// @notice Initialize against an escrow this factory already funded.
    function initialize(address subject, address escrow, uint256 launchId) external returns (address auction) {
        auction = _initialize(subject, escrow, launchId);
    }

    function registerCanonicalPaymentReceiver(address auction) external {
        require(msg.sender == address(strategy), "LaunchFactoryDouble: not strategy");
        registeredCanonicalAuction = auction;
    }

    function _fundedEscrow(address subject, address treasury) private returns (address escrow) {
        escrow = LibClone.clone(escrowImplementation);
        _approve(subject, escrow, strategy.PENDING_ALLOCATION());
        ConditionalVestingEscrowV2(escrow).initialize(subject, treasury, address(strategy));
    }

    function _initialize(address subject, address escrow, uint256 launchId) private returns (address auction) {
        _approve(subject, address(strategy), strategy.DISTRIBUTION_PULL());
        auction = strategy.initializeDistribution(
            RegentLBPStrategyV2.DistributionParams({launchId: launchId, escrow: escrow})
        );
    }

    function _approve(address token, address spender, uint256 amount) private {
        // solhint-disable-next-line avoid-low-level-calls
        (bool ok,) = token.call(abi.encodeWithSignature("approve(address,uint256)", spender, amount));
        require(ok, "LaunchFactoryDouble: approve failed");
    }
}
