# SENTINEL

The gate every change in this codebase passes before it goes live. The codebase chief runs it, pushes, and deploys. Nobody else runs a gate for this codebase.

## This codebase

Fill in once and keep current.

- **Fly app:** `autolaunch-sh` (`platform/fly.toml`). Migrations run from the separate `autolaunch-sh-migrations` app (`platform/fly.migrations.toml`), never from a serving machine. Staging is `autolaunch-staging` (`platform/fly.staging.toml`).
- **Setup:** `cd platform && mix setup` (dependencies, `npm ci`, the database, then the assets).
- **Full check:** `make check` from the repository root: `check-platform` (`mix precommit`: compile with warnings as errors, unused-lock check, `hex.audit`, format, Credo strict, Sobelow, xref, `ash.codegen --check`, usage rules, ExUnit with property tests; then the TypeScript typecheck and Vitest), `check-required-fixes` and `check-cli`.
- **Deploy:** two steps from `platform/README.md` (Deployment), after building the image from a `git archive` export with `SOURCE_COMMIT=<full sha>` (`operations/CHECKLIST.md`, step 7) and running the read-only `/app/bin/pending-migrations` check on its digest:
  ```sh
  fly machine run registry.fly.io/autolaunch-sh:<revision-tag> /app/bin/migrate \
    --app autolaunch-sh-migrations --region iad --vm-memory 1024 \
    --env AUTOLAUNCH_DEPLOYMENT_ROLE=production --rm
  fly deploy --app autolaunch-sh --config fly.toml \
    --image registry.fly.io/autolaunch-sh@sha256:<digest> --ha=false
  ```
  A release with a migration follows `operations/RELEASE.md` first (a fresh backup and its id in the evidence).
- **Protected areas:**
  - Sign-in and sessions: `platform/lib/autolaunch/accounts/`, `platform/lib/autolaunch/privy.ex`, `platform/lib/autolaunch_web/controllers/privy_session_controller.ex`, `platform/lib/autolaunch_web/controllers/x_oauth_controller.ex`, `platform/lib/autolaunch_web/live/session.ex`
  - Pairing: `platform/lib/autolaunch_web/components/pairing_box.ex`
  - Secrets and settings: `platform/config/runtime.exs`, `platform/fly.toml`, `platform/fly.migrations.toml`, `platform/rel/overlays/bin/`
  - Wallets, money, staking and claims: `platform/lib/autolaunch/*_actions.ex` (the wallet boundaries), `platform/lib/autolaunch/stocks/`, `platform/lib/autolaunch/robinhood/`, `platform/lib/autolaunch/chain/`, `platform/lib/autolaunch/treasury_*.ex`, `platform/lib/autolaunch_web/controllers/treasury_controller.ex`, `platform/lib/autolaunch/credits.ex`, `platform/lib/autolaunch/points/`, `platform/contracts/chain-contracts.yaml`, `platform/contracts/treasury-security-evidence.yaml`, `contracts/`
  - Database changes: `platform/priv/repo/migrations/`

### Gaps against this gate today

These are written down, not papered over. Until each is closed, the evidence file names it under "Not proven".

- **No secret scan.** Nothing in `make check` scans for secrets.
- **No browser tests in the full check.** There is no Playwright in the repository; pages at 390 and 1280 are a manual step (`operations/CHECKLIST.md`, step 4).
- **Not fully offline.** `check-required-fixes` reads ash-template's main branch through `gh api`, and `check-cli` installs regents-cli from GitHub.
- **No single deploy command.** The image build with `SOURCE_COMMIT` is described in words, not as one command, and nothing refuses a dirty tree or a commit that is not on origin/main. The Dockerfile does require `SOURCE_COMMIT`, and `/healthz` answers `ok <commit>` (503 when the database is down).
- **The migration step starts a short-lived machine** (`fly machine run ... --rm` on `autolaunch-sh-migrations`). The chief confirms with Sean that this is not "adding machines" before relying on it.

## 1. Run it on a fresh copy

1. Commit. `git status --porcelain` must be empty. Write down the commit SHA and the tree hash (`git rev-parse <sha>^{tree}`, the id of the exact file contents).
2. Make a fresh copy of that exact commit: `git archive <sha> | tar -x -C <empty dir>`. Add submodules at their pinned commits.
3. In the fresh copy, with a clean environment (`env -i`, which starts with no inherited variables; no direnv), run only the documented setup and the full check.

## 2. Blocks a deploy

Every item here must hold. If one fails, fix it, commit, and start again at section 1.

### The full check

