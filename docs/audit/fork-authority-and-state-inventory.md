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

**The human step.** A reviewer reads the candidate, checks every value against an independent
source, and supplies the one thing the chain does not expose — the transaction gas schedule active
at those headers, which is a protocol rule rather than a contract getter. The reviewer then sets
`status` to `observed_and_committed`, installs the file at `reports/frozen/fork-observations.json`,
adds `fork` to `activated_gates` in `requirements/ledger.toml`, flips the eighteen fork claims to
active, and commits both.

**Phase two — `bin/fork-gate.sh check`.** Runs under the `fork` profile, which grants **no** write
permission anywhere, so it is structurally incapable of authoring an observation. Before it touches
the provider it proves the record says `observed_and_committed`, that the ledger activates `fork`
and every fork claim is active, and that both files are committed and clean. After both header runs
it proves both files are still byte-identical to what was committed and that no candidate was
produced. It then reconciles the two runs' reports as one merged multiset against the compiled
listing, so each of the eighteen claims maps to exactly one pinned and one later selector and each of
the thirty-six executes exactly once.

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
and is the only kind of commit `bin/fork-gate.sh check` accepts because the record and activation
must already be committed and clean before provider access begins.

## 4. Execution status

> **Not executed for this candidate.** Everything in this section describes the run made against an
> earlier candidate's production bytecode. `regent-alv1.7` and `regent-alv1.7.1` both changed
> production bytes, so this candidate has no provider-backed evidence of its own. That run is
> `regent-4wx`'s, it happens **once**, and it happens against the final candidate — after this
> correction and the separate liquidity-position locker are both integrated and reviewed — rather
> than once per intermediate candidate. The committed observation record is chain truth and is
> unaffected; the execution against Regent bytecode is what has to be repeated.

**Executed and passing under read-only Base authority, for the earlier candidate.** The reviewed
observation binds blocks `50362455` and `50362755`. The ledger activates `fork`; the compiled
listing contains exactly the thirty-six mapped selectors; and the compare-only gate executed each
one exactly once, eighteen at each header, with zero failures or skips. It reconciled fifty-six
normalized cross-header verdicts and proved the committed observation and ledger were unchanged
after both runs.

The discovery pass wrote only gitignored scratch and closed no claim. A separate provider was used
to confirm both headers, every recorded runtime identity and supported proxy classification, the
two implementation identities, CCA's zero fee controller, live staking and token getters, and the
pinned PositionManager counter before the record was installed. No provider write, signature,
deployment, or value movement occurred.

## 5. Staged fork state, and the production path that makes each state reachable

Every cheatcode below acts on Forge's local fork state. None of them reaches the provider, and none
of them manufactures an intermediate state that production cannot reach on its own.

