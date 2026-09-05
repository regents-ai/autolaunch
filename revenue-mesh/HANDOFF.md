# Autolaunch RevenueMesh v1 — continuation handoff

I want to discuss and possibly work on: completing Autolaunch RevenueMesh v1 from its reviewed offline EVM and Arbitrum foundation through relaying, manifests, deployment tooling, Solana support, and eventually founder-authorized activation.

## Before doing any implementation

- Find the Regent workspace and the `autolaunch-revenue-mesh` repository from the current directory, a parent directory, or the usual workspace.
- Read the local `AGENTS.md` instructions and start with the Regent workflow skill. This project routes money and touches contracts, chains, wallets, deployment, and custody boundaries, so implementation tickets are Tier 1 unless the chief of staff explicitly classifies a narrower non-protected slice otherwise.
- Locate the founder-supplied specification titled **“Autolaunch RevenueMesh v1 — Technical Specification.”** Treat this handoff as orientation, not a replacement for that source.
- Inspect the current repository, tests, documentation, recent commits, Beads state through the chief-of-staff boundary, and the current `autolaunch-contracts` release candidate before proposing changes.
- Re-check all time-sensitive chain, token, contract-address, fee, API, and production-status facts against current official documentation. Do not treat a copied address in this handoff as live-chain proof.
- Independently decide whether each remaining task is still needed, correctly ordered, and scoped. Call out stale assumptions, hidden economic choices, design contradictions, and anything that should stop the work.
- Do not push, deploy, publish payment addresses, sign, use wallets, access production data, read secrets, fund gas, send canaries, burn or mint USDC, or move value unless the founder gives separate explicit authority for that exact consequential action.

## Product objective

For each graduated Autolaunch launch `L`, RevenueMesh should provide immutable chain-local USDC payment receivers that settle into the launch's existing Base revenue path:

```text
Non-Base RevenueInbox-L
        ↓
USDC bridge
        ↓
Base PaymentReceiverV1 / RevenueInbox-L
        ↓
SubjectSplitterV1 / Splitter-L
```

A payer sends the exact accepted source-chain asset to the published route address. No operator wallet takes custody or chooses the final recipient. Anyone may initiate the source sweep and complete settlement. Every route permanently names one Base receiver and splitter.

The system is intentionally separate from the core Autolaunch contracts. A route is derived from:

- the Base receiver;
- the Base splitter; and
- the selected source chain and route kind.

It must work whether the service exists before or after the Autolaunch launch graduates.

## Honest trust and product claims

The product phrase should be:

> **Immutable, non-custodial USDC revenue routes**

The intended guarantees are:

- **Beneficiary immutable:** the Base destination cannot change.
- **Non-custodial:** no Autolaunch operator wallet holds revenue.
- **Permissionless:** anyone can initiate or complete settlement.
- **Relayer independent:** a failed or malicious relayer cannot redirect funds.
- **Verifiable:** source receipts, bridge messages, Base mints, and splitter recognition are public evidence.

Do not claim the route is fully trustless. CCTP burns source USDC, relies on Circle's offchain attestation service, and mints on the destination. Circle is part of the trust model. Expose transport security separately:

- `CCTP_ISSUER_NATIVE`
- `CANONICAL_L2_PLUS_CCTP`
- `EXTERNAL_BRIDGE`

## Intended chain matrix

Revalidate this matrix before relying on it:

| Chain | Intended status | Route | Classification |
| --- | --- | --- | --- |
| Arbitrum One | First production candidate | Native USDC → CCTP V2 → Base | `CCTP_ISSUER_NATIVE` |
| Solana | First production candidate | Native USDC → CCTP V2 → Base | `CCTP_ISSUER_NATIVE` |
| Arc | Testnet work only until official public-mainnet facts exist | Arc USDC → CCTP → Base | `CCTP_ISSUER_NATIVE` only after admission |
| Robinhood Chain | Experimental conditional beta | Canonical L2 withdrawal → Ethereum USDC → CCTP → Base | `CANONICAL_L2_PLUS_CCTP` |
| Tempo | Prefer deferred; otherwise explicitly external | USDC.e → Stargate/LayerZero → Base | `EXTERNAL_BRIDGE` |

