// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {CoveredCallsV1} from "../../src/CoveredCallsV1.sol";
import {WeeklyExpiry} from "../doubles/WeeklyExpiry.sol";

/// @notice The deploy packet's contract, after `deploy/rehearse.sh` has sent the packet's exact
///         transaction on a local Base copy: the code and reads the packet promises, then a whole
///         call's life with the real AMZNc, Base USDC and live REGENT staking, the 1% fee landing in
///         staking. Run only by `deploy/rehearse.sh` (profile `rehearsal`).
/// @dev    Foundry's local B20 lacks the Cobalt `effectiveAt()` read live on Base since then, so it
///         stands in its mainnet value (0, nothing scheduled), as the fork suite does.
contract DeployPacketRehearsal is Test {
    /// An AMZNc/USDC pool holding AMZNc, used only to fund the test seller.
    address internal constant AMZNC_HOLDER = 0x532e0F46d1e528507FC9454d5847C231f23bDDf6;
    uint256 internal constant TOKEN = 1e8;
    uint256 internal constant USD = 1e6;

    string internal packet;
    CoveredCallsV1 internal calls;
    IERC20 internal stock;
    IERC20 internal usdc;
    address internal staking;
    address internal seller = makeAddr("seller");
    address internal buyer = makeAddr("buyer");

    function setUp() public {
        packet = vm.readFile("deploy/packet.json");
        calls = CoveredCallsV1(vm.parseJsonAddress(packet, ".create2.predicted_address"));
        stock = IERC20(calls.stock());
        usdc = IERC20(calls.usdc());
        staking = calls.staking();
    }

    function test_packetContractIsWhatThePacketPromises() public view {
        assertEq(block.chainid, vm.parseJsonUint(packet, ".chain_id"));
        assertEq(address(calls).codehash, vm.parseJsonBytes32(packet, ".post_deploy.runtime_code_keccak"));
        assertEq(address(stock), vm.parseJsonAddress(packet, ".constructor[0].value"));
        assertEq(address(usdc), vm.parseJsonAddress(packet, ".constructor[1].value"));
        assertEq(staking, vm.parseJsonAddress(packet, ".constructor[2].value"));
        assertEq(calls.unit(), vm.parseUint(vm.parseJsonString(packet, ".post_deploy.reads['unit()']")));
        assertEq(calls.FEE_BPS(), 100);
        assertEq(calls.EXERCISE_WINDOW(), 1 days);
    }

    /// list, fill, exercise, claim and collectStrike on the deployed instance with real tokens.
    function test_wholeLifeOnTheDeployedInstance() public {
        vm.mockCall(address(stock), abi.encodeWithSignature("effectiveAt()"), abi.encode(uint256(0)));
        vm.prank(AMZNC_HOLDER);
        stock.transfer(seller, 2 * TOKEN);
        deal(address(usdc), buyer, 1_000 * USD);
        uint64 expiry = WeeklyExpiry.next(block.timestamp, 1);

        vm.startPrank(seller);
        stock.approve(address(calls), 2 * TOKEN);
        uint256 id = calls.list(2 * TOKEN, 300 * USD, 3 * USD, expiry);
        vm.stopPrank();

        uint256 stakingBefore = usdc.balanceOf(staking);
        vm.startPrank(buyer);
        usdc.approve(address(calls), type(uint256).max);
        calls.fill(id, 2 * TOKEN);
        vm.stopPrank();
        // 6 USDC of premium: 1% (0.06 USDC) into live staking, the rest to the seller.
        assertEq(usdc.balanceOf(staking) - stakingBefore, 60_000);
        assertEq(usdc.balanceOf(seller), 6 * USD - 60_000);

        vm.warp(expiry);
        vm.startPrank(buyer);
        calls.exercise(id, 2 * TOKEN);
        calls.claim(id);
        vm.stopPrank();
        assertEq(stock.balanceOf(buyer), 2 * TOKEN);

        vm.prank(seller);
        calls.collectStrike(id);
        assertEq(usdc.balanceOf(seller), 6 * USD - 60_000 + 600 * USD);
        assertEq(stock.balanceOf(address(calls)), 0);
        assertEq(usdc.balanceOf(address(calls)), 0);
    }
}
