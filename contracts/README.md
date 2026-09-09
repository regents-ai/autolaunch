# Autolaunch contracts

Three independent Foundry projects. Each is verified from its own directory, and none reads
another's sources or build output.

| Component | Purpose | Verify |
| --- | --- | --- |
| [v1/](v1/README.md) | The founder-frozen Autolaunch V1 auction system: specification, Solidity, requirement ledger, frozen release surface, deployment packet, and the three gates that decide whether the proofs still hold. Nothing in it is deployed. | `cd v1 && bin/gate.sh`, offline, after the one-time setup in its README |
| [stocks/](stocks/README.md) | Autolaunch Stocks: a new token auctioned through the pinned CCA for one admitted Base stock token, then migrated into a locked NEW/STOCK pool with STOCK-side revenue lanes. Local implementation with PROVISIONAL preset values; nothing in it is deployed or admitted. | `cd stocks && python3 bootstrap-deps.py <hydrated autolaunch checkout> && forge build && forge test --fuzz-runs 64`; fork suite per its README |
| [revenue-mesh/](revenue-mesh/README.md) | The offline CCTP foundation for immutable USDC revenue routes into a Base `PaymentReceiverV1`. Every route it produces is an unverified, inactive candidate. | `cd revenue-mesh && forge fmt --check && forge build && forge test --offline` |

`v1/` pins its dependency closure as Git submodules. They are declared in the repository's
top-level `.gitmodules` at `contracts/v1/lib/...` and materialized only for contract work; see
[v1/README.md](v1/README.md#setup). `stocks/` exports the same pinned revisions into its own
ignored `lib/` with `bootstrap-deps.py` and never edits `v1/`. `revenue-mesh/` has no external
dependencies.

The V1 gate proves that the whole repository, not only `v1/`, is one clean Git object, so
run it on a committed tree without build output elsewhere in the checkout.

The website's runtime copies of the V1 ABIs and chain manifest live in
[`platform/contracts/`](../platform/contracts/). They are consumers of this directory, not
sources.

## Founder decisions recorded 9 September 2026

- **Agent launch fee: 500,000 REGENT** (was the factory's built-in 1,000,000). `contracts/v1` is
  frozen, so the constant `INITIAL_LAUNCH_FEE` is not edited; the factory's designed mutable surface
  is used instead: the Governance and REGENT Safe calls `setLaunchFee(500_000e18)` as the activation
  step right after `unpauseLaunches`. The local Base-fork lab applies the same call
  (`contracts/stocks/bin/local-stocks-lab.py set-agent-fee`), and the website reads `launchFee()`
  from the factory, so no other component hardcodes the amount. Re-freezing V1 with a new constant
  would change its runtime identity and every frozen record; that remains a separate founder call.
- **Stocks launch fee: 100,000 REGENT**, paid at creation into REGENT staking as staker rewards
  (`fundRegentRewards`), never refunded. Implemented in `contracts/stocks/`.
- **Stocks preset values accepted** as recorded in `contracts/stocks/README.md`, on the basis that the
  step schedule keeps ~30% of the auction supply in the final block, as Agent's does.
- **Hook permission set accepted**: `beforeSwap` + `afterSwap` with return deltas so STOCK is charged on
  every swap form.
- **Listing**: only launches this website verified are listed, for now.
- **One active Stocks launch per account** is a website rule; the contracts admit any launcher.
