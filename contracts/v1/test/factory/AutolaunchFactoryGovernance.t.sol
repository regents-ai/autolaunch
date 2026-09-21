// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {BaseBindings} from "../../src/bindings/BaseBindings.sol";
import {RegentsAutolaunchFactoryV1} from "../../src/factory/RegentsAutolaunchFactoryV1.sol";
import {AutolaunchFixture} from "../integration/AutolaunchFixture.sol";
import {Vm} from "forge-std/Vm.sol";

/// @notice `C4-I1` and `C4-I2`: governance owns exactly one switch — the new-launch pause — and a
///         launch moves no REGENT from its launcher and leaves no standing allowance behind.
contract AutolaunchFactoryGovernanceTest is AutolaunchFixture {
    event LaunchesPaused();
    event LaunchesUnpaused();

    function setUp() public {
        _deployAutolaunch();
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

        // Closing what construction already closed is the same explicit state error it always was.
        vm.expectRevert(RegentsAutolaunchFactoryV1.LaunchesAlreadyPaused.selector);
        vm.prank(governance);
        fresh.pauseLaunches();

        // A launch is refused before an ID is allocated and before anything is deployed.
        RegentsAutolaunchFactoryV1.LaunchParams memory params = _params();
        uint64 nonceBefore = vm.getNonce(address(fresh));
        vm.expectRevert(RegentsAutolaunchFactoryV1.LaunchesArePaused.selector);
        vm.prank(launcher);
        fresh.launch(params);

        assertEq(fresh.nextLaunchId(), 1, "a born-paused factory allocated an ID");
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

    /// @notice `FAC-027`: launching costs nothing. A launcher holding REGENT and granting no
    ///         allowance launches, keeps every unit, and nothing is left standing afterwards, for the
    ///         launcher or for the factory.
    /// @dev Cleanup is asserted against the spenders Regent actually names. It deliberately is not
    ///      asserted universally, because the pinned UERC20 is a Solady ERC20 that reports an
    ///      unrevokable infinite allowance to the canonical Permit2 for every holder. That upstream
    ///      behaviour is proved here rather than papered over, together with the reason it cannot be
    ///      used against Regent custody: no Regent contract implements ERC-1271, so none of them can
    ///      ever sign the authorization Permit2 would need.
    function test_FAC_027_LaunchMovesNoRegentAndLeavesNoAllowance() public {
        regent.mint(launcher, 1_000_000e18);
        assertEq(regent.allowance(launcher, address(factory)), 0, "the launcher granted an allowance");
        uint256 safeBefore = regent.balanceOf(BaseBindings.GOVERNANCE_AND_REGENT_SAFE);

        Launched memory launched = _launchAs(launcher, _params());

        assertEq(regent.balanceOf(launcher), 1_000_000e18, "the launch took REGENT from the launcher");
        assertEq(regent.allowance(launcher, address(factory)), 0, "a REGENT allowance survived the launch");
        assertEq(regent.balanceOf(address(factory)), 0, "the factory kept REGENT");
        assertEq(regent.balanceOf(BaseBindings.GOVERNANCE_AND_REGENT_SAFE), safeBefore, "the Regent Safe was paid");
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
