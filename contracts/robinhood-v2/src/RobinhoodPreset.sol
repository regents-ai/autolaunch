// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

/// @title RobinhoodPreset
/// @notice Every fixed Robinhood-chain launch term, in one place, with its provenance.
/// @dev USDG is the local dollar asset of the Robinhood chain: the protocol lane's settlement and the
///      protocol inbox are USDG. Nothing here depends on Base USDC or on REGENT. Supply split, floor,
///      required raise, tick grid, position geometry, pool fee, basis-point denominator and metadata
///      caps are shared with the Base Stocks component through `StocksPreset`; the block schedule is
///      Robinhood's own, because a Robinhood block is a tenth of a second where a Base block is two
///      seconds. There is no launch fee and no governance minimum raise.
library RobinhoodPreset {
    /// @notice USDG base units per whole dollar. Every launchpad reads the bound token's own
    ///         `decimals()` at construction and refuses any other value, so the constants below are
    ///         the dollar amounts they read as.
    uint8 internal constant USDG_DECIMALS = 6;

    // -------------------------------------------------------------------------
    // auction schedule (founder decision of 21 September 2026: every Base block term scaled twentyfold
    // so that each term lasts the same clock time at Robinhood's 0.1-second blocks)
    // -------------------------------------------------------------------------

    /// @notice Every auction opens exactly ten minutes after its creation block. The launcher does
    ///         not choose it.
    uint64 internal constant START_LEAD_BLOCKS = 6_000;

    /// @notice One day of bidding.
    uint64 internal constant AUCTION_DURATION_BLOCKS = 864_000;

    /// @notice The Base claim and migration delays (64 and 128 blocks), scaled.
    uint64 internal constant CLAIM_DELAY_BLOCKS = 1_280;
    uint64 internal constant MIGRATION_DELAY_BLOCKS = 2_560;

    /// @notice The creator vesting's term: 30 days of 0.1-second blocks, counted from the graduation
    ///         block in the auction's block units. The Base term (`StocksPreset.CREATOR_VESTING_BLOCKS`)
    ///         scaled twentyfold.
    // Founder decision 2026-10-01
    uint64 internal constant CREATOR_VESTING_BLOCKS = 25_920_000;

    /// @notice Thirteen packed `uint24 mps | uint40 blockDelta` steps summing to
    ///         `AUCTION_DURATION_BLOCKS` blocks and exactly `ConstantsLib.MPS = 1e7`.
    /// @dev Derived from the Base schedule (`StocksPreset.AUCTION_STEPS`): every scheduled window is
    ///      twenty times as many blocks and its per-block rate is the Base rate divided by twenty,
    ///      rounded to the nearest whole mps (5 to 10 mps over 108,900 down to 60,459 blocks). The
    ///      rounding shifts each step's release a little from Base's 5.79%-5.88%: the twelve scheduled
    ///      steps release 5.445% (first window) to 6.2432% each and the terminal block 29.3055%,
    ///      against Base's 29.88024% (accepted by the founder, 21 September 2026; per-step table in
    ///      the README). The twelfth step carries the nineteen blocks the single terminal block does
    ///      not, and the terminal block carries the remaining 2,930,550 mps. `RobinhoodPreset.t.sol`
    ///      proves both sums against this exact vector.
    bytes internal constant AUCTION_STEPS = hex"000005000001a964" hex"0000070000014ca8" hex"00000800000130d8"
        hex"0000080000011ff8" hex"0000080000011418" hex"0000090000010b08" hex"00000900000103b0" hex"000009000000fd84"
        hex"000009000000f848" hex"000009000000f3ac" hex"00000a000000efb0" hex"00000a000000ec2b" hex"2cb7760000000001";

    uint256 internal constant AUCTION_STEP_COUNT = 13;

    // -------------------------------------------------------------------------
    // protocol revenue
    // -------------------------------------------------------------------------

    /// @notice The hook's lanes, in basis points (`StocksPreset.BPS_DENOMINATOR`) of a swap's gross
    ///         STOCK amount: 0.3% to the launch's creator, 1% to the protocol lane (converted to USDG
    ///         outside swaps) and 3% to the launch's memestock stakers. The hook takes their sum, 4.3%,
    ///         floored once; the creator and protocol lanes are each floored and the staker lane is the
    ///         rest.
    // Founder decision 2026-09-28
    uint16 internal constant CREATOR_LANE_BPS = 30;
    uint16 internal constant PROTOCOL_LANE_BPS = 100;
    uint16 internal constant STAKER_LANE_BPS = 300;

    // -------------------------------------------------------------------------
    // Base destination
    // -------------------------------------------------------------------------

    /// @notice The only chain a bridge adapter may deliver protocol revenue to. Base mainnet.
    uint256 internal constant BASE_CHAIN_ID = 8453;
}