| Cheatcode | Where | What it stages | The real production path |
| --- | --- | --- | --- |
| `vm.createSelectFork(alias, block)` | `ForkFixture._selectFork` | A fresh isolated fork at one recorded header | Reading Base at a block. Each claim gets its own fork, so no claim inherits another's warmed access list or staged balances. |
| `vm.roll` | `ProtocolFork`, `TransactionGasFork` | Moves to an auction's own start, end, claim, or migration block | Time passing. The auction's schedule is fixed at creation; every roll is forward-only and lands on a block the auction itself defines. |
| `deal(REGENT, launcher, fee)` | `ForkAutolaunch._launchAsWallet` | Gives a launcher exactly the current launch fee | A launcher acquires REGENT and approves the factory. A fork cannot mint REGENT, so the balance is staged; the approval and the launch are then the real calls. |
| `deal(REGENT, bidder, amount)` | `ProtocolFork`, `TransactionGasFork` | Gives a bidder REGENT to bid with | A bidder acquires REGENT. Every subsequent step — the ERC20 approval to Permit2, the Permit2 allowance, the five-argument bid — is the real production sequence. |
| `deal(USDC, depositor, amount)` | `ProtocolFork._checkLiveStaking` | Gives a depositor USDC to skim | The splitter's USDC skim. The approval and `depositUSDC` call shapes are the splitter's own. |
| `deal(REGENT, stranger, amount)` then a real `transfer` | `ProtocolFork._checkManagers` | Pre-seeds the shared PositionManager with third-party REGENT | An ordinary holder sending REGENT to the shared PositionManager. Only the acquisition is staged; the transfer is a real one. Seeding it is what makes the preservation provable rather than trivially zero: graduation settles the exact two amounts it funds, so a foreign balance that was there before is still there afterwards, to the unit. |
| a bidder's own `claimTokens` then a real `transfer` | `ProtocolFork._checkManagers` | Pre-seeds the shared PositionManager with this launch's SUBJECT and with another launch's | A bidder who claimed auction tokens sending some of them onward. Nothing is staged at all here: the SUBJECT is really claimed from a really graduated auction. The second launch's SUBJECT is what proves cross-launch inventory stays untouched. |
| `vm.prank(bidder)` / `vm.prank(outbidBidder)` for `exitBid`, `exitPartiallyFilledBid`, `claimTokens` | `ProtocolFork` | Acts as the bid's own owner | Those calls are the bid owner's own. Every required refund, partial-exit and claim path is driven from that bidder's account, never from a backend. The pinned CCA refuses a claim on an unexited bid, so a claim is always the two calls a real bidder makes. |
| `vm.prank(launcher)` / `vm.prank(bidder)` | throughout | Acts as an ordinary EOA | Those accounts are ordinary EOAs with no privilege. Pranking one is the same as that person sending the transaction. |
| `vm.prank(owner)` on live staking | `ProtocolFork._checkLiveStaking` | Pauses the deployed live staking contract | Its own owner pausing it. The owner address is *read from the deployed contract*, never assumed, and the only call made as that owner is one the owner can really make. The pause is local fork state, is never sent to Base, and lives in a fork created by that one claim, so no other claim ever sees it. A `pause()` that fails is a failed claim, not a passing alternative. |
| `vm.load(binding, slot)` | `ForkFixture._classifyProxy`, both phases | Reads the three recognized proxy implementation slots | A read. It mutates nothing. The families are EIP-1967, EIP-1822 and the older ZeppelinOS slot; Base's own USDC uses the last of those, so reading only the EIP-1967 slot would misclassify a real proxy as a plain contract. |
| `vm.writeJson` | `ForkDiscovery` only | Writes the reviewable candidate | Not a production path at all. It is the discovery pass recording what it saw into gitignored scratch, under the only profile that may write anything, and it can reach neither `reports/frozen/` nor any committed file. |
| `deal(USDC, payer, amount)` and `deal(REGENT, payer, amount)` | `ProductionLifecycleFork` | Gives an ordinary payer a balance to pay a canonical receiver with | A customer paying a launch. Only the acquisition is staged; the approval and the `pay` call are the payer's own, and every skim destination is then asserted on the deployed contracts. |
| `deal(REGENT, swapper, amount)` then a real swap | `ProductionLifecycleFork` | Gives an ordinary trader REGENT to swap | A trader swapping on the launch's official v4 pool. The approval and the swap are that account's own calls through an ordinary router. |
| `new PoolSwapTest(PoolManager)` | `ProductionLifecycleFork` | Deploys the pinned v4-core swap router on the fork | A router. The hook has **no** router allowlist by design and charges every router identically, so an arbitrary router is a production-reachable caller rather than a substitute for one. It holds no authority over any Regent contract, and the swap it performs is a real swap against the real deployed PoolManager. |
| `vm.prank(payer)` / `vm.prank(swapper)` | `ProductionLifecycleFork` | Acts as an ordinary EOA | Those accounts are ordinary EOAs with no privilege, exactly like the launcher and the bidders. |

Explicitly **not** used anywhere in `test-fork/`: `vm.store`, `vm.etch`, `vm.mockCall`,
`vm.warp` past an auction's own schedule, and any grant of a role a real caller could not obtain.
Nothing in `test-fork/` manufactures protocol authority, contract code, custody, or a state
production cannot reach on its own.

## 6. Isolation and coldness

Each of the thirty-six fork selectors calls `_selectFork` itself, so it opens its own fork and runs
in state no other selector touched. That is what makes the mandatory live-staking pause safe: it
happens in a fork one claim created and no other claim can observe. It is also what makes the gas
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
