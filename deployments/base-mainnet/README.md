# Base mainnet

**Nothing here has been deployed.** The repository is mainnet NO-GO.

Three files live in this directory, and keeping them apart is the point.

- `mainnet-no-go-packet.json` is a **proposal**. It describes what the five-transaction ceremony
  would do, using code identity and deployability margins measured by a run that touched no
  network. `bin/deployment-gate.sh` renders it deterministically and compares it byte for byte
  against this committed copy; it can fail an installed packet and can write a reviewable candidate
  to `reports/generated/deployment/`, but it can never install one. Its `selection` and
  `external_observation` sections are whatever the ceremony selection below holds — null while that
  is pending, which is why this packet cannot claim the exact ceremony was rehearsed.

- `ceremony-selection.json` is the **founder's input**, and the only thing here a human writes. It
  holds the public deployer selection — account, starting nonce, mined hook salt, and the seven
  addresses those determine — and a snapshot of the mutable external control surface the rehearsal
  compares against. It starts pending, with every field null, and no gate mode ever writes it:
  `--prepare <deployer>` writes a candidate into gitignored scratch and stops, `--rehearse` only
  compares, and `--rehearse` refuses to run at all while this file is pending. Every value in it is
  public; no key, mnemonic, keystore path, endpoint or credential belongs here.

- `deployed-manifest.json` is a **record**, and it is empty. It is populated once, from confirmed
  Base receipts, after a founder GO_TO_DEPLOY has named the packet's exact digest and the ceremony
  has actually run. No simulated fact may reach it — not a fork address, not a rehearsal
  transaction hash, not a fork block number. The gate proves on every run that it carries no
  address, no hash, and no nonzero number.

`docs/audit/deployment-ceremony.md` describes the ceremony, the gate modes, the endpoint boundary,
the external-state preflight, and the approval boundary in full.
