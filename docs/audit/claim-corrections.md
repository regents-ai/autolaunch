# C5 claim corrections and inherited obligations

Every change C5 made to a claim that a closed ticket already owned, and every inherited obligation
it discharged. C5 itself changed no contract behaviour: its only production edit was one comment
range in `src/bindings/BaseBindings.sol`.

Section 4 records what its successor, `regent-alv1.6.1`, changed after C5's own final audit stopped
it — including the enumerated source-delta gate that replaced C5's all-bytes-equal claim. Section 5
records what the next successor, `regent-alv1.7` (C6), changed: the recovery administrator is deleted
outright, recovery becomes permissionless and whole-balance, and one launch-time treasury admission
is added.

## 1. Corrections to closed claims

| Claim | Owner | What was wrong | What C5 did |
| --- | --- | --- | --- |
| `FAC-023` | C4 | The statement admitted the raise interval without saying what a launch at either end settles on, which let the maximum *bid* price be read as a clearing price. | Statement corrected. `test_FAC_023_*` now asserts that a one-wei raise clears at the fixed floor — at both the lowest and the highest admitted bid tick — and **asserts the exact LP amounts** the position consumed, `1` wei REGENT and `981` wei SUBJECT, rather than bounding them and publishing the figures separately. |
| `STR-014` | C3 | The zero-liquidity fuzz derived its minimum raise from a claim the pinned CCA does not make: that a graduating checkpoint clears the whole remaining supply in one step. It does not. | Statement corrected and `testFuzz_STR_014_GraduatedDistributionNeverPlansZeroLiquidity` rewritten around the relation the CCA does prove — one uniform clearing price over whatever supply actually sold. Rewriting it surfaced a real constraint the overstatement had hidden: supply is indivisible, so a reachable raise is at least the price of one whole SUBJECT unit. The corrected fuzz passes across the whole genuinely reachable set. |
| `MIG-017` | C4 | Rollback was enumerated for graduation only, and the residue was measured at the PositionManager — which proves nothing, because the plan's `CONTRACT_BALANCE` settlement drains that contract to zero whether the refund was zero or enormous. | Statement corrected twice over. The test now enumerates the retirement path's own five external calls as well, and it measures the residue **where the pinned planner actually sends it**: `TAKE_PAIR`'s recipient is `ActionConstants.MSG_SENDER`, which the PositionManager resolves to its own caller, the strategy. The proof is now the PoolManager's own balance delta equalling exactly what the strategy funded, plus the treasury receiving exactly the unused raise and this launch's escrow receiving exactly the unused reserve — so the refund is **exactly zero in both currencies** at the real recipient. |
| `HOK-006` | C2 | The statement did not name the boundaries that actually matter for a specified-currency charge taken before the swap resolves. | Statement narrowed to the partial-fill and zero-fill boundaries the existing test already drives. No test change. |
| `HOK-016` | C2 | "Settlement failure reverts the swap" did not distinguish the two insufficient-settlement branches. | Statement narrowed to name both: a splitter that reverts, and a splitter that returns without consuming the exact approved lane. Both were already exercised. No test change. |
| `HOK-018` | C2 | The statement was broader than the exercised evidence, and the nested sub-lane shapes were never driven. | Statement corrected to name exactly what is driven, and `test_HOK_018_*` **extended with the mandatory nested zero-lane sub-case**: a nested swap issued from inside the hook's settlement call, too small for either 1% lane to floor above zero. The hook's zero-lane branch returns before it takes, approves, or calls anything, leaves the outer swap's live approval untouched, and the outer swap settles exactly as an uninterrupted one would. The claim also now records that the nested attacker's own failure mode is an arithmetic panic in its outer settlement, not a hook-authored revert. |
| `FAC-002` | C4 | "No user salts" read as though the launcher had no influence on the created address at all. | Statement corrected: name and symbol *do* move the pinned UERC20 CREATE2 address, because the pinned factory hashes them into its own salt. That is upstream identity derivation, it confers no authority, and Autolaunch itself still exposes no public or creator-selected salt. |
| `FAC-015` | C4 | "The treasury is immutable" said nothing about the blast radius of a launcher-chosen one. | Statement corrected to name the radius: a hostile or broken treasury can break or strand only its own launch's value, while every other registered pool keeps settling. No denylist was added. |
| `STR-012` / `STR-018` | C3 | Both overlapped with `INV-009` and `MIG-018` on who owns cross-launch and repeated-call behaviour. | **Statement-only disambiguation.** `STR-012` and `STR-018` now own single-operation behaviour, `INV-009` owns sequence-level cross-launch isolation, and `MIG-018` owns repeated terminal calls. No selector and no test moved. |
| `INV-003` / `INV-005` / `INV-006` / `INV-009` / `INV-010` | C5 | Several were phrased loosely enough to be satisfied by one shared model. | Each given its own independent accounting model and a statement that says which question it answers. Principal, remainder, per-launch reserve conservation, cross-launch isolation, and attribution are five separate models. |
| `INV-006` | C5 | The graduated half bounded LP consumption with `<=` rather than closing the reserve, so a graduation that consumed one wei of LP and sent the rest to a treasury would have passed. | Statement and model corrected to an equation. The handler measures, per launch, the exact LP SUBJECT consumed and the exact reserve residue returned to that launch's own escrow — separated from the auction's own unsold sweep by balance deltas taken either side of the migration — and the invariant requires the two to sum to `RESERVE_ALLOCATION` exactly. The failure half requires the retirement to have moved exactly the reserve to its own escrow. Treasury, factory, hook, and cross-launch destinations are each excluded by name. |
| `INV-009` | C5 | The statement claimed interleaved *launch creation*, which the handler never exercised: its three launches are created in `setUp` before the sequence begins. | Statement narrowed to the operations actually interleaved — bidding, block and clock progression, migration, vesting release, late retirement, and external gifts — and it now says explicitly that `STR-012` owns single-operation creation isolation. |
| `INV-009` handler | C5 | `rollForward` advanced only the block height. Vesting is measured in seconds, so `release` was a permanent no-op, the treasury never held SUBJECT, and every gift branch beneath it was dead — while the campaign still reported full call counts and zero reverts. | The timeline now advances the block timestamp with the height at Base's fixed two-second block time, which is monotone and production-reachable. A new deterministic selector, `test_INV_009_HandlerReleaseAndGiftBranchesAreReachable`, drives one fixed sequence through the handler's own entry points and requires both branches to do real work, so a regression to a block-only clock fails loudly. |
| `DEP-043` | C5 | The check followed a recorded proxy family but only ever read the EIP-1967 slot for a non-proxy, never re-derived the family from chain state, never compared the implementation's own code identity, and let an EIP-1822 proxy point at an implementation with no code. | The family, the implementation address, the implementation's runtime code hash and its runtime length are all re-derived live and compared against the reviewed record. Three families are recognized — EIP-1967, EIP-1822 and the older ZeppelinOS slot Base's own USDC uses — and every proxy family must point at an implementation that carries code. |
| `DEP-044` | C5 | The statement named `symbol` and the test never called it. | `symbol()` is now called on the deployed token and compared against the reviewed record, alongside `decimals` and the exact transfer and allowance semantics. |
| `DEP-045` | C5 | A `pause()` that reverted or did nothing was treated as a passing alternative — "no pause surface" — which is exactly the outcome the claim exists to rule out. The deployed `paused()` getter was never read. | The owner-driven pause is mandatory: it must succeed, `paused()` must then read true, and the skim must revert. The deployed `owner()` and `paused()` are read and compared against the reviewed record first, and a contract already paused on Base is itself a stop. Each header runs in its own fork, so the pause is never visible to another claim. |
| `DEP-046` | C5 | The residue was logged rather than asserted, and it was watched at the PositionManager — which `CONTRACT_BALANCE` drains to zero regardless. Only one currency was pre-seeded, and nothing distinguished cross-launch inventory. | Both pool currencies are pre-seeded through real paths — a REGENT holder's own transfer, and a bidder's own claimed SUBJECT — plus a second launch's SUBJECT as cross-launch inventory. The exact pinned-planner disposition is then asserted: both pool currencies drained to zero at the PositionManager, the seeded REGENT forwarded to this launch's treasury and the seeded SUBJECT to this launch's escrow through `TAKE_PAIR`'s real recipient, and the other launch's SUBJECT untouched to the unit. |
| `DEP-048` | C5 | The four-argument `submitBid` was called rather than the five-argument overload the frozen surface records, and one conditional auction outcome stood in for every required path. | Three launches carry three bidders through three endings on every run: a full refund on a launch no single bid can carry, an applicable partial exit constructed by outbidding a low bid, and a graduated claim. The allowance flow is proved exactly — ERC20 approval to Permit2, a Permit2 allowance with a bounded expiration, exact consumption and cleanup — every call is the account's own, and the five-argument overload is used throughout. |
| `DEP-049` | C5 | Two terminal outcomes were driven and neither was proved terminal. | Three are driven — graduated, zero-bid retirement, and a partially bid retirement that misses its raise — and each is then proved terminal: a repeated finalization reverts and moves no escrow or retired SUBJECT. |
| `DEP-050` | C5 | "the latest Base head" left the comparison open-ended, and the proxy verdict echoed a committed string back out — identical at both headers by construction, and therefore evidence of nothing. | Narrowed to the pinned header recorded for *this candidate* and the later head captured for the same candidate, and every verdict is now derived from live chain state at that header: the proxy family is classified from the slots themselves, and the implementation address and its code identity are each compared against the reviewed record rather than restated. The ceremony-time fresh-head recheck stays with `regent-4wx`. |
| `ABI-007` | C5 | "exactly as the product watcher consumes them" made a claim about a downstream consumer this repository has no evidence about, and the frozen record carried only an indexed *count* — which cannot tell `Foo(address indexed a, uint256 b)` from `Foo(address a, uint256 indexed b)`. | Narrowed to compiler and frozen-artifact truth only, and strengthened: the freezer now records each event argument's exact type, indexed flag, name and position, and the test pins every production event field by field. The Ash watcher's own coverage is separate product work under `490.8.2/.3`. |
| `GAS-001` / `GAS-002` | C5 | The frozen record carried byte lengths and SHA-256 digests but no EVM code identity, no compiler per contract, no constructor shape, and neither of the two pinned dependency builds the ceremony needs. | Statements corrected. The freezer now records the compiler, the runtime and creation keccak-256, the constructor shape, and the margins for all six production contracts plus `UERC20Factory` and the per-launch `UERC20` build, and marks per contract whether its artifact keccak is a deployed `EXTCODEHASH`. The tests prove that flag honest in both directions and reconcile the four admitted identities against the production constants. SHA-256 remains beside them as a packet-diffing digest only. |
| `GAS-007` | C5 | The control swap ran a different amount on a different pool, so the measured difference carried the swap-size effect as well as the callback, and the published figures were not re-proved by anything. | The control is now exact: the hook's lane boundary is a single wei, so the charging swap and the zero-lane control run one wei apart on pools the fixture opens identically and asserts identical. A second production-sized pair is recorded and labelled for what it is. Cold is stated as the user-transaction posture and warm as the control. `bin/gate.sh` now reconciles every published figure against the value `GAS-007` actually emitted. |

