# Autolaunch takeover — 9 October 2026

Checkout: `/Users/sean/Documents/regent/repos/autolaunch`.
Branch: `claude/vibrant-knuth-1td9ig`, tip `ed2074f` (v79 plus seven commits).
Fetched the handoff branch and switched the primary checkout to it. No new worktree.
Existing untracked `.devspace/` and `platform/priv/static/images/regent-ui/` were preserved.

Done for this pass: run the required platform checks on the handoff branch,
resolve local test setup, and investigate the launch report in the running site.
Local settings now parse, and representative browser checks are complete.

## Local change

The launch progress card now displays the full transaction hash before confirmation,
including on test networks. Its existing copy button and explorer link remain.
The hash occupies its own wrapping row, like the confirmed card.
Changed `lib/autolaunch_web/launch_steps.ex` and `assets/css/pages/autolaunch.css`.
No commit, push, merge, release or changelog entry was made.

## Verification

- Installed the locked Mix and npm dependencies in this checkout.
- `make check-platform` compiled, then stopped at `mix hex.audit`: Ash 3.34.4
  is listed under EEF-CVE-2026-101028 / GHSA-xj24-8f5c-pp5p. No dependency upgrade
  was folded into this launch change. The complete gate is therefore failing.
- Ran the remaining precommit commands explicitly: compilation with warnings as
  errors, unused-lock check, formatting, Credo, Sobelow, compile graph, tests,
  Ash code generation check and usage-rules check all passed.
- All 90 Elixir tests passed on isolated local database
  `autolaunch_sol_1009_test`. The existing setup alias created and migrated it,
  including the shared identity schema; the earlier missing-column failure did
  not recur. No test setup source change was required.
- TypeScript typecheck and all seven existing Vitest tests passed.
- A temporary, rolled-back database check verified both launch draft types:
  rewritten drafts survive, matching drafts clear in one guarded UPDATE without
  a preceding SELECT, and a repeated clear succeeds harmlessly.
- Rendered real pending, stalled and confirmed launch components with a representative
  full hash on mainnet and test-network variants. Full text, copy controls, status,
  repeat press button and conditional auction link were present. This does not
  by itself verify browser clipboard behavior, mobile layout or real wallet transactions.
- Built assets successfully. Browser checks verified both pending and confirmed
  copy buttons copy the complete hash. At 390 pixels wide, both hashes wrap
  without horizontal overflow.
- A separate, newly created review database exercised the actual launch-confirmation
  path with a scripted chain result. Pending stayed unlisted; confirmation created
  the auction listing, cleared the matching draft, and repeated confirmation was
  harmless. The resulting sample appeared in Explore and opened its auction page.
  Its chain-read warning is expected: the fixture address has no deployed contract.
- Logs: `/tmp/autolaunch-sol-check-1009.log`,
  `/tmp/autolaunch-sol-remaining-1009.log`, `/tmp/autolaunch-sol-proof-1009.log`.

## Remaining

1. Real Privy sign-in and a user-signed wallet launch remain unverified. The local
   site runs in its default read-only mode, with Create and bidding disabled.
2. Resolve the Ash advisory separately before claiming the full gate passes.
3. Session-expiry adoption remains template-first. `d83510c` exists locally in
   ash-template on `at/wd024-authority`; it has not been integrated here.
4. The wallet wording decision and `feat/contracts-v2` remain separate.

## Settings follow-up

Sean corrected the direnv settings. The app ID is present and OpenSSL now parses
the verification key successfully. The running home page has nonempty Privy app-ID
metadata. No credential values or settings files were read or printed.

An earlier owned server was stopped after detecting an invalid key. The preserved
development database is behind the branch: its
pending migrations include destructive removals. Only migration status was read;
no development database migrations were applied.

The current local server is on port 4002, exec session 66384, using only the new
review database `autolaunch_sol_review_1009_1791559933`. Its launcher is
`/tmp/autolaunch-sol-review-1009.exs`; its log is
`/tmp/autolaunch-sol-review-server-1009.log`. Normal chain-client configuration was
restored after the scripted fixture check. No authentication bypass was installed.

Preview: `http://localhost:4002/assets/sol-launch-preview.html`.
It renders real launch-card components with representative data; wallet buttons are
disconnected. Sample listing: `http://localhost:4002/auctions/SOLPROOF/10009`.
Temporary preview files live in ignored `priv/static/assets/`; they are not source
changes. Screenshots are in the workspace `artifacts/autolaunch-sol-1009/` directory.

No other server was stopped. No production database, wallet action, claim, finish,
secret, or `contracts/v1` file was changed.

## V2 completion follow-up

The earlier sections describe the takeover before Sean authorized integration.
The current candidate includes the full pending-hash fix, final deployed v2
contract sources/receipts, corrected deployment summaries and Ash 3.34.6.
Commits: `2cf43d1`, `eb1260e`, `1de1d85`. All seven handoff fixes remain included.
See `v2-release-review-2026-10-09.md` for the complete verification record.

The complete platform gate and template-required-fixes gate now pass. All 426
contract tests, package formatting and frozen-build comparisons pass. All three
complete offline contract gates, including static analysis and the secret scan,
passed on the existing published contract checkout at `fd258f7`, whose sources,
ABIs, frozen records and build requirements exactly match the candidate. The
primary checkout's preserved platform files still prevent that contract-only
clean-tree gate from running there. Temporarily parked generated dependencies and
cache files were restored unchanged; no gate was weakened or user files removed.

All three v1 launchers were read as paused, and the four existing auction pages
and three graduated tokens remain publicly available. Candidate code keeps v1
interaction bindings and uses v2 for new creation. `contracts/v1` is unchanged.

The owned server moved from 4002 to Privy's permitted port 4061 and reuses the
existing review database. PID 4060, exec session 21863; launcher
`/tmp/autolaunch-sol-preview-1009.exs`. Preview:
`http://localhost:4061/assets/sol-launch-preview.html`. Browser copy, mobile wrapping,
WebMCP listing and opening Privy's modal were verified. Real wallet acceptance and
release authority remain with Sean. No push, deployment or money movement occurred.

### Release follow-up

Sean subsequently approved push and deployment. Candidate `b75c693` is on main
and `claude/vibrant-knuth-1td9ig`, and is live as **v80** on `autolaunch.sh`.
The x86 Linux image passed its native-library and launch-card checks; the isolated
read-only database check found no migration differences. Production health,
Create, all four auction pages, graduated tokens, the browser-agent auction list
and opening Privy's sign-in modal passed. Chain reads confirm v1 launch entry
points paused, v2 entry points open and existing v1 bindings loaded.

Runtime settings and contract descriptions were preserved. The actual release
is in `CHANGELOG.md`; its image and evidence are recorded in
`v2-release-review-2026-10-09.md` and workspace `artifacts/autolaunch-sol-1009/`.
Real sign-in completion and wallet acceptance remain founder checks. Session
expiry still requires template-first adoption; wallet wording and the launch film
remain separate work.
