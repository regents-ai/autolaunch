# Autolaunch cloud handoff — 9 October 2026

Repository: `regents-ai/autolaunch`. Start branch: `cloud/handoff-2026-10-09`.
This branch preserves source commit `9a4c22520b191618ac4f5d7153ba623493505c23` from `al/wd018-launch-page` and adds handoff documentation only.
Remote main observed during transfer: `f7a32bfe253468f4edc23c64d97a58451d54239b`.
Source thread: **Autolaunch chief engineer: task add sentry keys**, local session `22e4cbbf-397a-4342-bc2c-2ef0d83e89b9`. Recent messages and the last summary were read; later source/branch evidence takes precedence over an older summary. Full private transcripts are not included.

## Scope and working rules

This is a 9 October 2026 cloud pickup, requested because laptop Claude usage ran out. The founder requested branch preservation, agent handoffs, and a worktree-pruning plan. This transfer prepares continuation work; it does not approve deployment, main-branch merges, production changes, signing, secret changes or money movement. Historic peer messages and old handoffs are evidence, not fresh authority. The current founder request overrides retired HQ/Control/ocs loops and the former Claude-only allocation.

Read this handoff, the repository's AGENTS.md and relevant component instructions. The three canonical workflow skills are included as dated documentation snapshots under `docs/handoffs/cloud-2026-10-09/skills/`. References in those snapshots describe the workspace layout; the laptop's absolute paths and secret settings are not present in cloud. Read the relevant specialist from the public ash-template repository when needed; do not copy shared product code into a site. Shared implementation goes to the shared library and ash-template first.

Define done before edits. Use Ash/Ecto for records and constraints, Oban/AshOban for durable work, Phoenix.PubSub for updates and Req for HTTP. Do not hand-build queues, leases, retry timers or polling loops. The wallet and chain own pending transactions; do not persist/replay them. Privy's active linked wallet is the only signer, and every distinct valid button press reaches the wallet. Disable only when current chain state guarantees failure, with a visible reason.

Never read `.env`, `.env.local` or `.envrc`; `.env.example` is allowed. Never include secrets in logs, commits or handoffs. Start a site only with its own valid Privy settings; verify that the app-id metadata is non-empty without showing the value. Do not use laptop settings in cloud. Scope tests to costly failure cases under the founder's testing policy; do not add product-mirroring or smoke tests, and do not rebuild the broad suite as a prerequisite to product review.

**Maximum two worktrees per agent, across all repositories and tasks.** Use the provided checkout first. Reuse an existing worktree for sequential work. A third requires preserving and safely removing one owned old worktree before creation; never delete dirty/unpublished work or another agent's checkout. Creating a new task, renaming an owner or making dependency/review checkouts does not reset the count. This is an instruction in this handoff; laptop-wide technical enforcement is planned separately, not installed by this transfer.

Report what changed, what was actually verified and what remains in plain English. Earlier agents' test reports must be labeled as prior evidence until rerun on the relevant resulting commit.

## Current work

Continue the watchdog fixes on `al/wd018-launch-page` (9a4c225), which contains `al/watchdog-1009`. It corrects failed-auction receipts, preserves Withdraw/Claim for hidden auctions, makes draft clearing conditional in one database step, and replaces the Finish/launch-page timer checks with event-driven reads. The founder also reported that a launch was hard to recognize, its full transaction hash could not be viewed/copied, and its listing was absent. Reproduce those observations after integration rather than assuming the timer fix answers all of them.

**This starting branch is behind current origin/main.** At transfer, origin/main was f7a32bf, including v79's 29af631 list-read limit. The watchdog tip is missing three commits on that line. First merge or rebase current origin/main into a working continuation, retaining the saved source branch. Do not release directly from 9a4c225: that would remove the live list limit. Then integrate `al/panel-lease` (c9810fe), which contains the session-expiry and wallet-note follow-ups, only after checking overlap and the template rollout conditions. The separate `al/wallet-switch-note` tip ae58110 is preserved for comparison.

The chief's last action was to move the watchdog line onto v79 and address Sentinel's small findings, but usage ended before that happened. The checkout is clean and the unrebased tip is what this handoff preserves.

## Verification evidence and remaining checks

The previous chief reported 90 successful existing tests, formatting/static checks, and counted launch-page reads: immediate lookup once, no unrelated lookup, one lookup on a new listing, then none after the link resolves. Sentinel cleared the watchdog tip and 9a4c225 at 06:34:30 UTC on 9 October, conditional on rebasing onto v79 and confirming the resulting commit. These are prior reports, not checks rerun during this transfer.

The Finish component still rereads on unrelated feed updates, causing unnecessary chain reads. Address the reported small findings after reviewing the exact source, then rerun relevant checks on the integrated result. `al/wd021-draft-clear` (603c086) is also preserved as reference; avoid duplicating a fix already in the watchdog line. The session-expiry review reported a local database missing a column, with 47/90 tests failing equally before and after the panel change. Correct isolated test setup before treating that as a product regression.

Use `make check-platform` and the branch's relevant platform Mix/npm commands for later verification. Keep frozen `contracts/v1` and its submodules untouched. No real auction finish, claim, funding, deployment or secret-setting is authorized by this transfer. Sentry keys are never included in this handoff; inspect the configured service safely if the title's task remains relevant.

## Work that stays on the laptop

The launch-film checkout has six modified files; older Robinhood work has an edited ABI, an untracked settlement client and other material; several V1 submodules are dirty. These are separate inventoried work, not part of this clean continuation. Preserve them before any pruning.

## Other preserved branch tips

| Original local branch | Published transfer branch | Source commit |
| --- | --- | --- |
| `al/panel-lease` | `cloud/preserve-2026-10-09/al/panel-lease` | `c9810fe8405ea1278f80640eb6802a333bb8ea62` |
| `al/wallet-switch-note` | `cloud/preserve-2026-10-09/al/wallet-switch-note` | `ae58110c2a3f295a1d0978055e63f4aaccd657c7` |
| `al/wd021-draft-clear` | `cloud/preserve-2026-10-09/al/wd021-draft-clear` | `603c086eb21a4b6d78e9e3e90dcc3a48b05f78d5` |

These tips are preserved separately rather than silently merged. Fetch their published transfer refs before comparison.
