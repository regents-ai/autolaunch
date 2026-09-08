# Autolaunch core tests

This is the active platform suite: **30 Elixir cases and 10 JavaScript cases**.
`manifest.json` identifies the approved cases and their original sources. Helpers
and image fixtures are retained here so the old test folders are not dependencies.

From `platform/`:

- `MIX_TEST_PARTITION=_core_manual AUTOLAUNCH_DB_POOL_SIZE=2 mix test --max-cases 2`
- `npm test`
- `npm run typecheck` (separate from the test budget)

Use an owned database partition, with lab/browser environment overrides unset.
The Mix test alias performs database setup; never point it at the preserved lab.

## Archive and old folders

The original tests, support, fixtures, browser/budget tests and runner configuration
were archived before extraction:

`/Users/sean/Documents/regent/artifacts/autolaunch-core-tests/original-tests-20260908-002826.tar.gz`

File hashes and the archive checksum are in `archive-manifest.json` beside it.
The original folders remain untouched and are no longer used by default test
discovery, support compilation, formatting or TypeScript checking:

- `platform/test/`
- `platform/assets/test/`

Those are the legacy folders to remove. **Keep `platform/core_tests/`.**
The old Playwright and budget config files were also archived; their npm scripts
were retired. They are not part of the core suite. Contract and public CLI test
suites are outside this change.

This suite protects the selected invariants; it is not product acceptance. Manual
functional review remains the priority. Do not restore broad callback/layout/mock
matrices or add new cases without an agreed concrete reason.
