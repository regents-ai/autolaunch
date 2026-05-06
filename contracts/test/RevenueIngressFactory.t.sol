// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {RevenueIngressAccount} from "src/revenue/RevenueIngressAccount.sol";
import {RevenueIngressFactory} from "src/revenue/RevenueIngressFactory.sol";
import {RevenueShareFactory} from "src/revenue/RevenueShareFactory.sol";
import {RevenueShareSplitterV2Deployer} from "src/revenue/RevenueShareSplitterV2Deployer.sol";
import {SubjectRegistry} from "src/revenue/SubjectRegistry.sol";
import {MintableERC20Mock} from "test/mocks/MintableERC20Mock.sol";
import {MockRegentRevenueFeeRouter} from "test/mocks/MockRegentRevenueFeeRouter.sol";

contract RevenueIngressFactoryTest is Test {
    bytes32 internal constant SUBJECT_ID = keccak256("subject");
    address internal constant TREASURY_SAFE = address(0x1111);
    address internal constant AGENT_TREASURY = address(0x2222);
    address internal constant REGENT_RECIPIENT = address(0x3333);

    MintableERC20Mock internal usdc;
    SubjectRegistry internal subjectRegistry;
    RevenueShareFactory internal revenueShareFactory;
    RevenueShareSplitterV2Deployer internal splitterDeployer;
    RevenueIngressFactory internal ingressFactory;
    MockRegentRevenueFeeRouter internal feeRouter;

    function setUp() external {
        usdc = new MintableERC20Mock("USD Coin", "USDC");
        subjectRegistry = new SubjectRegistry(address(this));
        feeRouter = new MockRegentRevenueFeeRouter(address(usdc), address(0x8888));
        splitterDeployer = new RevenueShareSplitterV2Deployer();
        revenueShareFactory = new RevenueShareFactory(
            address(this),
            address(usdc),
            subjectRegistry,
            address(feeRouter),
            address(splitterDeployer)
        );
        ingressFactory =
            new RevenueIngressFactory(address(usdc), address(subjectRegistry), address(this));
        subjectRegistry.setAuthorizedRegistrar(address(revenueShareFactory), true);

        revenueShareFactory.createSubjectSplitter(
            SUBJECT_ID,
            address(0xB0B),
            address(ingressFactory),
            TREASURY_SAFE,
            address(feeRouter),
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
