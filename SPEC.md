# Autolaunch V1 Clean Rebuild

**Status:** Founder directive; current Autolaunch V1 contract authority  
**Frozen:** 2026-08-20  
**Implementation repository:** `repos/autolaunch-contracts`  
**Release posture:** local implementation and proof only; mainnet remains NO-GO

This specification supersedes the prior Autolaunch Safe/ERC-8004/registry contract graph for new V1 work. The historical `regent-contracts` implementation and its evidence remain read-only references. The live global REGENT Stake and Redeem contracts and product flow are not replaced.

## 1. Required outcome

```text
Launch
→ SUBJECT + CCA auction + pending escrow

Failed auction
→ 100B SUBJECT to dead address
→ bidder refunds preserved

Graduated auction
→ final-price v4 pool + dead full-range LP NFT
→ vesting + splitter + canonical receiver
```

Every normative Solidity claim has a stable requirement ID, at least one named Solidity test, a recorded `hermetic`, `invariant`, `fork`, or `deployment` gate, and exact execution evidence before the claim may close.

## 2. Control cutover and ticket sequence

- Register `autolaunch-contracts` in Control with protected Solidity, deployment, manifest, ABI, test, and gate paths.
- Stop `regent-490.33`, release its stale custody, and preserve its candidate and worktrees read-only.
- Supersede the old `regent-490` epic without reopening or deleting closed history.
- Retarget `490.5`, `490.6`, `490.8.2`, `490.8.3`, `490.12`, `490.21`, `839.5`, `839.5.1`, `4wx`, and `839.7` to the new freeze.
- Preserve completed generic watcher work in `490.8.1` and `490.8.4`.
- Leave the global Stake/Redeem implementation and certification path unchanged.

Sequential Tier 1 tickets:

| Ticket | Deliverable |
| --- | --- |
| C0 | Repository bootstrap, dependency pins, requirement ledger, hermetic gate, threat model, Slither setup |
| C1 | Fixed escrow, splitter, and receiver clone implementations |
| C2 | Shared Uniswap v4 fee hook |
| C3 | Shared factory-bound LBP strategy fork |
| C4 | Autolaunch factory and complete local integration |
| C5 | Claim audit, invariants, gas/size proofs, fork tests, ABI/manifest freeze |

Use one writer at a time. Each ticket uses a fresh Claude Opus 5 coding session with the Regent contract-worker rules, `solidity-security`, and `crytic-slither`; C2 also uses the pinned v4 security guidance. Each candidate receives an independent adversarial Opus 5 review and chief review. No confirmed P0 or P1 integrates.

## 3. Frozen dependencies and Base bindings

Pin exact commits and the full recursive gitlink closure:

- CCA v2.1: `7d7602d257733315434570f2a0c2f94f1c7b207a`
- Liquidity Launcher: `3a3103543f50a13a0ae52a253bb98a925d72146f`
- UERC20 factory: `09ae130f7a10f7c1b96e0dc7d9724d567080c4ef`
- Solidity `0.8.26`, Cancun EVM target, optimizer `200`, via-IR, bytecode metadata disabled
- Exact recursive v4-core, v4-periphery, Permit2, OpenZeppelin, Solady, and Forge gitlinks

