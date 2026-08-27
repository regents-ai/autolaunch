# C5 claim corrections and inherited obligations

Every change C5 made to a claim that a closed ticket already owned, and every inherited obligation
it discharged. C5 itself changed no contract behaviour: its only production edit was one comment
range in `src/bindings/BaseBindings.sol`.

Section 4 records what its successor, `regent-alv1.6.1`, changed after C5's own final audit stopped
it — including the enumerated source-delta gate that replaced C5's all-bytes-equal claim. Section 5
records what the next successor, `regent-alv1.7` (C6), changed: the recovery administrator is deleted
outright, recovery becomes permissionless and whole-balance, and one launch-time treasury admission
is added. Section 6 records what `regent-alv1.7.1` (C6.1) changed: the per-launch clones return to
the pinned upstream ordinary `CREATE`, C6's CREATE2 and clone-fingerprint treasury machinery is
deleted, and launch-time admission narrows to exactly six addresses.

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
| Both fork headers must reconcile against one listing | `bin/check-requirements.py ledger` now accepts several executed reports and merges them as one multiset, so the pinned and later runs together satisfy the compiled listing of every mapped selector — thirty-six when this obligation was discharged, twenty-seven since `regent-4wx` narrowed the fresh-head repetition to a nine-claim subset. The merge is what makes either shape reconcile against one listing. The fork profiles also build into `out-fork`, so fork artifacts can never change the artifact count the required gate reconciles. |
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

> **Corrected by `regent-alv1.7.1`.** This section is the current description. C6's original text
> described a wider refusal set and a CREATE2 clone identity, both of which section 6 deletes.

The launcher still chooses the treasury, and it is still immutable. There is one private check inside
`RegentLBPStrategy.initializeDistribution`, after the escrow is authenticated and before the auction
is created, and it refuses exactly six addresses: the bound factory, the shared strategy, the bound
fee hook, the frozen PoolManager, the frozen PositionManager, and the frozen live staking contract.
Sending a launch's payouts to any of them would either strand them in an account with no path back
out or feed them into shared accounting that was never told about them.

Nothing else is judged. There is no `code.length` test, no clone-runtime fingerprint, no interface
probe, no registry, no generalized denylist, and no predicted-address rule, because each of those
would refuse the ordinary treasuries the design exists for. The escrow's own zero-treasury and
`treasury_ == address(this)` refusals run one call earlier and are unchanged.

Each launch's splitter and canonical receiver are deployed with ordinary `LibClone.clone`, exactly as
the pinned upstream migrator does. A clone's address is therefore a function of the shared strategy's
nonce at the moment of graduation, and of nothing any caller chose. Nothing derives it in advance,
nothing publishes it, and no launch is refused on account of it. `LaunchGraduated` and the strategy
record remain the only canonical account of what a launch deployed.

Two consequences follow from that narrowness. Both are named, tested, and accepted rather than
prevented.

**An existing artifact as a treasury.** A launcher may name a splitter or canonical receiver that
another launch already deployed. Its own payouts then land inside that artifact's ordinary
accounting, where permissionless surplus recognition or permissionless recovery routes them onward
under that launch's rules — `FAC-015`, proved end to end through two real launches.

**A collision with the strategy's next clone address.** A launcher may name an address the shared
strategy's current nonce would later produce. That launch's own graduation then tries to deploy a
clone onto its own treasury, and the clone's initializer refuses to bind a treasury equal to itself,
so the whole migration reverts. Ordinary EVM atomicity rolls back the clone, the terminal record,
every transfer and the nonce advance together, which means an immediate retry targets the same
address and fails identically. The launch stalls — with its raised REGENT still in the CCA, its
escrow still `Pending`, its 5% reserve and the auction's unsold SUBJECT unmoved, no pool and no
vesting begun, and the CCA's own exit and claim rights untouched — until any other launch's
graduation consumes the next two nonces. The stalled launch then migrates normally, onto different
addresses, possibly routing its payouts into whichever artifact took the contested one. `STR-019`
drives that whole sequence against the real factory, the real auctions and the real strategy nonce.

