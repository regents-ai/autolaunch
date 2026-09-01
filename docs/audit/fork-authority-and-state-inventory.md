# Fork authority and staged-state inventory

The separately authorized read-only Base fork gate, the exact authority it runs under, and every
piece of test state it stages with a cheatcode — each named against the real production path that
makes that state reachable.

## 1. Founder fork authority

The founder's instruction authorizing the separate fork gate, carried verbatim:

```text
PLEASE IMPLEMENT THIS PLAN. Separate authorized fork gate covers: Exact Base runtime and codehash bindings; protocolFeeController() == address(0); real CCA creation and bidder Permit2 behavior; live staking depositUSDC behavior and paused fail-closed behavior; PoolManager/PositionManager semantics; successful, failed, and zero-bid terminal paths; full transaction gas including intrinsic/calldata; pinned block and fresh latest-head repetitions.
```

**SHA-256:** `1100a62d23c8ae53c90d47a6d4e42d26e166efdb9ec48b5777990c8e3a8c3b6d`

That digest is over the text above followed by exactly one newline byte and nothing else. It was
recomputed while writing this document and matched; the two other plausible encodings — no trailing
newline, and CRLF — hash to different values and are recorded here so a future reader can tell which
encoding the digest belongs to without guessing.

## 2. What the authority does and does not cover

Covered: read-only Base access for the claims listed above, at a pinned header and a later head.

### 2.1 How the two headers are used, and the one limitation that follows

The authority's "pinned block and fresh latest-head repetitions" is satisfied as follows, and the
shape is stated plainly because it is narrower than "everything twice".

**Every fork claim is proved at the committed pinned header.** That is the complete portfolio: the
whole production lifecycle end to end, both terminal paths, the real CCA and Permit2 bidder
sequence, the PoolManager and PositionManager preservation claim, the live staking deposit and its
owner-driven paused failure, the token semantics, and the three complete-transaction gas envelopes.

**A focused subset is proved again at the later head.** Exactly nine claims run there — `DEP-040`,
`DEP-041`, `DEP-042`, `DEP-043`, `DEP-047`, `DEP-050`, `DEP-051`, `DEP-052` and `GAS-006` — and
between them they re-derive, from live chain state at that header, the deployed code identity, code
presence, proxy family and implementation identity of every binding, the CCA factory's zero fee
controller, the chain id, the complete header binding, and the gas-measurement method. Those are the
facts a chain moving under the evidence would move first.

**One full lifecycle portfolio runs, not two.** The behaviour claims that drive real launches, bids,
migrations and swaps are pinned-only. This packet does not claim otherwise anywhere.

**The accepted limitation, named.** The pinned proof covers the live staking contract's real deposit
*and* its owner-driven paused failure, which is the fail-closed half `DEP-045` exists for. But
`paused()` is mutable deployed state, and the reduced fresh-head subset does not re-read it. Code
identity moving would be caught at the later head; an owner flipping that flag would not. **That
state must therefore be read again, immediately before any separately authorized deployment**, and
a deployed `paused() == true` is a stop exactly as it is inside `DEP-045`.

Not covered, and not attempted anywhere in this repository: any Base write, broadcast, deployment,
signature, key generation, wallet request, admission change, production-data access, or value
movement. `bin/fork-gate.sh` refuses to start if any signing-authority environment variable is set,
and `.gitignore` keeps `/broadcast/` out of the tree entirely.

The endpoint is reached only through the `base` alias in `foundry.toml`, whose value is the
unresolved reference `${REGENT_BASE_RPC_URL}`. Both gates read the *effective* Foundry configuration
and fail if that alias ever resolves there, and both scan every artifact they produce for any host
outside a documentation and provenance allowlist. No endpoint reaches a log, a report, argv, or a
commit.

## 3. The two phases, and the human step between them

Discovery and checking are different programs run under different Foundry profiles, and the step
that turns one into the other is deliberate and human.

