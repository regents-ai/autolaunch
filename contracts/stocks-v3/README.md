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

**Not deployed.** The launchpad is born paused, as every version is. It is to be opened by the
Governance and REGENT Safe only after Base mainnet is producing 0.2-second blocks; before Denim
every duration here would run ten times too long (a 10-day auction). Nothing here branches on the
Denim block: version 2 serves launches before it, version 3 after it.

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

## Layout

The layout is version 2's, with `src/StocksLaunchpadV3.sol` and `src/interfaces/IStocksLaunchpadV3.sol`
in place of the version 2 launchpad. Added tests:

| Path | Proves |
| --- | --- |
| `test/StocksPreset.t.sol` | The new constants; the schedule sums to `1e7` over 431,991 blocks; it equals version 2 at every version 2 step boundary and stays within 10,218 mps of it at every 2-second mark and, by fuzzing, at any block. |
| `test/StocksScheduleAuction.t.sol` | The pinned CCA accepts the schedule, and a version 3 launch's auction reports exactly what a version 2 auction from the same factory reports at every version 2 boundary, ten times as many blocks in. |
| `test/StocksLaunchpadMigrate.t.sol` | Creator vesting on timestamps: before graduation, at the start, the middle, the end and after it, and five blocks sharing one timestamp releasing nothing new. |
| `test/V2Schedule.sol` | Version 2's schedule, kept only as the reference, and the schedule arithmetic the tests use. |
| `test/sepolia/StocksSepoliaLaunch.t.sol` | On a fork of Base Sepolia (0.2 s blocks since 21 October 2026): the chain runs five blocks a second, and a launch through the real pinned CCA factory (code hash checked) and Permit2 opens 10 minutes after creation, releases version 3's amount at 12 hours, ends after a day, claims after 128 s, migrates at 256 s and not one block earlier, and vests the creator half at 15 days and all at 30. |

`test/fork/AerodromeStockRouteFork.t.sol` runs the stock routes, unchanged from version 2, against
the local Base-fork lab. Version 2's deployment kit (`script/`, `deployments/`, `bin/`, `requirements/`,
`reports/frozen/`, `abi/`, `SECURITY.md`) and the lab controller are not carried: a version 3 deployment kit is a separate step.

## Checks

```sh
cd contracts/stocks-v3
python3 bootstrap-deps.py /path/to/hydrated/autolaunch/checkout   # once; fills lib/
forge build
forge test                                     # hermetic, offline
FOUNDRY_PROFILE=sepolia forge test             # Base Sepolia fork, public endpoint, read-only
```

The Sepolia profile forks `https://sepolia.base.org` inside Forge; nothing is signed or sent. The
pool pieces, USDC, REGENT staking and the stock are built fresh at their Base mainnet addresses,
which hold nothing usable on Sepolia; the CCA factory and Permit2 are Sepolia's own.
