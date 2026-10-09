# V2 release review — 9 October 2026

Scope: Sean asked whether the v2 release left anything out, especially his request
to fix what happens after a successful Memestake or Revstake launch. This review
covers creation confirmation and listing, and the successful auction's graduation.
It does not authorize publishing, deployment, signing, or production data changes.

Done means the running release is identified, its contract selection is checked,
the success requirements are traced through released source, and unpublished work
is compared against those requirements. The original review found omissions in v79. The implementation follow-up below
records their resolution in a tested local candidate; v79 itself has not changed.

## Running release

- Fresh Git fetch: main is f7a32bf; the release changelog names build 29af631.
- Fly's current started machine runs v79 and image
  sha256:61185e3aa3fd8825c75598ecfc018307b36c3ee1d0eae8a289f69341986eda14,
  matching the recorded v79 build. No newer release was found.
- Read-only inspection of the running site's loaded descriptions confirmed the
  recorded v2 Revstake factory and strategy on Base, Base Memestake launchpad,
  and Robinhood Memestake launchpad. Base lists 10 stocks; Robinhood lists 25.
  Both Memestake descriptions retain their v1 sections.
- The running site's own latest-block readers answered successfully for all three
  launch systems, with new launches unpaused. The first configured stock on each
  Memestake chain was admitted. This was not a fresh check of all 35 admissions.
- The running application's finisher configuration is enabled. No finishing job
  was invoked by this review.
- The public health endpoint answers ok. The public auction list still contains
  the four legacy auctions, including the graduated Base and Robinhood examples.

Only selected public contract addresses, counts, terms and booleans were printed.
No credentials, RPC endpoints or settings files were printed. There was no direct
production database access.

## Success requirements

| Requirement | Released? | Evidence / missing part |
| --- | --- | --- |
| Recognizable confirmation, full confirmed hash, Copy and explorer link | Yes | 92f9dff, shipped v73; shared LaunchSteps.launched_panel used by all three launch components |
| Reset the form after confirmed creation; allow another launch | Yes | v73 page messages and draft clearing; v70/v72 remove the account's single-auction limits |
| Clear only the draft that still names the launch, even if another tab changes it | Incomplete | Main reads then clears; a0fbde9 makes the matching and clearing one database statement |
| Keep finding the auction page when listing takes longer | Incomplete | Main retries for about one minute then stops; c2c5d20 listens for new listings and updates all three launch cards |
| Show the full hash before confirmation | Incomplete | Main shortens the visible hash, though its copy control already carries the full value; Sol's two-file local change shows and wraps the full hash |
| List a receipt-verified Base launch, including when its browser closes | Yes | LaunchReviews and discovery for both Base launch types; scoped checks passed |
| Successful graduation opens the intended pool, preserves custody and pays claims | Contract checks pass | Tests run from the published contract branch, not main's stale contract sources; no real auction was finished |
| Refresh Finish on a new block from its own chain | Incomplete | b8adf17 and 1ced19b are outside main |
| Keep hidden Robinhood auctions' Withdraw/Claim, without a public token link | Incomplete | f5ffc11 and ed2074f are outside main |
| Correct failed-auction refund receipts and bids exactly at the price | Incomplete | 176a5bf is outside main |

The seven commits above are on claude/vibrant-knuth-1td9ig at ed2074f, based on
current main. Sol's full-hash display/wrapping edits remain uncommitted in that
checkout. They were previously compiled, checked and exercised in a local browser
with representative components and an isolated review database. Real Privy sign-in
and user-signed submission remain unverified.

## Contract source and deployment records left outside main

feat/contracts-v2 at fd258f7 has 16 commits absent from main. Its three deployment
manifests say deployed and contain receipt-based addresses; main's three manifests
still say not deployed and contain empty contract lists.

More than documentation was missed: main's StocksPreset still assigns 49.5% to
the auction, 49.5% to the pool and 1% to the creator. The contract branch has the
approved 5 October 49.75% / 49.75% / 0.5% split. The released site's terms already
state the latter. Robinhood imports that same preset. Main's Revstake hook code
already has the 2% staker lane; the branch also corrects its old 1% comments.

The Base and Robinhood Memestake package READMEs still say "not deployed" even on
the contract branch. Their deployment records contain the actual receipts, so those
status summaries also need correction when the branch is integrated. The deliberately
deferred Robinhood-to-Base revenue bridge is documented separately; it is not a
missing launch-success fix.