## 2. Known limitation carried, not fixed

`test_STR_012_ReserveIsIsolatedPerAuction` in `test/strategy/RegentLBPStrategy.t.sol` drives two
launches and, after retiring the first, rolls the block height *backwards* to the second launch's
start in order to bid on it. No chain can do that. The property it asserts is real and the test
passes, but the sequence it uses is not one production can produce.

That file is outside C5's allowed paths, so this is recorded rather than repaired. The same defect
was present in `test/factory/AutolaunchFactoryReceivers.t.sol`, which *is* inside the allowlist, and
there it was corrected: `test_FAC_024_*` now bids inside the launch's own open window before the
shared migration block, so its timeline only ever moves forward. `INV-009`'s handler is monotone by
construction for the same reason, so the sequence-level version of this property does have
production-reachable evidence.

**Proposed follow-up:** one narrow Tier-1 successor to make
`test_STR_012_ReserveIsIsolatedPerAuction` monotone, with no statement change.

## 3. Inherited obligations discharged

| Obligation | Disposition |
| --- | --- |
| C0R: `README.md` must describe the gate's actual order and layout | Corrected. The README's numbered gate order now matches `bin/gate.sh` exactly, including the frozen-surface check and the secret scan, and the layout table distinguishes `reports/generated/` from `reports/frozen/`. |
| C0R: the exact `BaseBindings` range correction | Applied. `DEP-040` through `DEP-050` became `DEP-040` through `DEP-051`, which is the whole production diff. Byte identity against the pre-edit C4 baseline is proved by the gate. |
| Freezer deletion must fail the ledger | `DEP-016` is a gate-dependency claim whose verified receipt only `bin/freeze-artifacts.py check` writes. Deleting the invocation from `bin/gate.sh` leaves the receipt absent and fails the ledger reconciliation. |
| Provider secret material must not reach evidence | `bin/check-requirements.py secrets` runs in both gates. It proves the configured `base` alias is still the unresolved `${REGENT_BASE_RPC_URL}` in the *effective* configuration, that no credential field carries a value, and that no scanned artifact names a host outside a documentation and provenance allowlist. |
| Cold/warm hook callback cost must be recorded separately | New claim `GAS-007`. See [gas-and-size.md](gas-and-size.md). |
| Fork discovery must be genuinely executable and separate from checking | `bin/fork-gate.sh discover` runs `test-fork/ForkDiscovery.t.sol` under a profile whose only writable path is gitignored scratch. It reads no committed observation, writes one reviewable candidate, closes no claim, and is excluded by name from every ledger reconciliation. `check` runs under a profile with no write permission at all and refuses to start until the reviewed record and the activated ledger are committed and clean — then proves them unchanged afterwards. |
| Both fork headers must reconcile against one listing | `bin/check-requirements.py ledger` now accepts several executed reports and merges them as one multiset, so the pinned and later runs together satisfy the compiled listing of all thirty-six mapped selectors. The fork profiles also build into `out-fork`, so fork artifacts can never change the artifact count the required gate reconciles. |
| Consumed upstream event and Permit2 surface must be frozen exactly | New claim `ABI-010`. Every consumed CCA event is pinned by indexed position, name and width — `BidSubmitted(uint256 indexed id, address indexed owner, uint256 priceQ96, uint128 amount)` included — and the Permit2 surface is frozen as the founder-selected allowance flow only, with `permit`, batched and `permitTransferFrom` shapes asserted absent. |
| Return tuple layouts must be frozen alongside input tuples | New claim `ABI-011`. `launches()`, `distribution()`, `poolKeyOf()` and `getHookPermissions()` are frozen field by field and reconciled against what the live contracts return. |
| The C4 runtime baseline must be an independent capture, not a self-declaration | `bin/freeze-artifacts.py check` now proves it against Git: the working file must be byte-identical to the blob the capture commit committed, that commit must sit directly on integrated C4, and the two must share one `src` tree. Forging it needs a rewritten history. |