Refusing either consequence would require the strategy to enumerate launches that do not exist yet.
Neither touches another launch's lifecycle state, custody ledger, or isolated 5% reserve.

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
| `FAC-015` | "Its blast radius is exactly one launch" was too strong once a launcher can point its treasury at another launch's artifact. | Statement corrected to say which isolation is promised and which is not: lifecycle state and each launch's isolated 5% reserve always are; explicit value routed to a launcher-selected cross-launch treasury is not. The immutability half and its test are unchanged; `test_FAC_015_CrossLaunchTreasuryIsNotValueIsolated` proves the named consequence end to end through real launches. **Corrected again in section 6:** the statement and the test now name an already-deployed splitter, which is what admission actually admits, instead of a predicted future clone address. |
| `SPL-017` | "Only the immutable recovery admin may recover" is false. | Rewritten to the new normative statement — permissionless, complete balance, immutable treasury, zero-balance revert, hostile token contained — and its selector renamed to `test_SPL_017_RecoveryIsPermissionlessWholeBalanceToTheTreasury`. The old selector is deleted rather than repointed at replacement behaviour. |
| `RCV-009` | Same, on the receiver. | Same treatment; the selector is now `test_RCV_009_RecoveryIsPermissionlessWholeBalanceToTheTreasury`. |
| `ABI-003` | `LaunchParams` no longer carries `recoveryAdmin`. | Statement corrected to the eight remaining fields, in order. The test proves them against both the compiler's field list and the tuple encoded in `launch`'s own selector. |
| `ABI-005` | "administrative recovery functions" is no longer what they are. | Statement corrected to the two permissionless recovery functions at their new amount-free signatures, and the selector renamed to `test_ABI_005_SplitterRecoverySurfaceIsExact`. |
| `ABI-012` | Half the claim — that the strategy's `RecoveryAdminHasNoCode(address)` survives — is now false. | Rewritten as the whole-surface deletion it has become, with its selector renamed to `test_ABI_012_DeletedRecoveryAdministrationSurfaceIsAbsent`. It still diffs in both directions: every deleted selector absent from the frozen surface and from every generated per-contract ABI, and the two replacement recovery entry points asserted present. |
| `STR-013` | Its selector list carried the recovery-admin admission test. | That selector is removed. The remaining six are unchanged; the frozen CCA parameter set is not affected. |
| `MIG-003` | "Graduation deploys the splitter clone" no longer says where. | Statement corrected to name the deterministic clone address alongside the bindings the selector already asserted. **Superseded in section 6:** with ordinary clones restored there is no deterministic address to name, so the statement and the test assert clone authenticity and exact clone count instead. |
| `DEP-046` | It described the deployed PositionManager's `CONTRACT_BALANCE` disposition, which graduation no longer asks for. | Statement corrected to preservation: a real graduation on Base settles only what this launch funds and leaves every other REGENT, SUBJECT and cross-launch balance at that shared contract untouched to the unit. The two fork selectors are unchanged in name and rewritten in body. |

### 5.5 Additions

| Addition | What it is |
| --- | --- |
| `STR-019` | The closed launch-time treasury refusal and admission set, proved class by class before any auction exists, with a fresh SUBJECT and a genuinely funded escrow per arm so every refusal is reached through the real authentication path. **Narrowed in section 6** to exactly six addresses, with a third selector that drives the accepted nonce-collision stall end to end. |
| `FAC-028` | Atomicity of that refusal at the factory: the fee movement, the created SUBJECT, the cloned and funded escrow, the auction, the launch ID, both records and every event roll back together, and no existing launch's lifecycle, escrow custody or isolated reserve is disturbed. **Narrowed in section 6** from nine arms to the six real refusal arms; every rollback assertion is retained. |
| `MIG-021` | The terminal half of `STR-019`: the two addresses admission refused are exactly the two addresses a real graduation of that same launch deploys to, correctly bound and registered. **Retired in section 6** together with `test/mocks/LaunchCloneSlots.sol`; the ID is never reused. |
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
- No view function is added. Launch-time treasury admission is a private helper over six addresses
  the strategy already publishes or already binds, so the strategy's read surface is unchanged apart
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

