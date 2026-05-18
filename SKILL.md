# Autolaunch

Use this skill when working on the Autolaunch launch lifecycle in this repo.

## Why agents use Autolaunch

Use this framing when the question is strategic, not just operational:

- Autolaunch is for agents that have some real edge and need runway to keep compounding it.
- The point is not "launch a token." The point is to raise capital, build treasury room, and keep paying for compute, APIs, data, retries, and distribution.
- The launch should create aligned backers who care about the agent staying online and getting stronger, not just a one-day spike of attention.
- The strongest short pitch is: turn agent edge into runway.

## Required environment

The golden path depends on a live backend:

- Phoenix running
- Postgres running
- launch-chain RPC configured and reachable
- SIWA sidecar reachable
- deploy binary, deploy workdir, and deploy script target present on the launch node

Without those pieces, the CLI and browser cannot complete the guided launch flow.

For agent-driven operation through `regents-cli`, assume these environment values are part of the setup:

- `AUTOLAUNCH_BASE_URL`
- either `AUTOLAUNCH_SESSION_COOKIE`
- or `AUTOLAUNCH_PRIVY_BEARER_TOKEN` plus `AUTOLAUNCH_WALLET_ADDRESS`
- optional `AUTOLAUNCH_DISPLAY_NAME`

Before a real launch, expect the launch node to pass:

- `mix autolaunch.doctor`
- `AUTOLAUNCH_MOCK_DEPLOY=true mix autolaunch.smoke`

After a real launch reaches `ready`, expect:

- `mix autolaunch.verify_deploy --job <job-id>`

If deploys are timing out because Sepolia or the deploy node is slow, adjust `AUTOLAUNCH_DEPLOY_TIMEOUT_MS` in the environment rather than changing the code path.

## Auction mental model

When you describe the public auction, keep the explanation plain and consistent:

- say that Autolaunch uses a Continuous Clearing Auction because it is meant to help quality teams bootstrap liquidity with healthier market behavior and real price discovery
- explain that buyers choose a total budget and a max price
- explain that the order runs across the remaining blocks like a TWAP instead of landing all at once
- explain that each block clears at the highest price where demand exceeds supply
- explain that buyers receive tokens only while the clearing price stays below their max price, and the remaining TWAP stops once that cap is exceeded
- explain that the intended strategy is to bid early with a real budget and a real max price, not to wait for timing games
- call out that, with sane auction timing, the design aims to reduce sniping, sandwiching, bundling, and other speed advantages

## Economic mental model

When the question is how the money flow actually works, keep these rules straight:

- each launch uses the fixed 10 / 5 / 85 supply split
- 10% of the 100 billion supply is sold in the auction
- 5% is reserved for LP migration
- 85% vests to the agent treasury over one year
- half of the auction $REGENT funds the LP migration
- the other half of the auction $REGENT goes to the agent Safe for operating runway

The fixed fee rules are also important:

- the official launch pool charges a fixed 2% fee
- that 2% split is fixed at 1% to Regent and 1% to the agent treasury
- recognized subject revenue first sends a fixed 1% skim to Regent
- the remaining 99% stays in the subject lane, where stakers earn their formula share and the treasury keeps the remainder

That means the sale gives the agent upfront quote-token runway, the launch pool gives the agent an always-on quote-token fee lane, and the subject lane gives long-term holders a reason to stay once real revenue arrives.

## Golden path

Treat the CLI as the main operator entrypoint:

1. `regents autolaunch safe wizard`
2. `regents autolaunch safe create`
3. `regents autolaunch prelaunch wizard`
4. `regents autolaunch prelaunch validate`
5. `regents autolaunch prelaunch publish`
6. `regents autolaunch launch run`
7. `regents autolaunch launch monitor`
8. `regents autolaunch launch finalize`
9. `regents autolaunch vesting status`
10. `regents autolaunch vesting release`

Skip the Safe steps only when the agent Safe already exists and the plan already points to it.

If you are working from the `regents-cli` source checkout instead of an installed package, run the same flow through:

`pnpm --filter @regentslabs/cli exec regents autolaunch ...`

## Local plan and auth rules

- `prelaunch wizard` is the command that creates or refreshes the saved local plan used by later guided commands.
- `launch run` and later steps should reuse that saved plan unless the operator explicitly names a different plan.
- Do not invent alternate local state flows outside the CLI state directory unless the product contract changes.
- When authenticated CLI calls fail, check the Privy bearer token or session cookie path first.
- When launch execution fails before any chain write, check `mix autolaunch.doctor` before assuming product logic is wrong.

## Prelaunch-first rules

- Always start with `prelaunch wizard` or `prelaunch show`.
- Never call raw `launch create` directly if a plan does not already exist.
- Treat the saved prelaunch plan as the source of truth for launch inputs.
- One active launch plan per agent identity. Older active drafts are archived.
- Hosted metadata and launch images live behind the Autolaunch backend in v1.

## Plan lifecycle

Prelaunch plans move through these states:

- `draft`
- `validated`
- `launchable`
- `launched`
- `archived`

The validation summary must carry:

- launch blockers
- warnings
- current identity metadata snapshot
- trust follow-up status
- exact launchability

## Launch run flow

`launch run` should:

- load the saved plan
- revalidate it against backend truth
- obtain the SIWA signature bundle
- queue the launch job
- read back the launch stack
- surface the job id, auction id, splitter, ingress, strategy, and vesting addresses clearly

## Monitoring flow

Use `launch monitor` for lifecycle checks before touching strategy actions.

The lifecycle surface must answer:

- is migration ready?
- is currency sweep ready?
- is token sweep ready?
- is vesting releasable?
- what action is recommended next?

## Finalize flow

Treat `launch finalize` as the default post-auction path.

It should guide the operator through:

- migrate when the strategy is ready
- sweep currency when the auction-side currency can move
- sweep token when leftover token can move

Use direct strategy commands only when debugging or recovering from an exceptional case.

## Vesting flow

Use `vesting status` first.

That output should show:

- vesting wallet
- releasable amount
- released amount
- beneficiary
- whether release is ready now

Then use `vesting release` only when the release path is actually ready.

## Advanced surfaces

The advanced contract and subject flows still exist, but they are not the primary operator path:

- `/contracts`
- `/subjects/:id`
- `/api/contracts/...`
- `regents autolaunch strategy ...`
- `regents autolaunch fee-registry ...`
- `regents autolaunch fee-vault ...`
- `regents autolaunch splitter ...`
- `regents autolaunch ingress ...`

Use those only for debugging, incident response, or explicit advanced ops.

## Separate REGENT staking rail

The company-token rewards rail is separate from agent subject revenue rights.

- Use the subject commands only for per-agent subject splitters on Sepolia.
- Use the REGENT staking commands only for the singleton `$REGENT` staking contract on Base mainnet.
- Do not describe the REGENT rail as automatic. Non-Base income is still: receive into Treasury A, bridge manually to Base USDC, then deposit manually into the Base staking contract.

## Canonical examples

Use [`docs/autolaunch_examples.json`](docs/autolaunch_examples.json) as the machine-readable reference for:

- prelaunch plan drafts
- prelaunch validation responses
- launch preview and launch job responses
- lifecycle monitor responses
- finalize responses
- vesting status responses
- bid quotes and position state

If a response shape changes, update the examples and the tests together.
