# Base mainnet

**Nothing here has been deployed.** The repository is mainnet NO-GO.

Two files live in this directory, and keeping them apart is the point.

- `mainnet-no-go-packet.json` is a **proposal**. It describes what the five-transaction ceremony
  would do, using code identity and deployability margins measured by a run that touched no
  network. `bin/deployment-gate.sh` renders it deterministically and compares it byte for byte
  against this committed copy; it can fail an installed packet and can write a reviewable candidate
  to `reports/generated/deployment/`, but it can never install one. Its `selection` section is
  empty because no deployer has been chosen, and its `external_observation` is null because no
  provider was accessed.

- `deployed-manifest.json` is a **record**, and it is empty. It is populated once, from confirmed
  Base receipts, after a founder GO_TO_DEPLOY has named the packet's exact digest and the ceremony
  has actually run. No simulated fact may reach it — not a fork address, not a rehearsal
  transaction hash, not a fork block number. The gate proves on every run that it carries no
  address, no hash, and no nonzero number.

`docs/audit/deployment-ceremony.md` describes the ceremony, the two gate modes, the external-state
preflight, and the approval boundary in full.
