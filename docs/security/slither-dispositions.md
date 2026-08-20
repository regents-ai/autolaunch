# Slither dispositions

## How Slither runs

`bin/gate.sh` runs Slither only after the recursive dependency closure, the frozen identity,
the build identity, the compiled test listing, the executed test set, and the requirement
ledger are all green:

```
slither . --fail-medium --json reports/generated/slither.json --checklist
```

Slither drives the repository's own Foundry build, so the compiler and settings it analyzes
under are the frozen ones the gate already proved. That build is
`forge build --skip ./test/** ./script/**`, so the analyzed scope is exactly this
repository's **production** Solidity under `src/`. Tests and scripts are outside the
analyzed scope because Slither's Foundry integration excludes them; pinned dependency
sources under `lib/` are excluded by `filter_paths` because this repository does not own
them.

`slither.config.json` disables nothing else. No detector is turned off, no severity is
excluded, and no triage database is used:

- `--fail-medium` fails the run on medium and high findings;
- every result at **any** severity, including low, informational, and optimization, must
  appear in the disposition table below, and the gate compares the recorded count against
  the count Slither actually reported in both its JSON report and its summary line;
- the gate fails closed if a `*slither.db.json` triage database appears anywhere outside
  `lib/`, so findings cannot be silently retired;
- the gate fails closed if Slither complains about its own configuration. Slither reports
  an unknown configuration key as an informational line and still exits 0, so a typo such
  as `exclude_lowww` would otherwise silently leave a severity filter unset;
- the gate compares the number of contracts Slither says it analyzed against the number of
  contracts, libraries, and interfaces declared under `src/`, so a narrowed source list
  cannot produce a quiet pass.

## Generated evidence

`reports/generated/slither.json`, `reports/generated/slither-checklist.md`, and
`reports/generated/slither.stderr.log` are regenerated on every gate run and stay
uncommitted until the C5 freeze, when the release packet fixes them as recorded artifacts.
Until then the reproducible command above, not a stored file, is the evidence. The gate
deletes the whole generated directory before each run and fails if any of the three pieces
of evidence is missing, empty, or malformed, so a stale artifact cannot survive into a
later run.

The checklist carries Slither's standard "not complete" banner whenever any path filter is
configured. Re-running the same command with `--show-ignored-findings` returns the same
results, so the `lib/` filter currently hides nothing.

## Results

<!-- slither-result-count: 0 -->

| Check | Impact | Confidence | Where | Disposition |
| --- | --- | --- | --- | --- |

Slither reported no result at any severity. The table is empty because there is nothing to
disposition, and the machine-checked count above is what the gate compares against the real
run — if a later ticket introduces a finding, the count stops matching and the gate fails
until the finding has a row here.

## Inline suppressions

<!-- slither-suppression-count: 0 -->

| File | Detector | Rationale | Protecting test |
| --- | --- | --- | --- |

There are none. A `slither-disable` annotation anywhere under `src/` or `test/` requires a
row above that names the exact detector, the reason the finding is safe, and the Foundry
test that protects the property. The gate re-derives the annotations from the source, fails
if the recorded count disagrees, fails if any annotation lacks a rationale, and fails if
the named protecting test is not in Foundry's compiled test listing. Naming a file is not
enough.

## Dispositions

| Date | Ticket | Scope analyzed | Disposition |
| --- | --- | --- | --- |
| 2026-08-20 | regent-alv1.1 (C0) | `src/bindings/BaseBindings.sol` and `src/bindings/FrozenIdentity.sol` — the two production Solidity units in the repository | Slither analyzed 2 contracts with 101 detectors and reported 0 results. Nothing was suppressed, filtered, or triaged. |

C0 contains constants only, so this is a small analyzed surface by construction, not a quiet
one: every later ticket adds production Solidity to the same unfiltered run, and every
result it produces gets a dated row here.