**Phase one — `bin/fork-gate.sh discover`.** Runs under the `fork-discovery` profile, whose only
write permission is `./reports/generated/fork`, which `.gitignore` keeps out of the tree. It runs
exactly one contract, `test-fork/ForkDiscovery.t.sol`, which reads no committed observation at all —
so it cannot compare a fact to itself — and writes one candidate:

```text
reports/generated/fork/fork-observations-candidate.json
```

It opens a fork at the chain head, takes that height as the later header and a fixed confirmation
depth behind it as the pinned header, and observes every binding's code length, runtime code hash,
proxy family, implementation address and implementation code identity at the pinned header, plus
REGENT's and USDC's decimals and symbol, the CCA factory's protocol fee controller, the
PositionManager's next token id, and the live staking contract's owner and paused state. It closes
no claim, carries no requirement id, and is excluded by name from every ledger reconciliation. The
gate then proves it changed no committed file.

Discovery runs the same way whether or not a reviewed observation is already committed. It has to:
re-observing a chain while the current record is still installed is the only way to produce a
replacement without deleting reviewed evidence first. That changes nothing about the boundary — the
pass reads no committed observation, the profile can write only that one gitignored directory, and
the gate compares the committed state of the record and the ledger before and after the provider is
reachable and stops on any difference. A candidate produced beside a live record is ignored scratch
until a human installs it.

**The human step.** A reviewer reads the candidate, checks every value against an independent
source, and supplies the one thing the chain does not expose — the transaction gas schedule active
at those headers, which is a protocol rule rather than a contract getter. The reviewer then sets
`status` to `observed_and_committed`, installs the file at `reports/frozen/fork-observations.json`,
replacing any record already there, makes sure `requirements/ledger.toml` activates `fork` with
every fork claim active, and commits whichever of the two files changed. For a replacement
observation the ledger is normally already correct and only the record moves.

**Phase two — `bin/fork-gate.sh check`.** Runs under the `fork` profile, which grants **no** write
permission anywhere, so it is structurally incapable of authoring an observation. Before it touches
the provider it proves the record says `observed_and_committed`, that the ledger activates `fork`
and every fork claim is active, and that the entire tracked and untracked non-generated worktree is
clean. After both header runs it proves the same whole-worktree condition and that no candidate was
produced. It then reconciles the two runs' reports as one merged multiset against the compiled
listing of twenty-seven mapped selectors — eighteen at the pinned header and the nine-claim
fresh-head subset at the later head — so every mapped selector executes exactly once and nothing
listed goes unrun. Only after those checks and verdict agreement pass does it write
`reports/generated/fork/fork-check-receipt.json`, binding the tested commit, full tree, source tree,
both execution-report hashes, compiled-list hash and the exact 18+9 selector counts.

Verdict agreement is reconciled by equality rather than by intersection. The later run's verdict keys
must be exactly `DEP-040`, `DEP-041`, `DEP-042`, `DEP-043`, `DEP-047`, `DEP-051`, `DEP-052`,
`GAS-006` and every per-binding `DEP-050.*` key the pinned verdict test emitted; a missing key and an
extra key each fail, and every shared key's decision must match. A later run that had silently shrunk
to a handful of claims therefore fails instead of reconciling a smaller overlap.

The two profiles also use their own build directory, `out-fork`, so fork artifacts can never
accumulate in `out/` and change the artifact count the required gate reconciles.

### 3.1 Nothing a provider produced is displayed before it is scanned

Both phases write every pass's stdout and stderr to files and scan them before anything is shown.
The two failure orders are kept apart deliberately:

- **the pass failed and its output is clean.** The output is not a secret; it has already passed the
  scan, so it is displayed and the whole scratch directory is retained, because it is the only
  diagnostic material a stop-report has.
- **the output is dirty, whatever the pass's exit status was.** Nothing is displayed. The scanner
  reports only redacted findings — the host, every other endpoint component, and every key-shaped
  token removed, inside a URL or outside one — names the local paths, and the gate then deletes the
  scratch unread. That is the one and only case in which scratch is destroyed.

