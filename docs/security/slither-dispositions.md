# Slither dispositions

## How Slither runs

`bin/gate.sh` runs Slither only after the pinned dependency closure, the build identity, the
source-enumerated test execution, and the requirement reconciliation are all green:

```
slither . --fail-medium --json reports/generated/slither.json --checklist > reports/generated/slither-checklist.md
```

`slither.config.json` filters exactly one thing: paths under `lib/`, which are pinned dependency
sources this repository does not own. No detector is disabled, no severity is excluded, and no
triage database is used. The gate fails closed if a `*slither.db.json` triage database appears
anywhere outside `lib/`, so findings cannot be silently retired.

Slither analyzes the repository's production Solidity through the same Foundry build the gate
proves, so the analyzed compiler and settings are the frozen ones.

## Generated evidence

`reports/generated/slither.json` and `reports/generated/slither-checklist.md` are regenerated on
every gate run and stay uncommitted until the C5 freeze, when the release packet fixes them as
recorded artifacts. Until then the reproducible command above, not a stored file, is the
evidence. Slither refuses to overwrite an existing report, so the gate deletes both files before
each run and fails if no JSON evidence is produced.

The checklist carries Slither's standard "not complete" banner whenever any path filter is
configured. Re-running the same command with `--show-ignored-findings` returns the same results,
so the `lib/` filter currently hides nothing.

## Inline suppressions

There are none. If a later ticket adds a `slither-disable` annotation, it must name the detector,
the reason it is safe, and the Solidity test that protects the property — and this document must
account for the file, or the gate fails.

## Dispositions

| Date | Ticket | Scope analyzed | Disposition |
| --- | --- | --- | --- |
| 2026-08-20 | regent-alv1.1 (C0) | `src/bindings/BaseBindings.sol` — the only production Solidity in the repository | Slither reported no results at any severity. Nothing was suppressed, filtered, or triaged. |

C0 contains constants only, so this is a small analyzed surface by construction, not a quiet one:
every later ticket adds production Solidity to the same unfiltered run, and every result it
produces gets a dated row here.
