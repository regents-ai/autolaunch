# Release checklist

Autolaunch checks and ships its own releases (Sean, 19 October 2026: "teams check and ship
their own releases"). Every release goes through this list before it reaches main and Fly, and
the release's evidence folder holds the output of each step. A change to sign-in, secrets,
production data, wallets, staking, claims or money movement also needs Sean's typed go naming
the release, in this project's thread.

[FEATURES.md](FEATURES.md) lists what people and agents can do on Autolaunch and the check
that proves each one, with the gaps; a release that adds or changes one of them updates it.

## Before the release

1. The head is pushed. Write `git rev-parse HEAD`, `git rev-parse HEAD^{tree}` and an empty
   `git status --porcelain` at the top of the evidence.
2. Fresh copy: `git archive <head> | tar -x` into an empty folder, then
   `cd platform && mix deps.get && npm ci && mix assets.setup && mix assets.build`, then
   `make check-platform`, `make check-required-fixes`, `make check-cli` and `make check-siwa-latest` from its root. All
   exit 0, and the run shows no "still using a connection" line. Keep the raw output.
3. Evidence block: what people and agents will notice, the commands that prove it with their
   output, and what was not proven.
4. Pages it touches, in headless Chromium at 390 with touch and at 1280: every standalone
   press at least 44 px on touch, no sideways scroll, no console or content-policy errors.
5. A release touching pairing, agent routes, drafts or launches runs `scripts/agent-journeys.sh`
   (see [FEATURES.md](FEATURES.md)) and keeps its output: an agent pairs, fills in a Memestock draft,
   and its person reviews and signs it on a copy of Base, at 390 with touch and at 1280.
6. Every bug found while making the release has a test that fails without its fix.
7. The changelog says what people and agents noticed, with no release numbers, commits or
   internal names.

## The release

8. A release whose diff from the live commit adds a migration, or moves a shared library
   pin that ships one, follows [RELEASE.md](RELEASE.md) first: a fresh backup and its id
   in the evidence. The deploy runs the migrations itself.
9. Write down the release the site can go back to (`fly releases -a autolaunch-sh`).
10. Start a `fly logs -a autolaunch-sh` tail before the deploy, saved in the evidence folder,
   and keep it until the checks after the deploy are done.
11. Push the head to main, then deploy it from a clean checkout with
    `scripts/deploy.sh autolaunch-sh` ([platform/README.md](../platform/README.md#deployment)).

## After the release

12. The live checks pass, `/healthz` names the deployed commit, and the pages the release
    touched are checked on autolaunch.sh.
13. The saved log tail shows no errors.
14. Add the release's row to [RELEASES.md](../RELEASES.md).