## 6. `regent-alv1.7.1` (C6.1) — treasury simplification and ordinary-clone restoration

One founder-directed correction to C6, in production code that changes no public ABI. The result
stays **mainnet NO-GO**.

### 6.1 What changed and why

C6 answered the "self-slot launch stall" by making both per-launch clones deterministic: CREATE2 over
a salt derived from private role constants and the launch's identity, so launch-time admission could
refuse a launch's own two future clone addresses. That worked, and it cost more than the founder
wants to pay: a fork of pinned upstream deployment behaviour, two extra immutables, two private role
constants, a salt derivation, an address predictor, a first-principles test helper restating all of
it, and a treasury refusal set that had grown from a list of shared accounts into a code-shape rule.

The founder ruling is to accept the stall and delete the machinery. C6.1 therefore:

- restores the pinned upstream ordinary `LibClone.clone` for both the splitter and the canonical
  receiver;
- deletes `splitterCloneCodehash`, `receiverCloneCodehash`, both private clone-role constants, the
  salt derivation, both `cloneDeterministic` calls, the CREATE2 address predictor, and
  `test/mocks/LaunchCloneSlots.sol`;
- narrows launch-time treasury admission to exactly six addresses, so the private helper no longer
  takes the launch ID or the SUBJECT and performs no code test of any kind;
- preserves everything else C6 did: `escrowCloneCodehash` and the escrow clone authentication it
  serves, the deleted recovery administrator, permissionless whole-balance recovery fixed to the
  immutable treasury, the three protected core assets, exact PositionManager settlement, the terminal
  lifecycle write before the first state-changing external call, and the migration ordering.

The hook is untouched in source and in compiled bytes. It remains REGENT-only: two independently
floored 1% lanes, one to the Regent Safe and one to the launch splitter, for 2% total; the absolute
requested amount when REGENT is specified, including partial and zero fills; the absolute realized
REGENT delta when REGENT is unspecified; no SUBJECT charge; pool fee still 0.30%.

### 6.2 Corrections to claims

| Claim | What was wrong | What this ticket did |
| --- | --- | --- |
| `STR-019` | The statement described a refusal set of six addresses *plus* three clone-runtime fingerprints *plus* two predicted addresses, none of which the code performs any more. | Rewritten to the exact six addresses and to the explicit absence of every other kind of test, and extended to state the nonce-collision stall and its recovery. Owner moved from `C6` to `C6.1`. `test_STR_019_RefusedTreasuryClassesAreRejectedBeforeTheAuctionExists` now enumerates six arms with a distinct funded escrow each; `test_STR_019_AdmissibleTreasuryClassesAreAccepted` now includes a really deployed escrow, splitter and receiver among the admitted classes; `test_STR_019_OwnFutureCloneTreasuriesAreRejected` is deleted; and a new integration selector, `test_STR_019_NextCloneTreasuryStallsMigrationUntilAnInterveningGraduationMovesTheNonce`, drives the whole stall-and-recovery sequence. |
| `FAC-028` | Three of its nine rollback arms named treasuries the strategy no longer refuses. | Narrowed to the six real refusal arms. Every rollback assertion — fee, token, escrow, auction, launch ID, both records, every event, and the untouched pre-existing launch — is retained unchanged. Owner moved from `C6` to `C6.1`. |
| `MIG-003` | It asserted a deterministic clone address that no longer exists. | Rewritten as ordinary clone identity: graduation creates exactly two contracts, and the recorded splitter presents the fixed 44-byte minimal-proxy runtime of the bound implementation with every binding this launch's own. No address assertion. |
| `FAC-015` | Its test constructed the cross-launch case from a *predicted* future splitter address, which is no longer how admission behaves, and the prose implied every nonce collision is permanent. | The test now graduates a launch first and points a second launch's treasury at that **already-deployed** splitter. The statement names the already-deployed case; the recoverable future-address collision is `STR-019`'s. |
| `MIG-021` | Its entire subject — deterministic clone identity — is deleted. | **Retired.** The entry, its selector `test_MIG_021_OwnCloneSlotsAreRefusedAndAreExactlyWhereGraduationDeploys` and the helper `test/mocks/LaunchCloneSlots.sol` are deleted, and the ID is never reused. `test/integration/AutolaunchTerminalCustody.t.sol` remains for `MIG-022`. |
| `MIG-017` | Two explanations still said the pinned planner's `CONTRACT_BALANCE` settlement drains the PositionManager to zero. C6 replaced those two settlement amounts, so it does not. | The rollback test's comment and its two assertion messages, and the PositionManager witness row in [fork-authority-and-state-inventory.md](fork-authority-and-state-inventory.md), now describe preserved foreign balances. The exact-settlement proof itself is unchanged. |

