# The Base deployment ceremony

This document describes the ceremony that would put the Autolaunch contracts on Base, the tooling
that prepares and rehearses it, and the boundary that keeps it from happening by accident.

**The repository is mainnet NO-GO.** Nothing has been deployed, signed, broadcast, funded, or
approved. No provider was accessed while preparing this tooling.

## The whole ceremony

Five transactions, sent one after another by one founder-selected disposable deployer. Every one
of them is a plain contract creation carrying zero value.

| # | Deployer nonce | Contract | What it is |
| --- | --- | --- | --- |
| 1 | `startingNonce` | `UERC20Factory` | the pinned token factory every admitted SUBJECT is created by |
| 2 | `startingNonce + 1` | `ConditionalVestingEscrowV1` | the escrow clone implementation |
| 3 | `startingNonce + 2` | `SubjectSplitterV1` | the splitter clone implementation |
| 4 | `startingNonce + 3` | `PaymentReceiverV1` | the receiver clone implementation |
| 5 | `startingNonce + 4` | `RegentsAutolaunchFactoryV1` | the factory, which builds the rest of the graph itself |

The fifth transaction is the only one that does more than create a single contract. Inside its own
constructor the factory creates `RegentLBPStrategy` with an ordinary `CREATE` — its first internal
creation, at factory nonce 1 — and then `RegentFeeHook` with a `CREATE2` over the pre-mined salt,
and binds the two together through the strategy's one-shot `bindHook`. A contract's nonce starts at
one, and `CREATE2` consumes a nonce just as `CREATE` does, so a factory that made any third internal
creation would end construction past nonce 3. `DEP-071` asserts exactly that.

There is no sixth transaction. No helper is deployed, no proxy is installed, no ownership is
transferred, no role is granted, no governance call is made, no application is admitted, and no
post-deployment binding call exists to make. The factory is born with its launch fee, its first
launch id, and its unpaused state already correct, and the frozen Governance/Regent Safe is already
its only mutable authority because that address is compiled into it.

## The three values the ceremony consumes

A ceremony has exactly three free parameters, and the approved packet pins all three:

- **the deployer** — a disposable account, selected by the founder, that ends the ceremony holding
  no protocol authority of any kind;
- **its exact starting nonce** — read from Base immediately before the ceremony, because the five
  addresses are entirely determined by the account and that number;
- **the pre-mined `hookSalt`** — mined once, during preparation, against the predicted factory
  address and the predicted strategy address, with the pinned Uniswap `HookMiner`.

`script/DeployAutolaunchV1.s.sol` consumes those three and produces none of them. It imports no
miner and contains no search loop, so a broadcast can only ever use the salt a packet pinned. The
mining happens in `test-deployment/`, which is preparation, and never during execution.

## What stops a wrong ceremony

Every check the script makes runs while Foundry simulates the whole script, which it does before a
separately authorized broadcast signs anything. A failed check aborts the simulation, so no
transaction sequence is assembled and nothing is broadcast at all. All of them are proved by
`DEP-075`:

- an unselected deployer is refused during derivation, before any nonce is read;
- a salt whose derived hook address does not carry exactly the five permission bits Uniswap v4
  encodes in a hook address is refused during derivation. The factory constructor's own
  `Hooks.validateHookAddress` would reject it too, but only in the fifth creation — after four
  transactions that, in a real ceremony, would already be irreversible;
- any chain that is not Base mainnet is refused by the broadcast entrypoint;
- a deployer whose live nonce is not the pinned starting nonce is refused before the first
  creation;
- each simulated creation's address is compared to the prediction before the next one is built, and
  the factory's own `strategy()` and `hook()` readbacks are compared afterwards.

**None of this is a check between confirmed Base transactions.** Once a broadcast begins, the
script runs no further and a later revert cannot unsend an earlier transaction. So an authorized
ceremony broadcasts the five creations sequentially, confirms each receipt before the next
transaction goes out, and verifies the resulting addresses and readbacks against the approved
packet afterwards.

A completed ceremony leaves the deployer five nonces past the number the packet pinned, which is
what makes the packet single-use. **A partial ceremony is terminal.** If any transaction fails or
is replaced after an earlier creation has confirmed on Base, the packet is invalid and is never
resumed: the nonce is read again, the graph is recomputed, the gates and the independent review are
repeated, and a new founder-approved digest is required.

## The two gate modes

`bin/deployment-gate.sh` is not part of the required check and never runs inside it.

- **`--offline`** is the writer's mode and carries this candidate's evidence. It runs with
  `FOUNDRY_OFFLINE=true` and with the Base endpoint variable cleared from the child environment, so
  no network can be reached even by accident. The whole ceremony is decidable this way, because the
  five creations call no external contract at all — the one frozen address the graph binds, the
  Base PoolManager, is compared rather than called.
- **`--rehearse`** is the chief's mode, run only under the founder's separate read-only Base
  authority and only after this candidate has been independently reviewed. It runs the same
  ceremony selectors against a read-only Base fork and adds the external-state preflight.

