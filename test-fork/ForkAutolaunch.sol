// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {BaseBindings} from "../src/bindings/BaseBindings.sol";
import {ConditionalVestingEscrowV1} from "../src/escrow/ConditionalVestingEscrowV1.sol";
import {RegentsAutolaunchFactoryV1} from "../src/factory/RegentsAutolaunchFactoryV1.sol";
import {RegentFeeHook} from "../src/hook/RegentFeeHook.sol";
import {PaymentReceiverV1} from "../src/revenue/PaymentReceiverV1.sol";
import {SubjectSplitterV1} from "../src/revenue/SubjectSplitterV1.sol";
import {RegentLBPStrategy} from "../src/strategy/RegentLBPStrategy.sol";
import {IContinuousClearingAuction} from "continuous-clearing-auction/interfaces/IContinuousClearingAuction.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {UERC20} from "uerc20-factory/tokens/UERC20.sol";
import {UERC20Factory} from "uerc20-factory/factories/UERC20Factory.sol";
import {ForkFixture} from "./ForkFixture.sol";

/// @notice Deploys the whole Autolaunch graph against the live Base bindings on an isolated fork.
/// @dev This is the deployment packet's own sequence, run against real deployed dependencies rather
///      than etched ones: deploy the pinned UERC20 factory and the three C1 implementations, mine
///      the hook salt against the real PoolManager and the predicted strategy, then let the factory
///      construct and bind the strategy and the hook from inside its own constructor.
///
///      Every piece of test state this harness stages, and the real production path that makes it
///      reachable, is inventoried in `docs/audit/fork-state-inventory.md`. Nothing is impersonated
///      that a real account could not do: bidders are funded with `deal` because a fork cannot mint
///      REGENT, and a launcher is funded and pranked because a launcher is an ordinary EOA.
abstract contract ForkAutolaunch is ForkFixture {
    uint256 internal constant INITIAL_LAUNCH_FEE = 1_000_000e18;

    /// @dev Exactly the five permission bits `RegentFeeHook` declares.
    uint160 internal constant HOOK_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );

    /// @notice The longest metadata every field admits, so gas is measured at the worst admitted shape.
    uint256 internal constant MAX_NAME_BYTES = 64;
    uint256 internal constant MAX_SYMBOL_BYTES = 16;
    uint256 internal constant MAX_DESCRIPTION_BYTES = 512;
    uint256 internal constant MAX_WEBSITE_BYTES = 256;
    uint256 internal constant MAX_IMAGE_BYTES = 256;

    RegentsAutolaunchFactoryV1 internal factory;
    RegentLBPStrategy internal strategy;
    RegentFeeHook internal hook;
    UERC20Factory internal uerc20Factory;
    ConditionalVestingEscrowV1 internal escrowImplementation;
    SubjectSplitterV1 internal splitterImplementation;
    PaymentReceiverV1 internal receiverImplementation;
    ForkRecoveryAdmin internal recoveryAdmin;

    address internal launcher = makeAddr("fork-launcher");
    address internal bidder = makeAddr("fork-bidder");
    address internal treasury = makeAddr("fork-treasury");

    struct ForkLaunch {
        uint256 launchId;
        UERC20 subject;
        ConditionalVestingEscrowV1 escrow;
        IContinuousClearingAuction auction;
    }

    /// @dev The deployment packet, run on the selected fork.
    function _deployOnFork() internal {
        uerc20Factory = new UERC20Factory();
        escrowImplementation = new ConditionalVestingEscrowV1();
        splitterImplementation = new SubjectSplitterV1();
        receiverImplementation = new PaymentReceiverV1();
        recoveryAdmin = new ForkRecoveryAdmin();

        address predictedFactory = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        address predictedStrategy = vm.computeCreateAddress(predictedFactory, 1);
        (, bytes32 hookSalt) = HookMiner.find(
            predictedFactory,
            HOOK_FLAGS,
            type(RegentFeeHook).creationCode,
            abi.encode(BaseBindings.POOL_MANAGER, predictedStrategy)
        );

        factory = new RegentsAutolaunchFactoryV1(
            address(uerc20Factory),
            address(escrowImplementation),
            address(splitterImplementation),
            address(receiverImplementation),
            hookSalt
        );
        strategy = factory.strategy();
        hook = factory.hook();
    }

    /// @notice Launch parameters at the worst admitted metadata shape and a caller-chosen raise.
    function _worstCaseParams(uint128 requiredRegentRaised)
        internal
        view
        returns (RegentsAutolaunchFactoryV1.LaunchParams memory params)
    {
        params = RegentsAutolaunchFactoryV1.LaunchParams({
            name: _filled(MAX_NAME_BYTES),
            symbol: _filled(MAX_SYMBOL_BYTES),
            description: _filled(MAX_DESCRIPTION_BYTES),
            website: _filled(MAX_WEBSITE_BYTES),
            image: _filled(MAX_IMAGE_BYTES),
            treasury: treasury,
            recoveryAdmin: address(recoveryAdmin),
            requiredRegentRaised: requiredRegentRaised,
            expectedLaunchFee: factory.launchFee()
        });
    }

    function _filled(uint256 length) internal pure returns (string memory) {
        bytes memory buffer = new bytes(length);
        for (uint256 i; i < length; ++i) {
            buffer[i] = "R";
        }
        return string(buffer);
    }

    /// @dev A connected wallet's exact approval and launch, from a real EOA.
    function _launchAsWallet(RegentsAutolaunchFactoryV1.LaunchParams memory params)
        internal
        returns (ForkLaunch memory launched, uint256 gasUsed, bytes memory calldataPayload)
    {
        deal(BaseBindings.REGENT, launcher, params.expectedLaunchFee);
        vm.startPrank(launcher);
        _approveExactly(BaseBindings.REGENT, address(factory), params.expectedLaunchFee);

        calldataPayload = abi.encodeCall(RegentsAutolaunchFactoryV1.launch, (params));
        uint256 before = gasleft();
        (bool ok, bytes memory returned) = address(factory).call(calldataPayload);
        gasUsed = before - gasleft();
        vm.stopPrank();
        require(ok, "fork launch reverted");

        (uint256 launchId, address subject, address auction, address escrow) =
            abi.decode(returned, (uint256, address, address, address));
        launched = ForkLaunch({
            launchId: launchId,
            subject: UERC20(subject),
            escrow: ConditionalVestingEscrowV1(escrow),
            auction: IContinuousClearingAuction(auction)
        });
    }

    function _approveExactly(address token, address spender, uint256 amount) internal {
        (bool ok,) = token.call(abi.encodeWithSignature("approve(address,uint256)", spender, amount));
        require(ok, "fork approve failed");
    }
}

/// @notice A deployed contract standing in for the immutable recovery admin on a fork.
/// @dev The production constructor requires an admin that carries code and checks nothing else, so
///      this is a deployment input rather than a substituted behaviour.
contract ForkRecoveryAdmin {
    function role() external pure returns (bytes32) {
        return "recovery-admin";
    }
}
