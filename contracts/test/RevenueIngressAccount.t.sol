// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {RevenueIngressAccount} from "src/revenue/RevenueIngressAccount.sol";
import {RevenueIngressFactory} from "src/revenue/RevenueIngressFactory.sol";
import {RevenueShareFactory} from "src/revenue/RevenueShareFactory.sol";
import {RevenueShareSplitterV2} from "src/revenue/RevenueShareSplitterV2.sol";
import {RevenueShareSplitterV2Deployer} from "src/revenue/RevenueShareSplitterV2Deployer.sol";
import {SubjectRegistry} from "src/revenue/SubjectRegistry.sol";
import {MintableERC20Mock} from "test/mocks/MintableERC20Mock.sol";
import {MockRegentStakingRevenueRouter} from "test/mocks/MockRegentStakingRevenueRouter.sol";

contract RevenueIngressAccountTest is Test {
    bytes32 internal constant SUBJECT_ID = keccak256("subject");
    address internal constant TREASURY_SAFE = address(0x1111);
    address internal constant AGENT_TREASURY = address(0x2222);

    MintableERC20Mock internal usdc;
    MintableERC20Mock internal stakeToken;
    SubjectRegistry internal subjectRegistry;
    RevenueShareFactory internal revenueShareFactory;
    RevenueIngressFactory internal ingressFactory;
    RevenueShareSplitterV2Deployer internal splitterDeployer;
    RevenueShareSplitterV2 internal splitter;
    RevenueIngressAccount internal ingress;
    MockRegentStakingRevenueRouter internal feeRouter;

    function setUp() external {
        usdc = new MintableERC20Mock("USD Coin", "USDC");
        stakeToken = new MintableERC20Mock("Agent", "AGENT");
        stakeToken.mint(address(this), 1000e18);
        subjectRegistry = new SubjectRegistry(address(this));
        feeRouter = new MockRegentStakingRevenueRouter(address(usdc), address(0x8888));
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

        address splitterAddress = revenueShareFactory.createSubjectSplitter(
            SUBJECT_ID,
            address(stakeToken),
            address(ingressFactory),
            TREASURY_SAFE,
            address(feeRouter),
            1000e18,
            "Subject",
            block.chainid,
            address(0x8004),
            42
        );
        splitter = RevenueShareSplitterV2(splitterAddress);
        vm.prank(TREASURY_SAFE);
        ingress = RevenueIngressAccount(
            payable(ingressFactory.createIngressAccount(SUBJECT_ID, "default-usdc-ingress", true))
        );
    }

    function testSweepRecognizesRevenueInsideSplitter() external {
        usdc.mint(address(ingress), 1000e18);

        (uint256 balance, uint256 recognized, bytes32 sourceRef) = ingress.sweepUSDC();

        assertEq(balance, 1000e18);
        assertEq(recognized, 1000e18);
        assertTrue(sourceRef != bytes32(0));
        assertEq(usdc.balanceOf(address(ingress)), 0);
        assertEq(usdc.balanceOf(address(splitter)), 900e18);
        assertEq(usdc.balanceOf(address(feeRouter)), 100e18);
        assertEq(feeRouter.totalUsdcProcessed(), 100e18);
        assertEq(splitter.treasuryResidualUsdc(), 900e18);
        assertEq(splitter.protocolFeeUsdc(), 100e18);
    }

    function testDepositUSDCRecordsAccountingTag() external {
        bytes32 sourceTag = bytes32("invoice-1");
        usdc.mint(address(this), 1000e18);
        usdc.approve(address(ingress), 1000e18);

        uint256 received = ingress.depositUSDC(1000e18, sourceTag);

        assertEq(received, 1000e18);
        assertEq(usdc.balanceOf(address(ingress)), 1000e18);
        assertEq(ingress.accountingTagCount(), 1);

        (uint256 blockNumber, address depositor, uint256 amount, bytes32 tag) =
            ingress.accountingTagAt(0);
        assertEq(blockNumber, block.number);
        assertEq(depositor, address(this));
        assertEq(amount, 1000e18);
        assertEq(tag, sourceTag);
    }

    function testAccountingTagsSinceBlockPaginatesAndFilters() external {
        usdc.mint(address(this), 6e18);
        usdc.approve(address(ingress), 6e18);

        ingress.depositUSDC(1e18, bytes32("old"));
        uint256 fromBlock = block.number + 1;
        vm.roll(fromBlock);
        ingress.depositUSDC(2e18, bytes32("new-1"));
        vm.roll(fromBlock + 1);
        ingress.depositUSDC(3e18, bytes32("new-2"));

        (RevenueIngressAccount.AccountingTag[] memory first, uint256 nextCursor, bool hasMore) =
            ingress.accountingTagsSinceBlock(fromBlock, 0, 1);
        assertEq(first.length, 1);
        assertEq(first[0].amount, 2e18);
        assertEq(first[0].sourceTag, bytes32("new-1"));
        assertEq(nextCursor, 2);
        assertTrue(hasMore);

        (RevenueIngressAccount.AccountingTag[] memory second, uint256 finalCursor, bool more) =
            ingress.accountingTagsSinceBlock(fromBlock, nextCursor, 100);
        assertEq(second.length, 1);
        assertEq(second[0].amount, 3e18);
        assertEq(second[0].sourceTag, bytes32("new-2"));
        assertEq(finalCursor, 3);
        assertFalse(more);
    }

    function testAccountingTagsRejectInvalidPagination() external {
        uint256 maxPageSize = ingress.MAX_ACCOUNTING_TAG_PAGE_SIZE();

        vm.expectRevert("LIMIT_ZERO");
        ingress.accountingTagsSinceBlock(0, 0, 0);

        vm.expectRevert("LIMIT_TOO_HIGH");
        ingress.accountingTagsSinceBlock(0, 0, maxPageSize + 1);

        vm.expectRevert("CURSOR_OOB");
        ingress.accountingTagsSinceBlock(0, 1, 1);
    }

    function testOwnerCanRescueNonUsdcToken() external {
        MintableERC20Mock other = new MintableERC20Mock("Other", "OTHER");
        other.mint(address(ingress), 55e18);

        vm.prank(TREASURY_SAFE);
        ingress.rescueUnsupportedToken(address(other), 55e18, address(0x5555));

        assertEq(other.balanceOf(address(0x5555)), 55e18);
    }

    function testOwnerCanRescueForcedEth() external {
        vm.deal(address(ingress), 1 ether);

        vm.prank(TREASURY_SAFE);
        ingress.rescueNative(address(0x7777));

        assertEq(address(ingress).balance, 0);
        assertEq(address(0x7777).balance, 1 ether);
    }

    function testRescueBlocksUsdc() external {
        vm.prank(TREASURY_SAFE);
        vm.expectRevert("PROTECTED_TOKEN");
        ingress.rescueUnsupportedToken(address(usdc), 1, TREASURY_SAFE);
    }

    function testSecondSweepRevertsWhenNothingRemains() external {
        usdc.mint(address(ingress), 1000e18);
        ingress.sweepUSDC();

        vm.expectRevert("NOTHING_TO_SWEEP");
        ingress.sweepUSDC();
    }

    function testSweepRevertsWhenSubjectIsInactive() external {
        address activeSplitter = revenueShareFactory.splitterOfSubject(SUBJECT_ID);
        vm.prank(TREASURY_SAFE);
        subjectRegistry.updateSubject(SUBJECT_ID, activeSplitter, TREASURY_SAFE, false, "Subject");

        usdc.mint(address(ingress), 1000e18);

        vm.expectRevert("SUBJECT_INACTIVE");
        ingress.sweepUSDC();
    }
}