## 4. `regent-alv1.6.1` — the terminal-custody correction

> **Superseded in part.** Everything below is the historical record of what `regent-alv1.6.1`
> changed. `regent-alv1.7` (section 5) then deleted the recovery administrator outright, so
> `FAC-016` and `MIG-020` — and every sentence here about an admin's code, its liveness, or its
> loss — no longer describe live behaviour. The `DEP-016`, `DEP-043`, `GAS-007`, `DEP-052`,
> `DEP-053` and gate-order entries below are unaffected and still current.

C5's own final Solidity audit stopped it: one confirmed terminal-path defect in production code, and
two pieces of fork evidence that claimed more than they measured. This successor corrects all three
and adds the founder-authorized exact-production fork lifecycle suite. The result stays **mainnet
NO-GO**.

### 4.1 The production defect and its fix

`SubjectSplitterV1.initialize` re-checked that the recovery admin still carried code. That check ran
on the **only** migration path a launched auction has, and whether an address carries code is mutable
environmental state: under EIP-6780 a contract created and destroyed in one transaction disappears
entirely. A launcher could therefore deploy its own admin, launch with it, destroy it in the same
transaction, and leave the launch permanently unable to graduate — after real bidders had paid in.

The fix is a deletion, not a new mechanism:

- the splitter's later code check and its now-unused `RecoveryAdminHasNoCode()` error are removed;
- `RegentLBPStrategy.initializeDistribution` remains the single launch-time contract-code check, so
  a code-less admin is still refused at admission (`FAC-016`, unchanged test);