A three-way merge simulation of current main and feat/contracts-v2 found no
conflicts. Its scoped v2 changes preserve the site's newer ABIs and platform changes.
The complete branch also contains shared contract documentation and preview-tool
changes; the follow-up excludes its three frozen v1 tooling edits. This was a simulation,
not a merge. No source or frozen V1 dependencies were changed.

## Checks run in this review

- 16 existing Base launch discovery/projection checks passed on the handoff
  candidate: both kinds list once, browser closure is covered, replay does not
  regress the auction, and notification follows commit.
- 88 existing contract checks passed on feat/contracts-v2: successful and failed
  graduation, sellout/minimum boundaries, pool opening price, locked liquidity,
  claim/refund custody and creator vesting. Revstake fuzz tests ran 512 cases each;
  Memestake suites used their configured 64 cases each. All ran locally offline.
- Git diff whitespace check passed. Existing dirty V1 submodules in the contract
  checkout and unrelated launch-film changes were preserved.
- Earlier candidate checks passed compilation, typechecking and the other
  precommit checks, but the complete platform gate still stops at the Ash 3.34.4
  advisory EEF-CVE-2026-101028 / GHSA-xj24-8f5c-pp5p. This review did not change
  dependencies or rerun the entire gate.

## Release contents still owed

1. Bring the contract branch's final v2 sources, frozen evidence and deployed
   manifests into the release source, preserving the site's current ABIs, and
   correct the two stale Memestake deployment-status summaries.
2. Include the seven handoff commits and the local full-hash display change.
3. Check the integrated candidate and address the existing dependency gate failure
   separately before calling the full gate clean.
4. Record the actual resulting release and repeat the configured sign-in/wallet
   acceptance with Sean. Publishing and release actions still require his approval.

Session-expiry work remains template-first. The separate wallet-message wording
decision and the marketing launch film are not required parts of this success fix.
The Revstake collection branch has no commits missing from current main.

No product source changed during this review. No merge, push, deploy, production
database change, secret change, real finish, claim or wallet transaction occurred.

## Implementation follow-up — 9 October 2026

Sean authorized completing the review's missing work. The local candidate is on
`claude/vibrant-knuth-1td9ig`: `2cf43d1` adds the full pending hash,
`eb1260e` integrates the final contract branch and its receipt records while
preserving the pre-merge `contracts/v1` tree, and `1de1d85` updates only Ash to
3.34.6 and synchronizes its generated usage rules. No schema change was needed.
The seven handoff commits remain included. No main merge, push or release occurred.

The package status summaries, contract map and launch-profile document now identify
all three deployed v2 systems and distinguish the four existing v1 auctions.
Shared preview tooling from the contract branch is included; Python compilation,
shell syntax and its twelve existing proxy tests passed. The restored v1 patch is
preserved at `/tmp/autolaunch-sol-excluded-v1-1009.patch`.

### Verified on the integrated candidate

- `make check-platform` passed: the full precommit gate, all 90 Elixir tests,
  TypeScript checking and all 7 Vitest tests. The advisory check is clean.
- `make check-required-fixes` passed against template main `4a2dd5c`.
- All offline contract tests passed: Revstake 201, Base Memestake 114,
  Robinhood Memestake 111. This includes the focused 88 launch/graduation,
  custody, sellout and boundary checks and the configured invariant suites.
- Formatting passed for all three v2 packages. Their frozen records reconciled
  with the builds: 12 content-pinned dependency snapshots each, the generated
  ABI/size/code records and the full compiled test listings. Robinhood required
  a complete build including deployment scripts; its committed records were
  already correct and were not changed by regeneration.
- The guarded draft-clear probe passed again for both draft types. Rewritten
  drafts survive, a matching draft clears in one guarded update, and replay
  is harmless. Pending, stalled and confirmed cards render the full hash.
- The actual browser copied the complete pending and confirmed hashes. At
  390 pixels wide the cards wrap without horizontal overflow. A fixture launch
  remains visible through Explore and the native WebMCP auction-list tool.
- Privy's actual login modal opens on the permitted localhost port 4061.
  Login completion and user-signed wallet submission remain unverified.

### Existing v1 launches

Sean clarified that no new v1 launches may open, while the four existing ones
must remain usable. Read-only checks on 9 October found both Base v1 launchers
paused; the running app's Robinhood reader found its v1 launchpad paused at block
84,327,913. Pausing these contracts affects creation only.

