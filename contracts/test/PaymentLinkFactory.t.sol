// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {PaymentLinkFactory} from "src/revenue/PaymentLinkFactory.sol";
import {PaymentLinkReceiver} from "src/revenue/PaymentLinkReceiver.sol";
import {RevenueShareFactory} from "src/revenue/RevenueShareFactory.sol";
import {RevenueShareSplitterV2} from "src/revenue/RevenueShareSplitterV2.sol";
import {RevenueShareSplitterV2Deployer} from "src/revenue/RevenueShareSplitterV2Deployer.sol";
import {SubjectRegistry} from "src/revenue/SubjectRegistry.sol";
import {MintableERC20Mock} from "test/mocks/MintableERC20Mock.sol";
import {MockRegentStakingRevenueRouter} from "test/mocks/MockRegentStakingRevenueRouter.sol";

contract PaymentLinkFactoryTest is Test {
    address internal constant OWNER = address(0xA11CE);
    address internal constant CREATOR = address(0xB0B);
    address internal constant PAYER = address(0xCAFE);
    address internal constant TREASURY = address(0x1234);
    address internal constant INGRESS_FACTORY = address(0x3333);
    bytes32 internal constant SUBJECT_ID = keccak256("payment-link-subject");

    MintableERC20Mock internal usdc;
    MintableERC20Mock internal stakeToken;
    SubjectRegistry internal subjectRegistry;
    RevenueShareFactory internal revenueShareFactory;
    RevenueShareSplitterV2Deployer internal splitterDeployer;
    MockRegentStakingRevenueRouter internal feeRouter;
    PaymentLinkFactory internal paymentLinkFactory;
    address internal splitter;

    function setUp() external {
        usdc = new MintableERC20Mock("USD Coin", "USDC");
        stakeToken = new MintableERC20Mock("Agent", "AGENT");
        subjectRegistry = new SubjectRegistry(OWNER);
        feeRouter = new MockRegentStakingRevenueRouter(address(usdc), address(0x8888));
        splitterDeployer = new RevenueShareSplitterV2Deployer();
        revenueShareFactory = new RevenueShareFactory(
            OWNER, address(usdc), subjectRegistry, address(feeRouter), address(splitterDeployer)
        );
        paymentLinkFactory = new PaymentLinkFactory(OWNER, address(usdc), address(subjectRegistry));

        vm.startPrank(OWNER);
        subjectRegistry.setAuthorizedRegistrar(address(revenueShareFactory), true);
        revenueShareFactory.setAuthorizedCreator(CREATOR, true);
        vm.stopPrank();

        vm.prank(CREATOR);
        splitter = revenueShareFactory.createSubjectSplitter(
            SUBJECT_ID,
            address(stakeToken),
            INGRESS_FACTORY,
            TREASURY,
            address(feeRouter),
            1_000_000e18,
            "Agent",
            0,
            address(0),
            0
        );
    }

    function testCreatesReceiverAndSweepsSimpleTransfers() external {
        vm.prank(CREATOR);
        address receiverAddress =
            paymentLinkFactory.createPaymentLink(SUBJECT_ID, "Sponsor", keccak256("sponsor"));

        PaymentLinkReceiver receiver = PaymentLinkReceiver(payable(receiverAddress));
        assertEq(receiver.destination(), splitter);
        assertTrue(paymentLinkFactory.isPaymentLink(receiverAddress));
        assertEq(paymentLinkFactory.paymentLinkForSubjectAt(SUBJECT_ID, 0), receiverAddress);
        assertEq(paymentLinkFactory.paymentLinkForCreatorAt(CREATOR, 0), receiverAddress);

        usdc.mint(PAYER, 100e6);
        vm.prank(PAYER);
        usdc.transfer(receiverAddress, 100e6);

        receiver.sweepUSDC(bytes32(0));

        assertEq(usdc.balanceOf(receiverAddress), 0);
        assertEq(RevenueShareSplitterV2(splitter).directDepositUsdc(), 100e6);
    }

    function testDepositUSDCRecordsMetadataAndForwardsFullBalance() external {
        vm.prank(CREATOR);
        PaymentLinkReceiver receiver = PaymentLinkReceiver(
            payable(paymentLinkFactory.createPaymentLink(
                    SUBJECT_ID, "Invoice", keccak256("invoice")
                ))
        );

        usdc.mint(PAYER, 25e6);
        vm.startPrank(PAYER);
        usdc.approve(address(receiver), 25e6);
        (uint256 received, uint256 recognized) = receiver.depositUSDC(25e6, keccak256("ref-1"));
        vm.stopPrank();

        assertEq(received, 25e6);
        assertEq(recognized, 25e6);
        assertEq(usdc.balanceOf(address(receiver)), 0);
        assertEq(RevenueShareSplitterV2(splitter).directDepositUsdc(), 25e6);
    }

    function testReceiverFollowsSubjectSplitterRotation() external {
        vm.prank(CREATOR);
        PaymentLinkReceiver receiver = PaymentLinkReceiver(
            payable(paymentLinkFactory.createPaymentLink(
                    SUBJECT_ID, "Rotating", keccak256("rotating")
                ))
        );

        RevenueShareSplitterV2 nextSplitter = new RevenueShareSplitterV2(
            address(stakeToken),
            address(usdc),
            INGRESS_FACTORY,
            address(subjectRegistry),
            SUBJECT_ID,
            TREASURY,
            address(feeRouter),
            1_000_000e18,
            "Agent v2",
            TREASURY
        );

        vm.prank(TREASURY);
        subjectRegistry.updateSubject(SUBJECT_ID, address(nextSplitter), TREASURY, true, "Agent v2");

        assertEq(receiver.destination(), address(nextSplitter));

        usdc.mint(PAYER, 10e6);
        vm.startPrank(PAYER);
        usdc.approve(address(receiver), 10e6);
        receiver.depositUSDC(10e6, keccak256("ref-2"));
        vm.stopPrank();

        assertEq(RevenueShareSplitterV2(splitter).directDepositUsdc(), 0);
        assertEq(nextSplitter.directDepositUsdc(), 10e6);
    }

    function testRejectsEthAndProtectsUsdcFromRescue() external {
        vm.prank(CREATOR);
        PaymentLinkReceiver receiver = PaymentLinkReceiver(
            payable(paymentLinkFactory.createPaymentLink(SUBJECT_ID, "No ETH", keccak256("no-eth")))
        );

        vm.deal(PAYER, 1 ether);
        vm.prank(PAYER);
        (bool success,) = address(receiver).call{value: 1 ether}("");
        assertFalse(success);

        usdc.mint(address(receiver), 1e6);
        vm.prank(CREATOR);
        vm.expectRevert("PROTECTED_TOKEN");
        receiver.rescueUnsupportedToken(address(usdc), 1e6, CREATOR);
    }

    function testRejectsLongLabels() external {
        vm.expectRevert("LABEL_TOO_LONG");
        paymentLinkFactory.createPaymentLink(SUBJECT_ID, _longLabel(), keccak256("long"));
    }

    function _longLabel() internal pure returns (string memory) {
        return "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    }
}