- the splitter keeps the same immutable admin address, the same fixed recovery destinations, the
  same zero/self checks, the same caller binding, and identical economics. No replacement admin, no
  fallback admin, no retry mode, and no new authority was added.

`MIG-020` proves the liveness half against a production-reachable state: the setup transaction
deploys the admin, launches through the real factory, and destroys the admin; a later transaction
then graduates the launch and proves the splitter, the canonical receiver, vesting, and the immutable
admin recording all complete. No `vm.etch`, `vm.store`, or `vm.mockCall` is used.

The narrower consequence is disclosed rather than hidden: if that immutable admin loses its code,
unsupported-token and forced-ETH recovery become permanently uncallable on the launch splitter and on
every receiver created for that launch. Everything else — graduation, revenue, staking, claims,
`claimAll`, unstaking, payments, vesting, swaps — keeps working, and USDC, REGENT and SUBJECT were
never recoverable anyway. `docs/security/threat-model.md` section 8 carries it as an accepted
consequence.

### 4.2 Corrections to claims

| Claim | What was wrong | What this ticket did |
| --- | --- | --- |
| `FAC-016` | "The recovery admin is an immutable deployed contract" read as a standing property, which is what produced the redundant second check. | Narrowed to what it is: a launch-time admission, performed once, in exactly one place. The rejection test is unchanged. |
| `DEP-016` | Asserted that **every** `src/**` byte equals the C4 capture — true while C5's only edit was a comment, obsolete the moment a successor has to correct behaviour. | Replaced by an enumerated source-delta gate. The historical C4 capture stays immutable and is still proved against Git. `requirements/frozen-identity.json` names exactly two contracts that may differ, each with a written reason; the freezer requires each of them to **actually** differ, so the record can never become a standing exemption, and requires every other contract to match byte for byte. It proves which bytes moved, never why. |
| `DEP-043` | "Proxy status" could be read as universal non-proxy detection, and the frozen Regent Safe — a Safe proxy, which keeps its singleton in slot 0 rather than a namespaced slot — was classified as a plain contract. | A Safe singleton detector is added for **exactly** that one address, and it admits the family only when four measurements agree: the slot-0 address, the `masterCopy()` return, a delegating-stub runtime shape, and a code-bearing singleton. Everything else reports one of the three supported implementation slots or `no_supported_proxy_pattern`, which says what was measured and makes no universal claim. Runtime code hashes stay mandatory for every binding regardless of family. |
| `GAS-007` | Held the callback measurement to a 100,000-gas target and a 300,000-gas ceiling. Neither exists — not in Uniswap v4, not in any pinned dependency, not in `SPEC.md` or a founder requirement. Passing an invented limit is not evidence. | Both literals and their pass/fail assertions removed. The claim now records its measurements and asserts only what the controlled measurement establishes; the alternate-router figure is explicitly recorded-only. The 14,000,000 complete-transaction ceiling remains the one absolute gas limit this repository asserts. |
| Published gate order | `README.md` listed Slither before the published-evidence reconciliation, and its forward cross-reference pointed at the wrong step. `bin/gate.sh` runs published evidence first. | The published order now matches the executable gate, and the `-vv` cross-reference points at the step that actually reads decoded logs. |

