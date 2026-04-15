// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LaunchFeeRegistry} from "src/LaunchFeeRegistry.sol";
import {LaunchFeeVault} from "src/LaunchFeeVault.sol";
import {LaunchPoolFeeHook} from "src/LaunchPoolFeeHook.sol";
import {RevenueShareSplitter} from "src/revenue/RevenueShareSplitter.sol";
import {SubjectRegistry} from "src/revenue/SubjectRegistry.sol";
import {MintableBurnableERC20Mock} from "test/mocks/MintableBurnableERC20Mock.sol";
import {MintableERC20Mock} from "test/mocks/MintableERC20Mock.sol";
import {MockHookDeployer} from "test/mocks/MockHookDeployer.sol";
import {MockHookPoolManager} from "test/mocks/MockHookPoolManager.sol";

contract LaunchRevenueFlowTest is Test {
    uint24 internal constant POOL_FEE = 0;
    int24 internal constant TICK_SPACING = 60;
    uint256 internal constant SWAP_AMOUNT = 100e18;
    uint256 internal constant EXPECTED_TREASURY_SHARE = 1e18;
    uint256 internal constant EXPECTED_PROTOCOL_RESERVE = 1e16;
    uint256 internal constant EXPECTED_STAKER_CLAIM = 99e15;
    uint256 internal constant EXPECTED_TREASURY_RESIDUAL = 891e15;

    address internal constant OWNER = address(0xA11CE);
    address internal constant PROTOCOL_TREASURY = address(0xBEEF);
    address internal constant SUBJECT_TREASURY = address(0x7EAD);
    address internal constant ALICE = address(0xA1);
    address internal constant LAUNCH_TOKEN = address(0x1001);
    address internal constant TRADER = address(0xB0B);
    bytes32 internal constant SUBJECT_ID = keccak256("launch-revenue-flow");

    LaunchFeeRegistry internal registry;
    LaunchFeeVault internal vault;
    LaunchPoolFeeHook internal hook;
    MockHookDeployer internal hookDeployer;
    MockHookPoolManager internal poolManager;
    MintableERC20Mock internal usdc;
    MintableBurnableERC20Mock internal stakeToken;
    RevenueShareSplitter internal splitter;
    SubjectRegistry internal subjectRegistry;

    bytes32 internal poolId;
    PoolKey internal poolKey;

    function setUp() external {
        vm.startPrank(OWNER);
        registry = new LaunchFeeRegistry(OWNER);
        vault = new LaunchFeeVault(OWNER, address(registry));
        hookDeployer = new MockHookDeployer();
        poolManager = new MockHookPoolManager();
        hook = hookDeployer.deploy(OWNER, address(poolManager), address(registry), address(vault));
        vault.setHook(address(hook));

        usdc = new MintableERC20Mock("USD Coin", "USDC");
        stakeToken = new MintableBurnableERC20Mock("Agent", "AGENT", 18);
        subjectRegistry = new SubjectRegistry(OWNER);
        splitter = new RevenueShareSplitter(
            address(stakeToken),
            address(usdc),
            address(subjectRegistry),
            SUBJECT_ID,
            SUBJECT_TREASURY,
            PROTOCOL_TREASURY,
            100,
            1000e18,
            "Atlas splitter",
            OWNER
        );
        subjectRegistry.createSubject(
            SUBJECT_ID, address(stakeToken), address(splitter), SUBJECT_TREASURY, true, "Atlas splitter"
        );

        poolId = registry.registerPool(
            LaunchFeeRegistry.PoolRegistration({
                launchToken: LAUNCH_TOKEN,
                quoteToken: address(usdc),
                treasury: address(splitter),
                regentRecipient: PROTOCOL_TREASURY,
                poolFee: POOL_FEE,
                tickSpacing: TICK_SPACING,
                poolManager: address(poolManager),
                hook: address(hook)
            })
        );
        vm.stopPrank();

        poolKey = PoolKey({
            currency0: Currency.wrap(LAUNCH_TOKEN),
            currency1: Currency.wrap(address(usdc)),
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });

        stakeToken.mint(ALICE, 100e18);
        stakeToken.mint(SUBJECT_TREASURY, 900e18);

        vm.startPrank(ALICE);
        stakeToken.approve(address(splitter), type(uint256).max);
        splitter.stake(100e18, ALICE);
        vm.stopPrank();

        usdc.mint(address(poolManager), 1000e18);
        poolManager.simulateSwap(
            address(hook),
            TRADER,
            poolKey,
            SwapParams({
                zeroForOne: true, amountSpecified: -int256(SWAP_AMOUNT), sqrtPriceLimitX96: 0
            }),
            -int128(int256(SWAP_AMOUNT)),
            int128(int256(SWAP_AMOUNT))
        );
    }

    function testLaunchFeeTreasuryShareBecomesClaimableRevenue() external {
        splitter.pullTreasuryShareFromLaunchVault(
            address(vault), poolId, EXPECTED_TREASURY_SHARE, bytes32("launch-round-1")
        );

        assertEq(vault.treasuryAccrued(poolId, address(usdc)), 0);
        assertEq(vault.regentAccrued(poolId, address(usdc)), EXPECTED_TREASURY_SHARE);
        assertEq(splitter.protocolReserveUsdc(), EXPECTED_PROTOCOL_RESERVE);
        assertEq(splitter.treasuryResidualUsdc(), EXPECTED_TREASURY_RESIDUAL);
        assertEq(splitter.previewClaimableUSDC(ALICE), EXPECTED_STAKER_CLAIM);

        vm.prank(ALICE);
        uint256 claimed = splitter.claimUSDC(ALICE);

        assertEq(claimed, EXPECTED_STAKER_CLAIM);
        assertEq(usdc.balanceOf(ALICE), EXPECTED_STAKER_CLAIM);
        assertEq(splitter.previewClaimableUSDC(ALICE), 0);
    }
}