### 6.3 The accepted stall, stated precisely

The audit finding C6 answered was real, and C6.1 does not pretend otherwise; it answers it with
disclosure and evidence instead of with machinery. A launcher who names the address the shared
strategy's current nonce would next produce gets a launch that is admitted, takes bidders' REGENT,
and then cannot complete its own migration.

What makes that acceptable rather than a loss:

- the failed migration is a whole-transaction revert, so nothing is half-done and nothing is
  remembered — including the nonce advance;
- while it is stalled the launch's value is exactly where it was: raised REGENT in the CCA, the 85%
  in a `Pending` escrow, the isolated 5% reserve at the strategy, unsold SUBJECT at the auction;
- bidders keep the CCA's own independent exit and claim rights throughout, which is where their
  REGENT and their tokens actually are;
- the collision is not permanent. The address depends on a shared nonce, so any other launch's
  graduation moves it, and the stalled launch then migrates normally;
- no other launch's lifecycle state, custody ledger or isolated reserve is touched at any point.

No retry mode, alternate pool, rescue migration, warning system, CREATE2 shim, or synthetic
clone-fingerprint admission test is added. If the treasury the launcher named has by then become the
intervening launch's splitter, the retry routes that launch's payouts into it — which is the
`FAC-015` consequence, arrived at by a different road.

### 6.4 ABI and downstream

C6.1 changes **no public ABI**. Every deleted item was private: two immutables with no getter, two
private constants, three private functions, and two arguments of a private helper. Every function
selector, event topic, indexed field, integer width, error and return-tuple layout is byte-identical
to the integrated C6 surface, and `bin/freeze-artifacts.py check` proves it by regenerating
`abi/*.json` and `reports/frozen/abi-surface.json` from this candidate's own artifacts and comparing
them byte for byte. The already-integrated C6 ABI delta in section 5.6 is therefore still the whole
delta a downstream consumer must apply.

The strategy's compiled runtime does change — it is smaller — so a fresh deployment produces a
different strategy address, and the hook is CREATE2-mined over `abi.encode(PoolManager, strategy)`.
Fresh hook-salt mining remains a deployment-packet obligation exactly as before; nothing in this
repository pins a hook address.

**Provider-backed evidence.** It was intentionally not run against this intermediate C6.1
candidate. `regent-4wx` has since run it once against the exact final C10 source, rather than once per
intermediate candidate. The final packet records the pinned-header proof and later-header drift
subset, while Control binds the exact evidence commit and tree.

## 7. `regent-alv1.10` (C9) — supply-proportional staker allocation and a one-block exit

