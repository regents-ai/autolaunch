// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {BaseBindings} from "../../src/bindings/BaseBindings.sol";
import {RegentsAutolaunchFactoryV1} from "../../src/factory/RegentsAutolaunchFactoryV1.sol";
import {AutolaunchFixture} from "../integration/AutolaunchFixture.sol";
import {Vm} from "forge-std/Vm.sol";

/// @notice `C4-I1` and `C4-I2`: governance owns exactly two switches — the launch fee and the new
///         launch pause — and a launch's fee movement is exact, proved by the Regent Safe's own
///         balance, and leaves no standing allowance behind.
contract AutolaunchFactoryFeeTest is AutolaunchFixture {
    event LaunchFeeUpdated(uint256 previousFee, uint256 newFee);
    event LaunchFeeCollected(uint256 indexed launchId, address indexed payer, address regentSafe, uint256 amount);
    event LaunchesPaused();
    event LaunchesUnpaused();

    function setUp() public {
        _deployAutolaunch();
    }

    /// @notice `FAC-005`: the factory is born costing exactly 1,000,000 REGENT, and that REGENT
    ///         lands at the Regent Safe and nowhere else.
    /// @dev The Safe's own balance delta is the proof, not a token return value. That has one
    ///      deliberate consequence worth stating rather than hiding: the Regent Safe cannot itself
    ///      pay a positive launch fee, because paying itself moves nothing. Governance launching
    ///      under a positive fee is not an admitted path; setting the fee to zero first is.
    function test_FAC_005_InitialLaunchFeeIsOneMillionRegentToTheSafe() public {
        assertEq(factory.INITIAL_LAUNCH_FEE(), 1_000_000e18, "the source constant is not one million REGENT");
        assertEq(factory.launchFee(), 1_000_000e18, "the factory was not born at the initial fee");

        uint256 safeBefore = regent.balanceOf(BaseBindings.GOVERNANCE_AND_REGENT_SAFE);
        uint256 factoryBefore = regent.balanceOf(address(factory));
        _defaultLaunch();

        assertEq(
            regent.balanceOf(BaseBindings.GOVERNANCE_AND_REGENT_SAFE) - safeBefore,
            1_000_000e18,
            "the Regent Safe did not receive exactly the fee"
        );
        assertEq(regent.balanceOf(launcher), 0, "the launcher kept part of the fee");
        assertEq(regent.balanceOf(address(factory)), factoryBefore, "the factory retained fee REGENT");

        // The Regent Safe paying itself a positive fee moves nothing, so the exactness proof fails
        // and the launch reverts whole.
        RegentsAutolaunchFactoryV1.LaunchParams memory params = _params();
        regent.mint(governance, 1_000_000e18);
        vm.prank(governance);
        regent.approve(address(factory), 1_000_000e18);
        vm.expectRevert(
            abi.encodeWithSelector(
                RegentsAutolaunchFactoryV1.InexactTransfer.selector, uint256(1_000_000e18), uint256(0)
            )
        );
        vm.prank(governance);
        factory.launch(params);

        // With the fee at zero, governance is an ordinary launcher like anyone else.
        vm.prank(governance);
        factory.setLaunchFee(0);
        vm.prank(governance);
        regent.approve(address(factory), 0);
        params.expectedLaunchFee = 0;
        vm.prank(governance);
        (uint256 launchId,,,) = factory.launch(params);
        assertEq(factory.launches(launchId).launcher, governance, "governance could not launch at a zero fee");
    }

    /// @notice `FAC-006`: only the frozen governance Safe moves the fee, and it may move it to any
    ///         value including zero.
    function test_FAC_006_OnlyGovernanceChangesTheLaunchFee() public {
        address[4] memory strangers = [launcher, outsider, address(strategy), address(factory)];
        for (uint256 i; i < strangers.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(RegentsAutolaunchFactoryV1.NotGovernance.selector, strangers[i]));
            vm.prank(strangers[i]);
            factory.setLaunchFee(1);
        }
        assertEq(factory.launchFee(), 1_000_000e18, "a stranger moved the fee");

        // Every boundary fee the specification names, each one actually launchable at exactly that
        // allowance. Zero is a first-class fee, not a disabled state.
        uint256[8] memory fees = [uint256(0), 1, 49, 50, 99, 100, 9_999, 10_000];
        for (uint256 i; i < fees.length; ++i) {
            vm.prank(governance);
            factory.setLaunchFee(fees[i]);
            assertEq(factory.launchFee(), fees[i], "governance could not set a boundary fee");

            uint256 safeBefore = regent.balanceOf(BaseBindings.GOVERNANCE_AND_REGENT_SAFE);
            RegentsAutolaunchFactoryV1.LaunchParams memory params = _params();
            params.expectedLaunchFee = fees[i];
            _launchAs(launcher, params);
            assertEq(
                regent.balanceOf(BaseBindings.GOVERNANCE_AND_REGENT_SAFE) - safeBefore,
                fees[i],
                "the Safe delta did not equal the boundary fee"
            );
            assertEq(regent.allowance(launcher, address(factory)), 0, "a boundary fee left an allowance behind");
        }
    }

    /// @notice `FAC-007`: a factory is born paused. Construction admits no launch, announces no
    ///         pause, and leaves the frozen Safe as the only account that can ever open it.
    /// @dev The subject is a second factory the fixture's deliberate governance unpause never
    ///      reached, so what it reports is what construction alone left behind and nothing else.
    function test_FAC_007_AFreshFactoryIsBornPausedUntilGovernanceOpensIt() public {
        vm.recordLogs();
        RegentsAutolaunchFactoryV1 fresh = _deployUntouchedFactory();

        // The paused default is storage, not an announcement: nothing anywhere in construction may
        // emit a pause event a reader could mistake for a governance decision.
        bytes32 paused = keccak256("LaunchesPaused()");
        bytes32 unpaused = keccak256("LaunchesUnpaused()");
        Vm.Log[] memory constructionLogs = vm.getRecordedLogs();
        for (uint256 i; i < constructionLogs.length; ++i) {
            assertTrue(constructionLogs[i].topics[0] != paused, "construction emitted a pause event");
            assertTrue(constructionLogs[i].topics[0] != unpaused, "construction emitted an unpause event");
        }

        assertTrue(fresh.launchesPaused(), "a freshly constructed factory does not start paused");
        assertEq(fresh.nextLaunchId(), 1, "a fresh factory did not start at launch id one");
        assertEq(fresh.launchFee(), 1_000_000e18, "a fresh factory did not start at the initial fee");

        // Closing what construction already closed is the same explicit state error it always was.
        vm.expectRevert(RegentsAutolaunchFactoryV1.LaunchesAlreadyPaused.selector);
        vm.prank(governance);
        fresh.pauseLaunches();

        // A launch is refused before the fee moves, before an ID is allocated, and before anything
        // is deployed.
        RegentsAutolaunchFactoryV1.LaunchParams memory params = _params();
        regent.mint(launcher, params.expectedLaunchFee);
        vm.prank(launcher);
        regent.approve(address(fresh), params.expectedLaunchFee);

        uint256 safeBefore = regent.balanceOf(BaseBindings.GOVERNANCE_AND_REGENT_SAFE);
        uint64 nonceBefore = vm.getNonce(address(fresh));
        vm.expectRevert(RegentsAutolaunchFactoryV1.LaunchesArePaused.selector);
        vm.prank(launcher);
        fresh.launch(params);

        assertEq(fresh.nextLaunchId(), 1, "a born-paused factory allocated an ID");
        assertEq(
            regent.balanceOf(BaseBindings.GOVERNANCE_AND_REGENT_SAFE), safeBefore, "a born-paused factory took a fee"
        );
        assertEq(regent.allowance(launcher, address(fresh)), params.expectedLaunchFee, "the fee allowance was consumed");
        assertEq(vm.getNonce(address(fresh)), nonceBefore, "a born-paused factory deployed something");

        // Opening it is governance's alone, and nothing about deploying it granted anyone else that.
        address[3] memory strangers = [launcher, outsider, address(this)];
        for (uint256 i; i < strangers.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(RegentsAutolaunchFactoryV1.NotGovernance.selector, strangers[i]));
            vm.prank(strangers[i]);
            fresh.unpauseLaunches();
        }
        assertTrue(fresh.launchesPaused(), "a stranger opened the factory");

        vm.expectEmit(true, true, true, true, address(fresh));
        emit LaunchesUnpaused();
        vm.prank(governance);
        fresh.unpauseLaunches();
        assertFalse(fresh.launchesPaused(), "governance could not open the factory");

        vm.prank(launcher);
        (uint256 launchId,,,) = fresh.launch(params);
        assertEq(launchId, 1, "the opened factory did not admit its first launch");
    }

    /// @notice `FAC-007`: only governance pauses or unpauses, the pause gates `launch` alone, and
    ///         repeating either transition is an explicit state error rather than a second path.
    function test_FAC_007_OnlyGovernancePausesNewLaunches() public {
        address[3] memory strangers = [launcher, outsider, address(strategy)];
        for (uint256 i; i < strangers.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(RegentsAutolaunchFactoryV1.NotGovernance.selector, strangers[i]));
            vm.prank(strangers[i]);
            factory.pauseLaunches();

            vm.expectRevert(abi.encodeWithSelector(RegentsAutolaunchFactoryV1.NotGovernance.selector, strangers[i]));
            vm.prank(strangers[i]);
            factory.unpauseLaunches();
        }
        assertFalse(factory.launchesPaused(), "a stranger paused the factory");

        vm.expectEmit(true, true, true, true, address(factory));
        emit LaunchesPaused();
        vm.prank(governance);
        factory.pauseLaunches();
        assertTrue(factory.launchesPaused(), "governance could not pause");

        vm.expectRevert(RegentsAutolaunchFactoryV1.LaunchesAlreadyPaused.selector);
        vm.prank(governance);
        factory.pauseLaunches();

        RegentsAutolaunchFactoryV1.LaunchParams memory params = _params();
        _fundFee(launcher, params.expectedLaunchFee);
        vm.expectRevert(RegentsAutolaunchFactoryV1.LaunchesArePaused.selector);
        vm.prank(launcher);
        factory.launch(params);
        assertEq(factory.nextLaunchId(), 1, "a paused factory allocated an ID");

        vm.expectEmit(true, true, true, true, address(factory));
        emit LaunchesUnpaused();
        vm.prank(governance);
        factory.unpauseLaunches();

        vm.expectRevert(RegentsAutolaunchFactoryV1.LaunchesNotPaused.selector);
        vm.prank(governance);
        factory.unpauseLaunches();

        vm.prank(launcher);
        (uint256 launchId,,,) = factory.launch(params);
        assertEq(launchId, 1, "the unpaused factory did not resume launching");
    }

    /// @notice `FAC-008`: a positive fee demands an allowance equal to it exactly — one wei short or
    ///         one wei over is refused before anything is created.
    function test_FAC_008_AllowanceMustEqualTheExpectedPositiveFee() public {
        RegentsAutolaunchFactoryV1.LaunchParams memory params = _params();
        uint256 fee = params.expectedLaunchFee;
        regent.mint(launcher, fee * 4);

        uint256[3] memory wrong = [fee - 1, fee + 1, 0];
        for (uint256 i; i < wrong.length; ++i) {
            vm.prank(launcher);
            regent.approve(address(factory), wrong[i]);

            vm.expectRevert(
                abi.encodeWithSelector(RegentsAutolaunchFactoryV1.LaunchFeeAllowanceMismatch.selector, fee, wrong[i])
            );
            vm.prank(launcher);
            factory.launch(params);
        }
        assertEq(factory.nextLaunchId(), 1, "a wrong allowance still allocated an ID");

        vm.prank(launcher);
        regent.approve(address(factory), fee);
        vm.prank(launcher);
        (uint256 launchId,,,) = factory.launch(params);
        assertEq(launchId, 1, "the exact allowance did not launch");
    }

    /// @notice `FAC-009`: a zero fee still requires a zero allowance, so no launcher can leave
    ///         standing spend authority over their REGENT with this factory.
    function test_FAC_009_ZeroFeeRequiresZeroAllowance() public {
        vm.prank(governance);
        factory.setLaunchFee(0);

        RegentsAutolaunchFactoryV1.LaunchParams memory params = _params();
        params.expectedLaunchFee = 0;

        regent.mint(launcher, 10e18);
        vm.prank(launcher);
        regent.approve(address(factory), 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                RegentsAutolaunchFactoryV1.LaunchFeeAllowanceMismatch.selector, uint256(0), uint256(1)
            )
        );
        vm.prank(launcher);
        factory.launch(params);

        vm.prank(launcher);
        regent.approve(address(factory), 0);

        uint256 safeBefore = regent.balanceOf(BaseBindings.GOVERNANCE_AND_REGENT_SAFE);
        uint256 launcherBefore = regent.balanceOf(launcher);
        vm.prank(launcher);
        (uint256 launchId,,,) = factory.launch(params);

        assertEq(launchId, 1, "the zero-fee launch did not happen");
        assertEq(regent.balanceOf(BaseBindings.GOVERNANCE_AND_REGENT_SAFE), safeBefore, "a zero fee moved REGENT");
        assertEq(regent.balanceOf(launcher), launcherBefore, "a zero fee cost the launcher REGENT");
    }

    /// @notice `FAC-010`: a launcher who signed against a fee governance has since changed gets
    ///         nothing — no token, no auction, no escrow, no ID, and no fee movement.
    function test_FAC_010_StaleExpectedFeeRevertsTheWholeLaunch() public {
        RegentsAutolaunchFactoryV1.LaunchParams memory params = _params();
        _fundFee(launcher, params.expectedLaunchFee);

        vm.prank(governance);
        factory.setLaunchFee(2_000_000e18);

        uint256 safeBefore = regent.balanceOf(BaseBindings.GOVERNANCE_AND_REGENT_SAFE);
        vm.expectRevert(
            abi.encodeWithSelector(
                RegentsAutolaunchFactoryV1.StaleLaunchFee.selector, uint256(2_000_000e18), uint256(1_000_000e18)
            )
        );
        vm.prank(launcher);
        factory.launch(params);

        assertEq(factory.nextLaunchId(), 1, "a stale fee allocated an ID");
        assertEq(regent.balanceOf(BaseBindings.GOVERNANCE_AND_REGENT_SAFE), safeBefore, "a stale fee moved REGENT");
        assertEq(regent.allowance(launcher, address(factory)), 1_000_000e18, "the stale allowance was consumed");

        // A fee change in the other direction is equally stale.
        vm.prank(governance);
        factory.setLaunchFee(1);
        vm.expectRevert(
            abi.encodeWithSelector(
                RegentsAutolaunchFactoryV1.StaleLaunchFee.selector, uint256(1), uint256(1_000_000e18)
            )
        );
        vm.prank(launcher);
        factory.launch(params);
    }

    /// @notice `FAC-025`: a fee change announces both the fee that was and the fee that is.
    function test_FAC_025_FeeUpdateEmitsTheExactPreviousAndNewFee() public {
        vm.expectEmit(true, true, true, true, address(factory));
        emit LaunchFeeUpdated(1_000_000e18, 7);
        vm.prank(governance);
        factory.setLaunchFee(7);

        vm.expectEmit(true, true, true, true, address(factory));
        emit LaunchFeeUpdated(7, 0);
        vm.prank(governance);
        factory.setLaunchFee(0);

        // Setting the same value again is a real, announced write, not a silent no-op.
        vm.expectEmit(true, true, true, true, address(factory));
        emit LaunchFeeUpdated(0, 0);
        vm.prank(governance);
        factory.setLaunchFee(0);
    }

    /// @notice `FAC-026`: a collected fee announces its launch, its payer, the Regent Safe, and the
    ///         exact amount; a zero fee announces nothing because nothing moved.
    function test_FAC_026_SuccessfulFeeCollectionEmitsTheExactCollectionEvent() public {
        RegentsAutolaunchFactoryV1.LaunchParams memory params = _params();
        _fundFee(launcher, params.expectedLaunchFee);

        vm.expectEmit(true, true, true, true, address(factory));
        emit LaunchFeeCollected(1, launcher, BaseBindings.GOVERNANCE_AND_REGENT_SAFE, 1_000_000e18);
        vm.prank(launcher);
        factory.launch(params);

        vm.prank(governance);
        factory.setLaunchFee(0);
        params.expectedLaunchFee = 0;

        vm.recordLogs();
        vm.prank(launcher);
        factory.launch(params);
        bytes32 topic = keccak256("LaunchFeeCollected(uint256,address,address,uint256)");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != topic, "a zero fee announced a collection");
        }
    }

    /// @notice `FAC-027`: the whole expected allowance is consumed by the launch and nothing is left
    ///         standing afterwards, for the launcher or for the factory.
    /// @dev Cleanup is asserted against the spenders Regent actually names. It deliberately is not
    ///      asserted universally, because the pinned UERC20 is a Solady ERC20 that reports an
    ///      unrevokable infinite allowance to the canonical Permit2 for every holder. That upstream
    ///      behaviour is proved here rather than papered over, together with the reason it cannot be
    ///      used against Regent custody: no Regent contract implements ERC-1271, so none of them can
    ///      ever sign the authorization Permit2 would need.
    function test_FAC_027_PositiveFeeLaunchLeavesNoResidualAllowance() public {
        RegentsAutolaunchFactoryV1.LaunchParams memory params = _params();
        _fundFee(launcher, params.expectedLaunchFee);
        assertEq(regent.allowance(launcher, address(factory)), 1_000_000e18, "the launcher did not approve the fee");

        Launched memory launched = _launchAs(launcher, params);

        assertEq(regent.allowance(launcher, address(factory)), 0, "a residual fee allowance survived the launch");
        assertEq(regent.balanceOf(address(factory)), 0, "the factory kept fee REGENT");
        assertEq(
            launched.subject.allowance(address(factory), address(strategy)),
            0,
            "a SUBJECT allowance survived the launch"
        );
        assertEq(
            launched.subject.allowance(address(factory), address(launched.escrow)),
            0,
            "an escrow SUBJECT allowance survived the launch"
        );
        assertEq(launched.subject.balanceOf(address(factory)), 0, "the factory kept SUBJECT");

        // The pinned token's own Permit2 behaviour, recorded rather than asserted away.
        assertEq(
            launched.subject.allowance(address(launched.escrow), PERMIT2),
            type(uint256).max,
            "the pinned UERC20 no longer forces an infinite Permit2 allowance"
        );

        // And the reason it is unusable against Regent custody: none of these can sign for it.
        bytes4 isValidSignature = bytes4(keccak256("isValidSignature(bytes32,bytes)"));
        address[5] memory custody = [
            address(factory),
            address(strategy),
            address(launched.escrow),
            address(escrowImplementation),
            address(splitterImplementation)
        ];
        for (uint256 i; i < custody.length; ++i) {
            assertFalse(_carriesSelector(custody[i].code, isValidSignature), "a Regent contract implements ERC-1271");
        }
    }
}
