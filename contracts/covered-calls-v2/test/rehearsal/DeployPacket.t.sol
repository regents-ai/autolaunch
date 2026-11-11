// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {CoveredCallsV2} from "../../src/CoveredCallsV2.sol";
import {WeeklyExpiry} from "../doubles/WeeklyExpiry.sol";

/// @notice The deploy packet's contract, after `deploy/rehearse.sh` has sent the packet's exact
///         transaction on a local Base copy: the code and reads the packet promises, then a whole
///         life with the real AMZNc, Base USDC and live REGENT staking: a listing filled, a bid sold
///         into, raised, cancelled and refunded, both calls exercised in the window, the stock
///         claimed and the strike collected, the 1% fees landing in staking. Run only by
///         `deploy/rehearse.sh` (profile `rehearsal`).
/// @dev    Foundry's local B20 lacks the Cobalt `effectiveAt()` read live on Base, so it stands in
///         its mainnet value (0, nothing scheduled), as CoveredCallsV1's rehearsal and fork suite do.
contract DeployPacketRehearsal is Test {
    /// An AMZNc/USDC pool holding AMZNc, used only to fund the test seller.
    address internal constant AMZNC_HOLDER = 0x532e0F46d1e528507FC9454d5847C231f23bDDf6;
    uint256 internal constant TOKEN = 1e8;
    uint256 internal constant USD = 1e6;

    string internal packet;
    CoveredCallsV2 internal calls;
    IERC20 internal stock;
    IERC20 internal usdc;
    address internal staking;
    address internal seller = makeAddr("seller");
    address internal buyer = makeAddr("buyer");
    address internal bidder = makeAddr("bidder");

    function setUp() public {
        packet = vm.readFile("deploy/packet.json");
        calls = CoveredCallsV2(vm.parseJsonAddress(packet, ".create2.predicted_address"));
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
        assertEq(calls.listingCount(), 0);
        assertEq(calls.bidCount(), 0);
    }

    /// list, fill, bid, sellToBid, raiseBid, cancelBid, refundBid, exercise, claim and collectStrike
    /// on the deployed instance with real tokens.
    function test_wholeLifeOnTheDeployedInstance() public {
        vm.mockCall(address(stock), abi.encodeWithSignature("effectiveAt()"), abi.encode(uint256(0)));
        vm.prank(AMZNC_HOLDER);
        stock.transfer(seller, 3 * TOKEN);
        deal(address(usdc), buyer, 1_000 * USD);
        deal(address(usdc), bidder, 1_000 * USD);
        uint64 expiry = WeeklyExpiry.next(block.timestamp, 1);
        uint256 stakingBefore = usdc.balanceOf(staking);

        vm.prank(seller);
        stock.approve(address(calls), 3 * TOKEN);
        vm.prank(buyer);
        usdc.approve(address(calls), type(uint256).max);
        vm.prank(bidder);
        usdc.approve(address(calls), type(uint256).max);

        // A listing of 2 AMZNc at a 300 USDC strike, filled whole: 6 USDC of premium, 1% to staking.
        vm.prank(seller);
        uint256 listed = calls.list(2 * TOKEN, 300 * USD, 3 * USD, expiry);
        vm.prank(buyer);
        calls.fill(listed, 2 * TOKEN);
        assertEq(usdc.balanceOf(seller), 6 * USD - 60_000);
        assertEq(usdc.balanceOf(staking) - stakingBefore, 60_000);

        // A bid for 2 AMZNc at a 310 USDC strike and 4 USDC a token escrows 8 USDC.
        vm.prank(bidder);
        uint256 bidId = calls.bid(2 * TOKEN, 310 * USD, 4 * USD, expiry, TOKEN);
        assertEq(usdc.balanceOf(address(calls)), 8 * USD);

        // The seller sells 1 AMZNc into it and is paid its 4 USDC at once, less 1% to staking.
        vm.prank(seller);
        uint256 sold = calls.sellToBid(bidId, TOKEN);
        assertEq(calls.held(sold, bidder), TOKEN);
        assertEq(usdc.balanceOf(seller), 6 * USD - 60_000 + 4 * USD - 40_000);
        assertEq(usdc.balanceOf(staking) - stakingBefore, 100_000);

        // Raised by 1 AMZNc (4 USDC more), then cancelled and refunded: the 8 USDC left comes back.
        vm.startPrank(bidder);
        calls.raiseBid(bidId, TOKEN);
        assertEq(usdc.balanceOf(address(calls)), 8 * USD);
        calls.cancelBid(bidId);
        assertEq(calls.refundable(bidId), 8 * USD);
        calls.refundBid(bidId);
        vm.stopPrank();
        assertEq(usdc.balanceOf(bidder), 1_000 * USD - 4 * USD);
        assertEq(usdc.balanceOf(address(calls)), 0);

        // In the window both holders exercise and claim; the seller collects both strikes.
        vm.warp(expiry);
        vm.startPrank(buyer);
        calls.exercise(listed, 2 * TOKEN);
        calls.claim(listed);
        vm.stopPrank();
        vm.startPrank(bidder);
        calls.exercise(sold, TOKEN);
        calls.claim(sold);
        vm.stopPrank();
        vm.startPrank(seller);
        calls.collectStrike(listed);
        calls.collectStrike(sold);
        vm.stopPrank();

        assertEq(stock.balanceOf(buyer), 2 * TOKEN);
        assertEq(stock.balanceOf(bidder), TOKEN);
        assertEq(stock.balanceOf(seller), 0);
        assertEq(usdc.balanceOf(seller), 10 * USD - 100_000 + 600 * USD + 310 * USD);
        assertEq(usdc.balanceOf(buyer), 1_000 * USD - 6 * USD - 600 * USD);
        assertEq(usdc.balanceOf(bidder), 1_000 * USD - 4 * USD - 310 * USD);
        assertEq(usdc.balanceOf(staking) - stakingBefore, 100_000);
        assertEq(stock.balanceOf(address(calls)), 0);
        assertEq(usdc.balanceOf(address(calls)), 0);
        assertEq(calls.listingCount(), 2);
        assertEq(calls.bidCount(), 1);
    }
}
