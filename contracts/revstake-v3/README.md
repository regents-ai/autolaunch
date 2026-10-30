# Autolaunch Revstake contracts, version 3

Version 3 is version 2 (`contracts/revstake-v2`) for Base's 0.2-second blocks. Base's Denim upgrade
(5 November 2026, 18:00 UTC) cuts the block time from 2 seconds to 0.2 seconds; timestamps stay in
whole seconds, so five blocks share each second. Version 2's strategy counts its auction and delays
in blocks, so on the new chain a 48-hour auction would end in 4.8 hours. Version 3 restates every
block count so each lasts the wall-clock time it did at 2-second blocks. Every sale, pool, fee,
escrow and staking term is unchanged; `contracts/revstake-v2/README.md` describes them.

This package builds against the dependency snapshot `contracts/stocks-v3` exports
(`../stocks-v3/lib`, pinned by `../stocks-v3/dependencies.json` to the revisions `contracts/v1`
builds against) and never fetches. Nothing in `contracts/revstake-v2` or any other package changes.

## Status

**Not deployed.** The factory is born paused, as every version is. It is to be opened by the
Governance and REGENT Safe only after Base mainnet is producing 0.2-second blocks; before Denim
every duration here would run ten times too long (a 20-day auction). Nothing here branches on the
Denim block: version 2 serves launches before it, version 3 after it.

## Changes from version 2

| Change | Version 2 | Version 3 | Why |
| --- | --- | --- | --- |
| Factory | `RegentsAutolaunchFactoryV2` | `RegentsAutolaunchFactoryV3` | It deploys and binds the new strategy and its own mined `RegentFeeHook` |
| Strategy | `RegentLBPStrategyV2` | `RegentLBPStrategyV3` | The launch terms below live in its bytecode |
| Start delay | 300 blocks | 3,000 blocks | Ten minutes at 0.2 s |
| Auction duration | 86,401 blocks | 864,001 blocks | Version 2's 86,400 scheduled blocks ten times over, plus its one terminal block |
| Step schedule | 13 steps | 19 steps, regenerated (below) | The same release at the same wall-clock time |
| Claim delay | 64 blocks | 640 blocks | 128 seconds after the end |
| Migration delay | 128 blocks | 1,280 blocks | 256 seconds after the end |

The escrow, splitter and payment receiver are reused: the factory accepts only implementations
whose runtime code hashes match version 2's, so a version 3 deployment points it at version 2's
deployed implementations. Their sources here are byte-identical copies, kept so the tests build
them. The escrow already vests on `block.timestamp` (365 days from the graduation timestamp) and is
unaffected by the block time. The splitter's rule that an unstake waits for the next block is about
ordering, not time, and is unchanged.

## Every duration

| Duration | Blocks | Wall-clock at 0.2 s blocks | Version 2 (blocks at 2 s) |
| --- | --- | --- | --- |
| Launch to auction start (`START_DELAY_BLOCKS`) | 3,000 | 10 minutes | 300, 10 minutes |
| Auction, start to end (`AUCTION_DURATION_BLOCKS`) | 864,001 | 172,800.2 s, 48 hours and 0.2 s | 86,401, 48 hours and 2 s |
| End to claim block (`CLAIM_DELAY_BLOCKS`) | 640 | 128 s | 64, 128 s |
| End to migration block (`MIGRATION_DELAY_BLOCKS`) | 1,280 | 256 s | 128, 256 s |
| Escrow vesting (`VESTING_DURATION`, unchanged) | not counted in blocks | 365 days from the graduation timestamp | 365 days |

## The step schedule

Each version 2 step of `b` blocks at `m = 10q + r` mps becomes `(10 - r) × b` blocks at `q` mps and
`r × b` blocks at `q + 1` mps, which releases exactly `m × b`; neighbouring pieces at one rate are
joined, and the single terminal block keeps its 2,988,006 mps. The auction therefore releases
exactly what version 2 released at every one of its step boundaries, at the same wall-clock time,
and between boundaries the two differ by at most 26,144 mps (0.26% of the sale).

