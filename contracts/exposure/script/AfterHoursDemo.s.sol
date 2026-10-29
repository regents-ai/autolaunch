// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";

import {ChainlinkPrintOracleV2} from "../src/ChainlinkPrintOracleV2.sol";
import {ExposureSeriesV1} from "../src/ExposureSeriesV1.sol";

interface IERC20Approve {
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IAerodromeRouter {
    function addLiquidity(
        address tokenA,
        address tokenB,
        bool stable,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity);
}

/// @title AfterHoursDemo
/// @notice The first series' live demo, run from the account that signs the broadcast:
///         `recordAndSettle` records every print that is due from the Chainlink feed and applies it;
///         `seed` mints a 0.2 AMZNc pair and opens an Aerodrome pool for each leg against USDC,
///         priced at the leg's ledger value (about $100 in all at $250 AMZNc).
/// @dev Every call is public and permissionless except that `seed` spends the signer's own AMZNc
///      and USDC. Broadcasting is Sean's to authorize.
contract AfterHoursDemo is Script {
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant AERODROME_ROUTER = 0xcF77a3Ba9A5CA399B7c97c74d54e5b1Beb874E43;
    uint256 internal constant DEMO_PAIR = 0.2e8;
    /// @notice How long after the script is simulated the pool transactions may still land.
    uint256 internal constant SEED_WINDOW = 1 hours;

    /// @notice Records and applies every print whose recording time has come, in order.
    function recordAndSettle(ExposureSeriesV1 series) external {
        ChainlinkPrintOracleV2 oracle = ChainlinkPrintOracleV2(series.oracle());
        vm.startBroadcast();
        while (series.status() != ExposureSeriesV1.Status.Ended) {
            uint256 index = series.settled();
            uint64 at = series.boundaries(index);
            if (block.timestamp < uint256(at) + oracle.RECORD_DELAY()) break;
            bool isOpen = index % 2 == 1;
            if (oracle.getPrint(oracle.feedId(), at, isOpen).finalizedAt == 0) {
                oracle.record(at, isOpen, roundInForce(oracle, at));
            }
            series.settle();
            console.log("applied print", index, series.lastPriceWad());
        }
        vm.stopBroadcast();
    }

    /// @notice Mints the demo pair and opens both leg pools at their ledger values. The pool
    ///         transactions must land within `SEED_WINDOW` of the simulation.
    function seed(ExposureSeriesV1 series) external {
        seedBy(series, block.timestamp + SEED_WINDOW);
    }

    function seedBy(ExposureSeriesV1 series, uint256 deadline) public {
        address overnight = address(series.overnight());
        address session = address(series.session());
        uint256 overnightUsdc = _usdc(series.overnightLedgerWad());
        uint256 sessionUsdc = _usdc(series.sessionLedgerWad());

        vm.startBroadcast();
        (, address signer,) = vm.readCallers();
        IERC20Approve(series.asset()).approve(address(series), DEMO_PAIR);
        series.mint(DEMO_PAIR);
        IERC20Approve(overnight).approve(AERODROME_ROUTER, DEMO_PAIR);
        IERC20Approve(session).approve(AERODROME_ROUTER, DEMO_PAIR);
        IERC20Approve(USDC).approve(AERODROME_ROUTER, overnightUsdc + sessionUsdc);
        IAerodromeRouter(AERODROME_ROUTER)
            .addLiquidity(overnight, USDC, false, DEMO_PAIR, overnightUsdc, DEMO_PAIR, overnightUsdc, signer, deadline);
        IAerodromeRouter(AERODROME_ROUTER)
            .addLiquidity(session, USDC, false, DEMO_PAIR, sessionUsdc, DEMO_PAIR, sessionUsdc, signer, deadline);
        vm.stopBroadcast();
        console.log("After-hours pool USDC", overnightUsdc);
        console.log("Market-hours pool USDC", sessionUsdc);
    }

    /// @notice The round of the oracle's pinned phase in force at `at`: the last one updated at or
    ///         before it. Rounds are numbered 1, 2, ... in time order within a phase, so this finds the
    ///         phase's last round and then the latest round not after `at`, by binary search.
    function roundInForce(ChainlinkPrintOracleV2 oracle, uint64 at) public view returns (uint64) {
        uint64 high = 1;
        while (_updatedAt(oracle, high) != 0) high *= 2;
        // Rounds 1 .. high - 1 may exist; find the last with updatedAt in (0, at].
        uint64 low = 0;
        while (high - low > 1) {
            uint64 mid = low + (high - low) / 2;
            uint256 updatedAt = _updatedAt(oracle, mid);
            if (updatedAt != 0 && updatedAt <= at) low = mid;
            else high = mid;
        }
        require(low != 0, "no round of the pinned phase is in force");
        return low;
    }

    function _updatedAt(ChainlinkPrintOracleV2 oracle, uint64 round) internal view returns (uint256 updatedAt) {
        (,,, updatedAt,) = oracle.feed().getRoundData(oracle.roundIdOf(round));
    }

    /// @dev USDC (6 decimals) for `DEMO_PAIR` raw units of a leg whose ledger is `ledgerWad` per token.
    function _usdc(uint256 ledgerWad) internal pure returns (uint256) {
        return DEMO_PAIR * ledgerWad / 1e8 / 1e12;
    }
}