### 4.3 Additions

| Addition | What it is |
| --- | --- |
| `MIG-020` | The terminal-path liveness regression described above. |
| `ABI-012` | The deleted splitter error selector `0x4f986444`, proved absent from the frozen error surface and from every generated per-contract ABI, while the strategy's distinct `RecoveryAdminHasNoCode(address)` selector `0xa6397a8c` is proved still present on both — a diff in both directions, not merely an absence. A runtime byte scan is deliberately not part of it: sound for a deleted function, whose dispatcher must carry the selector literally, but unsound for a custom error under this repository's via-IR build, which emits this error's revert prologue as `shl(226, 0x298e5ea3)` rather than `shl(224, 0xa6397a8c)`, so the live strategy runtime carries the four selector bytes nowhere. |
| `DEP-052` | Complete fork-header binding. Every fork claim now reaches its own work only through `_selectFork`, which compares the block number, parent number, parent hash, timestamp, base fee and chain id against the reviewed record before the claim executes; and the two committed headers are proved to be exactly the fixed pinned-to-later distance apart. |
| `DEP-053` | The founder-authorized exact-production fork lifecycle suite. See section 4.5. |
| Provider-output scan | `bin/fork-gate.sh` no longer displays anything a provider produced before scanning it. See section 4.4. |

### 4.4 Provider output is scanned before it is displayed

The previous fork gate printed each pass's log and *then* scanned the run's artifacts — so anything
the scan was going to find had already been printed — and on an ordinary provider or test failure it
stopped without keeping scanned diagnostics.

Two failure orders are now kept apart:

- **the run failed and its output is clean.** The output is not a secret. It has already passed the
  scan, so it is displayed and the whole scratch directory is retained for diagnosis.
- **the output is dirty, whatever the run's exit status.** Nothing is displayed. The scanner reports
  only redacted findings — the host, every other endpoint component, and every key-shaped token
  removed, whether or not it sat inside a URL — names the local paths, and the gate deletes the
  scratch unread. That is the one and only case in which scratch is destroyed.

The endpoint is still read only from `REGENT_BASE_RPC_URL`, never from argv and never from a
committed file. Both orders are proved deterministically and without a provider by
`test/tooling/provider_output_scan_test.py`, which `bin/gate.sh` runs and fails closed on.

### 4.5 The exact-production fork lifecycle suite

`DEP-053` deploys the exact final production UERC20 factory, the three C1 implementations, the
factory, the strategy and the mined hook on an isolated Base-mainnet fork at each committed header
independently, reconciles their creation and runtime code identities against the frozen build, and
then drives the whole path through production-reachable callers against the real CCA, Permit2,
REGENT, USDC, live staking, PoolManager and PositionManager: exact wallet fee approval and launch,
five-argument bidding, a failed auction with full bidder refund and exactly 100 billion SUBJECT
retired, a graduated auction migrating at the CCA final price, bidder exit and SUBJECT claim, SUBJECT
stake, canonical receiver payments in all three recognized assets, splitter skims, one real Uniswap
v4 swap settling both 1% REGENT hook lanes with no hook inventory left, `claimAll`, and unstake. It
then asserts exact final balances and allowances, both lifecycles, dead-address ownership of the LP
NFT, the position's actual consumption and both residues, and that no Regent contract holds an
unexplained balance.

Test-only staging is exactly two things and both are itemized in
[fork-authority-and-state-inventory.md](fork-authority-and-state-inventory.md): `deal` giving an
ordinary wallet REGENT or USDC, because a fork cannot mint either, and `vm.prank` acting as an
ordinary unprivileged EOA. One test-only contract is deployed — the pinned v4-core `PoolSwapTest`
router — and the hook has no router allowlist by design, so an arbitrary router is a
production-reachable caller rather than a substitute for one.

The existing focused fork claims and the both-header complete-transaction gas proofs remain separate
named tests. No Base Sepolia path exists. The authorized provider access was read-only, and every
claim ran in isolated local fork state at both committed Base headers.

### 4.6 The deleted selector and the Ash lane

Removing the splitter's redundant check deletes one custom error from the frozen ABI:
`RecoveryAdminHasNoCode()`, selector `0x4f986444`. `ABI-012` proves it is gone from every production
contract's frozen error surface and from every generated per-contract ABI, and that the strategy's
distinct `RecoveryAdminHasNoCode(address)` selector `0xa6397a8c` is still on both.

