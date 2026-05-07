// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {RegentRevenueStaking} from "src/revenue/RegentRevenueStaking.sol";
import {RegentStakingRevenueRouter} from "src/revenue/RegentStakingRevenueRouter.sol";
import {SubjectRegistry} from "src/revenue/SubjectRegistry.sol";
import {MintableERC20Mock} from "test/mocks/MintableERC20Mock.sol";

contract RegentStakingRevenueRouterTest is Test {
    bytes32 internal constant SUBJECT_ID = keccak256("subject");
    address internal constant OWNER = address(0xA11CE);
    address internal constant TREASURY = address(0x1111);
    address internal constant OTHER_TREASURY = address(0x2222);
    address internal constant OTHER_SPLITTER = address(0xDEAD);
    uint256 internal constant USDC_FEE = 100e6;

    MintableERC20Mock internal usdc;
    MintableERC20Mock internal regent;
    SubjectRegistry internal subjectRegistry;
    RegentRevenueStaking internal staking;
    RegentStakingRevenueRouter internal router;

    function setUp() external {
        usdc = new MintableERC20Mock("USD Coin", "USDC");
        regent = new MintableERC20Mock("REGENT", "REGENT");
        subjectRegistry = new SubjectRegistry(OWNER);
        staking =
            new RegentRevenueStaking(address(regent), address(usdc), TREASURY, 1_000_000e18, OWNER);
        router = new RegentStakingRevenueRouter(
            OWNER, address(usdc), address(subjectRegistry), address(staking)
        );

        vm.prank(OWNER);
        subjectRegistry.createSubject(
            SUBJECT_ID, address(0xBEEF), address(this), TREASURY, true, "Subject"
        );
    }

    function testRouterAcceptsFeeOnlyFromRegisteredSubjectSplitter() external {
        usdc.mint(address(router), USDC_FEE);

        vm.prank(OTHER_SPLITTER);
        vm.expectRevert("ONLY_SUBJECT_SPLITTER");
        router.processProtocolFee(SUBJECT_ID, TREASURY, USDC_FEE, bytes32("source"));
    }

    function testRouterRejectsTreasuryMismatch() external {
        usdc.mint(address(router), USDC_FEE);

        vm.expectRevert("TREASURY_MISMATCH");
        router.processProtocolFee(SUBJECT_ID, OTHER_TREASURY, USDC_FEE, bytes32("source"));
    }

    function testRouterRejectsZeroAmount() external {
        vm.expectRevert("AMOUNT_ZERO");
        router.processProtocolFee(SUBJECT_ID, TREASURY, 0, bytes32("source"));
    }

    function testRouterRejectsSettlementLargerThanMax() external {
        uint256 tooLarge = router.maxUsdcPerSettlement() + 1;
        usdc.mint(address(router), tooLarge);

        vm.expectRevert("SETTLEMENT_TOO_LARGE");
        router.processProtocolFee(SUBJECT_ID, TREASURY, tooLarge, bytes32("source"));
    }

    function testRouterRejectsStakingUsdcMismatch() external {
        MintableERC20Mock otherUsdc = new MintableERC20Mock("Other USD", "oUSD");

        vm.expectRevert("STAKING_USDC_MISMATCH");
        new RegentStakingRevenueRouter(
            OWNER, address(otherUsdc), address(subjectRegistry), address(staking)
        );
    }

    function testRouterDepositsUsdcIntoRegentRevenueStaking() external {
        usdc.mint(address(router), USDC_FEE);

        uint256 deposited =
            router.processProtocolFee(SUBJECT_ID, TREASURY, USDC_FEE, bytes32("source"));

        assertEq(deposited, USDC_FEE);
        assertEq(usdc.balanceOf(address(router)), 0);
        assertEq(usdc.balanceOf(address(staking)), USDC_FEE);
        assertEq(staking.totalUsdcReceived(), USDC_FEE);
        assertEq(router.totalUsdcSettled(), USDC_FEE);
        assertEq(router.totalUsdcDepositedToRegentStaking(), USDC_FEE);
    }

    function testRouterRevertsIfStakingIsPaused() external {
        vm.prank(OWNER);
        staking.setPaused(true);

        usdc.mint(address(router), USDC_FEE);

        vm.expectRevert("PAUSED");
        router.processProtocolFee(SUBJECT_ID, TREASURY, USDC_FEE, bytes32("source"));
    }

    function testProtocolFeeBpsCannotExceedCapButCanReturnToCap() external {
        vm.startPrank(OWNER);
        router.setProtocolSkimBps(500);
        assertEq(router.protocolSkimBps(), 500);
        router.setProtocolSkimBps(1000);
        assertEq(router.protocolSkimBps(), 1000);

        vm.expectRevert("PROTOCOL_SKIM_TOO_HIGH");
        router.setProtocolSkimBps(1001);
        vm.stopPrank();
    }
}
