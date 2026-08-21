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

## 3. Execution status for this candidate

**Not executed.** No read-only Base provider is injected in this candidate's environment, so:

- `reports/frozen/fork-observations.json` is `discovery_pending` and carries no observed value;
- `test-fork/ForkFixture.sol` reverts with `ForkObservationsPending` rather than checking a record
  it would have had to invent;
- `bin/fork-gate.sh check` refuses to run against a pending record;
- `requirements/ledger.toml` leaves `fork` out of `activated_gates`, so all sixteen fork claims are
  `pending` and none of their thirty-two selectors can close anything.

The harness is candidate-complete and compiles and formats clean under the `fork` profile. It has
never touched a network.

## 4. Staged fork state, and the production path that makes each state reachable

Every cheatcode below acts on Forge's local fork state. None of them reaches the provider, and none
of them manufactures an intermediate state that production cannot reach on its own.

| Cheatcode | Where | What it stages | The real production path |
| --- | --- | --- | --- |
| `vm.createSelectFork(alias, block)` | `ForkFixture._selectFork` | A fresh isolated fork at one recorded header | Reading Base at a block. Each claim gets its own fork, so no claim inherits another's warmed access list or staged balances. |
| `vm.roll` | `ProtocolFork`, `TransactionGasFork` | Moves to an auction's own start, end, claim, or migration block | Time passing. The auction's schedule is fixed at creation; every roll is forward-only and lands on a block the auction itself defines. |
| `deal(REGENT, launcher, fee)` | `ForkAutolaunch._launchAsWallet` | Gives a launcher exactly the current launch fee | A launcher acquires REGENT and approves the factory. A fork cannot mint REGENT, so the balance is staged; the approval and the launch are then the real calls. |
| `deal(REGENT, bidder, amount)` | `ProtocolFork`, `TransactionGasFork` | Gives a bidder REGENT to bid with | A bidder acquires REGENT. Every subsequent step — the ERC20 approval to Permit2, the Permit2 allowance, the five-argument bid — is the real production sequence. |
| `deal(USDC, depositor, amount)` | `ProtocolFork._checkLiveStaking` | Gives a depositor USDC to skim | The splitter's USDC skim. The approval and `depositUSDC` call shapes are the splitter's own. |
| `deal(REGENT, POSITION_MANAGER, amount)` | `ProtocolFork._checkManagers` | Pre-seeds the PositionManager with nonzero inventory | Any other launch, or any third party, leaving a balance at the shared PositionManager. Seeding it is what makes the `CONTRACT_BALANCE`/`TAKE_PAIR` residue record meaningful rather than trivially zero. |
| `vm.prank(launcher)` / `vm.prank(bidder)` | throughout | Acts as an ordinary EOA | Those accounts are ordinary EOAs with no privilege. Pranking one is the same as that person sending the transaction. |
| `vm.prank(owner)` on live staking | `ProtocolFork._checkLiveStaking` | Pauses the deployed live staking contract | Its own owner pausing it. The owner address is *read from the deployed contract*, never assumed, and the only call made as that owner is one the owner can really make. The pause is local fork state and is never sent to Base. |
| `vm.load(binding, slot)` | `BaseBindingsFork._checkProxyStatus` | Reads a standard proxy implementation slot | A read. It mutates nothing. |

Explicitly **not** used anywhere in `test-fork/`: `vm.store`, `vm.etch`, `vm.mockCall`,
`vm.warp` past an auction's own schedule, and any grant of a role a real caller could not obtain.

## 5. Isolation and coldness

Each of the thirty-two fork selectors calls `_selectFork` itself, so it opens its own fork and runs
in state no other selector touched. That is what makes the gas claims' cold measurements real: the
first external touch inside a freshly created fork is genuinely cold, and `GAS-006` proves it by
running a second identical-shape launch in the same fork as a warm control and requiring it to be
cheaper. A run whose warm control is not cheaper has not measured cold state and fails.

## 6. Branches that stay hermetic

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
