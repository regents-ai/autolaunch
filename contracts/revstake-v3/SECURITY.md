# Autolaunch Revstake version 3: security posture

Status: not deployed, unit-proven against the hermetic suite, not externally audited. Version 3
is version 2 for Base's 0.2-second blocks (`README.md`): the design rules, the test map and the
known limits in `../revstake-v2/SECURITY.md` apply unchanged, with `RegentsAutolaunchFactoryV3` and
`RegentLBPStrategyV3` in place of the version 2 factory and strategy. This file records only what
version 3 adds.

## What changes

- **Durations.** Every block count in the strategy is restated so it lasts the wall-clock time it
  did at 2-second blocks, and the auction's step schedule is regenerated to release exactly what
  version 2 released at each of its step boundaries
  (`test/strategy/RegentLBPStrategySchedule.t.sol`).
- **Reused implementations.** The escrow, splitter and payment receiver are version 2's deployed
  contracts. The factory's constructor refuses any implementation, or UERC20 factory, whose runtime
  code hash is not the one this build pins, so a substituted or swapped address cannot be bound.

## The deployment

- One creation from one deployer, checked against its prediction while Foundry simulates the
  script; the strategy, the LP locker and the hook are read back before the simulation ends
  (`test-deployment/DeploymentCeremony.t.sol`, which also proves a swapped implementation is
  refused by its code hash).
- The script imports no miner: the hook salt is mined once in `test-deployment/` and pinned in the
  packet, and the script only consumes it.
- The factory is born paused; the deployer holds no role afterwards. The only privileged power is
  the Governance and Regent Safe's pause and unpause of new launches.
- `prepare` and `rehearse` prove on Base that each reused address carries the frozen runtime code
  hash, and `rehearse` simulates the exact creation transaction on a Base node, offered the latest
  block's gas limit as the node reports it at that run.
