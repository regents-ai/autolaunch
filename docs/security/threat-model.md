# Threat model — Autolaunch V1

Scope: the system frozen by [SPEC.md](../../SPEC.md). This document enumerates what the system
protects, who may act on it, where it depends on code it does not own, and how each adversarial
failure class is answered by a requirement in [the ledger](../../requirements/ledger.toml).

It describes only frozen specification behavior. It invents no contract behavior, and every
mitigation it names is a requirement ID whose evidence becomes mandatory when its owning ticket
activates. At C0 the repository holds immutable bindings and proof scaffolding only, so every
mitigation below except the dependency, binding, chain, and ABI provenance claims is still
pending. A pending mitigation is a named obligation, never evidence.

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
   is unproven until the authorized fork gate runs (`DEP-040` through `DEP-050`).
4. **Governance.** The Regent Safe may change the launch fee and pause new launches, and
   nothing else (`FAC-006`, `FAC-007`, `FAC-019`).
5. **Recovery admin.** An immutable deployed contract may move only forced ETH and unsupported
   ERC20s, only to the immutable treasury, on both the receiver and the splitter (`RCV-009`, `RCV-010`, `SPL-017`, `SPL-018`).
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
| Staking, claims, revenue | any caller, for itself only | splitter surface | `SPL-012`, `SPL-010` |
| Recovery | immutable recovery admin | `recoverUnsupportedToken`, `recoverForcedETH` on both receiver and splitter | `RCV-009`, `RCV-010`, `RCV-011`, `SPL-017`, `SPL-018`, `ABI-005` |

No upgrade authority, implementation pointer, kill switch, keeper, or arbitrary-execution
surface exists anywhere in the frozen design.

## 4. External dependencies and calls

| Dependency | Called for | Failure handling |
| --- | --- | --- |
| CCA factory and auction | auction creation, finalization, sweeps, refunds | technical failure is an ordinary revert with no retry state (`STR-004`); admission requires the exact runtime code hash and a zero protocol fee controller (`DEP-040`, `DEP-041`) |
| UERC20 factory | SUBJECT creation | token carries no administrative power afterwards (`TOK-003`, `TOK-005`) |
| PoolManager | pool initialization and swap settlement | settlement failure reverts the swap (`HOK-016`) |
| PositionManager | full-range position mint, NFT to dead address | migration rolls back on failure (`MIG-006`, `MIG-017`) |
| Live staking `depositUSDC` | USDC skim | exact approval, behavior verification, allowance cleanup (`SPL-003`) |
| REGENT, USDC, SUBJECT ERC20s | transfers, allowances | exact-allowance and exact-balance assertions (`FAC-008`, `MIG-016`) |

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

## 7. Adversarial failure classes

| Class | Concrete attempt | Answered by |
| --- | --- | --- |
| Dependency substitution | build against a moving branch, a look-alike commit, a copied `lib/` tree without git metadata, or a closure missing a nested dependency | `DEP-001`–`DEP-008` |
| Compiler or setting drift | different solc, optimizer runs, re-enabled metadata, or an environment override of the fuzz portfolio | `DEP-009`, `DEP-010`, `DEP-014`, `DEP-015` |
| Authority forgery in the frozen literals | edited address, code hash, chain, or selector in a manifest, fixture, or binding source; a binding renamed onto another binding's value | `DEP-011`, `DEP-012`, `DEP-029` |
| Interface-derived ABI | a selector taken from a vendored interface that omits or misstates the implementation | `DEP-013`, `ABI-001` |
| Fee griefing | stale expected fee, wrong allowance, or fee charged for a failed launch | `FAC-008`–`FAC-010`, `FAC-018` |
| Authority creep | pause blocking refunds, claims, or vesting; launcher provenance conferring power | `FAC-017`, `FAC-019`, `SPL-010` |
| Metadata abuse | oversized, empty, or malformed UTF-8 metadata | `FAC-013`, `FAC-014` |
| Inventory leakage | unsold, reserve, or residual SUBJECT stranded after either terminal path | `MIG-016`, `FAIL-004`, `ESC-005`, `ESC-006` |
| Migration partial commit | failure after an external call leaving a half-migrated launch | `MIG-017`, `STR-004` |
| Repeat or replay | migrating or retiring twice, re-running an initializer | `MIG-018`, `FAIL-008`, `ABI-008` |
| Hook boundary escape | unregistered key, foreign caller, hostile router, reentrancy | `HOK-017`, `HOK-018` |
| Fee lane evasion | tiny swaps, rounding at the exact fee boundaries, exact-output, or unspecified-currency paths avoiding a lane | `HOK-005`–`HOK-009`, `HOK-012`, `HOK-019`, `SPL-016` |
| Fee retention | hook keeping attributable inventory for a later flush | `HOK-014`, `HOK-015`, `INV-004` |
| Staker dilution or theft | interleaved stake and unstake around a deposit, or claiming another staker's share | `SPL-012`, `SPL-013`, `SPL-015`, `INV-003` |
| Remainder skimming | repeatedly recognizing dust to drain the carried remainder | `SPL-007`, `INV-005` |
| Recovery abuse | recovering a core token, staked principal, an unclaimed claim, or the carried remainder; recovering to a caller-chosen destination; sending ordinary ETH to create recoverable balance | `RCV-008`, `RCV-009`, `RCV-010`, `SPL-017`, `SPL-018`, `SPL-019` |
| Malicious token | a token that reverts, re-enters, or lies about transfers | `SPL-014`, `SPL-021`, `RCV-011`, `RCV-012` |
| Gas exhaustion | a terminal transaction that cannot fit in a Base block | `GAS-003`–`GAS-006` |
| Evidence laundering | a mock closing a deployed-runtime claim; a placeholder test closing a future claim; a product claim borrowing the gate-dependency evidence class; an overloaded or duplicated test identity collapsing two claims into one | ledger evidence classes, gate-aware activation, and compiled-listing multiset reconciliation, all enforced by `bin/check-requirements.py` |

## 8. Explicitly out of scope at C0

No RPC or provider access, fork execution, deployment, signature, transaction, wallet action,
secret access, production data, admission decision, or value movement occurs in this repository.
Live-chain truth remains an unproven assumption recorded as pending fork requirements.
