// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {RevenueShareFactory} from "src/revenue/RevenueShareFactory.sol";
import {SubjectRegistry} from "src/revenue/SubjectRegistry.sol";
import {MintableBurnableERC20Mock} from "test/mocks/MintableBurnableERC20Mock.sol";

contract RevenueShareFactoryTest is Test {
    address internal constant OWNER = address(0xA11CE);
    address internal constant CREATOR = address(0xB0B);
    address internal constant ATTACKER = address(0xBAD);
    address internal constant USDC = address(0x2222);
    address internal constant TREASURY_SAFE = address(0xCAFE);
    address internal constant TREASURY = address(0x7000);
    address internal constant PROTOCOL = address(0x9000);
    bytes32 internal constant SUBJECT_ID = keccak256("factory-subject");

    SubjectRegistry internal subjectRegistry;
    RevenueShareFactory internal factory;
    MintableBurnableERC20Mock internal stakeToken;

    function setUp() external {
        subjectRegistry = new SubjectRegistry(OWNER);
        factory = new RevenueShareFactory(OWNER, USDC, subjectRegistry);
        stakeToken = new MintableBurnableERC20Mock("Agent", "AGENT", 18);
        stakeToken.mint(address(this), 1000 ether);

        vm.prank(OWNER);
        subjectRegistry.transferOwnership(address(factory));
        factory.acceptSubjectRegistryOwnership();
    }

    function testRejectsUnauthorizedSplitterCreation() external {
        vm.prank(ATTACKER);
        vm.expectRevert("ONLY_AUTHORIZED_CREATOR");
        factory.createSubjectSplitter(
            SUBJECT_ID,
            address(stakeToken),
            TREASURY_SAFE,
            PROTOCOL,
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
            TREASURY_SAFE,
            PROTOCOL,
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
        vm.expectRevert("IDENTITY_REGISTRY_ZERO");
        factory.createSubjectSplitter(
            SUBJECT_ID,
            address(stakeToken),
            TREASURY_SAFE,
            PROTOCOL,
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
        vm.expectRevert("AGENT_SAFE_ZERO");
        factory.createSubjectSplitter(
            SUBJECT_ID,
            address(stakeToken),
            address(0),
            PROTOCOL,
            1000 ether,
            "Agent",
            0,
            address(0),
            0
        );

        vm.prank(CREATOR);
        vm.expectRevert("PROTOCOL_RECIPIENT_ZERO");
        factory.createSubjectSplitter(
            SUBJECT_ID,
            address(stakeToken),
            TREASURY_SAFE,
            address(0),
            1000 ether,
            "Agent",
            0,
            address(0),
            0
        );
    }

    function testOwnerCanTransferSubjectRegistryOwnershipOutOfFactory() external {
        vm.prank(OWNER);
        factory.transferSubjectRegistryOwnership(TREASURY);

        assertEq(subjectRegistry.pendingOwner(), TREASURY);

        vm.prank(TREASURY);
        subjectRegistry.acceptOwnership();

        assertEq(subjectRegistry.owner(), TREASURY);
    }
}
