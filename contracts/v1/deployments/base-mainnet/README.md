# Base mainnet

**Deployed on Base on 22 September 2026.** The founder approved packet digest
`0x5ba245ed0af9de1c1749f0b50cd54919a8084faf580d92282ef0592144f35327` and sent its five creations from deployer
`0x9b2C414614aEE294202c1219520955EF3B596031`; `deployed-manifest.json` records them. The factory was
born paused and admits no launch until the Governance and Regent Safe calls `unpauseLaunches()`.

| Contract | Address | Base block |
| --- | --- | --- |
| UERC20Factory | `0x90bA0ef13f7791Dd308bD3e10cd6aD755840d563` | 51660956 |
| ConditionalVestingEscrowV1 | `0xAFa68eEFd0b9c02Be2BC2306AEe50CDE4BC2133d` | 51660988 |
| SubjectSplitterV1 | `0x777b2e0F3c7787DA781c3948651249C2C822e9C3` | 51661009 |
| PaymentReceiverV1 | `0x34636E5Cd649C1BBda2b63676c76F66E60bAe5E2` | 51661029 |
| RegentsAutolaunchFactoryV1 | `0x635615cCEF2Ef24D0655fC2eBC47a14e005FEF6e` | 51661052 |
| RegentLBPStrategy | `0x69c13CCd9312e21d66fd162896E39bFC5f886F95` | 51661052 |
| RevstakeLPLocker | `0xBdC4b69bfd66aCDb8b794bADbEf3a50a14891159` | 51661052 |
| RegentFeeHook | `0x1F4E9AD63d95531d44eC90A700F21F0bBD40e044` | 51661052 |

| Nonce | Creation | Transaction |
| --- | --- | --- |
| 0 | UERC20Factory | `0xed61af550d66a8b53cbddf45af2142a5f159fd12bff60b77a5aa8a52b2a976b7` |
| 1 | ConditionalVestingEscrowV1 | `0x7506a773f73d4e756e96f44d6070d61abdeaacb54edafc1f100a939736494f93` |
| 2 | SubjectSplitterV1 | `0x98bf96b122101e9d07c6949e04635dcecc2a851a2b13eb045aea532b7b0d0ff9` |
| 3 | PaymentReceiverV1 | `0x385eb8e2ef17b4abf9bfa1fa68f58274df8127bc86adbc4d511c878553f0dc04` |
| 4 | RegentsAutolaunchFactoryV1 | `0x5cd9b0d5e8ed3b8c3036350cac2fce3b7024d05b96694aa2c507f7bd65114596` |

The installed packet is rendered from the Revstake candidate. Its production authority is
commit `7d564cec735c3b1b928ec4e2ede0b244682d105b`, tree
`97ea43cbf2e6625889b64deefcea406ea11ccdc5`, carrying `contracts/v1/src` tree
`eeeb1cedb315c97bf1a22658c02a5210a9c517c9`, and it embeds the commit-bound fork-check receipt for
evidence commit `4451c776f84fa904dd02b0c4360d360a45a945cb`. The code identity, sizes and EIP-170 and
EIP-3860 margins it records for the factory and the strategy are this candidate's own measurements,
because the Revstake terms and the fee-only LP locker changed both contracts' compiled bytes.

**The selection section was re-prepared and rehearsed with the LP locker as the eighth predicted
address.** The strategy constructor creates `RevstakeLPLocker` at strategy nonce 1, so the packet
now predicts eight contracts from the five transactions and records three internal creations. Under
the founder's separate read-only Base authority,
`bin/deployment-gate.sh --prepare 0x9b2C414614aEE294202c1219520955EF3B596031` read the selected
deployer's live nonce (`0`), mined the hook salt, re-derived the eight predicted addresses and
snapshotted the live Safe and live-staking control surface at Base block `51657720`. The deployer,
its nonce, the salt (`0x…1bc5`), the seven addresses the prior packet predicted and every
control-surface value came back byte-identical to that packet; what moved was the eighth prediction
(`lp_locker`, `0xBdC4b69bfd66aCDb8b794bADbEf3a50a14891159`), the topology's third internal creation
and its single canonical `created_by`/`creator_nonce` shape, `external_observation.observed_at_block`
and the digest, now `0x5ba245ed0af9de1c1749f0b50cd54919a8084faf580d92282ef0592144f35327`. The prior
digest `0x5548e545551bca298bbf8e878da23ffe2c7be147939c1033ed65ad6acb184521` is retired and names
nothing. A human installed that candidate, and `--offline` re-rendered it byte for byte.
`--rehearse` then held every frozen binding and the control surface to the committed values,
re-derived the eight addresses exactly, and simulated the exact deployment script — including the
strategy's `lpLocker()` readback — against a read-only Base fork with no signer and no broadcast.
A rehearsal is not an approval: the packet's own `authorization` field describes the proposal as
rendered, and the founder's approval of its digest is recorded in the deployed manifest's
`approved_packet_digest`.

