# Threat model — Autolaunch V1

Scope: the system frozen by [SPEC.md](../../SPEC.md). This document enumerates what the system
protects, who may act on it, where it depends on code it does not own, and how each adversarial
failure class is answered by a requirement in [the ledger](../../requirements/ledger.toml).

It describes only frozen specification behavior. It invents no contract behavior, and every
mitigation it names is a requirement ID whose evidence becomes mandatory when its owning ticket
activates. Through C4 the repository holds the immutable bindings, the proof scaffolding, the three
fixed clone targets — `ConditionalVestingEscrowV1`, `SubjectSplitterV1`, and `PaymentReceiverV1` —
the one shared `RegentFeeHook`, the one shared `RegentLBPStrategy`, and the one
`RegentsAutolaunchFactoryV1` that deploys and binds both of them and creates every launch. The
dependency, binding, chain, ABI-provenance, factory, token, escrow, splitter, receiver, hook,
strategy, migration, and failure mitigations therefore carry hermetic evidence. What is still
pending is C5's: the fork gate's deployed-runtime claims (`DEP-040` through `DEP-051`), the
stateful invariant class, the complete-transaction gas class, and the ABI freeze. A pending
mitigation is a named obligation, never evidence.

## 1. Assets

| Asset | Where it lives | Loss condition |
| --- | --- | --- |
| SUBJECT supply (100B per launch) | token, auction, strategy reserve, escrow, vesting | any unit created, destroyed, or stranded outside the specified destinations |
| Bidder REGENT | CCA auction | a failed auction leaves a bidder unable to reclaim |
| Launch fee REGENT | payer allowance, Regent Safe | fee taken without a launch, taken twice, or taken at a stale price |
| Swap fee REGENT | hook, Regent Safe, splitter | a lane is unfloored, misrouted, or retained by the hook |
| Payment inflows (USDC, REGENT, SUBJECT) | receiver, splitter, live staking | referral or skim ordering diverts value, or staker funds pay a non-staker |
| Staked SUBJECT principal | splitter | principal spent by revenue, claim, or recovery paths |
| Full-range LP position | PositionManager NFT at the dead address | the position becomes owned or withdrawable by anyone |
| Treasury and Regent Safe destinations | immutable constructor state | a destination becomes mutable or caller-selected |

## 2. Trust boundaries

1. **Founder-frozen literals.** `SPEC.md` is the only source of pins, addresses, and the CCA
   runtime code hash. Everything downstream is reconciled to it (`DEP-011`, `DEP-012`).
2. **Pinned upstream source.** CCA v2.1, the Liquidity Launcher, and the UERC20 factory are
   read-only dependencies at exact commits (`DEP-001` through `DEP-008`). Their behavior is
   trusted only at those commits; a moving branch is never an input.
3. **External deployed contracts.** REGENT, USDC, the CCA factory, PoolManager,
   PositionManager, and live staking are code this repository does not own. Their runtime truth
   — deployed code, code hash, proxy shape, implementation identity, getter results, and cold
   state — is unproven until the authorized fork gate runs (`DEP-040` through `DEP-051`). No
   hermetic test can reach any of it. Code this repository *does* own, including the clone
   implementations and their clones, is proved hermetically instead (`DEP-060`).
4. **Governance.** The Regent Safe may change the launch fee and pause new launches, and
   nothing else (`FAC-006`, `FAC-007`, `FAC-019`).
5. **Recovery admin.** An immutable address, admitted **once, at launch, as a deployed contract**,
   may move only forced ETH and unsupported ERC20s, only to the immutable treasury, on both the
   receiver and the splitter (`RCV-009`, `RCV-010`, `SPL-017`, `SPL-018`). "Deployed contract" is a
   launch-time admission and nothing more: `RegentLBPStrategy.initializeDistribution` is the single
   place the code check exists (`FAC-016`), and no later call re-evaluates it. Carrying code is
   mutable environmental state — EIP-6780 lets an account created and destroyed in one transaction
   disappear — and graduation is a launched auction's only migration path, so re-checking it later
   would let a launcher strand its own graduated launch. The consequence is disclosed in section 8.
6. **Everyone else.** Launchers, bidders, stakers, payers, swappers, and migrators are
   untrusted callers whose only power is the specified public surface.

## 3. Authorities and entrypoints

