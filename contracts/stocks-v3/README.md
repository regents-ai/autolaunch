# Autolaunch Stocks contracts, version 3

Version 3 is version 2 (`contracts/stocks-v2`) for Base's 0.2-second blocks. Base's Denim upgrade
(5 November 2026, 18:00 UTC) cuts the block time from 2 seconds to 0.2 seconds; timestamps stay in
whole seconds, so five blocks share each second. Version 2 counts its auction, its delays and the
creator vesting in blocks, so on the new chain each would last a tenth of its intended time: a
24-hour auction would end in 2.4 hours and the 30-day creator vesting would finish in 3 days.
Version 3 restates every block count so each lasts the wall-clock time it did at 2-second blocks,
and moves the creator vesting onto `block.timestamp`. Every sale, pool, fee and staking term is
unchanged; `contracts/stocks-v2/README.md` describes them.

This is a separate Foundry component. Nothing in `contracts/stocks-v2` or any other package
changes. It builds against the pinned dependency snapshot it exports itself (`dependencies.json`,
`bootstrap-deps.py`), at the same revisions `contracts/v1` builds against.

## Status

**Deployed and open since 12 November 2026**: the launchpad at
`0x1db36b3BD9eC61c54B06a753FeC0b425237D7E7C` and its bid adapter at
`0xa28334dEbaeea58Cd0b12D6814219498293EE1fA` ([receipts](deployments/base-mainnet/README.md)). The
launchpad was born paused, as every version is, and the Governance and REGENT Safe admitted the ten
stocks and opened it the same day. Base mainnet has made 0.2-second blocks since block 53,556,127 (5 November 2026,
18:00:01 UTC), measured on the chain on 12 November 2026 over 3,000 and 300,000 blocks; Base has
announced no further change. Nothing here branches on the Denim block: version 2, now paused,
served launches before it, version 3 serves them after it.

## Changes from version 2

| Change | Version 2 | Version 3 | Why |
| --- | --- | --- | --- |
| Launchpad | `StocksLaunchpadV2`, `IStocksLaunchpadV2` | `StocksLaunchpadV3`, `IStocksLaunchpadV3` | The launch terms below live in its bytecode |
| Hook and bid adapter | bound to `IStocksLaunchpadV2` | the same sources bound to `IStocksLaunchpadV3` | They read the launchpad they serve; new instances are created with it |
| Start lead | 300 blocks | 3,000 blocks | Ten minutes at 0.2 s |
| Auction duration | 43,200 blocks | 431,991 blocks | Version 2's 43,199 scheduled blocks ten times over, plus its one terminal block |
| Step schedule | 13 steps | 13 steps, regenerated (below) | The same release at the same wall-clock time |
| Claim delay | 64 blocks | 640 blocks | 128 seconds after the end |
| Migration delay | 128 blocks | 1,280 blocks | 256 seconds after the end |
| Creator vesting | `CREATOR_VESTING_BLOCKS` 1,296,000, linear per block from the graduation block | `CREATOR_VESTING_SECONDS` 30 days (2,592,000 s), linear per second from the graduation timestamp, no cliff | Seconds do not change with the block time; the launch record's `vestingStartBlock` becomes `vestingStart`, a timestamp |

The splitter, the locker and the stock routes keep their version 2 sources; the launchpad deploys
its own locker and splitter implementation as version 2's did. The splitters' rule that an unstake
waits for the next block is about ordering, not time, and is unchanged.

## Every duration

| Duration | Blocks | Wall-clock at 0.2 s blocks | Version 2 (blocks at 2 s) |
| --- | --- | --- | --- |
| Creation to auction start (`START_LEAD_BLOCKS`) | 3,000 | 10 minutes | 300, 10 minutes |
| Auction, start to end (`AUCTION_DURATION_BLOCKS`) | 431,991 | 86,398.2 s, 24 hours less 1.8 s | 43,200, 24 hours |
| End to claim block (`CLAIM_DELAY_BLOCKS`) | 640 | 128 s | 64, 128 s |
| End to migration block (`MIGRATION_DELAY_BLOCKS`) | 1,280 | 256 s | 128, 256 s |
| Creator vesting (`CREATOR_VESTING_SECONDS`) | not counted in blocks | 30 days from the graduation timestamp | 1,296,000 blocks, 30 days |
| Stock route feed age (`MAX_FEED_AGE`, unchanged) | not counted in blocks | 7 days | 7 days |

## The step schedule

Each version 2 step of `b` blocks at `m = 10q + r` mps becomes `(10 - r) × b` blocks at `q` mps and
`r × b` blocks at `q + 1` mps, which releases exactly `m × b`; neighbouring pieces at one rate are
joined, and the single terminal block keeps its 2,988,024 mps. The auction therefore releases
exactly what version 2 released at every one of its step boundaries, at the same wall-clock time,
and between boundaries the two differ by at most 10,218 mps (0.10% of the sale).

| Step | mps | Blocks |
| --- | --- | --- |
| 1 | 10 | 10,890 |
| 2 | 11 | 43,560 |
| 3 | 13 | 17,032 |
| 4 | 14 | 25,548 |
| 5 | 15 | 46,392 |
| 6 | 16 | 43,624 |
| 7 | 17 | 68,680 |
| 8 | 18 | 71,462 |
| 9 | 19 | 12,712 |
| 10 | 18 | 6,238 |
| 11 | 19 | 73,764 |
| 12 | 20 | 12,088 |
| 13 | 2,988,024 | 1 |