The endpoint is read only from `REGENT_BASE_RPC_URL`, never from argv and never from a committed
file. Both orders are proved deterministically, without a provider, by
`test/tooling/provider_output_scan_test.py`, which `bin/gate.sh` runs.

### 3.2 The reviewed candidate and the activation commit are different commits

The earlier C5 review object was offline: its observation was `discovery_pending`, `fork` was absent
from `activated_gates`, and every fork claim was pending. This candidate is the **different, later
activation object**. It contains the independently reviewed observation record, activates `fork`,
and is the only kind of commit `bin/fork-gate.sh check` accepts because the record, activation and
entire non-generated checkout must already be committed and clean before provider access begins.

## 4. Execution status

**Executed and passing under read-only Base authority for the `regent-alv1.16` receiver-provenance
source authority.** The reviewed observation binds blocks `50541328` and `50541628`. The ledger
activates `fork`, the compiled listing maps twenty-seven selectors, and the compare-only gate
executed all eighteen fork claims at the pinned header plus exactly the approved nine-claim subset at
the later header, with zero failures or skips.

That run was made against production authority commit
`f4114f5276386f48bf8dc53ee344189d98c8896e`, full tree
`bb660324bb1d5cc322adeb243b0bd51779821fcb`, carrying `src/` tree
`91a741e417b75706a4071f7bdac2c5e13548c0fc`, and the gate proved both against Git and against the
checkout before any fork test opened. The evidence commit is
`ea8c81b2a5724213d3aeb4b0d81885b932f7d1aa`, which carries that same source tree and no
production-byte change: it moves the two `source_authority` fields inside the record and applies one
whitespace-only `forge fmt` to `test-fork/ProductionLifecycleFork.t.sol`. No observed value moved
with it — the same reviewed headers, bindings, proxy families, implementations and transaction gas
schedule were re-checked live against Base and matched exactly, which is what makes this a
re-execution against different bytecode rather than a re-observation of the chain. Discovery was
therefore not re-run, and nothing about the reviewed record was re-derived by the candidate it
certifies.

The check wrote the commit-bound receipt naming that exact evidence commit, its tree, its source
tree, both report hashes and the exact eighteen-plus-nine executed-selector split. Earlier fork
output without that receipt does not authorize packet preparation, and the deployment renderer names
the receipt's exact evidence commit and independently re-derives all of it before any preparation
provider access. `bin/deployment-gate.sh --prepare` and `--rehearse` have not been run against this
identity; only the read-only fork check and the offline deployment gate have.

The earlier discovery pass wrote only gitignored scratch and closed no claim. A separate provider
was used to confirm both headers, every recorded runtime identity and supported proxy
classification, the two implementation identities, CCA's zero fee controller, live staking and token
getters, and the pinned PositionManager counter before the record was installed. No provider write,
signature, deployment, or value movement occurred in that pass or in this one.

### 4.1 The failed `regent-4wx` attempt, recorded as what it was

One authorized attempt to run the replacement execution has already been made and did not produce
evidence. The value injected under `REGENT_BASE_RPC_URL` was not an endpoint, so **no fork was ever
created**: no observation candidate was written, nothing was installed at
`reports/frozen/fork-observations.json`, no claim closed, no verdict was emitted, and nothing was
certified. The committed record and the ledger were byte-identical before and after it, which is the
property the gate proves rather than asserts. It is recorded here because an attempt that produced
nothing is still part of the honest history of this evidence, and because the correction it prompted
is visible in `bin/fork-gate.sh`: the injected value's shape is now refused at the authority boundary,
before any provider access, instead of failing later inside Forge. The value itself was not printed
or persisted then and is not now.

## 5. Staged fork state, and the production path that makes each state reachable

Every cheatcode below acts on Forge's local fork state. None of them reaches the provider, and none
of them manufactures an intermediate state that production cannot reach on its own.