One founder-directed change to how a recognized net is divided, and one narrow rule about when a
staked position may leave. The result stays **mainnet NO-GO**.

### 7.1 What changed and why

Through C6.1 the splitter asked one question of each recognition: is anything staked? If nothing was,
the whole 98% net went to the launch treasury; if anything at all was, the whole 98% net went to the
accumulator and was divided among whoever happened to be staked. A single account holding a
thousandth of a percent of the supply, alone, therefore earned the entire net — its share of *the
stake set*, not its share of the token.

C9 replaces that question with a proportion. The 2% skim and its two destinations are untouched. The
post-skim net is then divided by fixed total-supply coverage: current stakers collectively receive
`floor(net * totalStaked / 100_000_000_000e18)`, computed in full precision, and the launch treasury
immediately receives the exact remainder in the same transaction. Current stakers divide only that
allocation through the accumulator that already existed, so an account staking a tenth of the supply
earns a tenth of the net whether it is the only staker or one of many, and the rounding that coverage
floors away belongs to the treasury.

The denominator is an internal constant with no getter and no setter. C9 left it as an assumption
about the caller graph — the splitter did not read the bound token's supply at all. C10 closes that,
and section 8.1 below carries the correction.

Separately, an unstake — partial or complete — now requires a later block than that account's own
latest stake, and every later stake resets the delay for that account's whole position. Stake and
claim remained immediate in C9; C10 extends the same rule to claims.

### 7.2 Corrected claims

| Claim | What was wrong | What this ticket did |
| --- | --- | --- |
| `SPL-005` | "Net 98% goes pro rata to current SUBJECT stakers" described a division among the stake set, which is exactly the behaviour the founder replaced. | Rewritten as the coverage rule and the per-account consequence: stakers collectively receive the floored fraction of the net that the staked share of the complete supply represents, and divide only that. Its test is renamed to `test_SPL_005_NetSplitsByFixedSupplyCoverage` and now proves 40% coverage held three-to-one, the founder's sole-10%-holder example, complete coverage, and a smallest-unit inflow. |
| `SPL-006` | It spoke only about zero stake, which is now one case of a general rule rather than the rule itself. | Rewritten as the treasury's whole entitlement: everything coverage does not reach, the floored-away rounding included, delivered in the same recognition — plus the rollback when that delivery fails. Its test is renamed to `test_SPL_006_UncoveredNetGoesImmediatelyToTheImmutableTreasury`. |
| `SPL-009` | "Staking is immediate" was true and complete before; it is now true but no longer complete, because the exit is not. | Rewritten to state both halves: stake and claim are immediate, the exit needs a later block, a later stake resets it, a refused exit mutates nothing, and an atomic stake/recognize/claim/unstake attempt fails entirely. Both selectors are renamed accordingly. |
| `SPL-013` | It said a staker is paid "the share their staked snapshot earned", which no longer names what the share is a share *of*. | Corrected to name the staker allocation as the divisible quantity, and its deterministic counterexample is re-derived at 50% and 25% coverage so the half-unit story it exists to tell still happens. |
| `HOK-011` | It said the splitter lane is skimmed and stopped there, which now understates what the lane meets. | Extended: the lane's post-skim net is divided by the same coverage rule a direct recognition uses, with no second skim and no hook-specific path. Its test proves a quarter-supply staker earning a quarter of the lane's net. |
| `INV-002` | Solvency alone no longer describes the whole split, because the treasury is now a destination on every recognition rather than only on unstaked ones. | Extended to require that the treasury holds exactly the net the staked supply never covered, reconciled against the handler's independent outside summary. |
| `ABI-004` | It enumerated the six caller-only functions, which is still exactly right, but said nothing about what the exit delay added. | Extended to require that the delay added exactly one ABI member — `SameBlockUnstake()` — and that neither the per-account stake block nor the fixed denominator became a readable getter. |

### 7.3 The obsolete stress case