Packed as `StocksPreset.AUCTION_STEPS` (13 × 8 bytes, `uint24 mps | uint40 blockDelta`):

```
00000a0000002a8a 00000b000000aa28 00000d0000004288 00000e00000063cc 00000f000000b538
000010000000aa68 0000110000010c48 0000120000011726 00001300000031a8 000012000000185e
0000130000012024 0000140000002f38 2d97f80000000001
```

Both sums are exact: the block deltas add to 431,991 (version 2's 43,199 scheduled blocks × 10,
plus 1) and `mps × blockDelta` adds to 10,000,000. Every step's product stays below the CCA's
`uint24` (the largest is 2,988,024).

### Where rounding lands

An mps is a whole number, and a tenth of version 2's rate is not, so each version 2 window is split
into a stretch at the rate rounded down and a stretch at the rate rounded up, in the proportion that
makes the window's total exact. Nothing is rounded across a window boundary, so nothing accumulates:
the release is equal to version 2's at all twelve boundaries. Inside a window the round-down stretch
comes first, so version 3 runs slightly behind version 2 and catches up by the window's end. The
widest gap is 10,218 mps (0.10% of the sale, about 508,000 tokens of 497.5 million), at about 3.97
hours. Where version 2 rose by less than 10 mps from one window to the next (windows 9 to 10), the
rate dips for one stretch (19, 18, 19): exact boundaries with whole mps leave no other choice, and
the CCA sets its clearing price from the demand against the supply still to be sold, not from one
block's rate.

### Tokens per block

Version 2 at 2 s blocks against version 3 at 0.2 s blocks, for a sale of 1,000,000,000 tokens (the
real sale is 497,500,000; multiply by 0.4975):

| Window | Version 2: mps × blocks | Tokens per 2 s block | Tokens a second | Version 3: mps × blocks | Tokens per 0.2 s block | Tokens a second |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | 108 × 5,445 | 10,800 | 5,400 | 10 × 10,890, 11 × 43,560 | 1,000, 1,100 | 5,000, 5,500 |
| 2 | 136 × 4,258 | 13,600 | 6,800 | 13 × 17,032, 14 × 25,548 | 1,300, 1,400 | 6,500, 7,000 |
| 3 | 150 × 3,902 | 15,000 | 7,500 | 15 × 39,020 | 1,500 | 7,500 |
| 4 | 158 × 3,686 | 15,800 | 7,900 | 15 × 7,372, 16 × 29,488 | 1,500, 1,600 | 7,500, 8,000 |
| 5 | 166 × 3,534 | 16,600 | 8,300 | 16 × 14,136, 17 × 21,204 | 1,600, 1,700 | 8,000, 8,500 |
| 6 | 170 × 3,418 | 17,000 | 8,500 | 17 × 34,180 | 1,700 | 8,500 |
| 7 | 176 × 3,324 | 17,600 | 8,800 | 17 × 13,296, 18 × 19,944 | 1,700, 1,800 | 8,500, 9,000 |
| 8 | 180 × 3,245 | 18,000 | 9,000 | 18 × 32,450 | 1,800 | 9,000 |
| 9 | 184 × 3,178 | 18,400 | 9,200 | 18 × 19,068, 19 × 12,712 | 1,800, 1,900 | 9,000, 9,500 |
| 10 | 188 × 3,119 | 18,800 | 9,400 | 18 × 6,238, 19 × 24,952 | 1,800, 1,900 | 9,000, 9,500 |
| 11 | 190 × 3,068 | 19,000 | 9,500 | 19 × 30,680 | 1,900 | 9,500 |
| 12 | 194 × 3,022 | 19,400 | 9,700 | 19 × 18,132, 20 × 12,088 | 1,900, 2,000 | 9,500, 10,000 |
| Last block | 2,988,024 × 1 | 298,802,400 | | 2,988,024 × 1 | 298,802,400 | |

On the real sale the last block releases 148,654,194 tokens in both versions.

### The last block

The pinned CCA's documentation requires the last block to sell a significant amount, because the
final clearing price opens the Uniswap pool and a thin last block would be easy to move. Version 3
keeps version 2's last block whole, at the same 29.88% of the sale in one block, rather than
spreading it over ten 0.2 s blocks. A last block is now a tenth as long, so there is less time to
react inside it, which only makes the single block harder to manipulate.

### Not chosen

An auction of exactly 24 hours (432,000 blocks) needs 9 more blocks: window 12 extended by 9 blocks
at 20 mps and the last block cut to 2,987,844 mps. It gains 1.8 seconds and takes 180 mps out of
the last block, which then no longer matches version 2's. It is not taken.

## Layout

The layout is version 2's, with `src/StocksLaunchpadV3.sol` and `src/interfaces/IStocksLaunchpadV3.sol`
in place of the version 2 launchpad.

The deployment kit follows version 2's, for the two creations version 3 makes:
`script/DeployStocksV3.s.sol`, the frozen release surface in `requirements/`, `reports/frozen/`
and `abi/`, the gate `bin/gate.sh`, `SECURITY.md`, and
`deployments/base-mainnet/`, whose `README.md` describes the ceremony and the Safe's admission of
version 2's ten routes afterwards. The ceremony tool is `bin/ceremony.py`.

## Checks

```sh
cd contracts/stocks-v3
python3 bootstrap-deps.py /path/to/hydrated/autolaunch/checkout   # once; fills lib/
forge build
./bin/gate.sh                                  # the required gate, offline, on a clean commit
python3 bin/ceremony.py render    # the deployment packet, offline
```
