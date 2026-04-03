// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {RevenueIngressAccount} from "src/revenue/RevenueIngressAccount.sol";
import {RevenueShareFactory} from "src/revenue/RevenueShareFactory.sol";
import {RevenueShareSplitter} from "src/revenue/RevenueShareSplitter.sol";
import {SubjectRegistry} from "src/revenue/SubjectRegistry.sol";
import {MintableERC20Mock} from "test/mocks/MintableERC20Mock.sol";

contract RevenueIngressAccountTest is Test {
    bytes32 internal constant SUBJECT_ID = keccak256("subject");
    address internal constant TREASURY_SAFE = address(0x1111);
    address internal constant AGENT_TREASURY = address(0x2222);
    address internal constant REGENT_RECIPIENT = address(0x3333);

    MintableERC20Mock internal usdc;
    MintableERC20Mock internal stakeToken;
    SubjectRegistry internal subjectRegistry;
    RevenueShareFactory internal revenueShareFactory;
    RevenueShareSplitter internal splitter;
    RevenueIngressAccount internal ingress;

    function setUp() external {
        usdc = new MintableERC20Mock("USD Coin", "USDC");
        stakeToken = new MintableERC20Mock("Agent", "AGENT");
        stakeToken.mint(address(this), 1000e18);
        subjectRegistry = new SubjectRegistry(address(this));
        revenueShareFactory = new RevenueShareFactory(address(this), address(usdc), subjectRegistry);
        subjectRegistry.transferOwnership(address(revenueShareFactory));

        address splitterAddress = revenueShareFactory.createSubjectSplitter(
            SUBJECT_ID,
            address(stakeToken),
            AGENT_TREASURY,
            REGENT_RECIPIENT,
            TREASURY_SAFE,
            TREASURY_SAFE,
            100,
            1000e18,
            "Subject",
            block.chainid,
            address(0x8004),
            42
        );
        splitter = RevenueShareSplitter(splitterAddress);
        ingress = new RevenueIngressAccount(
            address(usdc), splitterAddress, SUBJECT_ID, "default-usdc-ingress", TREASURY_SAFE
        );
    }

    function testSweepRecognizesRevenueInsideSplitter() external {
        usdc.mint(address(ingress), 1000e18);

        (uint256 balance, uint256 recognized) = ingress.sweepUSDC(keccak256("invoice-1"));

        assertEq(balance, 1000e18);
        assertEq(recognized, 1000e18);
        assertEq(usdc.balanceOf(address(ingress)), 0);
        assertEq(usdc.balanceOf(address(splitter)), 1000e18);
        assertEq(splitter.treasuryResidualUsdc(), 990e18);
        assertEq(splitter.protocolReserveUsdc(), 10e18);
    }

    function testOwnerCanRescueNonUsdcToken() external {
        MintableERC20Mock other = new MintableERC20Mock("Other", "OTHER");
        other.mint(address(ingress), 55e18);

        vm.prank(TREASURY_SAFE);
        ingress.rescueToken(address(other), 55e18, address(0x5555));

        assertEq(other.balanceOf(address(0x5555)), 55e18);
    }

    function testSecondSweepRevertsWhenNothingRemains() external {
        usdc.mint(address(ingress), 1000e18);
        ingress.sweepUSDC(keccak256("invoice-1"));

        vm.expectRevert("NOTHING_TO_SWEEP");
        ingress.sweepUSDC(keccak256("invoice-2"));
    }
}
