# Autolaunch Stocks version 3: security posture

Status: not deployed, unit-proven against the hermetic suite, not externally audited. Version 3
is version 2 for Base's 0.2-second blocks (`README.md`): the design rules, the invariants and their
proofs, and the known limits in `../stocks-v2/SECURITY.md` apply unchanged to every source this
package keeps from version 2 (the hook, the bid adapter, the splitter, the LP locker and the stock
routes). This file records only what version 3 adds.

## What changes

- **Durations.** Every block count in the launchpad is restated so it lasts the wall-clock time it
  did at 2-second blocks, and the auction's step schedule is regenerated to release exactly what
  version 2 released at each of its step boundaries (`test/StocksPreset.t.sol`,
  `test/StocksScheduleAuction.t.sol`).
- **Creator vesting on timestamps.** `releaseCreatorVesting` vests linearly over 30 days of
  `block.timestamp` from the graduation timestamp, so five blocks sharing one second release
  nothing new (`test/StocksLaunchpadMigrate.t.sol`).
- **No route is created.** The ten version 2 routes are reused, unchanged. The launchpad accepts a
  route only through the Governance and Regent Safe's `admitStock(stock, route)`, which requires
  code at both addresses, the route's `stock()` to be that stock and its `usdc()` to be Base USDC.

## The deployment

- Two creations from one deployer, in one fixed order, both checked against their predictions while
  Foundry simulates the script; the launchpad's three internal creations are read back before the
  simulation ends (`test-deployment/DeploymentCeremony.t.sol`).
- The script imports no miner: the hook salt is mined once in `test-deployment/` and pinned in the
  packet, and the script only consumes it.
- The launchpad is born paused with no stock admitted; the deployer holds no role afterwards. Only
  the Safe can admit a stock, which the ceremony suite proves against a route deployed the way
  version 2 deployed its routes, together with the deployer's refusal and a mismatched stock's
  refusal.
- `rehearse` simulates the exact creation transactions and the Safe's ten admissions on a Base node,
  each creation offered the latest block's gas limit as the node reports it at that run.