**Exact final ABI delta for the Ash lane:** `SubjectSplitterV1` loses the error
`RecoveryAdminHasNoCode()` / `0x4f986444`. Nothing else in any production ABI changes — no function
selector, no event topic, no indexed field, no integer width, and no other error.

That no Ash source consumes the deleted selector follows from the controlling specification rather
than from a search of the product repository, which is outside this ticket's boundary and was not
read. `SPEC.md` section 11 permits contract-independent Ash work before C5 only on condition that it
"may not invent a Regent ABI, deployed address, runtime fact, predecessor-hint source, projector
fact, entitlement, or admission result", and binds every Regent ABI consumer to the freeze C5 now
carries. **Required downstream confirmation:** have the Ash lane compare the exact delta above
against its own tree when it consumes the frozen ABI, since this repository cannot see that tree.

## 5. `regent-alv1.7` (C6) — the recovery and treasury correction

Three founder-approved corrections. The result stays **mainnet NO-GO**.

### 5.1 The recovery administrator is deleted

`regent-alv1.6.1` disclosed an accepted consequence: if a launch's immutable recovery admin ever
stopped carrying code, that launch's `recoverUnsupportedToken` and `recoverForcedETH` became
permanently uncallable on its splitter and on every receiver created for it. C6 removes the
consequence by removing the account that caused it.

The administrator existed to decide two things — the amount and, implicitly, when — and neither is a
decision. Both calls now read the complete recoverable balance themselves and send it to the
launch's immutable treasury:

- `recoverUnsupportedToken(address token)` sweeps this contract's whole balance of `token`, with
  USDC, REGENT and SUBJECT permanently refused;
- `recoverForcedETH()` sweeps this contract's whole ETH balance;
- both keep their reentrancy guard, both revert on a zero recoverable balance without mutating
  anything, and a hostile unsupported token can still fail only its own call.

A caller can name neither an amount nor a destination and keeps nothing, so opening the calls to
anyone grants nobody anything. What it removes is the single account whose loss could strand a
launch's stray assets forever.

### 5.2 Launch-time treasury admission

The launcher still chooses the treasury, and it is still immutable. C6 adds one private check inside
`RegentLBPStrategy.initializeDistribution`, after the escrow is authenticated and before the auction
is created, refusing a closed set:

- by exact address: the bound factory, the shared strategy, the bound fee hook, the frozen
  PoolManager, the frozen PositionManager, and the frozen live staking contract;
- by fixed minimal-clone runtime fingerprint: any address already carrying the 44-byte Solady clone
  runtime of the admitted escrow, splitter, or receiver implementation;
- by exact address again: the two addresses this launch's own splitter and canonical receiver will
  be deployed to.

That last pair is the part worth explaining. An earlier draft of this ticket admitted them, on the
reasoning that admission can only answer for the code an address carries *now*. The audit rejected
that: the two clones were deployed with plain `CREATE`, so their addresses depended on the
strategy's nonce, and a launcher who guessed that nonce produced a launch that was admitted, took
bidders' REGENT, and then could never bind its own splitter — a stall with no alternate migration.

C6 removes the guess instead of accepting the stall. Both clones are now deployed with `CREATE2`
from a salt the strategy derives from one of its own private role constants and the launch's
immutable identity — the factory-assigned launch ID and the SUBJECT the authenticated escrow bound.
Nothing about that salt is supplied, chosen, or influenced by any caller, and it grants no authority.
Because it depends on nothing but facts that already exist when `initializeDistribution` runs, both
addresses are known before the auction is created, so admission can refuse them truthfully.
`MIG-021` closes the loop from the other end: a real graduation deploys to exactly the two addresses
admission refused. The derivation stays internal — it is not part of the strategy's ABI, and
`LaunchGraduated` and the strategy record remain the only canonical account of what a launch
deployed.

Everything else stays admissible with no code requirement at all — the dead address, an ordinary
EOA, an arbitrary contract, the Governance and Regent Safe, a live CCA auction, and an address only
a *different* launch's artifact will occupy. There is no registry, no generalized denylist, and no
code-length rule, because each of those would refuse the ordinary treasuries the design is for. The
escrow's own `treasury_ == address(this)` refusal runs one call earlier and is unchanged.

One consequence of that deliberate narrowness survives, and it is named and tested rather than
hidden: a launcher who names an address which later becomes *another* launch's splitter or receiver
may deliver its own payouts into that launch's ordinary accounting — `FAC-015`. Refusing it would
require the strategy to enumerate every launch that does not exist yet. It costs that launcher its
own value and nobody else's; lifecycle state and each launch's isolated 5% reserve stay isolated.

### 5.3 Exact PositionManager funding