- Passes on the first run in the fresh copy. A second run that passes does not count.
- Includes everything: compile, format, lint, unit, property, JavaScript and browser tests (Chromium at 390 and 1280 wide), and the secret scan.
- Clean teardown: no warnings, no deprecation notices, no connection-owner-exited lines, even when the exit code is 0.
- Fully offline. Tests fail on any outside network call. No skipped tests, no conditional assertions.
- A flaky test blocks. Fix the cause; never skip or retry it.

### Data safety

- Database changes can be undone, add indexes `CONCURRENTLY`, and record a backup id and row counts before they run.
- No drop, truncate, reset or delete of live rows unless Sean's letter covers exactly that.

### Sign-in and secrets

- Sign-in, sessions and pairing behave as before, unless the change is about them (then Sean's letter, see section 5).
- The secret scan is clean. No secrets in code, tests, logs or docs.
- Error logs carry kind, module and SQLSTATE (the database's error code) only, never bound values or request data.

### UI (apps only)

- Buttons use the design system's normal size on desktop; 44 px only for touch targets.
- Contrast: text 4.5:1; button edges and marks 3:1 at rest.

### Headers (apps only)

- Strict CSP, frame and referrer headers on every response, images and video included, with a test that proves it.
- Fonts self-hosted. No third-party calls from any page.

### Health (apps only)

- `/healthz` answers `ok <SOURCE_COMMIT>`. It returns 503 only when the database is unreachable.

### Ready to ship

- The commit is pushed to GitHub main before the deploy.
- The rollback target is named: the current live Fly version and its image.
- The image is built from this exact commit. Where the app carries old assets across releases, the build fails if the previous image is missing.

## 3. Fix-forward

These do not block a deploy. List every gap you see under "Fix-forward" in the evidence file. The review hooks (Astra) pick them up after the push.

- Tests: a regression test per bug fixed; exact key sets at every level of public JSON; selectors by role and accessible name, no test ids; no tests that only check strings.
- UI: layout shift under 0.1 at 390 and 1280, including 30 s idle; reduced motion respected; no idle animation loops; no "…" truncation; nothing only reachable by hover; copy true at every width.
- Server: JSON routes fail as JSON (503 with Retry-After when the database is down, 500 with no error text otherwise); polled public feeds served from a cache with bounded queries.
- Downloads and uploads: files verified before the 200, streamed with bounded memory, a concurrency cap with a clean "try again"; image pixel count checked before decoding.
- Speed: any speed claim backed by 5 alternating base and head runs and a repo check such as a first-load byte budget.
- Docs and changelog: public changelog lists visible changes only, with no commit ids or internals.

## 4. Push and deploy

1. Push the commit to GitHub main. Never force-push. Undo with a normal revert commit.
2. Note the rollback target: `fly releases -a <app>` and the current image.
3. Deploy with the command above.
4. After-checks on the live app, saved to the evidence file:
   - `/healthz` shows the new commit;
   - main pages load at 390 and 1280 wide;
   - headers present on a page and an image;
   - `fly logs -a <app>` tail from deploy through these checks is clean.
5. If any after-check fails, roll back to the named target at once and record it.
6. Commit the evidence file and push. Evidence-only and docs-only commits are not deployed and need no run of their own.

Never, with or without a letter: `fly secrets deploy`, adding or resizing machines, force-push.

Only when Sean's letter names the exact command: ssh, console, a remote shell, or a production database connection.

## 5. What waits for Sean

Money, wallets, staking and claims; sign-in, sessions and pairing; secrets; any change to live data beyond a database change that can be undone and deletes nothing.

For these, post one question in your own thread naming the exact commit, the commands you will run, and lettered options. Wait until Sean types the letter there. Quote his letter and its time in the evidence file.

Money rules that always hold: value moves only when a user or operator signs it, never the server; the preview shows the full address and the full maximum cost, and matches the signed request byte for byte; signed commands run only against offline stand-ins in tests.

## 6. Evidence file

Commit one file per shipped commit at `sentinel/runs/<short-sha>.md`. It records:

- Commit SHA, tree hash, `git status --porcelain` empty.
- Fresh-copy steps exactly as run, and that it was the first run.
- Each check command with exit code and counts (tests, failures, skips: 0).
- Secret scan: clean, with the command used.
- Teardown: clean, or what was printed.
- Database changes: backup id and row counts before, or "none".
- Protected: no, or Sean's letter quoted with its time.
- Fly: rollback version and image, new version and image, after-check results, saved log tail.
- CLI impact: new or changed routes, JSON shapes or flags that regents-cli needs, or "none".
- Fix-forward: the gaps from section 3.
- Not proven: anything you did not check, in plain words.
