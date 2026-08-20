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
excluded, and no triage database is used. Slither can be narrowed two entirely valid ways —
a well-formed configuration key, or a well-formed command-line flag — so the gate pins both:

- **The configuration.** `slither.config.json` must equal one exact allowed shape:
  `filter_paths` exactly `^lib/`, all six severity exclusions false, `exclude_dependencies`
  false, and `compile_force_framework` foundry. An added key, a changed value, a broadened
  filter, or a detector exclusion list all fail, whether or not the key is spelled
  correctly. A typo such as `exclude_lowww` fails as an unrecognized key, and a correct
  `"exclude_low": true` fails as a narrowing.
- **The command line.** `bin/gate.sh` records the exact argv it is about to run and then
  runs that argv, and the gate compares the recording against the one allowed invocation.
  `--detect`, `--exclude`, `--exclude-low`, `--filter-paths`, and `--triage-mode` are all
  rejected because none of them is in the allowed argv.
- **The detector portfolio.** The expected portfolio comes from the pinned Slither binary's
  own registered detector classes, read through the binary's own interpreter, and the gate
  requires the analyzed run to report exactly that many detectors. `--list-detectors` is
  **not** the authority: it omits hidden detectors and under-reports the set that actually
  runs. Any narrowing, from the configuration or the command line, shrinks the reported
  count and fails here.
- `--fail-medium` fails the run on medium and high findings;
- every result at **any** severity, including low, informational, and optimization, gets its
  own row in the disposition table below. Each row is matched against an exact fingerprint —
  detector, impact, confidence, and the repository-relative source mapping Slither reported
  — as a multiset in both directions. Two findings from the same detector at two locations
  are two fingerprints and need two rows; a row whose location is wrong or missing matches
  nothing and fails;
- the gate fails closed if a `*slither.db.json` triage database appears anywhere outside
  `lib/`, so findings cannot be silently retired;
- the gate fails closed if Slither complains about its own configuration;
- the gate compares the number of contracts Slither says it analyzed against the number of
  contracts, libraries, and interfaces declared under `src/`, so a narrowed source list
  cannot produce a quiet pass.

## Generated evidence

`reports/generated/slither.json`, `reports/generated/slither-checklist.md`,
`reports/generated/slither.stderr.log`, `reports/generated/slither-command.txt`, and
`reports/generated/slither-detectors.txt` are regenerated on every gate run and stay
uncommitted until the C5 freeze, when the release packet fixes them as recorded artifacts.
Until then the reproducible command above, not a stored file, is the evidence. The gate
deletes the whole generated directory before each run and fails if any piece of that
evidence is missing, empty, or malformed, so a stale artifact cannot survive into a later
run.

The checklist carries Slither's standard "not complete" banner whenever any path filter is
configured. Re-running the same command with `--show-ignored-findings` returns the same
results, so the `lib/` filter currently hides nothing.

## Results

<!-- slither-result-count: 0 -->

| Check | Impact | Confidence | Where | Disposition |
| --- | --- | --- | --- | --- |

Slither reported no result at any severity, so there is nothing to disposition.

`Where` is not prose: it is the exact normalized source mapping of the result, built from
the repository-relative filenames and line numbers in Slither's JSON, in the form
`src/Path.sol#L12,L13; src/Other.sol#L40`. The gate reconciles the four fingerprint columns
against the real run as a multiset in both directions, so a missing row, an extra row, a
mistyped location, and two same-detector findings sharing one row all fail.

## Inline suppressions

<!-- slither-suppression-count: 0 -->

| File | Detector | Rationale | Protecting test |
| --- | --- | --- | --- |

There are none. A `slither-disable` annotation anywhere under `src/`, `test/`, or `script/`
requires a row above that names the exact detector, the reason the finding is safe, and the
Foundry test that protects the property. The gate scans all three directories
unconditionally — a directory this repository does not have yet simply contributes no rows,
so a later ticket that adds `script/` is covered the moment it exists. It re-derives the
annotations from the source, fails if the recorded count disagrees, fails if any annotation
lacks a rationale, and fails if the named protecting test is not in Foundry's compiled test
listing. Naming a file is not enough.

This table and the results table are read only within their own sections, so a row from one
can never stand in for a row in the other, and neither can be satisfied by the narrative
table below.

## Dispositions

| Date | Ticket | Scope analyzed | Disposition |
| --- | --- | --- | --- |
| 2026-08-20 | regent-alv1.1 (C0) | `src/bindings/BaseBindings.sol` and `src/bindings/FrozenIdentity.sol` — the two production Solidity units in the repository | Slither analyzed 2 contracts with 101 detectors and reported 0 results. Nothing was suppressed, filtered, or triaged. |
| 2026-08-20 | regent-alv1.1.1 (C0R) | unchanged: the same two production Solidity units | Same run, now reconciled against the pinned binary's 101 registered detector classes rather than a written-down number, with the configuration and the argv both pinned to their allowed shape. Slither analyzed 2 contracts with 101 detectors and reported 0 results. Nothing was suppressed, filtered, or triaged. |

C0 contains constants only, so this is a small analyzed surface by construction, not a quiet
one: every later ticket adds production Solidity to the same unfiltered run, and every
result it produces gets a dated row here.
