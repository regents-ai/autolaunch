# Base mainnet

**Nothing here has been deployed.** The repository is mainnet NO-GO.

The installed packet is rendered from the Revstake candidate. Its production authority is
commit `7d564cec735c3b1b928ec4e2ede0b244682d105b`, tree
`97ea43cbf2e6625889b64deefcea406ea11ccdc5`, carrying `contracts/v1/src` tree
`eeeb1cedb315c97bf1a22658c02a5210a9c517c9`, and it embeds the commit-bound fork-check receipt for
evidence commit `4451c776f84fa904dd02b0c4360d360a45a945cb`. The code identity, sizes and EIP-170 and
EIP-3860 margins it records for the factory and the strategy are this candidate's own measurements,
because the Revstake terms and the fee-only LP locker changed both contracts' compiled bytes.

**The selection section was re-prepared and rehearsed for this identity.** Under the founder's
separate read-only Base authority, `bin/deployment-gate.sh --prepare 0x9b2C414614aEE294202c1219520955EF3B596031`
read the selected deployer's live nonce (`0`), mined the hook salt, re-derived the seven predicted
addresses and snapshotted the live Safe and live-staking control surface at Base block `51650703`.
Every one of those values came back byte-identical to the prior packet; the only fields that moved
were the two contracts' code identity, the embedded fork-check receipt,
`external_observation.observed_at_block` and the digest. A human installed that candidate, and
`--offline` re-rendered it byte for byte. `--rehearse` then held every frozen binding and the
control surface to the committed values, re-derived the seven addresses exactly, and simulated the
exact deployment script against a read-only Base fork with no signer and no broadcast. Status stays
mainnet NO-GO and authorization stays `not authorized`; a rehearsal is not an approval.

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
