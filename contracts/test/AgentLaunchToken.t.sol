// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {AgentLaunchToken} from "src/AgentLaunchToken.sol";

contract AgentLaunchTokenTest is Test {
    uint256 internal constant INITIAL_SUPPLY = 1000e18;
    uint256 internal constant TRANSFER_AMOUNT = 125e18;
    uint256 internal constant TRANSFER_FROM_AMOUNT = 200e18;

    AgentLaunchToken internal token;

    address internal constant OWNER = address(0xA11CE);
    address internal constant RECIPIENT = address(0xB0B);
    address internal constant SPENDER = address(0xCAFE);

    function setUp() external {
        token = new AgentLaunchToken("Agent Coin", "AGENT", INITIAL_SUPPLY, OWNER);
    }

    function testTransferHasNoFee() external {
        vm.prank(OWNER);
        assertTrue(token.transfer(RECIPIENT, TRANSFER_AMOUNT));

        assertEq(token.balanceOf(OWNER), INITIAL_SUPPLY - TRANSFER_AMOUNT);
        assertEq(token.balanceOf(RECIPIENT), TRANSFER_AMOUNT);
        assertEq(token.totalSupply(), INITIAL_SUPPLY);
    }

    function testTransferFromHasNoFee() external {
        vm.prank(OWNER);
        token.approve(SPENDER, TRANSFER_FROM_AMOUNT);

        vm.prank(SPENDER);
        assertTrue(token.transferFrom(OWNER, RECIPIENT, TRANSFER_FROM_AMOUNT));

        assertEq(token.balanceOf(OWNER), INITIAL_SUPPLY - TRANSFER_FROM_AMOUNT);
        assertEq(token.balanceOf(RECIPIENT), TRANSFER_FROM_AMOUNT);
        assertEq(token.allowance(OWNER, SPENDER), 0);
    }
}
