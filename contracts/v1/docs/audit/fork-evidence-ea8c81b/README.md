# Retained fork evidence — commit `ea8c81b`

Four files copied byte for byte out of `reports/generated/fork/` after the compare-only fork check
that produced `fork-check-receipt.json`. They are the reports whose `sha256` that receipt names, and
whose receipt digest the deployment packet names.

| File | What it is |
| --- | --- |
| `forge-test-list.json` | the compiled fork test list — the selectors Forge discovered for the run |
| `forge-test-pinned.json` | the run at the pinned header: eighteen selectors |
| `forge-test-later.json` | the run at the later header: the approved nine-selector subset |
| `fork-check-receipt.json` | the receipt binding the tested commit, tree, `src/` tree and the three report hashes |

The run covered by these files is fork-evidence commit
`ea8c81b2a5724213d3aeb4b0d81885b932f7d1aa` on production authority
`f4114f5276386f48bf8dc53ee344189d98c8896e`.

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
| `forge-test-pinned.json` | `211eec28b51558075a7f5bee7f4eddb128e605df85869fc0372db6767843c80d` |
| `forge-test-later.json` | `17c509de4eef4c334272962d13d31596c6f2442e1b213bf45577a7e49caa4875` |
| `fork-check-receipt.json` | `a1cb403f5c01dfdf5c6e998bd8ea429e9142c99ca4518faf494a00dd01e68853` |

Re-check them with:

```
shasum -a 256 docs/audit/fork-evidence-ea8c81b/*.json
```

## What this directory is not

These copies are evidence only. They are not an authority, no gate reads them, and they alter
neither `deployments/base-mainnet/mainnet-no-go-packet.json` nor its digest. The receipt inside the
packet remains the object the deployment gate accepts. The repository stays mainnet NO-GO.
