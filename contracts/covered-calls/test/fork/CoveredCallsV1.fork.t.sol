// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

import {CoveredCallsV1} from "../../src/CoveredCallsV1.sol";
import {WeeklyExpiry} from "../doubles/WeeklyExpiry.sol";

interface IB20AssetFork {
    function multiplier() external view returns (uint256);
    function effectiveAt() external view returns (uint256);
    function grantRole(bytes32 role, address account) external;
    function updateMultiplier(uint256 newMultiplier) external;
    function pause(uint8[] calldata features) external;
    function unpause(uint8[] calldata features) external;
}

interface IPolicyRegistryFork {
    function updateBlocklist(uint64 policyId, bool blocked, address[] calldata accounts) external;
}

/// @notice Covered calls against the real AMZNc B20 token, Base USDC and live REGENT staking on a
///         local Base fork. Run with `forge test --profile fork --network base --fork-url <anvil>`,
///         where anvil is `anvil --network base --fork-url <Base RPC>` (Foundry 1.8.4 or later).
///         The issuer's admin and policy accounts are impersonated only to stage a corporate
///         action, a blocklisting and a pause, exactly as the issuer would.
/// @dev    Foundry's local B20 is the Beryl version: it has `multiplier` and the instant
///         `updateMultiplier`, but not the Cobalt ERC-8056 reads live on Base since then
///         (`effectiveAt`, `newUIMultiplier`, `toUIAmount`), which revert locally. `effectiveAt` is
///         therefore stubbed with the value Base mainnet returns (0, nothing scheduled), and a
///         scheduled change is staged by stubbing its time and flipping the multiplier at that time
///         with `updateMultiplier`, which is what the scheduled change does when it falls due.
contract CoveredCallsV1ForkTest is Test {
    address internal constant AMZNC = 0xb200000000000000000000d9192b6B456483C2E8;
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant LIVE_STAKING = 0xb027Dc261636E30Cbc0fE25b2F8e1ed273354AB5;
    /// The deepest AMZNc/USDC pool, used only as a holder to take stock from.
    address internal constant AMZNC_POOL = 0x532e0F46d1e528507FC9454d5847C231f23bDDf6;
    address internal constant TOKEN_ADMIN = 0x38467bE00970af18076fd08F6b4Cf38Ba91572B1;
    address internal constant POLICY_ADMIN = 0xEC0F05C174e54FBf0Fe16ad930a8AFEbCe612812;
    address internal constant POLICY_REGISTRY = 0x8453000000000000000000000000000000000002;
    uint64 internal constant TRANSFER_POLICY = 5;
    bytes32 internal constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 internal constant PAUSE_ROLE = keccak256("PAUSE_ROLE");
    bytes32 internal constant UNPAUSE_ROLE = keccak256("UNPAUSE_ROLE");
    uint8 internal constant TRANSFER = 0;
    uint256 internal constant TOKEN = 1e8;
    uint256 internal constant USD = 1e6;

    CoveredCallsV1 internal calls;
    IERC20 internal stock = IERC20(AMZNC);
    IERC20 internal usdc = IERC20(USDC);
    address internal seller = makeAddr("seller");
    address internal buyer = makeAddr("buyer");
    address internal issuerOps = makeAddr("issuerOps");
    uint64 internal expiry;

    function setUp() public {
        _stubEffectiveAt(0);
        calls = new CoveredCallsV1(AMZNC, USDC, LIVE_STAKING);
        expiry = WeeklyExpiry.next(block.timestamp, 1);

        vm.prank(AMZNC_POOL);
        stock.transfer(seller, 10 * TOKEN);
        deal(USDC, buyer, 1_000_000 * USD);

        vm.prank(seller);
        stock.approve(address(calls), type(uint256).max);
        vm.prank(buyer);
        usdc.approve(address(calls), type(uint256).max);

        vm.startPrank(TOKEN_ADMIN);
        IB20AssetFork(AMZNC).grantRole(OPERATOR_ROLE, issuerOps);
        IB20AssetFork(AMZNC).grantRole(PAUSE_ROLE, issuerOps);
        IB20AssetFork(AMZNC).grantRole(UNPAUSE_ROLE, issuerOps);
        vm.stopPrank();
    }

    function _list(uint256 amount) internal returns (uint256 id) {
        vm.prank(seller);
        id = calls.list(amount, 260 * USD, 4 * USD, expiry);
    }

    function _stubEffectiveAt(uint256 at) internal {
        vm.mockCall(AMZNC, abi.encodeWithSelector(IB20AssetFork.effectiveAt.selector), abi.encode(at));
    }

    /// The seller stops sales while the issuer has transfers paused; the remainder waits for a claim.
    function test_fork_cancelWorksWhileTransfersArePaused() public {
        uint256 id = _list(3 * TOKEN);
        _pauseTransfers(true);
        vm.prank(seller);
        calls.cancel(id);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(CoveredCallsV1.ExceedsAvailable.selector, 1, 0));
        calls.fill(id, 1);
        _pauseTransfers(false);
        vm.prank(seller);
        calls.claim(id);
        assertEq(stock.balanceOf(seller), 10 * TOKEN);
    }

    function _pauseTransfers(bool paused) internal {
        uint8[] memory features = new uint8[](1);
        features[0] = TRANSFER;
        vm.prank(issuerOps);
        if (paused) IB20AssetFork(AMZNC).pause(features);
        else IB20AssetFork(AMZNC).unpause(features);
    }

    function test_fork_constructorReadsTheRealDecimals() public view {
        assertEq(calls.unit(), 1e8);
    }

    /// The whole life of an exercised call with real tokens, and the fee reaching live staking.
    function test_fork_exercisedLifecycle() public {
        uint256 id = _list(2 * TOKEN);
        assertEq(stock.balanceOf(address(calls)), 2 * TOKEN);

        uint256 stakingBefore = usdc.balanceOf(LIVE_STAKING);
        vm.prank(buyer);
        calls.fill(id, 2 * TOKEN);
        assertEq(usdc.balanceOf(seller), 8 * USD - 80_000);
        assertEq(usdc.balanceOf(LIVE_STAKING) - stakingBefore, 80_000);
        assertEq(usdc.balanceOf(address(calls)), 0);

        vm.warp(expiry);
        vm.startPrank(buyer);
        calls.exercise(id, 2 * TOKEN);
        calls.claim(id);
        vm.stopPrank();
        assertEq(stock.balanceOf(buyer), 2 * TOKEN);

        vm.prank(seller);
        calls.collectStrike(id);
        assertEq(usdc.balanceOf(seller), 8 * USD - 80_000 + 520 * USD);
        assertEq(stock.balanceOf(address(calls)), 0);
    }

    function test_fork_unexercisedStockReturnsAfterTheWindow() public {
        uint256 id = _list(3 * TOKEN);
        vm.prank(buyer);
        calls.fill(id, TOKEN);
        vm.warp(uint256(expiry) + 1 days);
        vm.prank(seller);
        calls.claim(id);
        assertEq(stock.balanceOf(seller), 10 * TOKEN);
    }

    /// A scheduled multiplier change inside the life is refused; one after it is not; once it has
    /// taken effect, listings open again and raw amounts are unchanged.
    function test_fork_scheduledCorporateActionBlocksOverlappingListings() public {
        uint256 at = uint256(expiry) + 12 hours;
        _stubEffectiveAt(at);

        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(CoveredCallsV1.CorporateActionScheduled.selector, at));
        calls.list(TOKEN, 260 * USD, 4 * USD, expiry);

        vm.prank(seller);
        uint256 early = calls.list(TOKEN, 260 * USD, 4 * USD, expiry - 1 weeks);

        vm.warp(at);
        vm.prank(issuerOps);
        IB20AssetFork(AMZNC).updateMultiplier(2e18);
        assertEq(IB20AssetFork(AMZNC).multiplier(), 2e18);

        vm.prank(seller);
        uint256 id = calls.list(TOKEN, 130 * USD, 2 * USD, expiry + 1 weeks);
        assertEq(calls.listings(id).amount, TOKEN);
        assertEq(calls.listings(early).amount, TOKEN);
        assertEq(stock.balanceOf(address(calls)), 2 * TOKEN);
        assertEq(stock.balanceOf(seller), 8 * TOKEN);
    }

    /// The issuer blocklisting the holder stops only that holder's stock from leaving.
    function test_fork_blocklistedHolderCannotClaimButTheSellerCollects() public {
        uint256 id = _list(2 * TOKEN);
        vm.prank(buyer);
        calls.fill(id, TOKEN);
        vm.warp(expiry);
        vm.prank(buyer);
        calls.exercise(id, TOKEN);

        address[] memory accounts = new address[](1);
        accounts[0] = buyer;
        vm.prank(POLICY_ADMIN);
        IPolicyRegistryFork(POLICY_REGISTRY).updateBlocklist(TRANSFER_POLICY, true, accounts);

        vm.prank(buyer);
        vm.expectRevert(SafeTransferLib.TransferFailed.selector);
        calls.claim(id);

        vm.warp(uint256(expiry) + 1 days);
        vm.startPrank(seller);
        calls.claim(id);
        calls.collectStrike(id);
        vm.stopPrank();
        assertEq(stock.balanceOf(seller), 9 * TOKEN);
        assertEq(usdc.balanceOf(seller), 4 * USD - 40_000 + 260 * USD);
        assertEq(stock.balanceOf(address(calls)), TOKEN);
    }

    /// A real transfer pause during the window: exercise still works, the seller's USDC strike is
    /// never held up, the stock waits, and both sides take their stock once transfers resume.
    function test_fork_transferPauseDelaysButNeverLosesStock() public {
        uint256 id = _list(2 * TOKEN);
        vm.prank(buyer);
        calls.fill(id, TOKEN);
        vm.warp(expiry);
        _pauseTransfers(true);

        vm.prank(buyer);
        calls.exercise(id, TOKEN);
        vm.prank(buyer);
        vm.expectRevert(SafeTransferLib.TransferFailed.selector);
        calls.claim(id);

        vm.warp(uint256(expiry) + 1 days);
        vm.startPrank(seller);
        calls.collectStrike(id);
        vm.expectRevert(SafeTransferLib.TransferFailed.selector);
        calls.claim(id);
        vm.stopPrank();

        vm.warp(uint256(expiry) + 60 days);
        _pauseTransfers(false);
        vm.prank(buyer);
        calls.claim(id);
        vm.prank(seller);
        calls.claim(id);
        assertEq(stock.balanceOf(buyer), TOKEN);
        assertEq(stock.balanceOf(seller), 9 * TOKEN);
        assertEq(usdc.balanceOf(seller), 4 * USD - 40_000 + 260 * USD);
    }
}