The public auction list retains AGI, JollyB, BITE and RDOG; all four auction pages
answered 200. The token list retains the three graduated tokens. AGI remains
ended with no bids, per the existing founder decision. No auction was finished.
New-launch preparation selects the configured v2 factory/launchpads and v2 ABIs.
Existing Memestake reads and wallet preparation retain each auction's own version
for its launchpad, bid adapter, hook and locker; Robinhood settlement can find
both launchpad versions. No actual claim, withdrawal or staking action was sent.
The candidate's `contracts/v1` tree is unchanged from the handoff branch.

### Remaining before release

The primary checkout's offline contract gate rejects its preserved local files
and installed platform dependencies. To complete verification without another
worktree, the existing `feat/contracts-v2` checkout at `fd258f7` was used. The
candidate's three v2 source trees, ABIs, frozen records, requirements and build
settings match that published branch exactly. No tracked file in the contract
checkout was changed.

All three complete offline gates passed there with the pinned Forge 1.5.1 commit,
Slither 0.11.5 and Python 3.14.7: build identity, 426 tests, frozen records, static
analysis, provider-secret scanning and final clean-tree verification. An inactive
legacy dependency export and Python cache were parked outside the checkout while
its gates ran, then restored with matching hashes. No v1 source or submodule was
changed. The three certification receipts are saved in the workspace at
`artifacts/autolaunch-sol-1009/contracts-v2-offline/`. They certify the published
contract commit; the integrated candidate's platform checks ran in its primary
checkout. No gate was weakened and no checkout was created or retired.

Sean's real sign-in and wallet acceptance, approval to publish and deploy, and an
accurate changelog entry tied to that actual deployment remain. No release number
was invented. Session-expiry adoption remains template-first; the separate wallet
wording and launch film remain outside this launch-success work.

Current preview: `http://localhost:4061/assets/sol-launch-preview.html`.
The server reuses `autolaunch_sol_review_1009_1791559933`; no additional database
was created in this follow-up. Its launcher and log are
`/tmp/autolaunch-sol-preview-1009.exs` and
`/tmp/autolaunch-sol-review-server-1009.log`. Representative wallet buttons are
not connected. The normal site stays read-only; no authentication bypass is installed.

### Prepared release notes

Use these in the changelog only when the actual deployed version and build are known:

- A launch shows the full transaction hash while waiting for confirmation; Copy and
  the explorer link remain available. Both pending and confirmed hashes wrap on mobile.
- The confirmed card keeps finding the auction page as new listings arrive. The
  draft clears only if it still describes that launch, preserving edits in another tab.
- Finish refreshes on a new block from the auction's own network.
- Hidden Robinhood auctions keep withdrawal and claim controls without public token links.
  Failed auctions show full refunds, and receipts handle bids exactly at the clearing price.
- Release source now includes the final deployed v2 contracts and receipt records,
  the 5 October fee terms and accurate package status summaries. Existing v1 auctions
  keep their own interaction bindings; new launches use v2.
- Ash is updated to the patched 3.34.6 version.

### Published release

Sean approved push and deployment on 9 October. Candidate `b75c693` was pushed
to main and `claude/vibrant-knuth-1td9ig`, then deployed to `autolaunch-sh` as
**v80**. Fly records its creation at `2026-10-09T18:26:54Z` with status complete.
Its exact image is
`registry.fly.io/autolaunch-sh@sha256:6c7759a873b1b21760356b8d20d6f13a47ef46e5ad3925cf5aae349e89b4cd40`.

The x86 Linux image was built on Fly's native builder after local Docker
emulation failed. Its source context included only tracked platform and blog
files. The exact image passed crypto, ES256 verification, Markdown, image-library
and pending/stalled/confirmed launch-card checks. Local preview files were absent.
The isolated migration app's read-only check reported no pending or missing
migrations; no migrations were applied, and its temporary machine was removed.

After rollout, Fly health and the public home, Create, token list and all four
existing auction pages passed. The browser-agent listing returned AGI, JollyB,
BITE and RDOG, and the production Privy sign-in modal opened. Read-only chain
checks confirmed all three v1 launch entry points paused and all three v2 entry
points open. Base and Robinhood v1 interaction bindings loaded. Runtime
descriptions, environment and machine capacity matched their pre-release values.

The v80 changelog records the actual build. Verification receipts and browser
evidence are under workspace `artifacts/autolaunch-sol-1009/`. Real sign-in
completion and wallet acceptance remain founder checks. Template-first session
expiry, wallet wording and the launch film remain separate work.