| Cheatcode | Where | What it stages | The real production path |
| --- | --- | --- | --- |
| `vm.createSelectFork(alias, block)` | `ForkFixture._selectFork` | A fresh isolated fork at one recorded header | Reading Base at a block. Each claim gets its own fork, so no claim inherits another's warmed access list or staged balances. |
| `vm.roll` | `ProtocolFork`, `TransactionGasFork`, `ProductionLifecycleFork` | Moves to an auction's own start, end, claim, or migration block, and — once, in the lifecycle suite — forward exactly one block | Time passing. The auction's schedule is fixed at creation; every roll is forward-only and lands on a block the auction itself defines. The single one-block roll is the splitter's own exit rule: no value at all may leave an account in that account's own stake block, so the suite first proves that the same-block `unstake`, `claim` and `claimAll` are each refused with the exact `SameBlockStakeExit(account, stakeBlock)` and that none of them moves principal, entitlement, splitter inventory or protected inventory, then advances one block and takes the entitlements and the principal out. Waiting one block is what a real staker does. |
| `deal(REGENT, launcher, fee)` | `ForkAutolaunch._launchAsWallet` | Gives a launcher exactly the current launch fee | A launcher acquires REGENT and approves the factory. A fork cannot mint REGENT, so the balance is staged; the approval and the launch are then the real calls. |
| `deal(REGENT, bidder, amount)` | `ProtocolFork`, `TransactionGasFork` | Gives a bidder REGENT to bid with | A bidder acquires REGENT. Every subsequent step — the ERC20 approval to Permit2, the Permit2 allowance, the five-argument bid — is the real production sequence. |
| `deal(USDC, depositor, amount)` | `ProtocolFork._checkLiveStaking` | Gives a depositor USDC to skim | The splitter's USDC skim. The approval and `depositUSDC` call shapes are the splitter's own. |
| `deal(REGENT, stranger, amount)` then a real `transfer` | `ProtocolFork._checkManagers` | Pre-seeds the shared PositionManager with third-party REGENT | An ordinary holder sending REGENT to the shared PositionManager. Only the acquisition is staged; the transfer is a real one. Seeding it is what makes the preservation provable rather than trivially zero: graduation settles the exact two amounts it funds, so a foreign balance that was there before is still there afterwards, to the unit. |
| a bidder's own `claimTokens` then a real `transfer` | `ProtocolFork._checkManagers` | Pre-seeds the shared PositionManager with this launch's SUBJECT and with another launch's | A bidder who claimed auction tokens sending some of them onward. Nothing is staged at all here: the SUBJECT is really claimed from a really graduated auction. The second launch's SUBJECT is what proves cross-launch inventory stays untouched. |
| `vm.prank(bidder)` / `vm.prank(outbidBidder)` for `exitBid`, `exitPartiallyFilledBid`, `claimTokens` | `ProtocolFork` | Acts as the bid's own owner | Those calls are the bid owner's own. Every required refund, partial-exit and claim path is driven from that bidder's account, never from a backend. The pinned CCA refuses a claim on an unexited bid, so a claim is always the two calls a real bidder makes. |
| `vm.prank(GOVERNANCE_AND_REGENT_SAFE)` for `unpauseLaunches` | `ForkAutolaunch._deployOnFork` | Opens the freshly deployed factory to launches | The frozen Governance/Regent Safe sending its own `unpauseLaunches()`. Every factory is born paused, so the suite first asserts that the factory it just deployed reports `launchesPaused() == true` and only then makes that one call — the real public function from the real bound address, never `vm.store` and never a manufactured flag. It stages exactly the deliberate governance transaction a deployed factory waits for, so the lifecycle below runs against an opened factory rather than against a state production cannot reach. It proves nothing about that Safe's signers or threshold, and it is not an authorization to activate anything on Base. |
| `vm.prank(launcher)` / `vm.prank(bidder)` | throughout | Acts as an ordinary EOA | Those accounts are ordinary EOAs with no privilege. Pranking one is the same as that person sending the transaction. |
| `vm.prank(owner)` on live staking | `ProtocolFork._checkLiveStaking` | Pauses the deployed live staking contract | Its own owner pausing it. The owner address is *read from the deployed contract*, never assumed, and the only call made as that owner is one the owner can really make. The pause is local fork state, is never sent to Base, and lives in a fork created by that one claim, so no other claim ever sees it. A `pause()` that fails is a failed claim, not a passing alternative. |
| `vm.load(binding, slot)` | `ForkFixture._classifyProxy`, both phases | Reads the three recognized proxy implementation slots | A read. It mutates nothing. The families are EIP-1967, EIP-1822 and the older ZeppelinOS slot; Base's own USDC uses the last of those, so reading only the EIP-1967 slot would misclassify a real proxy as a plain contract. |
| `vm.writeJson` | `ForkDiscovery` only | Writes the reviewable candidate | Not a production path at all. It is the discovery pass recording what it saw into gitignored scratch, under the only profile that may write anything, and it can reach neither `reports/frozen/` nor any committed file. |
| `deal(USDC, payer, amount)` and `deal(REGENT, payer, amount)` | `ProductionLifecycleFork` | Gives an ordinary payer balances for atomic payments and two bare aggregate USDC transfers | A customer paying a launch or transferring USDC before permissionless aggregation. Only acquisition is staged. Atomic `pay`, bare ERC20 transfers, one-argument receiver `sweep`, and one-argument splitter `recognizeSurplusRevenue` are real production calls. The aggregate calls assert zero reference through contract events and live-staking calldata, conserve every destination balance, and clear their allowances. |
| `deal(REGENT, swapper, amount)` then a real swap | `ProductionLifecycleFork` | Gives an ordinary trader REGENT to swap | A trader swapping on the launch's official v4 pool. The approval and the swap are that account's own calls through an ordinary router. |
| `new PoolSwapTest(PoolManager)` | `ProductionLifecycleFork` | Deploys the pinned v4-core swap router on the fork | A router. The hook has **no** router allowlist by design and charges every router identically, so an arbitrary router is a production-reachable caller rather than a substitute for one. It holds no authority over any Regent contract, and the swap it performs is a real swap against the real deployed PoolManager. |
| `vm.prank(payer)` / `vm.prank(swapper)` | `ProductionLifecycleFork` | Acts as an ordinary EOA | Those accounts are ordinary EOAs with no privilege, exactly like the launcher and the bidders. |

