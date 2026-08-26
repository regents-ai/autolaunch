// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {BaseBindings} from "../../src/bindings/BaseBindings.sol";
import {RegentsAutolaunchFactoryV1} from "../../src/factory/RegentsAutolaunchFactoryV1.sol";
import {RegentLBPStrategy} from "../../src/strategy/RegentLBPStrategy.sol";
import {IDistributorFactory} from "liquidity-launcher/src/interfaces/IDistributorFactory.sol";
import {UERC20Metadata} from "uerc20-factory/libraries/UERC20MetadataLibrary.sol";
import {ITokenFactory} from "uerc20-factory/interfaces/ITokenFactory.sol";
import {AutolaunchFixture} from "../integration/AutolaunchFixture.sol";
import {ConditionalVestingEscrowV1} from "../../src/escrow/ConditionalVestingEscrowV1.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {StagedERC20} from "../strategy/doubles/StagedERC20.sol";

/// @notice `C4-I3`: a failure at any external boundary of `launch` is an ordinary EVM revert that
///         leaves no launch ID, no mapping entry, no token, no escrow, no auction, no fee movement,
///         no allowance and no contract nonce behind.
/// @dev Every stage below fails exactly one named boundary the launch crosses, one at a time, from
///      an identical pre-launch state, and each one then asserts the complete pre-launch ledger.
///      The stages are the plan's own enumeration: the fee transfer and its exactness proof, UERC20
///      creation, each readback, the escrow approval, the escrow initialization and its exact pull,
///      the strategy initialization and its exact pull, the CCA creation and its readback, the
///      SUBJECT delivery, the post-distribution custody proof, and the final record agreement.
///
///      Two injection shapes are used, and each is the honest one for its boundary. Identity
///      boundaries are failed by making the real dependency answer wrongly. Token-movement
///      boundaries are failed with the imported `StagedERC20` fault harness standing in for the
///      created SUBJECT, because a real `UERC20` cannot be made to misbehave and because mocking a
///      call at the not-yet-created token's own address would give that address code and turn every
///      such test into a CREATE2 collision instead.
contract AutolaunchFactoryRollbackTest is AutolaunchFixture {
    /// @notice The pre-launch facts an aborted launch must leave untouched.
    struct Pristine {
        uint256 nextLaunchId;
        uint64 factoryNonce;
        uint64 strategyNonce;
        uint256 launcherRegent;
        uint256 launcherAllowance;
        uint256 safeRegent;
        uint256 factoryRegent;
        address predictedSubject;
        address predictedEscrow;
    }

    function setUp() public {
        _deployAutolaunch();
    }

    /// @notice `FAC-021`: no injected boundary failure can leave a partial launch behind, and the
    ///         very next clean launch is unaffected by any of them.
    function test_FAC_021_AnyLaunchStageFailureRollsBackCompletely() public {
        // One earlier launch exists, so every stage runs against a factory that already has real
        // state to corrupt, and so a mis-bound auction is an auction that genuinely exists.
        Launched memory existing = _defaultLaunch();
        Pristine memory pristine = _pristine();

        // 1. the fee transfer itself
        vm.mockCallRevert(
            BaseBindings.REGENT, abi.encodePacked(bytes4(keccak256("transferFrom(address,address,uint256)"))), ""
        );
        _assertRollsBack(
            pristine, "1 fee transfer", abi.encodeWithSelector(SafeTransferLib.TransferFromFailed.selector)
        );

        // 2. the fee's exactness proof, measured at the Regent Safe
        vm.mockCall(
            BaseBindings.REGENT,
            abi.encodeWithSignature("balanceOf(address)", BaseBindings.GOVERNANCE_AND_REGENT_SAFE),
            abi.encode(uint256(0))
        );
        _assertRollsBack(
            pristine,
            "2 fee exactness proof",
            abi.encodeWithSelector(RegentsAutolaunchFactoryV1.InexactTransfer.selector, INITIAL_LAUNCH_FEE, uint256(0))
        );

        // 3. UERC20 creation
        vm.mockCallRevert(address(uerc20Factory), abi.encodePacked(ITokenFactory.createToken.selector), "");
        _assertRollsBack(pristine, "3 UERC20 creation", "");

        // 4. the created token carries no code
        _mockCreatedToken(outsider);
        _assertRollsBack(
            pristine,
            "4 codeless SUBJECT readback",
            abi.encodeWithSelector(RegentsAutolaunchFactoryV1.SubjectHasNoCode.selector, outsider)
        );

        // 5. the created token records a different creator
        _mockCreatedToken(address(_unrelatedToken()));
        _assertRollsBack(
            pristine,
            "5 foreign creator readback",
            abi.encodeWithSelector(RegentsAutolaunchFactoryV1.SubjectCreatorMismatch.selector, outsider)
        );

        // 6. the created token records a different graffiti: another launch's real SUBJECT, whose
        //    creator is genuinely this factory but whose graffiti is that launch's ID
        _mockCreatedToken(address(existing.subject));
        _assertRollsBack(
            pristine,
            "6 graffiti readback",
            abi.encodeWithSelector(RegentsAutolaunchFactoryV1.SubjectGraffitiMismatch.selector, bytes32(uint256(1)))
        );

        // 7. the SUBJECT approval the escrow clone needs
        StagedERC20 faulty = _faultySubject(pristine.nextLaunchId, TOTAL_SUPPLY);
        vm.mockCall(address(faulty), abi.encodeWithSignature("approve(address,uint256)"), abi.encode(false));
        _assertRollsBack(pristine, "7 escrow approval", abi.encodeWithSelector(SafeTransferLib.ApproveFailed.selector));

        // 8. the escrow's own initialization check, on a SUBJECT that is not the fixed supply
        _faultySubject(pristine.nextLaunchId, TOTAL_SUPPLY - 1);
        _assertRollsBack(
            pristine,
            "8 escrow initialization",
            abi.encodeWithSelector(ConditionalVestingEscrowV1.InvalidSubjectSupply.selector, TOTAL_SUPPLY - 1)
        );

        // 9. the escrow's exact 85% pull, reverted and then silently short
        _faultySubject(pristine.nextLaunchId, TOTAL_SUPPLY).arm(1, StagedERC20.Fault.Revert);
        _assertRollsBack(
            pristine, "9 escrow pull reverted", abi.encodeWithSelector(SafeTransferLib.TransferFromFailed.selector)
        );
        _faultySubject(pristine.nextLaunchId, TOTAL_SUPPLY).arm(1, StagedERC20.Fault.ShortTransfer);
        _assertRollsBack(
            pristine,
            "9 escrow pull short",
            abi.encodeWithSelector(
                ConditionalVestingEscrowV1.InexactTransfer.selector, PENDING_ALLOCATION, PENDING_ALLOCATION - 1
            )
        );

        // 10. the strategy's exact 15% pull
        _faultySubject(pristine.nextLaunchId, TOTAL_SUPPLY).arm(2, StagedERC20.Fault.ShortTransfer);
        _assertRollsBack(
            pristine,
            "10 strategy pull short",
            abi.encodeWithSelector(
                RegentLBPStrategy.InexactTransfer.selector,
                strategy.DISTRIBUTION_PULL(),
                strategy.DISTRIBUTION_PULL() - 1
            )
        );

        // 11. the strategy's initialization entry point
        vm.mockCallRevert(address(strategy), abi.encodePacked(RegentLBPStrategy.initializeDistribution.selector), "");
        _assertRollsBack(pristine, "11 strategy initialization", "");

        // 12. a codeless created auction
        vm.mockCall(
            BaseBindings.CCA_FACTORY, abi.encodeWithSelector(IDistributorFactory.create.selector), abi.encode(outsider)
        );
        _assertRollsBack(
            pristine,
            "12 codeless auction readback",
            abi.encodeWithSelector(RegentLBPStrategy.AuctionHasNoCode.selector, outsider)
        );

        // 13. a real but mis-bound created auction: another launch's auction, returned in its place
        vm.mockCall(
            BaseBindings.CCA_FACTORY,
            abi.encodeWithSelector(IDistributorFactory.create.selector),
            abi.encode(address(existing.auction))
        );
        _assertRollsBack(
            pristine,
            "13 mis-bound auction readback",
            abi.encodeWithSelector(
                RegentLBPStrategy.AuctionBindingMismatch.selector,
                uint256(0),
                uint256(uint160(pristine.predictedSubject)),
                uint256(uint160(address(existing.subject)))
            )
        );

        // 14. the 10% delivery into the auction
        _faultySubject(pristine.nextLaunchId, TOTAL_SUPPLY).arm(3, StagedERC20.Fault.ShortTransfer);
        _assertRollsBack(
            pristine,
            "14 SUBJECT delivery",
            abi.encodeWithSelector(
                RegentLBPStrategy.InexactTransfer.selector,
                uint256(strategy.AUCTION_ALLOCATION()),
                uint256(strategy.AUCTION_ALLOCATION()) - 1
            )
        );

        // 15. the post-distribution custody proof at the factory
        StagedERC20 gifted = _faultySubject(pristine.nextLaunchId, TOTAL_SUPPLY);
        vm.mockCall(
            address(gifted), abi.encodeWithSignature("balanceOf(address)", address(factory)), abi.encode(uint256(1))
        );
        _assertRollsBack(
            pristine,
            "15 factory custody proof",
            abi.encodeWithSelector(RegentsAutolaunchFactoryV1.SubjectNotFullyDistributed.selector, uint256(1))
        );

        // 16. the final agreement between the returned identities and the strategy's own record
        RegentLBPStrategy.Distribution memory wrong;
        wrong.launchId = 4242;
        vm.mockCall(
            address(strategy), abi.encodeWithSelector(RegentLBPStrategy.distribution.selector), abi.encode(wrong)
        );
        _assertRollsBack(
            pristine,
            "16 final record agreement",
            abi.encodeWithSelector(
                RegentsAutolaunchFactoryV1.LaunchRecordMismatch.selector,
                uint256(0),
                pristine.nextLaunchId,
                uint256(4242)
            )
        );

        // Nothing any of those attempts reached for exists, and the next clean launch is normal.
        Launched memory clean = _launchAs(launcher, _params());
        assertEq(clean.launchId, pristine.nextLaunchId, "the clean launch did not take the untouched ID");
        assertEq(address(clean.subject), pristine.predictedSubject, "the clean launch is not at the predicted SUBJECT");
        assertEq(address(clean.escrow), pristine.predictedEscrow, "the clean launch is not at the predicted escrow");
        assertEq(clean.subject.balanceOf(address(clean.escrow)), PENDING_ALLOCATION, "the clean escrow is not funded");
        assertEq(
            uint8(_distribution(clean).lifecycle), uint8(RegentLBPStrategy.Lifecycle.Active), "the clean launch is idle"
        );
    }

    /// @notice `FAC-028`: a treasury the strategy refuses at launch rolls the whole attempted launch
    ///         back — the fee, the SUBJECT, the escrow, the auction, the records and the events
    ///         together — and never disturbs an existing launch.
    /// @dev The refusal happens after the fee has moved, after the SUBJECT exists and after that
    ///      launch's escrow has been cloned and funded with the exact 85%, so this is the widest
    ///      rollback the launch path has. The six arms are the whole refusal set: the six shared
    ///      system destinations, each by exact address. `STR-019` owns the class enumeration at the
    ///      strategy, including the classes admission deliberately admits.
    function test_FAC_028_RefusedTreasuryRollsTheWholeLaunchBack() public {
        Launched memory existing = _defaultLaunch();
        Pristine memory pristine = _pristine();

        address[6] memory refused = [
            address(factory),
            address(strategy),
            address(hook),
            BaseBindings.POOL_MANAGER,
            BaseBindings.POSITION_MANAGER,
            BaseBindings.LIVE_STAKING
        ];

        for (uint256 i; i < refused.length; ++i) {
            RegentsAutolaunchFactoryV1.LaunchParams memory params = _params();
            params.treasury = refused[i];
            _assertRollsBack(
                pristine,
                string.concat("refused treasury ", vm.toString(i)),
                abi.encodeWithSelector(RegentLBPStrategy.RefusedTreasury.selector, refused[i]),
                params
            );
        }

        // The launch that already existed is untouched by every one of those attempts.
        assertEq(
            uint8(_distribution(existing).lifecycle),
            uint8(RegentLBPStrategy.Lifecycle.Active),
            "a refused launch disturbed an existing launch"
        );
        assertEq(
            existing.subject.balanceOf(address(existing.escrow)),
            PENDING_ALLOCATION,
            "a refused launch reached an existing launch's escrow custody"
        );
        assertEq(
            existing.subject.balanceOf(address(strategy)),
            RESERVE_ALLOCATION,
            "a refused launch reached an existing launch's isolated reserve"
        );

        // And the next launch, on an admitted treasury, is completely normal.
        Launched memory clean = _launchAs(launcher, _params());
        assertEq(clean.launchId, pristine.nextLaunchId, "the clean launch did not take the untouched ID");
        assertEq(
            uint8(_distribution(clean).lifecycle), uint8(RegentLBPStrategy.Lifecycle.Active), "the clean launch is idle"
        );
    }

    // -------------------------------------------------------------------------
    // helpers
    // -------------------------------------------------------------------------

    function _pristine() private returns (Pristine memory pristine) {
        RegentsAutolaunchFactoryV1.LaunchParams memory params = _params();
        _fundFee(launcher, params.expectedLaunchFee);

        pristine.nextLaunchId = factory.nextLaunchId();
        pristine.factoryNonce = vm.getNonce(address(factory));
        pristine.strategyNonce = vm.getNonce(address(strategy));
        pristine.launcherRegent = regent.balanceOf(launcher);
        pristine.launcherAllowance = regent.allowance(launcher, address(factory));
        pristine.safeRegent = regent.balanceOf(BaseBindings.GOVERNANCE_AND_REGENT_SAFE);
        pristine.factoryRegent = regent.balanceOf(address(factory));
        pristine.predictedSubject = uerc20Factory.getUERC20Address(
            params.name, params.symbol, 18, address(factory), bytes32(pristine.nextLaunchId)
        );
        pristine.predictedEscrow = vm.computeCreateAddress(address(factory), pristine.factoryNonce);
    }

    /// @dev Attempt the launch with whatever fault is currently armed, require it to revert, and
    ///      prove every pre-launch fact survived untouched.
    function _assertRollsBack(Pristine memory pristine, string memory stage, bytes memory expected) private {
        _assertRollsBack(pristine, stage, expected, _params());
    }

    function _assertRollsBack(
        Pristine memory pristine,
        string memory stage,
        bytes memory expected,
        RegentsAutolaunchFactoryV1.LaunchParams memory params
    ) private {
        if (expected.length == 0) vm.expectRevert();
        else vm.expectRevert(expected);
        vm.prank(launcher);
        factory.launch(params);
        vm.clearMockedCalls();

        assertEq(factory.nextLaunchId(), pristine.nextLaunchId, string.concat(stage, ": an ID was consumed"));
        assertEq(vm.getNonce(address(factory)), pristine.factoryNonce, string.concat(stage, ": a factory nonce moved"));
        assertEq(
            vm.getNonce(address(strategy)), pristine.strategyNonce, string.concat(stage, ": a strategy nonce moved")
        );
        assertEq(regent.balanceOf(launcher), pristine.launcherRegent, string.concat(stage, ": launcher REGENT moved"));
        assertEq(
            regent.allowance(launcher, address(factory)),
            pristine.launcherAllowance,
            string.concat(stage, ": the fee allowance moved")
        );
        assertEq(
            regent.balanceOf(BaseBindings.GOVERNANCE_AND_REGENT_SAFE),
            pristine.safeRegent,
            string.concat(stage, ": the Regent Safe received a fee")
        );
        assertEq(
            regent.balanceOf(address(factory)),
            pristine.factoryRegent,
            string.concat(stage, ": the factory kept REGENT")
        );
        assertEq(
            factory.launchIdOfSubject(pristine.predictedSubject), 0, string.concat(stage, ": a SUBJECT was indexed")
        );
        assertEq(
            factory.launches(pristine.nextLaunchId).subject,
            address(0),
            string.concat(stage, ": a launch record survived")
        );
        assertEq(pristine.predictedSubject.code.length, 0, string.concat(stage, ": a SUBJECT survived"));
        assertEq(pristine.predictedEscrow.code.length, 0, string.concat(stage, ": an escrow survived"));
        assertEq(
            strategy.auctionOfSubject(pristine.predictedSubject),
            address(0),
            string.concat(stage, ": the strategy recorded an auction")
        );
    }

    /// @dev Make the pinned UERC20 factory hand back an address it did not create.
    function _mockCreatedToken(address token) private {
        vm.mockCall(
            address(uerc20Factory), abi.encodeWithSelector(ITokenFactory.createToken.selector), abi.encode(token)
        );
    }

    /// @dev A SUBJECT that passes both admission readbacks and can be made to misbehave on any one
    ///      of the launch's three token movements: the escrow's 85% pull, the strategy's 15% pull,
    ///      and the strategy's 10% delivery into the auction.
    function _faultySubject(uint256 launchId, uint256 supply) private returns (StagedERC20 token) {
        token = new StagedERC20();
        token.mint(address(factory), supply);
        _mockCreatedToken(address(token));
        vm.mockCall(address(token), abi.encodeWithSignature("creator()"), abi.encode(address(factory)));
        vm.mockCall(address(token), abi.encodeWithSignature("graffiti()"), abi.encode(bytes32(launchId)));
    }

    /// @dev A real UERC20 created by an unrelated caller through the same permissionless factory.
    function _unrelatedToken() private returns (address token) {
        vm.prank(outsider);
        token = uerc20Factory.createToken(
            "Impostor",
            "IMP",
            18,
            TOTAL_SUPPLY,
            outsider,
            abi.encode(UERC20Metadata({description: "d", website: "w", image: "i"})),
            bytes32(uint256(7))
        );
    }
}