`SPL-012` carried a deterministic maximum-ratio sequence: one wei of stake taking the whole net of a
`type(uint128).max` inflow, then the rest of the supply staking against an accumulator at its widest
value. Its purpose was a `stakedOf * accumulator` product that a naive implementation would overflow.
Coverage makes that frontier unreachable — the allocation a single wei can receive is now bounded by
the wei's share of the supply, which caps the accumulator far below where the product could overflow
— so preserving the test would have meant preserving a shape the arithmetic can no longer take.

It is re-derived rather than kept or silently dropped. `_assertCoverageExtremesStaySolvent` proves the
two ends of the coverage range against the same maximum economic inflow per asset: one wei of stake,
where the allocation must be nonzero and yet far below the net with the exact difference reaching the
treasury, and complete coverage, where it must be the whole net with the treasury receiving nothing.

### 7.4 Delta and evidence

No function selector, event topic, indexed field, or integer width changed in C9 itself. The
splitter's compiled runtime moved, so the factory's `SPLITTER_IMPLEMENTATION_RUNTIME_CODE_HASH`
literal moved with it — that literal was the factory's only edit, and no other factory behaviour
changed. The escrow, the hook, the strategy and the receiver compiled to bytes identical to the
previous candidate's.

## 8. `regent-alv1.11` (C10) — supply binding, next-block value exits, and exact recognition shares

C9 was reviewed and three things came back. Each is closed here; nothing else about the splitter
changes.

### 8.1 The denominator is now the bound token's own supply

C9 divided every net by a fixed 100 billion and argued that the caller graph guaranteed it. That is
an argument about who deploys a clone, not a property of the clone. A splitter bound to a token with
a different supply divided by the wrong denominator, and nothing in the contract would have said so.

Initialization now executes one bare precondition, immediately after the existing duplicate-token
refusal and before the first binding is written:

```solidity
require(IERC20Minimal(subject_).totalSupply() == SUBJECT_TOTAL_SUPPLY);
```

`IERC20Minimal` already declared `totalSupply()`, so no interface moves. A supply one unit short, one
unit over, absent, or unreadable leaves the clone unbound rather than bound to a denominator that is
not its own — every binding write happens after the check, so a refused initialization is atomic. The
splitter stores no copy of the supply, exposes no getter for it, adds no error of its own for it, and
never reads it again: after initialization the denominator is the same internal constant it was, and
it is now a proven property of the bound token rather than an assumption about its deployer.

The premise this rests on is the pinned UERC20's, not the splitter's: `UERC20`'s constructor mints
`params.totalSupply` exactly once and `BaseUERC20` exposes no mint or burn afterwards, so an admitted
SUBJECT's supply is fixed for its lifetime and graduation consumes this check once. Section 8 of the
threat model records that premise and what a self-made clone gets instead.

### 8.2 Every value exit waits, not only the principal exit

C9 delayed `unstake` and left `claim` and `claimAll` immediate. The delay's purpose is to make a
stake, recognize, take-the-value-out round trip impossible inside one transaction, and a claim is
taking value out. A funded position could still stake, recognize revenue against its own coverage,
and claim the resulting share, all atomically; only the principal had to wait.

`unstake`, `claim` and `claimAll` now share one private check, and the error names what it is waiting
on: `SameBlockStakeExit(address account, uint256 stakeBlock)`, which replaces `SameBlockUnstake()`.
The stake block is recorded only after the exact SUBJECT pull succeeds, so a refused stake delays
nothing. Refusal order is preserved exactly: `unstake` still refuses a zero amount and then an
over-withdrawal before it asks about the block, so a non-staker is still told it has no stake;
`claim` still refuses an unsupported token first; `claimAll` asks about the block first of all. A
same-block claim with nothing to pay is refused rather than treated as a silent no-op, because a
no-op that succeeds is indistinguishable from a rule that does not apply.

