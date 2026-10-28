// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

import {ExposureFactoryV1} from "../../src/ExposureFactoryV1.sol";
import {ExposureSeriesV1} from "../../src/ExposureSeriesV1.sol";
import {PrintOracleV1} from "../../src/PrintOracleV1.sol";

interface IB20AssetFork {
    function multiplier() external view returns (uint256);
    function grantRole(bytes32 role, address account) external;
    function updateMultiplier(uint256 newMultiplier) external;
    function pause(uint8[] calldata features) external;
    function unpause(uint8[] calldata features) external;
}

interface IPolicyRegistryFork {
    function updateBlocklist(uint64 policyId, bool blocked, address[] calldata accounts) external;
}

/// @notice An exposure series on the real AMZNc B20 token on a local Base fork, created through the
///         factory and settled from a 2-of-3 PrintOracleV1. Run with
///         `FOUNDRY_PROFILE=fork forge test --network base --fork-url <anvil>`, where anvil is
///         `anvil --network base --fork-url <Base RPC>` (Foundry 1.8.4 or later, for B20 precompiles).
///         The issuer's admin and policy accounts are impersonated only to stage a split, a
///         blocklisting and a transfer pause, exactly as the issuer would.
contract ExposureSeriesV1ForkTest is Test {
    address internal constant AMZNC = 0xb200000000000000000000d9192b6B456483C2E8;
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
    bytes32 internal constant FEED = keccak256("AMZNc NASDAQ official open and close, USD per raw token, v1");

    IERC20 internal stock = IERC20(AMZNC);
    PrintOracleV1 internal oracle;
    ExposureSeriesV1 internal series;
    uint64[] internal schedule;
    address internal safe = makeAddr("governance safe");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal issuerOps = makeAddr("issuerOps");
    address[3] internal reporters = [makeAddr("reporter1"), makeAddr("reporter2"), makeAddr("reporter3")];

    function setUp() public {
        address[] memory list = new address[](3);
        (list[0], list[1], list[2]) = (reporters[0], reporters[1], reporters[2]);
        oracle = new PrintOracleV1(list, 2);

        uint64 t = uint64(block.timestamp) + 1 hours;
        schedule.push(t);
        schedule.push(t + 17.5 hours);
        schedule.push(t + 24 hours);
        schedule.push(t + 41.5 hours);
        schedule.push(t + 48 hours);

        ExposureFactoryV1 factory = new ExposureFactoryV1(safe);
        vm.prank(safe);
        series = factory.createSeries(
            ExposureSeriesV1.Terms({
                asset: AMZNC,
                oracle: address(oracle),
                feedId: FEED,
                termsHash: keccak256("AMZNc exposure terms"),
                maxReportDelay: 6 hours,
                depositCap: 1_000_000e8,
                boundaries: schedule,
                overnightName: "AMZNc Overnight",
                overnightSymbol: "AMZNc-N",
                sessionName: "AMZNc Session",
                sessionSymbol: "AMZNc-S"
            })
        );

        vm.startPrank(AMZNC_POOL);
        stock.transfer(alice, 10 * TOKEN);
        stock.transfer(bob, 10 * TOKEN);
        vm.stopPrank();
        vm.prank(alice);
        stock.approve(address(series), type(uint256).max);
        vm.prank(bob);
        stock.approve(address(series), type(uint256).max);

        vm.startPrank(TOKEN_ADMIN);
        IB20AssetFork(AMZNC).grantRole(OPERATOR_ROLE, issuerOps);
        IB20AssetFork(AMZNC).grantRole(PAUSE_ROLE, issuerOps);
        IB20AssetFork(AMZNC).grantRole(UNPAUSE_ROLE, issuerOps);
        vm.stopPrank();
    }

    /// @dev Two reporters publish the print for boundary `index` ten minutes after it; then it is applied.
    function _settle(uint256 index, uint128 priceWad) internal {
        uint64 at = schedule[index];
        vm.warp(at + 10 minutes);
        for (uint256 i; i < 2; ++i) {
            vm.prank(reporters[i]);
            oracle.report(FEED, at, index % 2 == 1, priceWad, keccak256("evidence"));
        }
        series.settle();
    }

    function _redeem(address who, uint256 n, uint256 s) internal returns (uint256) {
        vm.prank(who);
        return series.redeem(n, s);
    }

    function test_fork_readsTheRealToken() public view {
        assertEq(series.overnight().decimals(), 8);
        assertEq(series.asset(), AMZNC);
    }

    /// The paper's worked example on the real token: deposit, four prints, split legs, redeem.
    function test_fork_workedExampleWithRealStock() public {
        _settle(0, 160e18);
        vm.prank(alice);
        series.mint(TOKEN);
        assertEq(stock.balanceOf(address(series)), TOKEN);

        _settle(1, 172e18);
        _settle(2, 166e18);
        _settle(3, 178e18);
        _settle(4, 170e18);
        assertEq(series.overnightLedgerWad(), 104e18);
        assertEq(series.sessionLedgerWad(), 66e18);

        IERC20 session = IERC20(address(series.session()));
        vm.prank(alice);
        session.transfer(bob, TOKEN);
        uint256 aliceBefore = stock.balanceOf(alice);
        uint256 bobBefore = stock.balanceOf(bob);
        assertEq(_redeem(alice, TOKEN, 0), TOKEN * 104 / 170);
        assertEq(_redeem(bob, 0, TOKEN), TOKEN * 66 / 170);
        assertEq(stock.balanceOf(alice) - aliceBefore, TOKEN * 104 / 170);
        assertEq(stock.balanceOf(bob) - bobBefore, TOKEN * 66 / 170);
    }

    /// A split changes the shares each raw token represents, not the raw units the series holds or owes.
    function test_fork_splitLeavesRawBackingAlone() public {
        _settle(0, 200e18);
        vm.prank(alice);
        series.mint(3 * TOKEN);
        vm.prank(issuerOps);
        IB20AssetFork(AMZNC).updateMultiplier(2e18);
        assertEq(IB20AssetFork(AMZNC).multiplier(), 2e18);
        // The oracle's price per raw token is unchanged by the split (half the equity price, twice the shares).
        _settle(1, 200e18);
        assertEq(stock.balanceOf(address(series)), 3 * TOKEN);
        assertEq(_redeem(alice, 3 * TOKEN, 3 * TOKEN), 3 * TOKEN);
    }

    /// The issuer's blocklist reaches the stock: a blocklisted holder cannot redeem until unblocked,
    /// and the refused payout burns nothing.
    function test_fork_blocklistedHolderWaitsUntilUnblocked() public {
        _settle(0, 160e18);
        vm.prank(bob);
        series.mint(2 * TOKEN);
        _blocklist(bob, true);

        vm.prank(bob);
        vm.expectRevert(SafeTransferLib.TransferFailed.selector);
        series.redeem(TOKEN, TOKEN);
        assertEq(series.overnight().balanceOf(bob), 2 * TOKEN, "the refused payout burned nothing");

        _blocklist(bob, false);
        assertEq(_redeem(bob, 2 * TOKEN, 2 * TOKEN), 2 * TOKEN);
    }

    function _blocklist(address account, bool blocked) internal {
        address[] memory accounts = new address[](1);
        accounts[0] = account;
        vm.prank(POLICY_ADMIN);
        IPolicyRegistryFork(POLICY_REGISTRY).updateBlocklist(TRANSFER_POLICY, blocked, accounts);
    }

    function test_fork_transferPauseDelaysButNeverLosesStock() public {
        _settle(0, 160e18);
        vm.prank(alice);
        series.mint(2 * TOKEN);
        _pauseTransfers(true);

        vm.prank(alice);
        vm.expectRevert(SafeTransferLib.TransferFailed.selector);
        series.redeem(TOKEN, TOKEN);
        vm.prank(bob);
        vm.expectRevert(SafeTransferLib.TransferFromFailed.selector);
        series.mint(TOKEN);
        // Prints keep applying while the stock is paused.
        _settle(1, 150e18);

        _pauseTransfers(false);
        assertEq(_redeem(alice, 2 * TOKEN, 2 * TOKEN), 2 * TOKEN);
    }

    function _pauseTransfers(bool paused) internal {
        uint8[] memory features = new uint8[](1);
        features[0] = TRANSFER;
        vm.prank(issuerOps);
        if (paused) IB20AssetFork(AMZNC).pause(features);
        else IB20AssetFork(AMZNC).unpause(features);
    }
}