Explicitly **not** used anywhere in `test-fork/`: `vm.store`, `vm.etch`, `vm.mockCall`,
`vm.warp` past an auction's own schedule, and any grant of a role a real caller could not obtain.
Nothing in `test-fork/` manufactures protocol authority, contract code, custody, or a state
production cannot reach on its own.

## 6. Isolation and coldness

Each of the twenty-seven mapped fork selectors calls `_selectFork` itself, so it opens its own fork
and runs in state no other selector touched. That is what makes the mandatory live-staking pause
safe: it happens in a fork one claim created and no other claim can observe. It is also what makes
the gas
claims' cold measurements real: the first external touch inside a freshly created fork is genuinely
cold, and `GAS-006` proves it by running a second identical-shape launch in the same fork as a warm
control and requiring it to be cheaper. A run whose warm control is not cheaper has not measured
cold state and fails.

## 7. Branches that stay hermetic

Named here so they are never mistaken for fork evidence:

- **Splitter fault injection.** The reverting, short-transferring, false-returning, and re-entrant
  token behaviours in `test/mocks/MockERC20.sol` and `test/strategy/doubles/StagedERC20.sol` are
  hermetic only. Deployed REGENT and USDC do none of those things, so those branches are
  unreachable against live state and are proved against doubles by design.
- **Live staking failure shapes.** `MockLiveStaking`'s partial-pull and wrong-report switches are
  hermetic. The fork gate proves the deployed contract's real deposit semantics and its own
  owner-driven paused failure, and nothing more.
- **Permit2.** The real deployment pins Solidity `=0.8.17` and cannot be built under the frozen
  `0.8.26` compiler, so hermetic tests use `test/strategy/doubles/Permit2Double.sol`. Its ABI
  authority is the pinned `IAllowanceTransfer` interface, frozen in
  `reports/frozen/abi-surface.json`; its deployed runtime is a fork observation.
