// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {StocksBindings} from "autolaunch-stocks/StocksBindings.sol";
import {RobinhoodBaseRevenueReceiverV1} from "../src/RobinhoodBaseRevenueReceiverV1.sol";

/// @title DeployRobinhoodBaseReceiver
/// @notice The one Base-side creation of the Robinhood deployment: the receiver that takes bridged
///         USDG protocol revenue as USDC and forwards it to live staking, attested by the Base Safe.
/// @dev One direct zero-value creation from the deployer at its pinned nonce, on Base (8453), against
///      the frozen Base bindings for USDC and live staking. The Robinhood Safe points the inbox at the
///      created receiver afterwards, by hand, together with the reviewed bridge adapter.
contract DeployRobinhoodBaseReceiver is Script {
    string internal constant DEPLOYER_ENV = "REGENT_DEPLOYMENT_DEPLOYER";
    string internal constant STARTING_NONCE_ENV = "REGENT_DEPLOYMENT_STARTING_NONCE";
    string internal constant BASE_SAFE_ENV = "REGENT_DEPLOYMENT_BASE_SAFE";

    /// @notice A founder-selected ceremony. Every field is pinned by the approved packet.
    struct Ceremony {
        address deployer;
        uint256 startingNonce;
        address baseSafe;
    }

    error UnselectedDeployer();
    error WrongChain(uint256 expected, uint256 found);
    error DeployerNonceMismatch(uint256 expected, uint256 found);
    error CreationAddressMismatch(address expected, address found);
    error DeployerNonceNotAdvancedExactly(uint256 expected, uint256 found);

    /// @notice The receiver's address: the deployer's `CREATE` at the pinned nonce.
    function predict(Ceremony memory ceremony) public pure returns (address) {
        if (ceremony.deployer == address(0)) revert UnselectedDeployer();
        return vm.computeCreateAddress(ceremony.deployer, ceremony.startingNonce);
    }

    /// @notice Build the creation and prove it lands where it was predicted.
    function execute(Ceremony memory ceremony) public returns (address receiver) {
        receiver = predict(ceremony);

        uint256 nonce = vm.getNonce(ceremony.deployer);
        if (nonce != ceremony.startingNonce) revert DeployerNonceMismatch(ceremony.startingNonce, nonce);

        vm.startBroadcast(ceremony.deployer);
        address created = address(
            new RobinhoodBaseRevenueReceiverV1(StocksBindings.USDC, StocksBindings.LIVE_STAKING, ceremony.baseSafe)
        );
        vm.stopBroadcast();
        if (created != receiver) revert CreationAddressMismatch(receiver, created);

        nonce = vm.getNonce(ceremony.deployer);
        if (nonce != ceremony.startingNonce + 1) {
            revert DeployerNonceNotAdvancedExactly(ceremony.startingNonce + 1, nonce);
        }
    }

    /// @notice The broadcast entrypoint, consuming the pinned ceremony values from the environment.
    function run() external returns (address) {
        if (block.chainid != StocksBindings.BASE_CHAIN_ID) {
            revert WrongChain(StocksBindings.BASE_CHAIN_ID, block.chainid);
        }
        return execute(
            Ceremony({
                deployer: vm.envAddress(DEPLOYER_ENV),
                startingNonce: vm.envUint(STARTING_NONCE_ENV),
                baseSafe: vm.envAddress(BASE_SAFE_ENV)
            })
        );
    }
}