| Binding | Address |
| --- | --- |
| REGENT | `0x6f89bcA4eA5931EdFCB09786267b251DeE752b07` |
| USDC | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` |
| CCA factory | `0x000000001F26a0044BaA66024e7b6599c61963F8` |
| PoolManager | `0x498581fF718922c3f8e6A244956aF099B2652b2b` |
| PositionManager | `0x7C5f5A4bBd8fD63184577525326123B519429bDc` |
| Live staking | `0xb027Dc261636E30Cbc0fE25b2F8e1ed273354AB5` |
| Governance and Regent Safe | `0x9fa152B0EAdbFe9A7c5C0a8e1D11784f22669a3e` |
| Dead address | `0x000000000000000000000000000000000000dEaD` |

The CCA binding requires runtime code hash `0xa1d2a90564f4f63580b25de42efaff92505c254b00fc666f65ab38126cce5cfa` and `protocolFeeController() == address(0)`. Any mismatch stops admission.

## 4. Factory

`LaunchParams` contains only `name`, `symbol`, `description`, `website`, `image`, `treasury`, `requiredRegentRaised`, and `expectedLaunchFee`.

Public mutations contain only:

```solidity
launch(LaunchParams)
setLaunchFee(uint256)
pauseLaunches()
unpauseLaunches()
createPaymentReceiver(uint256 launchId, address beneficiary, uint16 referralBps)
```

Rules:

- Supply is exactly 100 billion 18-decimal SUBJECT: 10% auction, 5% LP reserve, 85% vesting.
- Initial launch fee is exactly 1,000,000 REGENT and goes to the Regent Safe.
- Governance may change the fee, including to zero, and pause or unpause only new launches.
- Factory allowance must equal the expected positive fee exactly. Zero fee requires zero factory allowance. A stale expected fee reverts everything.
- Start is always `block.number + 1,800`.
- There is no user start, floor, hook, pool setting, Safe, ERC-8004 identity, or salt.
- IDs are sequential; internal salts derive only from the ID; duplicate names and symbols are allowed.
- Metadata is nonempty and byte-bounded: name 64, symbol 16, description 512, website 256, image 256.
- Treasury is immutable and launcher-chosen. There is no recovery admin and no recovery authority anywhere in the system.
- Launch-time treasury admission lives only in `RegentLBPStrategy.initializeDistribution`, after the escrow is authenticated and before the auction is created. It refuses exactly six addresses: the bound factory, the shared strategy, the bound fee hook, the frozen PoolManager, the frozen PositionManager, and the frozen live staking contract. Every other treasury is admitted. There is no code-length rule, no codehash fingerprint, no interface probe, no registry, no generalized denylist, and no predicted-address rule.
- Each launch's splitter and canonical receiver are deployed with ordinary CREATE clones, so each address follows from the shared strategy's nonce at graduation and from nothing any caller chose. Neither address exists as a fact before that graduation succeeds: `LaunchGraduated` and the strategy record are the only canonical account of what a launch deployed.
- An admitted treasury may be an already-deployed Autolaunch artifact of another launch, and then delivers this launch's payouts into that artifact's ordinary accounting. An admitted treasury may also collide with an address the strategy's current nonce would later produce; that graduation's clone initializer reverts, the whole migration rolls back including the nonce advance, and the launch stalls — with its raised REGENT still in the CCA, its escrow still pending, its reserve and unsold SUBJECT unmoved, no pool or vesting begun, and CCA exit and claim rights intact — until any other launch's graduation moves the nonce past the collision. Both are accepted launcher-selected destination behaviour; refusing either would require enumerating launches that do not exist yet.
- Launcher provenance gives no authority. A later failed auction does not refund the fee.
- Factory pause never blocks existing auctions, finalization, refunds, staking, claims, swaps, payments, vesting, or recovery.

## 5. Auction, strategy, escrow, and migration

Fixed auction configuration: duration 86,401 blocks; claim delay 64 blocks; migration eligibility end plus 128 blocks; frozen 104-byte, 13-step schedule; floor Q96 `79_228_162_514_264_337_593_543_900`; bid tick Q96 `792_281_625_142_643_375_935_439`; nonzero mathematically reachable required raise; auction protocol fee 0%.

The shared strategy receives one irreversible binding to the factory and hook. Only that factory initializes distributions. Anyone may call `migrate(auction)`. Technical failure is an ordinary EVM revert: no retry counter, retry mode, alternate pool, recovery migration, or committed technical-failure state.

Economic failure:

1. Strategy sends its isolated 5% reserve to escrow.
2. Escrow sweeps the failed-auction 10%.
3. Escrow proves exactly 100 billion SUBJECT and sends it to the dead address.
4. Bidder REGENT remains refundable from the CCA.
5. No pool, splitter, receiver, hook registration, or vesting is committed.

Graduation is atomic:

1. checkpoint and prove graduation;
2. derive the final-price PoolKey and PoolId;
3. deploy the splitter as an ordinary clone;
4. register the PoolId once in the hook;
5. sweep REGENT and initialize at the exact CCA final price;
6. mint one full-range LP position to the dead address;
7. send unused REGENT to immutable treasury;
8. send unused SUBJECT reserve to escrow;
9. sweep successful-auction unsold SUBJECT into escrow;
10. deploy the canonical zero-referral receiver as an ordinary clone;
11. activate 365-day vesting from that timestamp;
12. record graduation atomically.

Steps 3 and 10 are ordinary CREATE clone deployments from the shared strategy, so each address is whatever that strategy's nonce produced at graduation; nothing about either address is caller-selected, derived in advance, or published.

The official pool is static 0.30%, tick spacing 60, with one managed full-range position whose NFT is sent to the dead address. Third parties may add independent positions.

The PositionManager is shared with every other v4 user, so graduation settles only the exact two amounts it transfers there for its own mint. REGENT and SUBJECT already held at the PositionManager are never settled, never become the launch's credit, and never reach its treasury or escrow.

## 6. Shared hook

The immutable strategy/PoolManager-bound hook lets only the strategy register an exact PoolKey once. It supports REGENT as specified or unspecified currency for exact-input and exact-output swaps. It independently floors two 1% REGENT lanes per swap: 1% goes directly to the Regent Safe and 1% goes to the subject splitter, where the normal 2% REGENT skim applies. Settlement finishes inside the swap transaction and the hook retains no attributable fee inventory afterward. It has no flush, threshold, keeper, pause, router allowlist, replacement, or fee setter. Settlement failure reverts the swap; PoolManager plus registered PoolKey is the authority boundary.

## 7. Splitter

The splitter recognizes exactly USDC, REGENT, and its own SUBJECT token. Every recognized inflow floors a 2% skim exactly once. USDC skim uses exact approval, live staking `depositUSDC`, behavior verification, and allowance cleanup. REGENT and SUBJECT skims go to the Regent Safe.

A splitter binds only a SUBJECT that reports exactly the complete 100 billion supply its net is divided by. Initialization reads that supply once, after the duplicate-token refusal and before any binding is written; any other supply, or a supply that cannot be read, leaves the clone unbound. The splitter stores no copy of it, exposes no getter for it, and never reads it again.

The 98% net is then divided by fixed total-supply coverage rather than among whoever happens to be staked. Current SUBJECT stakers collectively receive the floored fraction of the net represented by the staked share of the complete 100 billion SUBJECT supply, and immutable treasury receives the exact remainder in the same recognition. `RevenueRecognized` reports both amounts, so gross is exactly skim plus staker share plus treasury share. Current stakers divide only that allocation pro rata, so an account staking a tenth of the supply earns a tenth of the net whether it is the only staker or one of many. Coverage rounding belongs to treasury, and a launch with nothing staked sends the whole net there. One staker-owned arithmetic remainder per token is protected and carried forward, as a subdivision of the staker share rather than a further amount. Staked SUBJECT principal, claims, and remainder are excluded from surplus and recovery.

Caller-only functions:

```solidity
stake(uint256)
unstake(uint256)
claim(address token)
claimAll()
depositRecognizedRevenue(address token, uint256 amount, bytes32 revenueRef)
recognizeSurplusRevenue(address token, bytes32 revenueRef)
```

Staking and accrual are immediate: stake present at a recognition earns from it at once. Every value exit waits — `unstake`, partial or complete, `claim`, and `claimAll` all require a later block than that caller's own latest stake, and every later stake resets the delay for that caller's whole position and its already accrued claims. `unstake` refuses a zero amount and an over-withdrawal first, in that order; `claim` refuses an unsupported token first; a same-block claim with nothing to pay is refused rather than treated as a no-op. Claims and unstaking are independent of the factory launch pause. Supported bare transfers become revenue only through permissionless surplus recognition.

## 8. Payment receivers and recovery

```solidity
pay(address token, uint256 amount, bytes32 paymentRef)
sweep(address token, bytes32 paymentRef)
setReceiverNote(bytes32 note)
recoverUnsupportedToken(address token)
recoverForcedETH()
```

- Referral is immutable, runs before splitter processing, and is 0 through 2.5% inclusive.
- Canonical receiver has zero referral and a treasury-edited note.
- Anyone may pay gas to create a custom receiver; its creator edits its note.
- Note defaults to the receiver address encoded as `bytes32` and appears with `paymentRef` in events.
- `pay` and bare-transfer `sweep` use the same atomic referral-before-splitter route.
- Ordinary ETH transfers revert.
- Recovery of forced ETH and of unsupported ERC20s is permissionless. Each call moves the complete recoverable balance, always to immutable treasury, and the caller names neither an amount nor a destination. A zero recoverable balance reverts without mutating anything.
- USDC, REGENT, and SUBJECT are permanently protected from recovery.
- No unsupported-token enumeration; a malicious token can fail only its recovery call.

## 9. Claim-level requirement ledger

C0 creates a machine-readable ledger. Every entry contains the requirement ID, exact normative statement, owning contract/ticket, test type, exact Foundry selectors, and designated gate. Solidity selectors begin with their ID, for example `test_FAC_001_LaunchUsesSequentialIdentity`, `test_HOK_007_ExactOutputChargesRegentWhenUnspecified`, `testFuzz_SPL_012_RecognizedRevenueRemainsSolvent`, and `invariant_INV_004_HookNeverRetainsAttributableRegent`.

The gate fails when a normative requirement is unmapped, a selector does not exist, a test did not execute exactly once, a test is skipped, or a requirement is complete before its gate passes. Mocks cannot satisfy deployed-runtime claims; those map to fork tests. UI-only claims later receive Ash/TypeScript coverage in addition to underlying Solidity coverage.

Required groups:

| IDs | Claim classes |
| --- | --- |
| `DEP-*` | Compiler and full recursive gitlink pins; chain ID; every external address, exact runtime code hash, proxy status, relevant getter, zero CCA controller, and clone implementation and runtime hashes. |
| `FAC-*` | Governance-only fee and pause; pause scope; fee-update and fee-collection events; exact positive and zero fee allowances plus cleanup; stale-fee and complete-launch rollback; metadata bounds; sequential IDs; duplicate names; no user salts; launcher provenance; fixed start; reachable raise; and complete launch. |
| `TOK-*` | Exactly 100B supply; 18 decimals; Autolaunch factory creator; immutable metadata; and no public mint, owner, tax, blacklist, upgrade, or administrative burn. |
| `STR-*` | Only the canonical factory initializes; unknown auctions are rejected; exact 10/5/85 transfer; per-auction reserve isolation; permissionless migration; exact CCA parameters; the closed launch-time treasury refusal and admission set; final-price conversion in both currency orderings; one-shot finalization; and no committed retry state. |
| `ESC-*` | One-time initialization; exact 85% pending custody; no pending release; strategy-only resolution; success starts 365-day linear vesting to the fixed treasury beneficiary; failure retires exactly 100B; and late failed SUBJECT goes only to the dead address. |
| `HOK-*` | Correct permission bits; only PoolManager callbacks; strategy-only write-once registration; registered PoolKey validation; all four swap shapes; independent 1% rounding; zero-fee tiny swaps; synchronous settlement; zero retained inventory; arbitrary router compatibility; and settlement-failure rollback. |
| `SPL-*` | Exactly three supported assets; initialization bound to the exact complete SUBJECT supply; exact 2% skim and destinations; fixed total-supply coverage of the net; immediate treasury delivery of the uncovered remainder, coverage rounding included, and of the whole net at zero stake; immediate stake and accrual with every value exit a later block on; stake and unstake snapshots; caller-only claims; fixed three-token `claimAll`; one protected remainder per token; principal protection; direct deposits and surplus recognition; permissionless whole-balance recovery; unsupported-token recovery exclusions; and forced-ETH behavior. |
| `RCV-*` | Canonical and custom creation; referral boundaries, flooring, beneficiary, and referral-before-splitter ordering; atomic pay and sweep; supported-token validation; note defaults, editor, and event; immutable beneficiary, splitter, and referral; and recovery fixed to treasury. |
| `MIG-*` | Graduation ordering; write-once PoolId; exact final price in both currency orders; static 0.30% and tick 60; one full-range NFT at the dead address; actual LP consumption; separate residues; exact PositionManager funding with foreign balances preserved; active vesting; migration-dependency reentrancy rejection; and complete rollback after every external call. |
| `FAIL-*` | Unmet raise, zero bids, partial bidding, full failed inventory return, exact dead-address delta, bidder refunds, no graduated infrastructure, and repeated-finalization rejection. |
| `INV-*` | Total-supply conservation; splitter solvency; SUBJECT principal and protected-remainder conservation; no cross-launch reserve use; no unexplained factory, strategy, or hook balances; immutable lifecycle; receiver conservation; and hook conservation. |
| `GAS-*` | Every runtime and initcode limit plus the complete direct-wallet launch, successful migration, and failed migration at or below 14M under maximum metadata, worst valid raise/inventory, cold external state, intrinsic gas, and calldata gas. Complete-transaction claims require the fork gate. |
| `ABI-*` | Exact selectors, event topics, indexed fields, integer widths, clone initializers, and absence of obsolete Safe, ERC-8004, registry, flush, and retry interfaces. |

Boundary coverage includes fee inputs `0, 1, 49, 50, 99, 100, 9_999, 10_000`; referral bps `0, 1, 249, 250, 251`; zero stake, first stake, full unstake, restake, interleaved deposits, and claims before and after stake changes; zero, partial, multiple-holder, and complete supply coverage plus a net whose coverage share floors to zero; a bound SUBJECT supply one unit short, one unit over, absent, and unreadable; same-block refusal of partial and complete unstake, single-asset claim, no-op claim, and `claimAll`, next-block success for each, and a later stake resetting the delay for accrued claims as well as principal; maximum and one-byte-over metadata plus malformed UTF-8; every refused and every admitted launch-time treasury class; simultaneous launches sharing one strategy and hook; both REGENT currency orderings; reentrancy attempts from recovery tokens, hook callbacks, receiver paths, and migration dependencies; and failure after every migration external call.

## 10. Gates

The hermetic gate performs recursive dependency identity verification, `forge fmt --check`, `forge build --sizes`, source-enumerated unit/fuzz/invariant execution, ledger reconciliation, then `slither . --fail-medium`. The gate parses the compiler, EVM, optimizer, via-IR, and metadata literals above and reconciles them against effective build artifacts. Fixed fuzz/invariant settings are committed. Every source-enumerated test runs exactly once with zero failures/skips. Slither runs only after green build, broadly excludes no production source, produces normalized JSON plus Markdown checklist evidence, and records one concrete disposition row per result, including duplicate results from the same detector. Its valid configuration is machine-checked so no detector or severity can be silently excluded and only pinned dependency source under `lib/` may be filtered. Inline suppressions name the detector, rationale, and protecting Solidity test; hidden triage is forbidden.

A separate explicitly authorized fork gate proves exact Base bindings, zero CCA controller, real CCA/Permit2 behavior, live staking `depositUSDC` including paused failure, PoolManager/PositionManager semantics, all terminal paths, complete gas including intrinsic/calldata, and pinned plus latest-head repetitions.

Stop if any contract claim is not deterministic, a requirement lacks coverage, an external runtime differs, accounting fails, hook settlement needs retained balances, a complete required transaction exceeds 14M gas, or upgrade/core-token recovery authority becomes necessary.

## 11. Product and release

**Founder continuation clarification — 2026-08-20.** Contract-independent Ash product work may proceed before C5 when it is limited to the active-Privy-wallet boundary, durable protected operation state, simple forms and progress states, and interfaces derived from the already pinned external CCA, Permit2, and REGENT sources. It must remain fail-closed in production and may not invent a Regent ABI, deployed address, runtime fact, predecessor-hint source, projector fact, entitlement, or admission result. Final bindings, public controls, and release proof still follow C5. This clarification authorizes local implementation and review only; it authorizes no provider write, wallet request, signature, transaction, deployment, or value movement.

After C5 freezes the ABI: `490.8.2/.3` project events through the existing watcher; `490.5` implements direct connected-wallet fee approval and launch; `839.5/.1` implement mandatory Permit2 bidding, five-argument bids, full/partial exits, claims, and refunds; `490.6` implements token details, SUBJECT stake/unstake/claims, canonical payments, and custom receivers. The token list uses a bounded recent graduated set from the database and connected-wallet balance filtering. Ash workers must use `ash-vibez` and exact repo-pinned Ash/Phoenix/LiveView sources. Global Stake/Redeem remains unchanged.

`490.12` owns Base Sepolia, `4wx` owns pinned/latest Base forks, and `839.7` owns the deployment packet. No provider write, deployment, signature, transaction, or value movement occurs without separate founder authority.

When all requirements, Solidity tests, Slither dispositions, authorized fork evidence, gas limits, and independent reviews are green, produce the founder audit packet and stop. Audit corrections use new Tier 1 successors and rerun affected claims plus the full gate. Mainnet remains NO-GO until founder audit and separate deployment instruction.
