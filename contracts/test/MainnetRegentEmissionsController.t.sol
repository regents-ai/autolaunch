// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {
    MainnetRegentEmissionsController,
    ISubjectRegistryMinimal
} from "src/revenue/MainnetRegentEmissionsController.sol";
import {RevenueShareSplitter} from "src/revenue/RevenueShareSplitter.sol";
import {SubjectRegistry} from "src/revenue/SubjectRegistry.sol";
import {SimpleMintableERC20} from "src/SimpleMintableERC20.sol";

contract MainnetRegentEmissionsControllerTest is Test {
    uint256 internal constant EPOCH_LENGTH = 3 days;
    uint256 internal constant GENESIS_TS = 1000;
    uint256 internal constant CHAIN_ID = 1;
    uint256 internal constant STARTING_REGENT = 1_000_000 ether;
    uint256 internal constant STARTING_USDC = 1_000_000_000_000;
    bytes32 internal constant SUBJECT_ID = keccak256("subject-1");
    bytes32 internal constant POOL_ID = keccak256("launch-pool");

    SimpleMintableERC20 internal regent;
    SimpleMintableERC20 internal usdc;
    SimpleMintableERC20 internal stakeToken;
    SubjectRegistry internal subjectRegistry;
    MainnetRegentEmissionsController internal controller;
    MockProtocolReserveSplitter internal splitter;
    MockLaunchFeeVaultRegent internal launchFeeVault;

    address internal constant TREASURY_SAFE = address(0xBEEF);
    address internal constant EMISSION_RECIPIENT = address(0xCAFE);
    address internal constant UPDATED_EMISSION_RECIPIENT = address(0xABCD);
    address internal constant USDC_TREASURY = address(0xD00D);

    function setUp() external {
        regent = new SimpleMintableERC20("Regent", "REGENT", 18, address(this), 0, address(this));
        usdc = new SimpleMintableERC20("USDC", "USDC", 6, address(this), 0, address(this));
        stakeToken = new SimpleMintableERC20("Stake", "STK", 18, address(this), 0, address(this));

        splitter = new MockProtocolReserveSplitter(address(usdc));
        launchFeeVault = new MockLaunchFeeVaultRegent(address(usdc));

        subjectRegistry = new SubjectRegistry(address(this));
        subjectRegistry.createSubject(
            SUBJECT_ID, address(stakeToken), address(splitter), TREASURY_SAFE, true, "Test Subject"
        );

        _setEmissionRecipient(EMISSION_RECIPIENT);

        controller = new MainnetRegentEmissionsController(
            address(regent),
            address(usdc),
            ISubjectRegistryMinimal(address(subjectRegistry)),
            USDC_TREASURY,
            GENESIS_TS,
            EPOCH_LENGTH,
            CHAIN_ID,
            address(this)
        );

        regent.mint(address(this), STARTING_REGENT);
        usdc.mint(address(this), STARTING_USDC);
        regent.approve(address(controller), type(uint256).max);
        usdc.approve(address(controller), type(uint256).max);
    }

    function testCreditPublishAndClaimUsesSnapshottedRecipient() external {
        _warpToEpochOne();

        uint32 epoch = controller.creditUsdc(
            SUBJECT_ID, 42_500_000, keccak256("credit-1"), bytes32("bridge"), keccak256("source")
        );
        assertEq(epoch, 1);
        assertEq(controller.subjectRevenueUsdc(1, SUBJECT_ID), 42_500_000);
        assertEq(controller.subjectRecipientSnapshot(1, SUBJECT_ID), EMISSION_RECIPIENT);

        _setEmissionRecipient(UPDATED_EMISSION_RECIPIENT);

        vm.warp(GENESIS_TS + EPOCH_LENGTH + 1);
        controller.publishEpochEmission(1, 1000 ether);

        uint256 claimable = controller.previewClaimable(1, SUBJECT_ID);
        assertEq(claimable, 1000 ether);

        controller.claim(1, SUBJECT_ID);
        assertEq(regent.balanceOf(EMISSION_RECIPIENT), 1000 ether);
        assertEq(regent.balanceOf(UPDATED_EMISSION_RECIPIENT), 0);
    }

    function testPullSplitterAndLaunchVaultUsdcCreditsEpochRevenue() external {
        _warpToEpochOne();

        usdc.mint(address(splitter), 12_000_000);
        usdc.mint(address(launchFeeVault), 8_000_000);

        (uint32 splitterEpoch, uint256 splitterReceived) =
            controller.pullSplitterUsdc(SUBJECT_ID, 12_000_000, keccak256("splitter"));
        assertEq(splitterEpoch, 1);
        assertEq(splitterReceived, 12_000_000);

        vm.prank(TREASURY_SAFE);
        controller.configureLaunchUsdcRoute(SUBJECT_ID, address(launchFeeVault), POOL_ID, true);

        (uint32 vaultEpoch, uint256 vaultReceived) =
            controller.pullLaunchVaultUsdc(SUBJECT_ID, 8_000_000, keccak256("vault"));
        assertEq(vaultEpoch, 1);
        assertEq(vaultReceived, 8_000_000);

        assertEq(controller.subjectRevenueUsdc(1, SUBJECT_ID), 20_000_000);
        assertEq(usdc.balanceOf(address(controller)), 20_000_000);
    }

    function testPullSplitterUsdcWorksWithRealRevenueShareSplitter() external {
        bytes32 realSubjectId = keccak256("subject-real-splitter");
        SimpleMintableERC20 realStakeToken =
            new SimpleMintableERC20("Real Stake", "RSTK", 18, address(this), 0, address(this));
        realStakeToken.mint(address(this), 1000 ether);

        RevenueShareSplitter realSplitter = new RevenueShareSplitter(
            address(realStakeToken),
            address(usdc),
            TREASURY_SAFE,
            address(controller),
            100,
            "Real Splitter",
            address(this)
        );

        subjectRegistry.createSubject(
            realSubjectId,
            address(realStakeToken),
            address(realSplitter),
            TREASURY_SAFE,
            true,
            "Real Subject"
        );
        vm.prank(TREASURY_SAFE);
        subjectRegistry.setEmissionRecipient(realSubjectId, CHAIN_ID, EMISSION_RECIPIENT);

        _warpToEpochOne();
        usdc.mint(address(this), 100_000_000);
        usdc.approve(address(realSplitter), 100_000_000);
        realSplitter.depositUSDC(100_000_000, bytes32("direct"), bytes32("real"));

        uint256 reserve = realSplitter.protocolReserveUsdc();
        assertEq(reserve, 1_000_000);

        (uint32 epoch, uint256 received) =
            controller.pullSplitterUsdc(realSubjectId, reserve, keccak256("real-splitter"));

        assertEq(epoch, 1);
        assertEq(received, reserve);
        assertEq(controller.subjectRevenueUsdc(1, realSubjectId), reserve);
        assertEq(usdc.balanceOf(address(controller)), reserve);
    }

    function _setEmissionRecipient(address recipient) internal {
        vm.prank(TREASURY_SAFE);
        subjectRegistry.setEmissionRecipient(SUBJECT_ID, CHAIN_ID, recipient);
    }

    function _warpToEpochOne() internal {
        vm.warp(GENESIS_TS + 1);
    }
}

contract MockProtocolReserveSplitter {
    address internal immutable usdc;

    constructor(address usdc_) {
        usdc = usdc_;
    }

    function withdrawProtocolReserve(address rewardToken, uint256 amount, address recipient)
        external
    {
        require(rewardToken == usdc, "TOKEN_MISMATCH");
        SimpleMintableERC20(usdc).transfer(recipient, amount);
    }
}

contract MockLaunchFeeVaultRegent {
    address internal immutable usdc;

    constructor(address usdc_) {
        usdc = usdc_;
    }

    function withdrawRegentShare(bytes32, address currency, uint256 amount, address recipient)
        external
    {
        require(currency == usdc, "TOKEN_MISMATCH");
        SimpleMintableERC20(usdc).transfer(recipient, amount);
    }
}
