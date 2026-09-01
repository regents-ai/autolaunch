# Base mainnet

**Nothing here has been deployed.** The repository is mainnet NO-GO.

The installed packet predates the receiver-provenance and aggregate-reference candidate and is
superseded. A replacement may be prepared only after the exact integrated candidate passes the
founder-run Base fork gate and produces its commit-bound receipt. Until then the existing selection,
addresses, hashes, margins, and digest are historical proposal data, not deployment authority.

Two files live in this directory, and keeping them apart is the point.

- `mainnet-no-go-packet.json` is a **proposal**, and the sole committed ceremony authority. It
  describes what the five-transaction ceremony would do, using code identity and deployability
  margins measured by a run that touched no network. `bin/deployment-gate.sh` renders it
  deterministically and compares it byte for byte against this committed copy; it can fail an
  installed packet and can write a reviewable candidate to `reports/generated/deployment/`, but it
  can never install one. Its `selection` and `external_observation` sections hold the founder's
  public deployer choice and the mutable external control surface; both are null until a human
  installs a candidate written by `--prepare <deployer>`, which is why this packet cannot yet claim
  the exact ceremony was rehearsed. Every value in it is public; no key, mnemonic, keystore path,
  endpoint or credential belongs here.

- `deployed-manifest.json` is a **record**, and it is empty. It is populated once, from confirmed
  Base receipts, after a founder GO_TO_DEPLOY has named the packet's exact digest and the ceremony
  has actually run. No simulated fact may reach it — not a fork address, not a rehearsal
  transaction hash, not a fork block number. The gate proves on every run that it carries no
  address, no hash, and no nonzero number.

`docs/audit/deployment-ceremony.md` describes the ceremony, the gate modes, the endpoint boundary,
the external-state preflight, and the approval boundary in full.
