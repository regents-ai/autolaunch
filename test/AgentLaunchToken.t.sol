// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {AgentLaunchToken} from "src/AgentLaunchToken.sol";

contract AgentLaunchTokenTest is Test {
    AgentLaunchToken internal token;

    address internal owner = address(0xA11CE);
    address internal recipient = address(0xB0B);
    address internal spender = address(0xCAFE);

    function setUp() external {
        token = new AgentLaunchToken("Agent Coin", "AGENT", 1000e18, owner);
    }

    function testTransferHasNoFee() external {
        vm.prank(owner);
        bool success = token.transfer(recipient, 125e18);

        assertTrue(success);
        assertEq(token.balanceOf(owner), 875e18);
        assertEq(token.balanceOf(recipient), 125e18);
        assertEq(token.totalSupply(), 1000e18);
    }

    function testTransferFromHasNoFee() external {
        vm.prank(owner);
        token.approve(spender, 200e18);

        vm.prank(spender);
        bool success = token.transferFrom(owner, recipient, 200e18);

        assertTrue(success);
        assertEq(token.balanceOf(owner), 800e18);
        assertEq(token.balanceOf(recipient), 200e18);
        assertEq(token.allowance(owner, spender), 0);
    }
}
