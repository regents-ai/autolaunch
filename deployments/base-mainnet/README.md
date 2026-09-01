# Base mainnet

**Nothing here has been deployed.** The repository is mainnet NO-GO.

The installed packet is rendered from the receiver-provenance candidate. Its production authority is
commit `f4114f5276386f48bf8dc53ee344189d98c8896e`, tree
`bb660324bb1d5cc322adeb243b0bd51779821fcb`, carrying `src/` tree
`91a741e417b75706a4071f7bdac2c5e13548c0fc`, and it embeds the commit-bound fork-check receipt for
evidence commit `ea8c81b2a5724213d3aeb4b0d81885b932f7d1aa`. The code identity, sizes and EIP-170 and
EIP-3860 margins it records for the splitter, the receiver, the factory and the strategy are this
candidate's own measurements, because the receiver-provenance lookup and the reference-free aggregate
paths changed all four contracts' compiled bytes.

**The selection section is carried forward, not re-prepared.** `--offline` never derives a deployer,
a starting nonce, a hook salt or an address; it renders those from the previously committed packet,
which stays the sole committed ceremony authority. Only `--prepare <deployer>` derives them, and
neither `--prepare` nor `--rehearse` has been run against this identity. The founder-selected
deployer, the mined hook salt and the seven predicted addresses are therefore the prior packet's
proposal awaiting re-preparation, and this packet does not claim the exact ceremony was rehearsed for
these bytes. `external_observation` is carried forward the same way, from the earlier authorized
read of live Base state. Status stays mainnet NO-GO and authorization stays `not authorized`.

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

- `deployed-manifest.json` is a **record**, and it is empty. It is populated once, from confirmed
  Base receipts, after a founder GO_TO_DEPLOY has named the packet's exact digest and the ceremony
  has actually run. No simulated fact may reach it — not a fork address, not a rehearsal
  transaction hash, not a fork block number. The gate proves on every run that it carries no
  address, no hash, and no nonzero number.

`docs/audit/deployment-ceremony.md` describes the ceremony, the gate modes, the endpoint boundary,
the external-state preflight, and the approval boundary in full.
