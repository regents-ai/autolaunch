# Autolaunch Revstake contracts, version 2

A Revstake launch creates an agent token, **SUBJECT**, with a fixed supply of 100 billion, sells
20% of it through the pinned Uniswap Continuous Clearing Auction (CCA) for REGENT, keeps 15% as the
pool reserve, and holds 65% in the launch's escrow to vest to its treasury. A launch that reaches
its required raise graduates:

- the auction itself sells the whole 20% sale allocation to the bidders, up to rounding crumbs:
  it carries any supply a block did not sell into later blocks and never lowers its price;
- the official SUBJECT/REGENT Uniswap v4 pool opens at the raise divided by the sale allocation,
  with one full-range position locked forever that pairs as much of the 15% reserve and of a
  three-quarter share of the raise as it can;
- the rest of the raise, at least a quarter, goes to the treasury;
- every SUBJECT left over (the auction's rounding crumbs, any reserve the position could not pair
  and anything sent to the strategy) goes to the escrow, and the 65% plus that leftover starts
  vesting to the treasury over 365 days.

A launch that misses its required raise fails: every bidder is refunded by the auction and the
whole supply is retired to the dead address.

This package replaces `contracts/v1` for new Base launches. It builds against the dependency
snapshot `contracts/stocks-v2` exports (`../stocks-v2/lib`, pinned by
`../stocks-v2/dependencies.json` to the revisions `contracts/v1` builds against) and never fetches.

## Status

Not deployed. The Base packet is prepared and rehearsed, awaiting the founder's approval of its
digest; see `deployments/base-mainnet/README.md`. Version 2 changes only the sale and graduation
terms (founder decisions of 27 September 2026). The hook, splitter, payment receiver and locker are the version 1 sources;
a version 2 deployment creates new instances bound to the new factory and strategy.

## Terms

| Term | Value |
| --- | --- |
| Supply | 100,000,000,000 SUBJECT, 18 decimals |
| Sale allocation | 20% (20,000,000,000) |
| Pool reserve | 15% (15,000,000,000) |
| Vesting | 65% (65,000,000,000) to the treasury over 365 days from graduation |
| Floor price | chosen by the launcher; must be a whole number of bid ticks (`floorPriceQ96 % 100 == 0`) and at least the CCA minimum |
| Bid tick spacing | `floorPriceQ96 / 100` |
| Required raise | the larger of `ceil(20B × floorPriceQ96 / 2^96)` REGENT and the launcher's `minimumRegentRaised`; never zero, so an auction nobody bid in never graduates; must be reachable on the bid grid |
| Auction | opens 300 blocks after creation, runs 86,401 blocks on the thirteen-step v1 schedule |
| Claim / migration | 64 / 128 blocks after the auction ends |
| Pool price | raise ÷ sale allocation |
| Pool position | full range from the reserve and a three-quarter budget of the raise, as much as it can pair, locked in `RevstakeLPLocker`; the treasury receives the rest of the raise |
| Pool fee | 0.30% LP fee, tick spacing 60, plus the `RegentFeeHook` lanes |
| Leftover SUBJECT | everything the strategy holds after graduation (the auction's rounding crumbs, unpaired reserve and any SUBJECT sent to it) goes to the escrow and vests to the treasury with the 65% |

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
| `src/escrow/ConditionalVestingEscrowV2.sol` | Holds the 65%, vests it and the graduation leftover to the treasury, retires the whole supply after failure. |
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
Base fork suite and no ceremony tooling; those remain in `contracts/v1` and are a separately
authorized step before any deployment.
