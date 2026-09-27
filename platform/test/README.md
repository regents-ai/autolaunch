# Autolaunch tests

The kept cases: Elixir in `platform/test/`, TypeScript in `platform/assets/test/`.
`manifest.json` names every approved case, why it is kept, and its original source.

From `platform/`:

- `MIX_TEST_PARTITION=_core_manual AUTOLAUNCH_DB_POOL_SIZE=2 mix test --max-cases 2`
- `npm test`
- `npm run typecheck` (separate from the test budget)

Use an owned database partition, with lab/browser environment overrides unset.
The Mix test alias performs database setup; never point it at the preserved lab.

## Archive

The original tests, support, fixtures, browser/budget tests and runner configuration
were archived before the cases were chosen:

`/Users/sean/Documents/regent/artifacts/autolaunch-core-tests/original-tests-20260908-002826.tar.gz`

File hashes and the archive checksum are in `archive-manifest.json` beside it.
Contract and public CLI test suites are outside this folder.

This suite protects the selected invariants; it is not product acceptance. Manual
functional review remains the priority. Do not restore broad callback/layout/mock
matrices or add new cases without an agreed concrete reason.