| Authority | Holder | Surface | Bounded by |
| --- | --- | --- | --- |
| Fee and pause | governance Safe | `setLaunchFee`, `pauseLaunches`, `unpauseLaunches` | `FAC-006`, `FAC-007`, `FAC-019` |
| Launch | any caller with the exact allowance | `launch` | `FAC-008`, `FAC-009`, `FAC-010`, `FAC-020` |
| Receiver creation | any caller | `createPaymentReceiver`, receiver creation | `FAC-024`, `RCV-001` |
| Distribution initialization | the bound factory only | strategy initialization | `STR-002` |
| Migration | any caller | `migrate(auction)` | `STR-003`, `MIG-001`, `MIG-013` |
| Pool registration | the strategy only, once | hook registration | `HOK-002`, `HOK-003` |
| Swap fee settlement | PoolManager with a registered key | hook callbacks | `HOK-013`, `HOK-016`, `HOK-017` |
| Staking, claims, revenue | any caller, for itself only | splitter surface | `SPL-014`, `SPL-010` |
| Recovery | immutable recovery admin | `recoverUnsupportedToken`, `recoverForcedETH` on both receiver and splitter | `RCV-009`, `RCV-010`, `RCV-011`, `SPL-017`, `SPL-018`, `ABI-005` |

No upgrade authority, implementation pointer, kill switch, keeper, or arbitrary-execution
surface exists anywhere in the frozen design.

## 4. External dependencies and calls

| Dependency | Called for | Failure handling |
| --- | --- | --- |
| CCA factory and auction | auction creation, finalization, sweeps, refunds | technical failure is an ordinary revert with no retry state (`STR-004`); admission requires the exact runtime code hash and a zero protocol fee controller (`DEP-040`, `DEP-041`); every binding's deployed hash is reconciled against the final manifest (`DEP-051`) |
| UERC20 factory | SUBJECT creation | only the Autolaunch factory creates SUBJECT and the token carries no administrative power afterwards (`TOK-003`, `TOK-005`) |
| PoolManager | pool initialization and swap settlement | only the bound singleton may invoke a hook callback and only a registered `PoolId` is served (`HOK-017`); settlement failure reverts the swap (`HOK-016`) |
| `SubjectSplitterV1` (per launch) | the hook's second 1% REGENT lane | the strategy binds only a splitter whose `regent`, `subject`, and `regentSafe` match the launch (`HOK-002`); an exact approval is fully consumed and the hook's REGENT balance must return to its pre-callback level, so a reverting, under-pulling, refunding, or re-entering splitter fails the whole swap (`HOK-011`, `HOK-014`, `HOK-016`, `HOK-018`) |
| PositionManager | full-range position mint, NFT to dead address | migration rolls back on failure (`MIG-006`, `MIG-017`) |
| Live staking `depositUSDC` | USDC skim | exact approval, behavior verification, allowance cleanup (`SPL-003`) |
| REGENT, USDC, SUBJECT ERC20s | transfers, allowances | exact-allowance and exact-balance assertions (`FAC-008`, `MIG-016`) |

### 4.1 Why the factory carries no reentrancy guard

`launch` and `createPaymentReceiver` are the factory's only value- or deployment-bearing entry
points, and neither can hand control to an address an attacker chose. Every external call either
one makes goes to a fixed, code-identity-checked destination: the frozen REGENT binding, the pinned
UERC20 factory whose runtime hash the constructor admitted, a freshly created `UERC20` at an address
the pinned factory derived, a clone of an admitted C1 implementation, and this factory's own
strategy. A launcher supplies a treasury and a recovery admin, but neither is ever *called* — the
treasury is only ever stored and later paid as an ERC20 recipient, and the recovery admin is only
ever stored and compared against `msg.sender` in the C1 clones. The four external contract types
that could plausibly call back are all Regent's own or pinned code, and the shared strategy carries
its own `nonReentrant` guard on both of its mutating entry points, so a re-entrant `launch` during a
migration and a re-entrant `migrate` during a launch are both refused there (`MIG-019`).

That leaves one honest residual: if a future REGENT or SUBJECT implementation gained a transfer
callback, a re-entrant `launch` would allocate the next ID and run a second, complete, independent
launch before the outer one finished. It would still be a complete launch or a complete revert —
`nextLaunchId` advances before any external call, the strategy refuses a second concurrent
initialization outright, and every identity is read back before the record is written — so there is
no state a nested call could corrupt and no value it could double-spend. A guard would buy nothing
that ordinary EVM atomicity and the strategy's own guard do not already provide, so none is added
(`FAC-021`, `MIG-019`).