The second finding the audit raised. `PositionPlanner.toPlan` — pinned upstream code, not ours —
closes every plan with `SETTLE(currency0, CONTRACT_BALANCE)`, `SETTLE(currency1, CONTRACT_BALANCE)`,
`TAKE_PAIR(currency0, currency1, MSG_SENDER)`. `CONTRACT_BALANCE` resolves to the PositionManager's
*entire* balance of each currency, and the PositionManager is shared with every other Uniswap v4
user on Base. Honouring it would have settled REGENT and SUBJECT this launch never funded, handed
the resulting credit back to the strategy as if it were this launch's unspent budget, and forwarded
it to this launch's treasury and escrow.

Graduation now replaces exactly those two settlement amounts with the exact two amounts it transfers
in for its own mint. The pinned action sequence is untouched, every mint parameter is untouched, and
this launch's own plan dust still returns through `TAKE_PAIR`. `MIG-022` proves the preservation on a
real graduation with both pool assets pre-seeded through production paths, and `DEP-046` proves the
same property against the deployed PositionManager on Base.

### 5.4 Corrections to claims

| Claim | What was wrong | What this ticket did |
| --- | --- | --- |
| `FAC-016` | The claim's subject — the recovery admin — no longer exists. | **Retired.** The entry and its selector `test_FAC_016_RecoveryAdminIsAnImmutableDeployedContract` are deleted, and the ID is never reused. Launch-time admission still exists, but it admits the treasury and is `STR-019`. |
| `MIG-020` | Same: it proved graduation survived a destroyed recovery admin. | **Retired.** The entry and its selector `test_MIG_020_GraduationSurvivesRecoveryAdminDestroyedAtLaunch` are deleted. Nothing replaces it, because the failure mode it guarded cannot occur without an administrator. |
| `FAC-015` | "Its blast radius is exactly one launch" was too strong once a launcher can point its treasury at another launch's artifact. | Statement corrected to say which isolation is promised and which is not: lifecycle state and each launch's isolated 5% reserve always are; explicit value routed to a launcher-selected cross-launch treasury is not. The immutability half and its test are unchanged; `test_FAC_015_CrossLaunchTreasuryIsNotValueIsolated` proves the named consequence end to end through real launches. |
| `SPL-017` | "Only the immutable recovery admin may recover" is false. | Rewritten to the new normative statement — permissionless, complete balance, immutable treasury, zero-balance revert, hostile token contained — and its selector renamed to `test_SPL_017_RecoveryIsPermissionlessWholeBalanceToTheTreasury`. The old selector is deleted rather than repointed at replacement behaviour. |
| `RCV-009` | Same, on the receiver. | Same treatment; the selector is now `test_RCV_009_RecoveryIsPermissionlessWholeBalanceToTheTreasury`. |
| `ABI-003` | `LaunchParams` no longer carries `recoveryAdmin`. | Statement corrected to the eight remaining fields, in order. The test proves them against both the compiler's field list and the tuple encoded in `launch`'s own selector. |
| `ABI-005` | "administrative recovery functions" is no longer what they are. | Statement corrected to the two permissionless recovery functions at their new amount-free signatures, and the selector renamed to `test_ABI_005_SplitterRecoverySurfaceIsExact`. |
| `ABI-012` | Half the claim — that the strategy's `RecoveryAdminHasNoCode(address)` survives — is now false. | Rewritten as the whole-surface deletion it has become, with its selector renamed to `test_ABI_012_DeletedRecoveryAdministrationSurfaceIsAbsent`. It still diffs in both directions: every deleted selector absent from the frozen surface and from every generated per-contract ABI, and the two replacement recovery entry points asserted present. |
| `STR-013` | Its selector list carried the recovery-admin admission test. | That selector is removed. The remaining six are unchanged; the frozen CCA parameter set is not affected. |
| `MIG-003` | "Graduation deploys the splitter clone" no longer says where. | Statement corrected to name the deterministic clone address alongside the bindings the selector already asserted. |
| `DEP-046` | It described the deployed PositionManager's `CONTRACT_BALANCE` disposition, which graduation no longer asks for. | Statement corrected to preservation: a real graduation on Base settles only what this launch funds and leaves every other REGENT, SUBJECT and cross-launch balance at that shared contract untouched to the unit. The two fork selectors are unchanged in name and rewritten in body. |

### 5.5 Additions

| Addition | What it is |
| --- | --- |
| `STR-019` | The closed launch-time treasury refusal and admission set, proved class by class before any auction exists, with a fresh SUBJECT and a genuinely funded escrow per arm so every refusal is reached through the real authentication path. Its second selector covers the two refusals that carry no code at all — this launch's own future clone addresses. |
| `FAC-028` | Atomicity of that refusal at the factory: the fee movement, the created SUBJECT, the cloned and funded escrow, the auction, the launch ID, both records and every event roll back together, and no existing launch's lifecycle, escrow custody or isolated reserve is disturbed. Nine arms, including the attempted launch's own two clone slots. |
| `MIG-021` | The terminal half of `STR-019`: the two addresses admission refused are exactly the two addresses a real graduation of that same launch deploys to, correctly bound and registered. The test derives both from first principles in `test/mocks/LaunchCloneSlots.sol` — the role strings, the salt, and the CREATE2 rule — sharing no code with production, so it proves the derivation rather than restating it. |
| `MIG-022` | Exact PositionManager funding on a real graduation, with REGENT and SUBJECT pre-seeded at the shared PositionManager through production paths and both preserved to the unit. |
| `test_FAC_015_CrossLaunchTreasuryIsNotValueIsolated` | The cross-launch consequence, driven through two real launches: the first launch's own vested payout lands on the address the second launch's splitter later occupies, and permissionless recovery then routes it to the second launch's treasury. |