Both modes refuse to start beside signing authority — private keys, mnemonics, keystores, senders,
hardware-wallet variables — and both refuse to run beside a `.env`, `.env.local`, or `.envrc` file.
Foundry loads a dotenv file into the process environment, and this ceremony reads three of its
parameters from that environment, so the gate detects such a file's presence and never reads its
contents. `forge script --broadcast` is never invoked, in either mode.

Before any build, any provider access, and before the hook address is derived, the gate proves the
effective deployment profile field by field against the frozen C10 build: compiler, EVM target,
optimizer, via-IR, bytecode hash, and CBOR metadata. A hook address is a function of the compiler
settings, so a graph derived under a drifted build would be a confident prediction of the wrong
address.

## The external-state preflight

Run only in `--rehearse` mode, and only ever a stop condition. Every read is a hard `staticcall`
that reverts if the provider, the account, or the getter fails, so a run that cannot reach Base
fails loudly instead of reporting an empty observation, and the gate can never claim a fork it did
not open. It re-reads:

- chain id 8453, and the presence or absence of deployed code at every frozen binding;
- the CCA factory's runtime code hash against the admitted one, and its
  `protocolFeeController() == address(0)`;
- live staking's `owner()`, `paused() == false`, and `usdc() == BaseBindings.USDC` — a paused live
  staking contract means the splitter's USDC skim cannot settle, so deploying into that state is a
  stop rather than a note;
- the mutable USDC policy: `paused() == false`, and that neither the frozen Regent Safe nor the
  live staking binding is blacklisted;
- the exact Governance/Regent Safe control surface: owners, threshold, guard, enabled modules,
  fallback handler, singleton, and version. The membership itself is recorded rather than asserted
  — the packet is what freezes it — while the relations that must hold whatever the membership is
  are asserted: a nonempty owner set, and a threshold between one and that owner count.

The preflight carries no requirement id and closes no claim. It is excluded by name from the
compiled listing and from the ledger reconciliation in both modes, exactly as `bin/fork-gate.sh`
excludes its discovery pass.

## The packet, and what may name it

`deployments/base-mainnet/mainnet-no-go-packet.json` is rendered deterministically by the gate from
the ceremony's own measurements, reconciled against `reports/frozen/deployable-sizes.json`, and
compared byte for byte against the committed copy. The gate can fail an installed packet and can
produce a reviewable candidate under `reports/generated/deployment/`, but it can never install one:
that is a deliberate human step, and the deployment profile's Solidity has no filesystem permission
at all, so no test can author a packet for itself.

The packet carries the frozen build, the exact five-transaction topology, the code identity and
both deployability margins for all seven contracts, the two immutable identities named apart, and a
`selection` section that is explicitly empty because no deployer has been chosen. Its digest is
`sha256` over the document rendered with `digest.value` set to null.

It carries **no gas figure**. The only gas anything here measures is each creation's in-EVM cost,
which is a floor: it excludes the intrinsic cost, the initcode calldata cost, and EIP-3860's
per-word charge that a real creation transaction carries. The full per-transaction estimates stay
pending the exact selected deployer and salt and an authorized rehearsal, and a founder funds the
ceremony from a live estimate against that deployer.

**Only a later founder instruction naming that exact digest may authorize a signature or a
broadcast.** Until then the status is `mainnet-NO-GO`, and it stays that way whichever mode the
gate was run in — a rehearsal is not an approval.

The candidate commit and tree a run was rendered from are proved by the gate at run time rather
than embedded in the packet: a file cannot carry the hash of the commit that contains it. The gate
refuses to treat a run as packet evidence unless the working tree is clean, and it prints the exact
commit, tree, and `src/` tree it ran against.

## The deployed manifest is a different thing

`deployments/base-mainnet/deployed-manifest.json` is the only record of deployed facts, and it is
deliberately empty. It is populated once, from confirmed Base receipts, after a GO_TO_DEPLOY. No
simulated fact may reach it — not a fork address, not a rehearsal transaction hash, not a fork
block number — and the gate proves on every run that it carries no address, no hash, and no nonzero
number. `contracts/autolaunch-release-manifest.json` remains the immutable build-identity record
and is untouched by any of this. Source verification on a block explorer is a named post-deployment
operation, not a prerequisite transaction in this five-creation ceremony.

## Requirement map

| Claim | What it proves |
| --- | --- |
| `DEP-070` | five direct zero-value creations on the deployer's own nonce sequence, in the fixed order, advancing the nonce by exactly five |
| `DEP-071` | the factory alone creates the strategy at factory nonce 1 and the hook by `CREATE2` over the pre-mined salt, at an address carrying exactly the five permission bits |
| `DEP-072` | every constructor binding and runtime readback across the seven contracts, and the four admitted runtime code hashes |
| `DEP-073` | the disposable deployer retains no protocol authority, and the frozen Safe is the sole mutable authority |
| `DEP-074` | EIP-170 and EIP-3860 margins for all seven contracts, plus each creation's in-EVM gas floor under a 14,000,000 guardrail. No complete deployment-transaction gas figure is measured or claimed |
| `DEP-075` | every mismatch aborts in simulation, before anything is created and before a broadcast has a sequence to send, and a completed ceremony cannot be resumed |