## 5. Lifecycle states

`launched → auction open → auction ended → (graduated | economically failed)`.

Graduation and failure are mutually exclusive and terminal (`INV-007`). Graduation is one atomic
twelve-step transaction (`MIG-013`); failure retires exactly 100 billion SUBJECT to the dead
address while leaving bidder refunds intact (`FAIL-004`, `FAIL-006`).

## 6. Accounting invariants

| Invariant | Requirement |
| --- | --- |
| SUBJECT supply conservation across every reachable sequence | `INV-001` |
| Splitter solvency per recognized token | `INV-002` |
| Staked principal never spent | `INV-003` |
| Hook retains no attributable REGENT | `INV-004` |
| Remainder never lost and never double-paid | `INV-005` |
| 5% LP reserve conserved until its destination consumes it | `INV-006` |
| One lifecycle state per launch | `INV-007` |
| Receiver referral, skim, and net amounts conserved | `INV-008` |
| No launch's reserve is ever used by another launch | `INV-009` |
| Factory, strategy, and hook hold no unexplained balance | `INV-010` |

## 7. Adversarial failure classes

| Class | Concrete attempt | Answered by |
| --- | --- | --- |
| Dependency substitution | build against a moving branch, a look-alike commit, a copied `lib/` tree without git metadata, or a closure missing a nested dependency | `DEP-001`–`DEP-008` |
| Compiler or setting drift | different solc, optimizer runs, re-enabled metadata, or an environment override of the fuzz portfolio | `DEP-009`, `DEP-010`, `DEP-014`, `DEP-015` |
| Frozen surface drift | a hand-edited ABI, a stale release manifest, or a recompiled runtime that no longer matches the reviewed bytes | `DEP-016` |
| Authority forgery in the frozen literals | edited address, code hash, chain, or selector in a manifest, fixture, or binding source; a binding renamed onto another binding's value | `DEP-011`, `DEP-012`, `DEP-029` |
| Interface-derived ABI | a selector taken from a vendored interface that omits or misstates the implementation | `DEP-013`, `ABI-001` |
| Deployed-code substitution | an external binding whose deployed runtime, code hash, or implementation behind a proxy differs from what the frozen manifest records | `DEP-040`, `DEP-043`, `DEP-051` |
| Clone substitution | an escrow, splitter, or receiver clone deployed from an implementation whose code identity is not the recorded one | `DEP-060` |
| Constructor substitution | deploying the factory against a look-alike UERC20 factory, a codeless address, or the wrong C1 implementation in any of the four admitted slots, so every later launch inherits foreign code | `DEP-060` |
| Deployer-supplied strategy or hook | a factory that accepts a strategy or a hook address from whoever deploys it, or that keeps a setter for either afterwards | `STR-001`, `HOK-001`, `FAC-012` |
| Hook-mining error | a salt that produces a hook address whose permission bits differ from the five the hook declares, so v4 calls the wrong callbacks or none | `HOK-004` |
| Launch-record forgery | a launch recorded before its returned token, escrow, auction and the strategy's own state all agree, or a token admitted without the creator and graffiti readbacks | `FAC-020`, `FAC-021`, `TOK-003` |
| Launch partial commit | failure at the fee transfer, the token creation, either readback, the escrow approval, the escrow initialization or its exact pull, the strategy initialization or its exact pull, the auction creation or readback, the delivery, the custody proof, or the final record agreement, leaving a half-created launch | `FAC-021` |
| Fee griefing | stale expected fee, wrong allowance, residual allowance left behind, or fee charged for a failed launch | `FAC-008`, `FAC-009`, `FAC-010`, `FAC-018`, `FAC-027` |
| Unobservable fee action | a fee change or a fee collection the product watcher cannot see | `FAC-025`, `FAC-026` |
| Authority creep | pause blocking refunds, claims, or vesting; launcher provenance conferring power | `FAC-017`, `FAC-019`, `SPL-010` |
| Metadata abuse | oversized, empty, or malformed UTF-8 metadata; token metadata edited after creation | `FAC-013`, `FAC-014`, `TOK-004` |
| Admin-address abuse | a zero, self, or non-contract recovery admin admitted at launch | `FAC-016` |
| Terminal-custody denial | a launcher's own recovery admin, admitted at launch and then destroyed under EIP-6780, used to make graduation impossible and strand a launch that already raised | `MIG-020`, and the single-check rule in section 5 below |
| Cross-launch interference | simultaneous launches sharing the one strategy and hook reaching each other's reserve or inventory | `FAC-022`, `STR-012`, `INV-009`, `INV-010` |
| Foreign auction injection | initializing or migrating an auction the strategy never recorded, including a real CCA auction over the same SUBJECT created outside the strategy | `STR-016` |
| Fake clone substitution | an escrow that answers every getter correctly but is not a clone of the bound implementation, or an authentic clone bound to a foreign strategy, an already-resolved lifecycle, or the wrong custody | `STR-013` |
| Hook misbinding | binding a codeless hook, a hook bound to another strategy, a hook carrying a foreign PoolManager, a second hook after the first, or binding from anyone but the factory | `STR-001`, `STR-002` |
| Protocol-fee capture | a CCA factory that reports a non-zero protocol fee controller, so part of the raise never reaches the pool | `STR-011` |
| Unreachable raise | a required raise of zero, or one above what the fixed ten-billion-SUBJECT auction can mathematically clear, guaranteeing a launch that can only fail | `STR-013` |
| Checkpoint exhaustion | a tick book large enough that the auction's final checkpoint cannot fit in one migration, used to strand a launch or to force a retry surface into existence | `STR-004` |
| Balance gifts | SUBJECT or REGENT sent to the shared strategy, or to PositionManager, to make one launch's residue accounting mis-attribute another's value | `STR-012`, `STR-015` |
| Zero-liquidity graduation | a reachable final price at which the offered raise and reserve plan no position at all, stranding a graduated launch | `STR-014`, `STR-015` |
| Inventory leakage | unsold, reserve, or residual SUBJECT stranded after either terminal path, or a distribution that does not split exactly 10/5/85 | `STR-017`, `MIG-016`, `FAIL-004`, `ESC-005`, `ESC-006` |
| Escrow custody diversion | releasing pending custody early, resolving from a foreign caller, holding the wrong pending amount, or redirecting vested SUBJECT away from the fixed treasury | `ESC-009`, `ESC-010`, `ESC-011`, `ESC-012`, `ESC-013` |
| Auction identity substitution | resolving or sweeping through an auction that sells another launch's token or names another recipient, or reading a graduation flag from a stale pre-checkpoint state | `ESC-004`, `ESC-005`, `ESC-014` |
| Unsold-inventory loss at graduation | skipping the graduated unsold sweep, running it twice, or opening vesting over an incomplete inventory | `ESC-014`, `ESC-002`, `ESC-007` |
| Note-editor capture | a caller other than the receiver's fixed note editor relabeling its payments | `RCV-016`, `RCV-006` |
| Price-ordering asymmetry | a final price that differs depending on which currency is token0, or a reachable price that converts outside the v4 tick range | `STR-014` |
| Migration partial commit | failure after an external call leaving a half-migrated launch | `MIG-017`, `STR-004` |
| Repeat or replay | migrating or retiring twice, finalizing an auction twice, re-running an escrow or clone initializer | `MIG-018`, `FAIL-008`, `STR-018`, `ESC-001`, `ABI-008` |
| Hook boundary escape | unregistered key, altered key field, foreign caller, hostile router | `HOK-017`, `HOK-018` |
| Official-pool pre-initialization | anyone bringing the deterministic official pool into existence at a price the auction never cleared, before or instead of the strategy | `HOK-002`, `HOK-003`, `HOK-017` |
| Hook permission forgery | a hook address carrying more, fewer, or different permission bits than the declared five, including either return-delta bit | `HOK-004` |
| Returned-delta manipulation | a delta with the wrong sign, a delta not backed by a matching `take`, an `int256`-minimum specified amount, or a two-lane total too large for the returned `int128` | `HOK-005`, `HOK-006`, `HOK-007`, `HOK-008`, `HOK-014` |
| Reentrancy | a recovery token, a hook callback, a receiver path, or a migration dependency re-entering mid-flow | `SPL-021`, `SPL-022`, `HOK-018`, `RCV-015`, `MIG-019` |
| Fee lane evasion | tiny swaps, rounding at the exact fee boundaries, exact-output, or unspecified-currency paths avoiding a lane | `HOK-005`, `HOK-006`, `HOK-007`, `HOK-008`, `HOK-009`, `HOK-012`, `HOK-019`, `SPL-016` |
| Fee retention | hook keeping attributable inventory for a later flush | `HOK-014`, `HOK-015`, `INV-004` |
| Staker dilution or theft | interleaved stake and unstake around a deposit, or claiming another staker's share | `SPL-013`, `SPL-014`, `SPL-015`, `INV-003` |
| Remainder skimming | repeatedly recognizing dust to drain the carried remainder | `SPL-007`, `INV-005` |
| Referral skimming | a referral paid above the floored share, or paid to anyone but the immutable beneficiary | `RCV-002`, `RCV-003`, `RCV-014` |
| Recovery abuse | recovering a core token, staked principal, an unclaimed claim, or the carried remainder; recovering to a caller-chosen destination; sending ordinary ETH to create recoverable balance | `RCV-008`, `RCV-009`, `RCV-010`, `SPL-017`, `SPL-018`, `SPL-019` |
| Malicious token | a token that reverts, lies about transfers, or breaks solvency accounting | `SPL-012`, `RCV-011`, `RCV-012` |
| Gas exhaustion | a terminal transaction that cannot fit in a Base block, or a gas figure measured without the intrinsic and calldata cost | `GAS-003`, `GAS-004`, `GAS-005`, `GAS-006` |
| Hook callback cost drift | a fee callback whose cold cost is not measured against a genuine control, so a swap becomes quietly more expensive than anyone recorded | `GAS-007` measures and publishes it; it asserts no absolute callback limit, because none exists in v4, in the pinned closure, or in a founder requirement. The only absolute gas limit is the 14,000,000 complete-transaction ceiling (`GAS-003`–`GAS-006`) |
| Obsolete surface survival | a Safe, ERC-8004, registry, flush, or retry interface left in the frozen ABI | `ABI-009` |
| Silent topic re-layout | an event whose indexed flag moves from one argument to another, leaving the signature, the topic and the indexed count unchanged while every watcher's topic filter breaks | `ABI-007`, `ABI-010` |
| Return-shape drift | a reordered, renamed, added or rewidened field in a returned struct, which no function selector records and every positional decoder breaks on | `ABI-011` |
| Evidence laundering | a mock closing a deployed-runtime, proxy, getter, cold-state, intrinsic, calldata, or complete-transaction gas claim; a placeholder test closing a future claim; a product claim borrowing the gate-dependency evidence class; an overloaded or duplicated test identity collapsing two claims into one | ledger evidence classes, gate-aware activation, and compiled-listing multiset reconciliation, all enforced by `bin/check-requirements.py` |
| Build laundering | editing `foundry.toml` and the frozen fixture together so the two repository copies agree on a setting the specification never granted | the gate parses the governing `SPEC.md` build line and compares it against both copies and against the produced artifacts (`DEP-009`) |
| Analysis narrowing | a valid detector, severity, or production-source exclusion in `slither.config.json` or on the Slither command line; a duplicate finding hidden under one disposition row; a hidden triage database | the gate pins the configuration and the argv to an exact allowed shape, reconciles the run's detector count against the pinned binary's registered portfolio, and reconciles every result fingerprint one-for-one against a visible row |

