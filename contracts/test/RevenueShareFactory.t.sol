// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {SimpleMintableERC20} from "src/SimpleMintableERC20.sol";
import {RevenueShareFactory} from "src/revenue/RevenueShareFactory.sol";
import {SubjectRegistry} from "src/revenue/SubjectRegistry.sol";

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
    SimpleMintableERC20 internal stakeToken;

    function setUp() external {
        subjectRegistry = new SubjectRegistry(OWNER);
        factory = new RevenueShareFactory(OWNER, USDC, subjectRegistry);
        stakeToken = new SimpleMintableERC20(
            "Agent", "AGENT", 18, address(this), 1000 ether, address(this)
        );

        vm.prank(OWNER);
        subjectRegistry.transferOwnership(address(factory));
    }

    function testRejectsUnauthorizedSplitterCreation() external {
        vm.prank(ATTACKER);
        vm.expectRevert("ONLY_AUTHORIZED_CREATOR");
        factory.createSubjectSplitter(
            SUBJECT_ID,
            address(stakeToken),
            TREASURY,
            PROTOCOL,
            TREASURY_SAFE,
            TREASURY_SAFE,
            1,
            TREASURY_SAFE,
            100,
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
            TREASURY,
            PROTOCOL,
            TREASURY_SAFE,
            TREASURY_SAFE,
            1,
            TREASURY_SAFE,
            100,
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
}