The original release recommendation was Arbitrum and Solana for v1; Arc in v1.1 after production support; Robinhood and Tempo as separately labeled experimental adapters.

## Canonical CCTP route

The direct path is:

1. Source inbox receives exact native source USDC.
2. Anyone calls `sweep(maxFee)`.
3. The inbox calls Circle `TokenMessengerV2.depositForBurn`.
4. Circle's Iris service attests the burn.
5. Anyone submits the message and attestation to Base `MessageTransmitterV2.receiveMessage`.
6. Native Base USDC is minted to the exact Base receiver.
7. Anyone calls the Base receiver's permissionless sweep.
8. The existing splitter recognizes and distributes the revenue.

The fixed destination fields are:

- Base CCTP domain `6`;
- Base receiver encoded as the CCTP mint recipient;
- zero destination caller, allowing permissionless completion;
- exact native source USDC as burn token; and
- finality threshold `2000` for Standard Transfer.

Circle's official references remain the authority for CCTP interfaces, domains, deployed contracts, USDC addresses, fees, finality, Iris endpoints, and message formats:

- [CCTP technical guide](https://developers.circle.com/cctp/references/technical-guide)
- [Supported chains and domains](https://developers.circle.com/cctp/concepts/supported-chains-and-domains)
- [CCTP EVM contract addresses](https://developers.circle.com/cctp/references/contract-addresses)
- [CCTP EVM interfaces](https://developers.circle.com/cctp/references/contract-interfaces)
- [USDC contract addresses](https://developers.circle.com/stablecoins/usdc-contract-addresses)

## Base compatibility

An ERC-20 transfer or CCTP mint changes a receiver's balance but does not call arbitrary receiver logic. The original specification allowed two profiles:

- **Direct-compatible receiver:** CCTP mints directly to the Base receiver, then anyone calls its process/flush/sweep method.
- **Landing adapter:** CCTP mints to a fixed `BaseLandingV1`, then anyone settles through the known receiver interface.

The current Autolaunch candidate is direct-compatible in principle. Its canonical `PaymentReceiverV1` has permissionless `sweep(address,bytes32)`, which routes the receiver's complete bare supported-token balance through its stored `SubjectSplitterV1`. No Base landing adapter has been added or shown necessary.

Activation still must fail closed per instance. A later provider-backed admission must prove all of these together:

- exact expected Base receiver address;
- initialized receiver;
- frozen admitted receiver runtime code hash;
- `splitter()` equals the supplied splitter;
- `usdc()` equals canonical Base USDC;
- `referralBps()` equals zero; and
- exact admitted Autolaunch factory provenance or equivalent frozen release evidence.

Matching bytecode alone is insufficient because same-code clones can contain different storage bindings. `BaseCompatibilityV1` evaluates supplied admission and observation facts, but it does not prove those observations came from the chain and cannot activate a route.

## Deterministic route identity and deployment

The route ID is:

```text
keccak256(abi.encode(
  "AUTOLAUNCH_REVENUE_ROUTE_V1",
  uint256(8453),
  baseReceiver,
  baseSplitter,
  sourceNamespace,
  sourceChainId,
  "CCTP_V2_STANDARD"
))
```

For EVM routes, a separately admitted non-upgradeable factory uses the route ID as its CREATE2 salt. The predicted inbox address is factory-relative and depends on:

- the admitted factory address;
- the route ID;
- the full creation code and constructor arguments; and
- the factory's complete immutable configuration.

Permissionless repeat deployment is safe only when existing runtime identity and every binding match exactly; otherwise it must fail closed. Never call an address globally canonical without separately admitting the factory, constructor policy, creation code, and provenance.

RevenueMesh owns the source namespace convention. For Arbitrum it is exactly:

```text
bytes32("eip155")
= 0x6569703135350000000000000000000000000000000000000000000000000000
```

The integrated Arbitrum test vector uses Base receiver `0x1111111111111111111111111111111111111111` and Base splitter `0x2222222222222222222222222222222222222222`, producing route ID:

```text
0x816118fa8cee7c00584d3965730ec11d752e7c97525586e160dbc03e88d734ab
```

## EVM source inbox requirements

`CctpRevenueInboxV1` is intended to have:

- exact constructor-bound source USDC and TokenMessenger V2;
- fixed source chain/domain/namespace;
- fixed Base receiver and splitter;
- immutable minimum sweep, fee ceiling, and per-message burn cap;
- permissionless `sweep(maxFee)`;
- `min(balance, maxBurnPerMessage)` chunking;
- exact temporary messenger allowance and zero residual allowance;
- reentrancy protection;
- full rollback on token, messenger, under-consumption, or cleanup failure; and
- one uniform runtime code identity across route instances, with bindings checked separately.

Forbidden functionality includes owners, roles, mutable destinations, bridge replacement, proxies, upgrades, arbitrary execution, delegatecall, operator pause, USDC withdrawal, and USDC rescue. Wrong tokens, ETH, unsupported USDC representations, and transport failure may strand funds permanently. This is an intentional consequence of beneficiary immutability, not an omitted admin feature.

## Permissionless relayer specification

The open-source relayer remains unimplemented. Its intended state machine is:

```text
SOURCE_RECEIVED
→ SOURCE_BURNED
→ ATTESTATION_PENDING
→ ATTESTED
→ BASE_MINTED
→ BASE_RECEIVER_SWEPT
→ SPLITTER_RECOGNIZED
```

It should:

1. Watch source inbox native-USDC balances.
2. Call `sweep(maxFee)` once the immutable minimum is reached.
3. Extract the exact CCTP V2 message evidence from the source transaction.
4. Poll Circle Iris V2 for the message and attestation.
5. Submit `receiveMessage(message,attestation)` on Base.
6. Call the admitted Base `PaymentReceiverV1.sweep` path.
7. Observe splitter recognition.
8. Produce a complete settlement receipt with source amount, actual Base mint, messages, transactions, and recognition batch.

The relayer holds only gas funds. It cannot change the asset, recipient, bridge, or splitter and cannot successfully replay a completed CCTP message. Another relayer must be able to replace it.

Arbitrum-owned operational facts should come from [Arbitrum chain information](https://docs.arbitrum.io/for-devs/dev-tools-and-resources/chain-info). At the last review, Arbitrum documented chain ID `42161`, Nitro Rollup settlement over Ethereum, no SLA for its public RPC, a sequencer endpoint limited to raw-transaction submission, and different retry treatment for transient submission errors versus terminal errors. Revalidate those facts before implementing reliability logic; do not treat a sequencer soft confirmation as parent-chain finality.

## Recognition and receipt semantics

Keep these stages distinct:

- **Source received:** source USDC reached the source inbox.
- **In transit:** source USDC was burned and Base mint is pending.
- **Base settled:** actual native Base USDC was minted to the receiver.
- **Recognized:** the Base receiver routed funds into the splitter.
- **Distributed:** splitter accounting completed.

Recognized value is the actual native Base USDC delivered, not the gross source amount. Preserve both gross and net amounts so bridge fees remain visible.

The current `PaymentReceiverV1.sweep` consumes its entire bare supported-token balance with a caller-selected reference. Several CCTP mints and unrelated donations may therefore be combined in one sweep. A receiver or splitter event alone cannot prove that one source burn was individually recognized. Receipts must preserve one-to-one CCTP message and Base-mint evidence while representing receiver recognition as a possibly aggregated batch.

Payment addresses are final revenue receivers, not escrow. A synchronous final purchase may pay the route directly. Refundable or asynchronous work needs a chain-local job escrow that forwards finalized revenue only after completion.

## Manifest and activation semantics

Every route manifest should ultimately expose:

- version and route ID;
- Base chain, receiver, splitter, optional landing adapter, and canonical Base USDC;
- source namespace, chain ID, payment address, exact accepted token contract/mint, symbol, and decimals;
- settlement transport, source and destination domains, finality, destination recipient, and permissionless completion;
- proxy/owner/mutability facts and code hashes;
- bridge security class;
- current balance, pending bridge value, and latest settlement; and
- an honest status.

Never display only “Send USDC here.” Always show the exact token contract or mint and distinguish native USDC from USDC.e or other dollar assets.

No address becomes `ACTIVE` until all of these pass:

- factory runtime identity and provenance admitted;
- exact constructor policy admitted;
- source chain, token, messenger, and CCTP configuration verified;
- predicted and deployed code hashes match;
- Base receiver instance and splitter bindings verified;
- source canary paid and swept;
- attested Base mint completed;
- Base receiver sweep completed; and
- splitter recognition observed.

All live checks, deployments, canaries, signing, publication, and activation remain founder-gated.

## CLI and autonomous deployment goal

The intended operator surface remains unimplemented. The target command family includes:

```text
autolaunch revenue-mesh deploy
autolaunch revenue-mesh sweep
autolaunch revenue-mesh complete
autolaunch revenue-mesh status
```

The deployment flow should validate Base chain `8453`, code existence, receiver/splitter pairing, compatibility profile, optional landing adapter need, deterministic addresses, implementation code hashes, a founder-authorized canary, Base settlement, splitter recognition, and only then publish an active manifest.

A graduation watcher may eventually deploy deterministic routes after reading a launch's Base receiver, splitter, and selected chains. Permissionless route creation does not itself require treasury custody, but deployment, policy admission, provider use, canaries, and publication are protected workflow steps.

## Solana design still to implement

The intended Solana route uses one immutable global program:

- a `RevenueRoute` PDA derived from `b"autolaunch-revenue-v1"`, the Base receiver bytes, and Base splitter bytes;
- a USDC associated token account owned by that PDA; this ATA is the public payment address;
- state fixing route ID, Base receiver/splitter, destination domain `6`, zero destination caller, finality `2000`, minimum sweep, fee ceiling, and bump;
- permissionless sweep through Circle `TokenMessengerMinterV2`; and
- revoked program upgrade authority after audit and deployment.

The caller funds the required CCTP message-event account. Recheck Circle's current [Solana CCTP programs and interfaces](https://developers.circle.com/cctp/references/solana-programs) before design or implementation.

## Later chain adapters

- **Arc:** reuse the EVM CCTP route only after official public-mainnet chain ID, RPC, native USDC, TokenMessenger V2, MessageTransmitter V2, CCTP domain, and production attestation support exist. Never reuse testnet domain or addresses in production.
- **Robinhood Chain:** the original design is a slow two-hop route: canonical Robinhood L2 representation of Ethereum USDC → permissionless canonical withdrawal to `EthereumTransitV1` → Ethereum-domain CCTP → Base. Before activation, prove the exact L1/L2 token relationship and complete a full deposit/withdrawal rehearsal. The expected latency exceeds the challenge period. Revalidate official Robinhood bridge and token documentation.
- **Tempo:** the recommended trust-minimized v1 choice is no support until native Circle USDC and CCTP exist. Any USDC.e route through Stargate/LayerZero must be separate, explicitly labeled `EXTERNAL_BRIDGE`, and permanently bind the exact token, pool/endpoint, Base recipient, output token, fee cap, and minimum output.

Do not present Robinhood or Tempo routes as equivalent to issuer-native CCTP.

## Cross-chain timing limitation

RevenueMesh cannot change the economics of the already immutable Base splitter. If the splitter allocates according to stake state when revenue is recognized, users may change stake before a visibly pending cross-chain batch arrives. Especially slow routes can make this material.

The product must either:

- disclose that cross-chain revenue uses stake state at Base processing time;
- rely on an existing activation delay or epoch mechanism; or
- introduce a future splitter with delayed stake activation or snapshots.

Do not claim RevenueMesh retroactively preserves source-payment-time stake composition.

## Integrated implementation state

Repository: `autolaunch-revenue-mesh`

Integrated `main` tip at handoff creation:

```text
85c914f4972684b551cc748026f61189f70644f4
```

Completed Regent tickets and immutable evidence:

- `regent-aog` — offline EVM CCTP foundation.
  - Initial candidate `a5eac110e5412d7e2c853e3a82d8a60db1065fc3`.
  - Adversarial review found a wrong-chain identity issue and a documentation overclaim.
  - Corrected and integrated candidate `01ca0bf0fab27e370acc2b491290f210bbe7b17f`.
  - Tier 1 verification passed.
- `regent-dwa` — Arbitrum One pinned factory wrapper.
  - Plan review required an exact, RevenueMesh-owned `eip155` encoding and fixed route vector.
  - Integrated candidate `85c914f4972684b551cc748026f61189f70644f4`.
  - Tier 1 verification passed.

Implemented public symbols:

- `CctpRevenueInboxV1`
- `RevenueInboxFactoryV1`
- `ArbitrumOneRevenueInboxFactoryV1`
- `BaseCompatibilityV1`
- `RevenueMeshTypes`
- `SafeToken`
- `IERC20`
- `ITokenMessengerV2`

Important repository documents are titled:

- **Autolaunch RevenueMesh**
- **Security**
- **Arbitrum One Wrapper Facts**
- **Base Compatibility**
- **Manifest and Settlement Facts**
- **Authority and Value-Flow Worksheet**
- **Contract Property Ledger**

Verified evidence at the integrated Arbitrum candidate:

- `forge fmt --check` passed.
- `forge build` passed.
- `forge test -vvv`: 35 passed, 0 failed, 0 skipped.
- Slither analyzed the candidate with zero findings.
- `ArbitrumOneRevenueInboxFactoryV1` deployability passed with runtime 10,934 bytes and total initcode 11,619 bytes including 64 constructor-argument bytes.
- Wrapper, base factory, and inbox ABIs contain no forbidden authority, mutation, rescue, proxy, arbitrary-call, fallback, or receive surface.
- Their runtimes contain no `DELEGATECALL`, `CALLCODE`, or `SELFDESTRUCT`.
- Independent adversarial candidate review approved with no remaining findings.

What has **not** happened:

- no production address has been selected or published;
- no minimum-sweep policy has been approved;
- no maximum-fee-BPS policy has been approved;
- no factory deployment mechanism or canonical factory address has been admitted;
- no live Arbitrum or Base code read has been used as release evidence;
- no Base receiver code hash or provenance has been admitted for RevenueMesh activation;
- no deployment, RPC use, signature, wallet request, gas funding, canary, burn, mint, or splitter settlement has occurred;
- no relayer, CLI, Solana program, Arc route, Robinhood route, Tempo route, UI, or graduation watcher exists yet.

## Immediate unresolved decisions

Do not guess these:

1. **Minimum sweep:** the immutable Arbitrum threshold below which funds wait. It affects dust stranding, liveness, and relayer economics.
2. **Maximum fee ceiling:** the immutable `maxFeeBps`. Circle's current Standard Transfer fee may be zero on a given route, but future fee behavior and forwarding choices must be handled deliberately.
3. **Canonical factory admission:** the exact constructor policy, deployment mechanism, expected factory address, runtime/creation hashes, deployer provenance, and evidence packet.
4. **Base release identities:** the exact frozen Autolaunch `PaymentReceiverV1` clone identity/provenance, canonical Base USDC, expected receiver, expected splitter, and initialized storage bindings.
5. **Activation authority:** the exact founder-authorized ceremony for live reads, deployment, canary value, manifest publication, and status change.

If the founder has not decided these, continue only with work that does not silently decide them.

## Remaining work in recommended order

### 1. Reconcile current state and decisions

- Verify `main`, ticket states, and the current `autolaunch-contracts` release candidate.
- Recheck the official Arbitrum and Circle facts.
- Ask for or locate founder decisions on minimum sweep, fee ceiling, factory deployment/admission, and Base release identities.
- If those decisions are absent, recommend explicit values and tradeoffs for discussion, but do not encode or deploy them as approved facts.

### 2. Arbitrum offline admission and deployment packet

- Freeze exact compiler/dependency inputs, wrapper creation/runtime hashes, constructor arguments, and predicted factory identity under the selected deployment mechanism.
- Add offline preflight logic for chain identity, candidate factory configuration, route prediction, Base compatibility observations, manifest construction, and fail-closed unknown profiles.
- Produce an exact, reviewable transaction and canary plan without executing it.
- Keep public RPC limitations and parent-chain finality semantics honest.
- Require independent Tier 1 review and Regent verification.

### 3. Permissionless CCTP relayer

- Implement the state machine and receipt model above.
- Use replaceable provider adapters and durable idempotency keyed to exact CCTP messages/nonces and transaction phases, without granting the relayer custody or recipient authority.
- Parse exact V2 events and use Iris V2 only; do not add CCTP V1 fallback.
- Model retries from authoritative transaction/receipt state, distinguish transient provider failure from terminal revert, and never treat one receiver sweep as proof of one source payment.
- Test with deterministic local mocks before any fork or live provider work.

### 4. CLI and manifest packages

- Implement deploy/preflight, route prediction, sweep, complete, status, and manifest commands.
- Make every output name the exact accepted token and security class.
- Abort on unknown Base compatibility, unknown factory identity, chain mismatch, address/code mismatch, or incomplete activation evidence.
- Keep transaction preparation separate from wallet signing and broadcast.

### 5. Solana production candidate

- Design and implement the PDA, ATA, Circle CPI, event-account funding, and immutable state.
- Prove the public payment address is the USDC ATA, not the PDA/program.
- Add full property tests and an explicit later ceremony to revoke upgrade authority.

### 6. Activation and end-to-end evidence

- Only with exact founder authority: perform provider-backed reads, deploy the admitted factory and route, fund and execute the small canary, complete CCTP mint, sweep the Base receiver, observe splitter recognition, and publish the signed/content-addressed manifest.
- Record source gross amount, actual Base mint, receiver recognition batch, exact receipts, canonical chain outcome, and any fees.

### 7. Optional later adapters and product surfaces

- Arc testnet and eventual production gate.
- Robinhood two-hop proof of concept and full canonical bridge rehearsal.
- Tempo deferral or explicitly external adapter.
- Official Autolaunch page, payment-address UX, settlement analytics, and graduation watcher.
- Independent audits, threat model refresh, release documentation, and founder deployment/admission review.

## Non-goals and safety constraints

- Do not modify existing Autolaunch economics to make RevenueMesh easier.
- Do not add an owner, admin, proxy, upgrade, rescue destination, arbitrary execution, mutable recipient, or operator pause.
- Do not silently accept bridged USDC, USDC.e, USDT, or arbitrary tokens as native USDC.
- Do not treat documentation or an explorer label as live code/provenance proof.
- Do not claim one-to-one splitter recognition when receiver sweeps can aggregate balances.
- Do not publish a deterministic address before the factory, policy, code identity, Base compatibility, and canary are admitted.
- Do not broaden a ticket into deployment or value movement. Those actions need separate founder authority even when the code is ready.

## Validation expectations

For each code ticket, use the smallest complete evidence appropriate to its Tier 1 boundary. Normally include:

- focused and full relevant unit/property tests;
- exact external ABI/event/message fixtures;
- authority and value-flow proof;
- rollback at every material external call stage;
- exact balance and allowance outcomes;
- ABI and runtime forbidden-surface proof;
- deployability measurement for every changed deployable contract;
- Slither or the relevant static analysis;
- one independent adversarial review of the frozen candidate; and
- `regentctl verify` after integration metadata is complete.

Live-chain evidence, deployment rehearsal, canaries, and signing are not ordinary test steps; they require explicit founder authority.

## Desired output from the receiving agent

- Start with independent review findings and a recommendation: continue as designed, narrow it, reorder it, or stop.
- State which facts were reverified and which remain assumptions or founder decisions.
- Identify the smallest next ticket that materially advances RevenueMesh without crossing an unauthorized boundary.
- If editing, keep the change isolated and scoped, provide the exact candidate commit and checks, and clearly separate offline evidence from live proof.
- Report what changed, what was verified, what remains, and the exact founder decision or authority needed next.
- Do not push, merge, close issues or pull requests, label, post public comments, deploy, publish, sign, or move value unless explicitly directed.