## 8. Accepted consequences of the founder-frozen simple design

These are not defects. Each is a behavior the frozen specification chooses, recorded here so a
reviewer meets it as a decision rather than as a surprise.

| Accepted consequence | What it means in practice | Where it is proved |
| --- | --- | --- |
| Immediate stake timing | A stake credits in the same block and earns from the very next recognition. Anyone who owns or can borrow SUBJECT may therefore stake, trigger recognition of a waiting inflow, claim, and unstake with nothing in between, and keep the whole net of that one recognition. The specification makes staking immediate, so no cooldown, activation delay, epoch, queue, previous-block eligibility rule, or total-supply denominator exists to prevent it, and adding one would change the frozen economics. What the round trip cannot reach is anything outside that single recognition: it earns from no recognition before its stake and none after its exit, and it takes nothing from another staker's position — it only dilutes the share of whoever was staked for that one recognition. | `SPL-009`, `SPL-013` |
| Permissionless surplus-recognition ordering | Anyone may call `recognizeSurplusRevenue`, so the block in which a bare transfer becomes revenue is chosen by an untrusted caller, and therefore so is the stake set that shares it. Combined with immediate staking, that caller may put itself into the stake set first and take the resulting share, which is the same accepted round trip as above. Recognition still pays only current stakers or the treasury, still skims exactly once, and still cannot relabel principal, unclaimed liability, or the carried remainder. | `SPL-011`, `SPL-009`, `SPL-008` |
| Paused live staking fails closed | While the live REGENT staking contract is paused or reverting, a USDC recognition with a nonzero skim reverts in full. USDC revenue simply cannot be recognized during that window; nothing is queued, retried, or diverted. | `SPL-003` |
| Losing the recovery admin's code permanently disables recovery, and only recovery | The recovery admin is admitted as a deployed contract exactly once, at launch. If that immutable address later stops carrying code — it self-destructs under EIP-6780 in the transaction that created it, or it never had a way to act in the first place — then nothing can ever again present `msg.sender == recoveryAdmin`, so `recoverUnsupportedToken` and `recoverForcedETH` become permanently uncallable on that launch's splitter **and on every receiver created for that launch**, canonical and custom alike. Unsupported ERC20s and force-sent ETH sitting in any of those contracts are then stuck forever, exactly as escrow's force-sent ETH already is. Nothing else is affected: graduation and migration, revenue recognition and skims, staking, claims, `claimAll`, unstaking, payments, sweeps, vesting, and swaps all continue to work, and USDC, REGENT and SUBJECT were never recoverable in the first place. The alternative — re-checking the admin's code on the graduation path — would let a launcher's own destroyed admin strand a launch that already raised, which is a far larger loss than a stuck unsupported token. No replacement admin, fallback admin, retry mode, or new authority is added. | `MIG-020`, `FAC-016`, `SPL-017`, `SPL-018`, `RCV-009`, `RCV-010` |
| Permanently stuck force-sent escrow ETH | The escrow has no recovery path of any kind, so ETH force-sent to it can never be moved. The specification gives escrow exactly two resolutions and no rescue authority, and adding one would be new authority over a custody contract. | `ESC-008` |
| Exact-inventory failure deadlock | Failure resolution requires exactly 100 billion SUBJECT. If a contributor is short or an extra unit is present, the launch stays pending rather than retiring a partial supply. Deadlock is preferred to an unprovable retirement. | `ESC-005` |
| The specified lane charges the requested amount, not the filled amount | When REGENT is the swap's specified currency the two lanes are charged against `abs(amountSpecified)` in `beforeSwap`, before the pool has executed anything. A price limit can therefore stop the fill short — in the extreme, at nothing at all — while the trader still pays both lanes on the full requested amount. The specification freezes the specified-currency charge at the requested amount, and moving it to the realized amount would mean charging after the swap in every shape, which is a different design. | `HOK-006` |
| The early take is a liveness boundary | Both lanes are taken from the singleton PoolManager before the trader's input is settled. If the singleton's REGENT balance cannot cover a lane the whole swap reverts, even though the swap was otherwise valid. Nothing is half-paid: the Safe lane may be paid first and is rolled back with everything else. The specification requires synchronous settlement with no retained inventory, so there is no deferral, queue, or partial-charge path to fall back to. | `HOK-016` |
| An unrelated REGENT gift stays stuck at the hook | The hook has no recovery, sweep, receive, or fallback path. REGENT sent to it outside a swap is not attributable fee inventory and is never spent, never distributed, and never recoverable; each swap simply finishes at exactly the pre-swap balance. Adding a rescue path would be new authority over a contract that is meant to have none. | `HOK-014`, `HOK-015` |
| The 5% reserve is an offered maximum, not a guaranteed contribution | The full-range position is quoted from the auction's own final price, so it consumes whichever side runs out first. Whatever the position does not consume — often most of the reserve — goes to that launch's escrow and joins its vesting schedule, and whatever raised REGENT it does not consume goes to the immutable treasury. The specification routes both residues explicitly, so neither is stranded and neither is topped up. | `STR-015`, `ESC-003` |
| Unrelated REGENT at the shared strategy stays untouched | REGENT sent to the shared strategy outside a launch is never attributed to any launch: graduation forwards only the delta its own auction sweep produced. That gift is therefore not recoverable by anyone, exactly like the hook's. It is named here rather than swept because sweeping it would mean paying one launch's treasury with value it did not raise. | `STR-015`, `INV-010` |
| PositionManager balance gifts join the launch's residues | The pinned position plan settles PositionManager's whole balance of each currency and takes the surplus back, which is upstream behavior this fork preserves. Anything gifted to PositionManager therefore leaves with the migrating launch rather than staying stuck. The strategy makes no claim over those units: its own accounting isolates the raise its auction produced and the reserve it recorded, and it records the position's actual consumption rather than the offered maxima. | `STR-015` |
| Checkpoint exhaustion is an upstream liveness condition | If the auction's tick book is large enough that its final checkpoint will not fit in one migration, the migration reverts and remembers nothing. The resolution is upstream and permissionless: anyone calls the auction's own `forceIterateOverTicks` to advance the book, then anyone calls `migrate` again. There is deliberately no attempt counter, progress record, partial migration, or retry mode inside the strategy, because any of those would be exactly the committed technical-failure state the specification forbids. | `STR-004` |
| One global scaled carry per asset | The indivisible part of each distribution is carried forward as a single scaled numerator per asset. It is inside protected liability, is never separately withdrawable, and cannot be surplus-recognized or recovered. | `SPL-007`, `SPL-018` |
| Every SUBJECT grants Permit2 an infinite allowance forever | The pinned UERC20 is a Solady ERC20, which reports `type(uint256).max` as every holder's allowance to the canonical Permit2 (`0x000000000022D473030F116dDEE9F6B43aC78BA3`) and cannot have it revoked. Every Autolaunch SUBJECT therefore lets Permit2 move any holder's balance on that holder's own signed authority, including the balances held by escrow, the strategy, the splitter, and the receivers. This is upstream token behavior the specification adopts by pinning that factory, not a Regent decision, and no Regent contract ever signs a Permit2 authorization. Allowance-cleanup proofs are therefore scoped to the spenders Regent actually names — the escrow, the strategy, the splitter, and the launch-fee payer — rather than asserting that a SUBJECT allowance is universally zero. | `FAC-027`, `MIG-016` |
| Regent custody contracts do not implement ERC-1271 | Neither the factory nor the strategy, escrow, splitter, or receivers implements `isValidSignature`, so none of them can ever produce a valid contract signature. In particular none of them can authorize a Permit2 transfer of its own balance, which is what closes the consequence above: the infinite Permit2 allowance is unusable against Regent custody because Regent custody can never sign for it. Nothing in the design needs contract signatures, and adding them would create a new authority surface over custody. | `MIG-016`, `FAIL-005` |
| The Regent Safe cannot pay a positive launch fee | A collected fee is proved by the Regent Safe's own balance delta, and the Safe paying itself moves nothing, so a launch sent by governance while the fee is positive reverts in full. Governance launching is not a designed path; if it ever needs one, it sets the fee to zero first and launches as an ordinary caller. Proving the fee at the destination rather than trusting a token return value is the deliberate choice here, and this is its one visible cost. | `FAC-005` |
| A one-wei required raise is admitted because it was measured, not assumed | The smallest admitted required raise is one wei, and the smallest reachable graduated outcome at that raise really does resolve: measured against the real pinned auction and `PositionPlanner`, a one-wei raise migrates in both PoolKey orderings and at both reachable clearing-price endpoints — the floor price and the highest on-grid price — consuming one wei of REGENT and 981 units of SUBJECT in the full-range position. `NoFullRangePosition()` is therefore not reachable inside the admitted range, and no artificial minimum raise is imposed. | `FAC-023`, `STR-014` |
| Per-account sub-unit dust | Flooring each account's share leaves sub-unit dust. It is banked per account against the accumulator, so a stake change neither forfeits it nor credits it a second time, and it stays inside protected liability until a later recognition completes it into a claimable whole unit. It is likewise never separately withdrawable, never surplus-recognizable, and never recoverable. | `SPL-013`, `SPL-007`, `SPL-012` |

## 9. Explicitly out of scope through C4

No RPC or provider access, fork execution, deployment, signature, transaction, wallet action,
secret access, production data, admission decision, or value movement occurs in this repository.
Live-chain truth remains an unproven assumption recorded as pending fork requirements.
