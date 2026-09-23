# Retained fork evidence — commit `4451c77`

Four files copied byte for byte out of `reports/generated/fork/` after the compare-only fork check
that produced `fork-check-receipt.json`. They are the reports whose `sha256` that receipt names, and
whose receipt digest the deployment packet names.

| File | What it is |
| --- | --- |
| `forge-test-list.json` | the compiled fork test list — the selectors Forge discovered for the run |
| `forge-test-pinned.json` | the run at the pinned header: eighteen selectors |
| `forge-test-later.json` | the run at the later header: the approved nine-selector subset |
| `fork-check-receipt.json` | the receipt binding the tested commit, tree, `contracts/v1/src` tree and the three report hashes |

The run covered by these files is fork-evidence commit
`4451c776f84fa904dd02b0c4360d360a45a945cb` on production authority
`7d564cec735c3b1b928ec4e2ede0b244682d105b`, executed on 2026-09-22 against the committed headers
`50541328` and `50541628`.

## Why they are retained here

`bin/gate.sh` deletes and rewrites `reports/generated/` on every run, and `.gitignore` keeps that
directory out of the tree. Without these copies the hashes the receipt names have nothing left to be
checked against, so a later reviewer could read the receipt but could not re-derive it.

## Hashes

Exactly as named by `fork-check-receipt.json` and, for the receipt itself, by the packet field
`fork_check_receipt_sha256`.

| File | sha256 |
| --- | --- |
| `forge-test-list.json` | `21cd56b89a58b16057cb73ca2814125866d519f0589e5cfe6371b9c4c6bdc4e3` |
| `forge-test-pinned.json` | `f3287014cddf4ede21f706edbd6f1f8ce6f9c3a00214c52291d89a4591928413` |
| `forge-test-later.json` | `4e237fb490a0ea7d1877b6ddae3eeedb27637326516357f4ac39cc6a7a6e124f` |
| `fork-check-receipt.json` | `84f34fb84e7f8429ee6fc8894d67a4af871304c374184627d8099e2d0549053e` |

Re-check them with:

```
shasum -a 256 docs/audit/fork-evidence-4451c77/*.json
```

## What this directory is not

These copies are evidence only. They are not an authority, no gate reads them, and they alter
neither `deployments/base-mainnet/mainnet-no-go-packet.json` nor its digest. The receipt inside the
packet remains the object the deployment gate accepts. The repository stays mainnet NO-GO.
