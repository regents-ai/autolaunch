// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {RevenueIngressAccount} from "src/revenue/RevenueIngressAccount.sol";
import {RevenueIngressFactory} from "src/revenue/RevenueIngressFactory.sol";
import {RevenueShareFactory} from "src/revenue/RevenueShareFactory.sol";
import {SubjectRegistry} from "src/revenue/SubjectRegistry.sol";
import {MintableERC20Mock} from "test/mocks/MintableERC20Mock.sol";

contract RevenueIngressFactoryTest is Test {
    bytes32 internal constant SUBJECT_ID = keccak256("subject");
    address internal constant TREASURY_SAFE = address(0x1111);
    address internal constant AGENT_TREASURY = address(0x2222);
    address internal constant REGENT_RECIPIENT = address(0x3333);

    MintableERC20Mock internal usdc;
    SubjectRegistry internal subjectRegistry;
    RevenueShareFactory internal revenueShareFactory;
    RevenueIngressFactory internal ingressFactory;

    function setUp() external {
        usdc = new MintableERC20Mock("USD Coin", "USDC");
        subjectRegistry = new SubjectRegistry(address(this));
        revenueShareFactory = new RevenueShareFactory(address(this), address(usdc), subjectRegistry);
        ingressFactory =
            new RevenueIngressFactory(address(usdc), address(subjectRegistry), address(this));
        subjectRegistry.transferOwnership(address(revenueShareFactory));
        revenueShareFactory.acceptSubjectRegistryOwnership();

        revenueShareFactory.createSubjectSplitter(
            SUBJECT_ID,
            address(0xB0B),
            TREASURY_SAFE,
            REGENT_RECIPIENT,
            100,
            1000e18,
            "Subject",
            block.chainid,
            address(0x8004),
            42
        );
    }

    function testSubjectManagerCreatesDefaultIngress() external {
        vm.prank(TREASURY_SAFE);
        address ingress =
            ingressFactory.createIngressAccount(SUBJECT_ID, "default-usdc-ingress", true);

        assertEq(ingressFactory.defaultIngressOfSubject(SUBJECT_ID), ingress);
        assertEq(ingressFactory.ingressAccountCount(SUBJECT_ID), 1);
        assertTrue(ingressFactory.isIngressAccount(ingress));
        assertEq(RevenueIngressAccount(payable(ingress)).owner(), TREASURY_SAFE);
        assertEq(RevenueIngressAccount(payable(ingress)).subjectId(), SUBJECT_ID);
    }

    function testInactiveSubjectBlocksIngressCreationAndDefaultSelection() external {
        vm.prank(TREASURY_SAFE);
        address ingressA =
            ingressFactory.createIngressAccount(SUBJECT_ID, "default-usdc-ingress", true);

        vm.prank(TREASURY_SAFE);
        address ingressB = ingressFactory.createIngressAccount(SUBJECT_ID, "backup-ingress", false);

        address activeSplitter = revenueShareFactory.splitterOfSubject(SUBJECT_ID);
        vm.prank(TREASURY_SAFE);
        subjectRegistry.updateSubject(SUBJECT_ID, activeSplitter, TREASURY_SAFE, false, "Subject");

        assertEq(ingressFactory.defaultIngressOfSubject(SUBJECT_ID), ingressA);

        vm.prank(TREASURY_SAFE);
        vm.expectRevert("SUBJECT_INACTIVE");
        ingressFactory.createIngressAccount(SUBJECT_ID, "late-ingress", false);

        vm.prank(TREASURY_SAFE);
        vm.expectRevert("SUBJECT_INACTIVE");
        ingressFactory.setDefaultIngress(SUBJECT_ID, ingressB);
    }
}