| Step | mps | Blocks |
| --- | --- | --- |
| 1 | 5 | 65,364 |
| 2 | 6 | 60,610 |
| 3 | 7 | 107,151 |
| 4 | 8 | 39,015 |
| 5 | 7 | 7,373 |
| 6 | 8 | 115,833 |
| 7 | 9 | 21,204 |
| 8 | 8 | 34,175 |
| 9 | 9 | 34,175 |
| 10 | 8 | 13,294 |
| 11 | 9 | 168,924 |
| 12 | 10 | 12,712 |
| 13 | 9 | 37,428 |
| 14 | 10 | 24,952 |
| 15 | 9 | 30,680 |
| 16 | 10 | 30,680 |
| 17 | 9 | 18,129 |
| 18 | 10 | 42,301 |
| 19 | 2,988,006 | 1 |

Packed as `RegentLBPStrategyV3.AUCTION_STEPS` (19 × 8 bytes, `uint24 mps | uint40 blockDelta`):

```
000005000000ff54 000006000000ecc2 000007000001a28f 0000080000009867 0000070000001ccd
000008000001c479 00000900000052d4 000008000000857f 000009000000857f 00000800000033ee
00000900000293dc 00000a00000031a8 0000090000009234 00000a0000006178 00000900000077d8
00000a00000077d8 00000900000046d1 00000a000000a53d 2d97e60000000001
```

## Layout

The layout is version 2's, with `src/factory/RegentsAutolaunchFactoryV3.sol` and
`src/strategy/RegentLBPStrategyV3.sol` in place of the version 2 factory and strategy. Tests
changed or added:

| Path | Proves |
| --- | --- |
| `test/strategy/RegentLBPStrategy.t.sol` | The new constants (`STR-005` to `STR-008`, `STR-013`) and the frozen 152-byte schedule. |
| `test/strategy/RegentLBPStrategySchedule.t.sol` | The schedule equals version 2 at every version 2 step boundary and stays within 26,144 mps of it at every 2-second mark and, by fuzzing, at any block; and a version 3 launch's auction from the pinned CCA reports exactly what a version 2 auction from the same factory reports at every boundary, ten times as many blocks in. |
| `test/strategy/V2Schedule.sol` | Version 2's schedule, kept only as the reference, and the schedule arithmetic the tests use. |
| `test/invariant/handlers/LifecycleHandler.sol` | The lifecycle invariants now move the chain at five blocks a second. |
| `test/sepolia/AutolaunchSepoliaLaunch.t.sol` | On a fork of Base Sepolia (0.2 s blocks since 21 October 2026): a launch through the real pinned CCA factory (code hash checked against `BaseBindings`) and Permit2 opens 10 minutes after launch, releases version 3's amount at 24 hours, ends after 48 hours, claims after 128 s, migrates at 256 s and not one block earlier, graduates, and vests the escrow half at half a year and all at a year. |

Version 2's deployment kit (`script/`, `test-deployment/`, `deployments/`, `bin/`, `requirements/`,
`reports/frozen/`, `abi/`, `SECURITY.md`) is not carried: a version 3 deployment kit is a separate
step.

## Checks

```sh
cd contracts/revstake-v3          # with ../stocks-v3/lib in place
forge build
forge test                                     # hermetic, offline
FOUNDRY_PROFILE=sepolia forge test             # Base Sepolia fork, public endpoint, read-only
```

`foundry.toml` sets `isolate = false`: each test runs as one transaction, as under the frozen Forge
1.5.1. Newer Forge isolates every top-level call by default, which spends a deployer nonce per call
and breaks the fixtures' address predictions.

The Sepolia profile forks `https://sepolia.base.org` inside Forge; nothing is signed or sent. The
pool pieces, REGENT, USDC and REGENT staking are built fresh at their Base mainnet addresses, which
hold nothing usable on Sepolia; the CCA factory and Permit2 are Sepolia's own.
