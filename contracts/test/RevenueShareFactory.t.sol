// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {RevenueShareFactory} from "src/revenue/RevenueShareFactory.sol";
import {RevenueShareSplitterV2Deployer} from "src/revenue/RevenueShareSplitterV2Deployer.sol";
import {SubjectRegistry} from "src/revenue/SubjectRegistry.sol";
import {MintableBurnableERC20Mock} from "test/mocks/MintableBurnableERC20Mock.sol";
import {MockRegentRevenueFeeRouter} from "test/mocks/MockRegentRevenueFeeRouter.sol";

contract RevenueShareFactoryTest is Test {
    address internal constant OWNER = address(0xA11CE);
    address internal constant CREATOR = address(0xB0B);
    address internal constant ATTACKER = address(0xBAD);
    address internal constant USDC = address(0x2222);
    address internal constant INGRESS_FACTORY = address(0x3333);
    address internal constant TREASURY_SAFE = address(0xCAFE);
    bytes32 internal constant SUBJECT_ID = keccak256("factory-subject");

    SubjectRegistry internal subjectRegistry;
    RevenueShareFactory internal factory;
    RevenueShareSplitterV2Deployer internal splitterDeployer;
    MintableBurnableERC20Mock internal stakeToken;
    MockRegentRevenueFeeRouter internal feeRouter;

    function setUp() external {
        subjectRegistry = new SubjectRegistry(OWNER);
        feeRouter = new MockRegentRevenueFeeRouter(USDC, address(0x8888));
        splitterDeployer = new RevenueShareSplitterV2Deployer();
        factory = new RevenueShareFactory(
            OWNER, USDC, subjectRegistry, address(feeRouter), address(splitterDeployer)
        );
        stakeToken = new MintableBurnableERC20Mock("Agent", "AGENT", 18);
        stakeToken.mint(address(this), 1000 ether);

        vm.prank(OWNER);
        subjectRegistry.setAuthorizedRegistrar(address(factory), true);
    }

    function testRejectsUnauthorizedSplitterCreation() external {
        vm.prank(ATTACKER);
        vm.expectRevert(RevenueShareFactory.OnlyAuthorizedCreator.selector);
        factory.createSubjectSplitter(
            SUBJECT_ID,
            address(stakeToken),
            INGRESS_FACTORY,
            TREASURY_SAFE,
            address(feeRouter),
            1000 ether,
            "Agent",
            1,
            address(0x8004),
            42
        );
    }

    function testAuthorizedCreatorCanCreateSplitter() external {
        vm.prank(OWNER);
        factory.setAuthorizedCreator(CREATOR, true);

        vm.prank(CREATOR);
        address splitter = factory.createSubjectSplitter(
            SUBJECT_ID,
            address(stakeToken),
            INGRESS_FACTORY,
            TREASURY_SAFE,
            address(feeRouter),
            1000 ether,
            "Agent",
            1,
            address(0x8004),
            42
        );

        assertTrue(splitter != address(0));
        assertEq(factory.splitterOfSubject(SUBJECT_ID), splitter);
        assertEq(subjectRegistry.subjectOfStakeToken(address(stakeToken)), SUBJECT_ID);
        assertEq(subjectRegistry.subjectForIdentity(1, address(0x8004), 42), SUBJECT_ID);
    }

    function testRejectsMalformedIdentityLinkInputs() external {
        vm.prank(OWNER);
        factory.setAuthorizedCreator(CREATOR, true);

        vm.prank(CREATOR);
        vm.expectRevert(RevenueShareFactory.IdentityRegistryZero.selector);
        factory.createSubjectSplitter(
            SUBJECT_ID,
            address(stakeToken),
            INGRESS_FACTORY,
            TREASURY_SAFE,
            address(feeRouter),
            1000 ether,
            "Agent",
            1,
            address(0),
            42
        );
    }

    function testRejectsZeroRecipients() external {
        vm.prank(OWNER);
        factory.setAuthorizedCreator(CREATOR, true);

        vm.prank(CREATOR);
        vm.expectRevert(RevenueShareFactory.AgentSafeZero.selector);
        factory.createSubjectSplitter(
            SUBJECT_ID,
            address(stakeToken),
            INGRESS_FACTORY,
            address(0),
            address(feeRouter),
            1000 ether,
            "Agent",
            0,
            address(0),
            0
        );

        vm.prank(CREATOR);
        vm.expectRevert(RevenueShareFactory.FeeRouterMismatch.selector);
        factory.createSubjectSplitter(
            SUBJECT_ID,
            address(stakeToken),
            INGRESS_FACTORY,
            TREASURY_SAFE,
            address(0),
            1000 ether,
            "Agent",
            0,
            address(0),
            0
        );
    }
}