### 5.6 Exact final ABI delta for the Ash lane

This is the complete production ABI change. Nothing else moved.

**`RegentsAutolaunchFactoryV1`**

- `launch` changes signature: `launch((string,string,string,string,string,address,address,uint128,uint256))` / `0x783eed53` becomes `launch((string,string,string,string,string,address,uint128,uint256))` / `0xd0464e3e`. The `recoveryAdmin` field is removed from `LaunchParams`; the other eight fields keep their order and widths.
- `LaunchCreated` changes topic0: `0xca3d1d4b2083435e11137aab340619d30df4b91203fffec8a2073a630d52e492` becomes `0x7b5b327fb976e7bf5fb279515b3ea1821166f52c0b46e5825f0146b249f963f2`. The non-indexed `recoveryAdmin` argument is removed; the three indexed arguments and every other field are unchanged.
- `launches(uint256)` keeps selector `0x7b443a76` but its **return tuple loses its sixth field**, `address recoveryAdmin`. A positional decoder must be updated even though the selector did not move.

**`RegentLBPStrategy`**

- `initializeDistribution` changes signature: `initializeDistribution((uint256,address,address,uint128))` / `0x8e9c3c87` becomes `initializeDistribution((uint256,address,uint128))` / `0xd7750ed5`. Factory-only, so no external consumer calls it.
- `distribution(address)` keeps selector `0xc2db09c1` but its **return tuple loses its fifteenth field**, `address recoveryAdmin`.
- Error `RecoveryAdminHasNoCode(address)` / `0xa6397a8c` is deleted; error `RefusedTreasury(address)` / `0xa30fa418` is added.
- No view function is added. The launch-scoped clone-address derivation and the two clone-runtime
  fingerprints it is checked against are private, so the strategy's read surface is unchanged apart
  from the `distribution` tuple above.

**`SubjectSplitterV1`**

- `initialize(address,address,address,address,address,address,address)` / `0x35876476` becomes `initialize(address,address,address,address,address,address)` / `0xcc2a9a5b`.
- `recoverUnsupportedToken(address,uint256)` / `0x0112d431` becomes `recoverUnsupportedToken(address)` / `0x22ab5669`.
- `recoverForcedETH(uint256)` / `0xcfbe2877` becomes `recoverForcedETH()` / `0x4725dd8e`.
- The `recoveryAdmin()` getter / `0x5f6529a3` is deleted.
- Error `NotRecoveryAdmin(address)` / `0x97e9d21c` is deleted.
- `SplitterInitialized` changes topic0: `0xf8dee9e13cd7985023b608a594d1dded7026dbee2410e00a6ffff7782f4eabf2` becomes `0x1689ff76899a73e015b320864ebe12f63b8028f741cd98db58bdcc9a32674efa`. The indexed `recoveryAdmin` argument is removed, so the event drops from three indexed arguments to two — `subject` and `treasury` — and a watcher filtering on the third topic must be updated.

**`PaymentReceiverV1`**

- `recoverUnsupportedToken(address,uint256)` / `0x0112d431` becomes `recoverUnsupportedToken(address)` / `0x22ab5669`.
- `recoverForcedETH(uint256)` / `0xcfbe2877` becomes `recoverForcedETH()` / `0x4725dd8e`.
- The `recoveryAdmin()` getter / `0x5f6529a3` is deleted.
- Error `NotRecoveryAdmin(address)` / `0x97e9d21c` is deleted.

**`ConditionalVestingEscrowV1`** and **`RegentFeeHook`**: no ABI change of any kind, and no source change. `bin/freeze-artifacts.py check` proves both compile to the exact runtime and creation byte strings the C4 capture recorded.

**Deployment consequence.** The strategy's runtime changed, so the strategy address a fresh
deployment produces changes, and the hook is CREATE2-mined over `abi.encode(PoolManager, strategy)`.
The fee hook's **source** is unchanged and its **runtime identity changes only through that new
immutable strategy binding**. Fresh hook-salt mining therefore remains a deployment-packet
obligation, exactly as before; nothing in this repository pins a hook address.

**Required downstream confirmation:** have the Ash lane compare the delta above against its own tree
when it consumes the frozen ABI. This repository cannot see that tree and did not read it.