Two files live in this directory, and keeping them apart is the point.

- `mainnet-no-go-packet.json` is a **proposal**, and the sole committed ceremony authority. It
  describes what the five-transaction ceremony would do, using code identity and deployability
  margins measured by a run that touched no network. `bin/deployment-gate.sh` renders it
  deterministically and compares it byte for byte against this committed copy; it can fail an
  installed packet and can write a reviewable candidate to `reports/generated/deployment/`, but it
  can never install one. Its `selection` and `external_observation` sections hold the founder's
  public deployer choice and the mutable external control surface; they are populated only by a
  candidate written by `--prepare <deployer>` and installed by a human, and every other mode renders
  them forward from the committed packet unchanged. Until `--prepare` runs again for the current
  identity, this packet cannot claim the exact ceremony was rehearsed. Every value in it is public;
  no key, mnemonic, keystore path, endpoint or credential belongs here.

- `deployed-manifest.json` is a **record**, written once by `bin/ceremony.py record` from the five
  confirmed Base receipts after the founder approved the packet's exact digest and the ceremony ran. No simulated fact may reach it — not
  a fork address, not a rehearsal transaction hash, not a fork block number. The gate admits exactly
  two states, defined once in `bin/ceremony.py` and proved on every run: the empty record, or a
  deployed record whose approved digest is the installed packet's and whose five transactions and
  eight contracts carry exactly the packet's predicted addresses. Anything else fails the gate.

## Recording

With every receipt confirmed on Base, list the five transaction hashes in ceremony order in a JSON
file (`{"transactions": ["0xHASH_1", "0xHASH_2", "0xHASH_3", "0xHASH_4", "0xHASH_5"]}`) and run,
from `contracts/v1`, with the read-only endpoint under `REGENT_BASE_RPC_URL`:

```bash
python3 bin/ceremony.py record --receipts receipts.json --approved-digest 0xPACKET_DIGEST
```

`record` refuses to run beside a signing, keystore, sender or hardware-wallet variable or beside a
`.env`, `.env.local` or `.envrc` file; it signs nothing and reads the chain only through `cast`. It
rebuilds the frozen release build and proves all eight artifacts against
`contracts/autolaunch-release-manifest.json` first. Then, for each hash in order, it proves the
sender is the packet's deployer, the nonce is the packet's starting nonce plus the index, the
transaction created a contract with zero value, the initcode is exactly the packet's creation code
and length, the created address is the predicted one and the receipt succeeded; proves each of the
eight created contracts carries the frozen runtime (the exact code hash where the runtime has no
immutables, byte equality with the immutable words masked otherwise); reads every constructor
binding back through the tool (fourteen readbacks, the strategy's `lpLocker()` and the locker's
`strategy()` among them, and the factory's paused state); checks the deployer's nonce is now
exactly five higher; and writes the deployed-manifest candidate, with each transaction's block
number and gas used, to `reports/generated/deployment/deployed-manifest.json`. A human installs it
here on the founder's word. The gate then holds it to the packet on every run.

The recorder was proved without any Base transaction: a fresh local Anvil started as chain 8453 on
a free loopback port, with the packet's deployer impersonated at nonce 0, received the five creation
initcodes as unsigned `eth_sendTransaction` calls (no key, no keystore, no `cast send`, no
`forge script --broadcast`), and created the packet's eight addresses exactly. `record` run against
that node with `REGENT_BASE_RPC_URL` pointed at it accepted the five hashes and wrote a manifest
the gate's check admits; the same run with a wrong approved digest, with the hashes reordered, and
with the resulting manifest tampered in its addresses, digest, status, keys or nonces was refused.
The Anvil endpoint was a loopback URL that existed only for that proof.

## The website's file

Once the deployed manifest is installed, from `contracts/v1`:

```bash
python3 bin/ceremony.py site-config --rpc-url URL --public-rpc-url URL
```

writes `reports/generated/deployment/site-config.json` in the exact shape the website loads:
`chain_id` 8453; the two endpoints as passed; `addresses`, the eight deployed contracts plus the
frozen `cca_factory`, `governance_safe`, `permit2`, `pool_manager`, `position_manager` and `regent`
from this build's bindings, all lowercase; `abis` for `auction`, `escrow`, `factory`, `hook`,
`lp_locker`, `permit2`, `receiver`, `splitter`, `strategy` and `token` from the frozen build; and
`start_blocks.factory`, the block the factory was created in. It refuses to run while the manifest
is the empty record, carries the endpoints passed on the command line, never prints them, and is
never committed; the gate wipes `reports/generated/deployment/` on every run.

`docs/audit/deployment-ceremony.md` describes the ceremony, the gate modes, the endpoint boundary,
the external-state preflight, and the approval boundary in full.
