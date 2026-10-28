// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

import {ExposureFactoryV1} from "../../src/ExposureFactoryV1.sol";
import {ExposureSeriesV1} from "../../src/ExposureSeriesV1.sol";
import {ChainlinkPrintOracleV1, IAggregatorV3} from "../../src/ChainlinkPrintOracleV1.sol";

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
///         factory and settled from the real Coinbase AMZN Chainlink feed over the week of 23 to 28
///         October 2026. Run against `anvil --network base --fork-url <Base RPC>
///         --fork-block-number 53209576` (Foundry 1.8.4 or later, for B20 precompiles) with
///         `FOUNDRY_PROFILE=fork forge test --network base --fork-url <anvil>`.
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
    address internal constant AMZN_FEED = 0x06A8E4b3aBB3B7543d8396FB2B763d22820cB295;

    IERC20 internal stock = IERC20(AMZNC);
    ChainlinkPrintOracleV1 internal oracle;
    ExposureSeriesV1 internal series;
    uint64[] internal schedule;
    address internal safe = makeAddr("governance safe");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal issuerOps = makeAddr("issuerOps");

    function setUp() public {
        oracle = new ChainlinkPrintOracleV1(AMZN_FEED);

        // Friday 23 Oct close, then Monday to Wednesday opens and closes (New York, summer time).
        uint64 friClose = 1793217600 - 5 days; // Fri 23 Oct 2026 20:00 UTC
        schedule.push(friClose);
        for (uint64 day = 3; day <= 5; ++day) {
            schedule.push(friClose + day * 1 days - 6.5 hours); // 13:30 UTC open
            schedule.push(friClose + day * 1 days); // 20:00 UTC close
        }

        ExposureFactoryV1 factory = new ExposureFactoryV1(safe);
        bytes32 feedId = oracle.feedId();
        vm.prank(safe);
        series = factory.createSeries(
            ExposureSeriesV1.Terms({
                asset: AMZNC,
                oracle: address(oracle),
                feedId: feedId,
                termsHash: keccak256("AMZNc exposure terms"),
                maxReportDelay: 7 days,
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

    /// @dev Records the feed's value in force at boundary `index` (found by walking back from the
    ///      latest round, as the site's keeper does) and applies it.
    function _settle(uint256 index) internal {
        uint64 at = schedule[index];
        if (block.timestamp < at + 1 hours) vm.warp(at + 1 hours);
        oracle.record(at, index % 2 == 1, _roundInForce(at));
        series.settle();
    }

    function _roundInForce(uint64 at) internal view returns (uint80 roundId) {
        (roundId,,,,) = IAggregatorV3(AMZN_FEED).latestRoundData();
        while (true) {
            (,,, uint256 updatedAt,) = IAggregatorV3(AMZN_FEED).getRoundData(roundId);
            if (updatedAt <= at) return roundId;
            --roundId;
        }
    }

    function _redeem(address who, uint256 n, uint256 s) internal returns (uint256) {
        vm.prank(who);
        return series.redeem(n, s);
    }

    function test_fork_readsTheRealToken() public view {
        assertEq(series.overnight().decimals(), 8);
        assertEq(series.asset(), AMZNC);
    }

    /// This week on real data: AMZN's Chainlink values in force at each open and close from Friday's
    /// close to Wednesday's, applied to a deposit of the real token, then the legs redeemed apart.
    function test_fork_thisWeekOnTheRealFeed() public {
        _settle(0); // Fri close 247.93375
        vm.prank(alice);
        series.mint(TOKEN);
        assertEq(stock.balanceOf(address(series)), TOKEN);
        for (uint256 i = 1; i < schedule.length; ++i) {
            _settle(i);
        }
        // Mon open 250.39085, close 248.98255; Tue 250.26999999, 254.2865; Wed 252.895, 252.9275.
        assertEq(series.lastPriceWad(), 252.9275e18);
        assertEq(series.overnightLedgerWad(), 126.31992499e18, "123.966875 + 2.457 + 1.28744999 - 1.3915");
        assertEq(series.sessionLedgerWad(), 126.60757501e18, "123.966875 - 1.4083 + 4.01650001 + 0.0325");
        assertEq(uint8(series.endReason()), uint8(ExposureSeriesV1.EndReason.Maturity));

        IERC20 session = IERC20(address(series.session()));
        vm.prank(alice);
        session.transfer(bob, TOKEN);
        uint256 overnightOwed = TOKEN * 126.31992499e18 / 252.9275e18;
        uint256 sessionOwed = TOKEN * 126.60757501e18 / 252.9275e18;
        assertEq(_redeem(alice, TOKEN, 0), overnightOwed);
        assertEq(_redeem(bob, 0, TOKEN), sessionOwed);
        assertLe(overnightOwed + sessionOwed, TOKEN);
    }

    /// A split changes the shares each raw token represents, not the raw units the series holds or owes.
    function test_fork_splitLeavesRawBackingAlone() public {
        _settle(0);
        vm.prank(alice);
        series.mint(3 * TOKEN);
        vm.prank(issuerOps);
        IB20AssetFork(AMZNC).updateMultiplier(2e18);
        assertEq(IB20AssetFork(AMZNC).multiplier(), 2e18);
        // Chainlink's total-return value is per raw token, so the split itself moves no ledger.
        _settle(1);
        assertEq(stock.balanceOf(address(series)), 3 * TOKEN);
        assertEq(_redeem(alice, 3 * TOKEN, 3 * TOKEN), 3 * TOKEN);
    }

    /// The issuer's blocklist reaches the stock: a blocklisted holder cannot redeem until unblocked,
    /// and the refused payout burns nothing.
    function test_fork_blocklistedHolderWaitsUntilUnblocked() public {
        _settle(0);
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
        _settle(0);
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
        _settle(1);

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