A top-up therefore locks the caller's complete position *and* everything that position has already
accrued until the next block. Recognition, accrual, the `claimable` views, caller-only authority and
stake effectiveness all stay immediate, and no production contract calls the splitter's caller-only
surface inside a composed transaction, so this reaches only direct user exits.

### 8.3 `RevenueRecognized` reports amounts, not a verdict

C9's event carried `bool paidToStakers`, which answered whether the staker allocation was nonzero and
nothing more. An indexer reading it could not tell how the net actually split without recomputing the
contract's own arithmetic. The field becomes the two exact amounts:

```solidity
event RevenueRecognized(
    address indexed token,
    address indexed source,
    bytes32 indexed revenueRef,
    uint256 gross,
    uint256 skim,
    uint256 net,
    uint256 stakerShare,
    uint256 treasuryShare
);
```

The recognition arithmetic is unchanged; only what is emitted is. `gross == skim + stakerShare +
treasuryShare` exactly, `stakerShare == 0` says what `paidToStakers == false` used to, and the
protected carry and per-account dust remain subdivisions of `stakerShare` rather than further token
amounts — they are inside the liability that share created, never added to it.

### 8.4 Corrected claims

| Claim | What was wrong | What this ticket did |
| --- | --- | --- |
| `SPL-009` | It stated that claiming was immediate and that only the unstake waited, which was true of C9 and is the gap C10 closes. | Rewritten as the whole exit rule: stake and accrual immediate, every value exit a later block on, the top-up locking accrued claims too, the preserved refusal order for each entry point, a refused no-op claim, and the atomic attempt failing entirely. Both selectors are renamed to `test_SPL_009_StakeAndAccrualTakeEffectImmediately` and `test_SPL_009_EveryValueExitWaitsForTheBlockAfterTheStake`. |
| `ABI-004` | It named `SameBlockUnstake()` as the delay's one ABI member and said nothing about whether the supply precondition added anything. | Rewritten to require the renamed `SameBlockStakeExit(address,uint256)`, to require the complete error surface to stay at the eleven the splitter declares plus its three inherited — which is what proves the bare precondition added no error — and to keep requiring that neither the per-account stake block nor the fixed supply became a readable getter. |
| `SPL-023` | New. Nothing required the bound SUBJECT to report the supply its net is divided by. | Added: the exact precondition, its position between the duplicate refusal and the first binding write, refusal for a supply one unit short, one unit over, absent and unreadable, no stored copy, no getter, no error, and no later read. `test_SPL_023_InitializationBindsOnlyTheCompleteSubjectSupply` carries it. |

### 8.5 Delta and evidence

The ABI delta is exactly two members: `SameBlockUnstake()` becomes
`SameBlockStakeExit(address,uint256)`, and `RevenueRecognized`'s trailing `bool` becomes two
`uint256`s, which moves that event's topic0. No function selector, no other event topic, no indexed
field and no integer width moves, and the error surface stays at fourteen members. The splitter's
compiled runtime moves, so the factory's `SPLITTER_IMPLEMENTATION_RUNTIME_CODE_HASH` literal moves
with it — that literal is the factory's only edit. The escrow, the hook, the strategy and the
receiver compile to bytes identical to the previous candidate's.

Test fixtures now present exactly the complete SUBJECT supply before a splitter is initialized, which
is what production already does, and the hook, pause-scope and receiver-invariant suites advance one
block before an existing exit. No assertion was removed or weakened. The splitter invariant handler
advances a block before its ordinary `claim`, `claimAll` and `unstake` actions rather than mirroring
the eligibility rule, so `fail_on_revert` keeps its full strength.

**Provider-backed evidence.** `regent-4wx` ran once against this exact final C10 source. The complete
pinned-header lifecycle and the focused later-header identity, proxy, controller, and gas-schedule
subset passed; the reviewed observation is committed and the compare-only check left it unchanged.
Control binds the exact final evidence commit and tree. No provider write, signature, broadcast,
deployment, or value movement occurred.
