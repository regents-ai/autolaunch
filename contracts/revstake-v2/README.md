# Autolaunch Revstake contracts, version 2

A Revstake launch creates an agent token, **SUBJECT**, with a fixed supply of 100 billion, sells
20% of it through the pinned Uniswap Continuous Clearing Auction (CCA) for REGENT, keeps up to 10%
as the pool reserve, and holds 70% in the launch's escrow to vest to its treasury. Every launch
opens at the same lowest floor price, and the required raise is that floor times the sale
allocation. A launch that reaches it graduates:

- the auction itself sells the whole 20% sale allocation to the bidders, up to rounding crumbs:
  it carries any supply a block did not sell into later blocks and never lowers its price;
- the official SUBJECT/REGENT Uniswap v4 pool opens at the auction's final clearing price, with
  one full-range position locked forever that pairs half the raise with at most the 10% reserve
  (at any reachable price half the raise needs no more than the reserve, so the REGENT side is
  the one that runs out);
- the rest of the raise, at least half, goes to the treasury;
- every SUBJECT left over (the reserve the position did not pair, the auction's rounding crumbs
  and anything sent to the strategy) goes to the escrow, and the 70% plus that leftover starts
  vesting to the treasury over 365 days.

A launch that misses its required raise fails: every bidder is refunded by the auction and the
whole supply is retired to the dead address.

This package replaces `contracts/v1` for new Base launches. It builds against the dependency
snapshot `contracts/stocks-v2` exports (`../stocks-v2/lib`, pinned by
`../stocks-v2/dependencies.json` to the revisions `contracts/v1` builds against) and never fetches.

## Status

Deployed on Base mainnet on 6 October 2026 for the 1 October 2026 terms (70/20/10, one fixed
floor, pool at the final clearing price, half the raise to the pool, 3% hook fee). Deployment
created the factory paused; opening is a separate Governance Safe action. See `deployments/base-mainnet/README.md`
and `deployments/base-mainnet/deployed-manifest.json`. New v2 launches are open as checked on
9 October 2026; the v1 factory is paused for new launches. Version 2 changes the sale and
graduation terms and the hook: the staker lane rises from 1% to 2%, while the 1% Regent lane
sends REGENT directly to live REGENT staking and SUBJECT to the Regent Safe. The total hook
fee is rounded once, with its remainder assigned to the staker lane. The splitter, payment
receiver and locker retain the version 1 sources; the v2 deployment creates new instances
bound to the new factory and strategy.

## Terms

| Term | Value |
| --- | --- |
| Supply | 100,000,000,000 SUBJECT, 18 decimals |
| Sale allocation | 20% (20,000,000,000) |
| Pool reserve | at most 10% (10,000,000,000) |
| Vesting | 70% (70,000,000,000) plus the unpaired reserve and leftovers, to the treasury over 365 days from graduation |
| Floor price | `FLOOR_PRICE_Q96 = 4,294,967,300` for every launch: the lowest whole number of bid ticks at or above the CCA minimum `2^32 + 1` |
| Bid tick spacing | `FLOOR_PRICE_Q96 / 100 = 42,949,673` |
| Required raise | `REQUIRED_REGENT_RAISED = ceil(20B × FLOOR_PRICE_Q96 / 2^96) = 1,084,202,174` REGENT base units; never zero, so an auction nobody bid in never graduates |
| Auction | opens 300 blocks after creation, runs 86,401 blocks on the thirteen-step v1 schedule |
| Claim / migration | 64 / 128 blocks after the auction ends |
| Pool price | the auction's final clearing price (`lbpInitializationParams().initialPriceX96`) |
| Pool position | full range from half the raise and at most the reserve, locked in `RevstakeLPLocker`; the treasury receives the rest of the raise |
| Pool fee | 0.30% LP fee, tick spacing 60, plus the `RegentFeeHook` 3%: 1% REGENT lane and 2% to the launch's splitter |
| Leftover SUBJECT | everything the strategy holds after graduation (the unpaired reserve, the auction's rounding crumbs and any SUBJECT sent to it) goes to the escrow and vests to the treasury with the 70% |

`migrate` is permissionless; the Regent bot sends it after the migration block.

### Rounding at the minimum

The pinned CCA counts a bid placed in the auction's first block in full, and counts a bid placed in
any later block up to one REGENT base unit short. A raise of exactly the minimum therefore
graduates only when it arrives in the first block; the minimum plus one base unit graduates in any
block. Front ends should ask for the minimum plus one unit.

## Layout

| Path | Owns |
| --- | --- |
| `src/factory/RegentsAutolaunchFactoryV2.sol` | Launch creation: token, escrow clone, auction through the strategy; payment receivers; the Governance and REGENT Safe's new-launch pause. |
| `src/strategy/RegentLBPStrategyV2.sol` | Auction parameters, required raise, migration, graduation into the pool, and retirement. |
| `src/escrow/ConditionalVestingEscrowV2.sol` | Holds the 70%, vests it and the graduation leftover to the treasury, retires the whole supply after failure. |
| `src/hook/RegentFeeHook.sol` | The official-pool fee hook. |
| `src/revenue/` | `SubjectSplitterV1`, `PaymentReceiverV1`, `RevstakeLPLocker`. |
| `src/bindings/BaseBindings.sol` | The frozen Base addresses. |
| `script/DeployRevstakeV2.s.sol` | The five-creation deployment, checked against its predictions while Foundry simulates it. |
| `test/` | Hermetic suite against real PoolManager, PositionManager, CCA factory and UERC20 bytecode. |
| `test-deployment/` | Rehearsal of the deployment script (`FOUNDRY_PROFILE=deployment`). |
| `requirements/`, `reports/frozen/`, `abi/` | The frozen identity, release surface and ABIs `bin/gate.sh` reconciles. |

## Checks

```
bin/gate.sh
```

The gate runs from a clean commit and is offline. It reconciles the toolchain, the effective
Foundry configuration, the compiled Base bindings and the dependency snapshot; checks formatting;
builds; regenerates and compares every frozen ABI and report; runs the whole suite; and runs Slither
against `docs/security/slither-dispositions.md`. The body is shared with the Memestake packages in
`../stocks-v2/bin/memestake-gate.sh`.

`FOUNDRY_PROFILE=deployment forge test` rehearses the deployment script. This package carries no
Base fork suite; the 28 September 2026 practice run on a copy of Base is described in
`SECURITY.md`. The signing kit uses the shared ceremony tool `../stocks-v2/bin/ceremony.py`; see
`deployments/base-mainnet/README.md`.
