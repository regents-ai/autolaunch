// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

/// @title StocksPreset
/// @notice Every fixed launch term of Autolaunch Stocks, in one place, with its provenance.
/// @dev A value marked `Founder decision 2026-09-09` began as a single bounded proposal from
///      `contracts/stocks-v2/README.md` and was accepted by the founder on 9 September 2026; nothing else
///      in the component restates it. Values with a brief or pinned-dependency provenance are exact.
library StocksPreset {
    // -------------------------------------------------------------------------
    // NEW token and allocation
    // -------------------------------------------------------------------------

    // Founder decision 2026-09-09
    uint8 internal constant NEW_DECIMALS = 18;

    /// @notice `S0`. Even; below the CCA `MAX_TOTAL_SUPPLY` (1 << 100).
    // Founder decision 2026-09-09
    uint256 internal constant INITIAL_SUPPLY = 1_000_000_000e18;

    /// @notice Half of `S0` is the sale allocation. Every unit of it reaches bidders when a launch
    ///         graduates: what the auction sells, and what it does not sell shared out pro rata.
    // Founder decision 2026-09-27
    // forge-lint: disable-next-line(unsafe-typecast)
    uint128 internal constant AUCTION_INVENTORY = uint128(INITIAL_SUPPLY / 2);

    /// @notice The other half of `S0` is the migration reserve, paired whole in the official pool.
    // Founder decision 2026-09-27
    // forge-lint: disable-next-line(unsafe-typecast)
    uint128 internal constant MIGRATION_RESERVE = uint128(INITIAL_SUPPLY / 2);

    // -------------------------------------------------------------------------
    // auction schedule
    // -------------------------------------------------------------------------

    /// @notice Brief P03 "approximately 24 hours" at Base's 2-second blocks.
    // Founder decision 2026-09-09 (the block count; the ~24 h intent is the brief's)
    uint64 internal constant AUCTION_DURATION_BLOCKS = 43_200;

    /// @notice Founder decision (21 September 2026): every auction opens exactly ten minutes after its
    ///         creation block, 300 blocks at Base's 2-second cadence. The launcher does not choose it.
    uint64 internal constant START_LEAD_BLOCKS = 300;

    /// @notice Same pinned CCA convention as Agent.
    uint64 internal constant CLAIM_DELAY_BLOCKS = 64;
    uint64 internal constant MIGRATION_DELAY_BLOCKS = 128;

    /// @notice Thirteen packed `uint24 mps | uint40 blockDelta` steps summing to
    ///         `AUCTION_DURATION_BLOCKS` blocks and exactly `ConstantsLib.MPS = 1e7`.
    /// @dev Derived from the Agent schedule's shape: twelve scheduled steps of shortening windows at
    ///      rising per-block rates, each releasing about 5.8% of the inventory (5,445 blocks at 108 mps
    ///      down to 3,022 blocks at 194 mps), and a thirteenth single terminal block carrying the
    ///      remaining 2,988,024 mps. `StocksPreset.t.sol` proves both sums against this exact vector
    ///      and the pinned `StepStorage` accepts it.
    bytes internal constant AUCTION_STEPS = hex"00006c0000001545" hex"00008800000010a2" hex"0000960000000f3e"
        hex"00009e0000000e66" hex"0000a60000000dce" hex"0000aa0000000d5a" hex"0000b00000000cfc" hex"0000b40000000cad"
        hex"0000b80000000c6a" hex"0000bc0000000c2f" hex"0000be0000000bfc" hex"0000c20000000bce" hex"2d97f80000000001";

    uint256 internal constant AUCTION_STEP_COUNT = 13;

    /// @notice Bid tick spacing is `floorPriceQ96 / BID_TICK_DIVISOR`; the floor must divide exactly.
    uint256 internal constant BID_TICK_DIVISOR = 100;

    // -------------------------------------------------------------------------
    // official pool
    // -------------------------------------------------------------------------

    // Founder decision 2026-09-09
    uint24 internal constant POOL_FEE = 3000;
    // Founder decision 2026-09-09
    int24 internal constant POOL_TICK_SPACING = 60;

    /// @notice Brief P08: each hook lane is `feeBase / LANE_DIVISOR`, floored per lane.
    uint256 internal constant LANE_DIVISOR = 100;
    uint16 internal constant REGENT_LANE_BPS = 100;
    /// @notice Founder decision: every launch's memestock stakers always earn exactly this lane.
    uint16 internal constant STAKER_LANE_BPS = 100;

    // -------------------------------------------------------------------------
    // metadata caps (same shape as the Agent factory; bytes, inclusive, each nonempty)
    // -------------------------------------------------------------------------

    uint256 internal constant MAX_NAME_BYTES = 64;
    uint256 internal constant MAX_SYMBOL_BYTES = 16;
    uint256 internal constant MAX_DESCRIPTION_BYTES = 512;
    uint256 internal constant MAX_WEBSITE_BYTES = 256;
    uint256 internal constant MAX_IMAGE_BYTES = 256;

    // -------------------------------------------------------------------------
    // terminal custody (mechanisms are labelled, not chosen, here)
    // -------------------------------------------------------------------------

    /// @notice Brief §1.2 recommendation: after a failed minimum the reserve and the swept inventory
    ///         are transferred to the dead address ("retired"); supply is not reduced because UERC20
    ///         has no burn. Bidders refund through the CCA.
    // Founder decision 2026-09-09 (failed-minimum retirement)
    bool internal constant RETIRE_FAILED_INVENTORY = true;

    /// @notice Graduation locks one full-range position in the fee-only `MemestockLPLocker`, opened at
    ///         the raise divided by the whole sale allocation and funded by the whole reserve and the
    ///         whole raise. Only the rounding remainder below one unit of liquidity is left over: its
    ///         STOCK accrues to the REGENT lane of the pool's hook, its NEW joins the bidders' share.
    // Founder decision 2026-09-09 (the destination of the STOCK rounding remainder)
    bool internal constant LP_STOCK_DUST_TO_REGENT_BUCKET = true;

    /// @notice Every unit of NEW the auction did not sell, with the reserve NEW the pool could not pair,
    ///         is claimable by the bids in proportion to the tokens each won; nothing is retired on
    ///         graduation. Each claim rounds down, so a few base units per bid stay unclaimed.
    // Founder decision 2026-09-27
    bool internal constant UNSOLD_NEW_TO_BIDDERS = true;
}
