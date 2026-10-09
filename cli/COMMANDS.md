# Autolaunch signed commands

These descriptions belong to the unified `regents autolaunch …` CLI. The standalone
`autolaunch` package implements public reads, not these signed commands. Importing
`commands.json` into a coordinated CLI release is required before these names are
available. Server deployment and native signer acceptance are separate checks.

Every command requires per-request SIWA proof for audience `autolaunch`. Private
account operations also require a current pairing and an Autolaunch account resolved
from the owner's verified Privy identity. Browser cookies are not agent authority.
Read `/agents.md` for pairing and recovery. No command signs a wallet transaction,
launches a token, changes treasury settings, spends Credits or approves a grant.

Private inputs go through JSON stdin. Use the installed CLI's `--help` for signing,
preparation and send options; keep codes, metadata and proofs out of arguments and
logs. Responses are JSON. The server's published OpenAPI contract defines exact
shapes; refusals retain HTTP status and `error.code`, `message` and `hint`.

## `agents whoami`

Read the agent's signed identity and current pairing without changing account data
or earning Points. Route: `GET /api/agents/v1/whoami`; no body inputs. An unpaired
agent can use it to discover pairing status.

Server: verify exact SIWA request → read signed identity and current pairing → return
the shared identity/pairing response. Requires the shared SIWA broker and Agents
schema. Invalid or unavailable proof refuses access; browser sign-in is no fallback.

## `agents pair`

Redeem the owner's short-lived pairing code with the agent's chosen name and actual
harness. Route: `POST /api/agents/v1/pair`; required stdin strings: `code`, `name`,
`harness`. This creates the named shared pairing; it grants no spending authority.

Server: verify exact SIWA request → validate and redeem the owner-issued code through
the shared pairing action → return its pairing response. Requires the SIWA broker,
Agents schema and a valid owner-issued code. Expired, used or invalid codes refuse;
request a fresh owner code rather than replaying a lost response blindly.

## `drafts revstake show`

Read the paired owner's Revstake metadata. Route: `GET /api/agent/v1/drafts/revstake`;
no body inputs. Returns `{data, kind}`; `data` is metadata or null when no draft exists.
It creates nothing and returns no financial or wallet settings.

Server: admit current paired actor → resolve its local owner → Ash `agent_read` on
the existing Revstake draft → project metadata. Requires shared identity/pairing and
the local draft table. Missing or revoked authority refuses; unavailable account data
returns `account_unavailable`. Available under the existing prelaunch read-only gate.

## `drafts revstake save`

Save one or more metadata strings to the same owner's Revstake draft. Route:
`PATCH /api/agent/v1/drafts/revstake`. Stdin fields: `name`, `symbol`, `description`,
`website`, `telegram`, `discord`, `other_link_1`, `other_link_2`, `other_link_3`.
Returns `{data, kind}` with the saved metadata and current pairing attribution.

Server: check prelaunch gate and paired actor → validate metadata-only input → in one
transaction read/create the owner's existing draft and run Ash `agent_save` → return
metadata. Requires local draft schema, pairing attribution migration and shared
pairing locks. Empty, unknown, financial or non-string fields return `invalid_draft`;
closed prelaunch returns `prelaunch_read_only`. Revocation refuses access. Repeated
saves retain one draft; concurrent saves use last-write-wins. If a response is lost,
read the draft before a fresh signed save. No launch or wallet action occurs.

## `drafts memestake show`

Read the paired owner's Memestake metadata. Route:
`GET /api/agent/v1/drafts/memestake`; no body inputs. Returns `{data, kind}` with
metadata or null. Creates nothing and returns no stock, chain or treasury settings.

Server: admit current paired actor → resolve local owner → Ash `agent_read` on the
existing Memestake draft → project metadata. Requires the shared identity/pairing
and local Memestake draft table. Refusals and prelaunch availability match Revstake
`show`.

## `drafts memestake save`

Save Memestake metadata through `PATCH /api/agent/v1/drafts/memestake`. Inputs,
response and repeat behavior match Revstake `save`. Stock selection, chain, treasury,
launch terms and wallet fields are rejected.

Server: check prelaunch gate and paired actor → validate metadata-only input → in one
transaction read/create the owner's existing Memestake draft and run Ash `agent_save`
→ return metadata. Requires its local draft schema and pairing attribution migration.
`invalid_draft`, revoked authority and `prelaunch_read_only` refuse the save; no
financial or launch gate is opened.

## `positions`

Read the owner's verified primary wallet bids and token holdings. Route:
`GET /api/agent/v1/positions`; no body inputs. Returns `{data: {bids, tokens}}` and
changes nothing.

Server: admit paired actor and verified local wallet → use existing portfolio readers
for Base bids, Robinhood positions and holdings → return the combined projection.
Requires local ownership policies, chain configuration and available chain reads.
Missing/revoked authority refuses; incomplete reads return `chain_unavailable` rather
than a partial success. Cannot bid, trade, settle, stake or claim.

## `account balances`

Read canonical Credits and the current spending budget. Route:
`GET /api/agent/v1/account/balances`; no body inputs. Returns canonical account and
pairing IDs, Credits, spending grant and whether grant approvals are available.

Server: admit paired actor → use shared Credits identity → read current grant,
24-hour usage and balance → return the account projection. Requires shared Credits
schema and pairing. Missing/revoked authority refuses; unavailable data returns
`account_unavailable`. Does not create a balance, approve a grant or spend anything.

## `credits history`

Read canonical Credits history. Route:
`POST /api/agent/v1/account/credits/history`; stdin is `{}` or optional string `after`.
Returns the shared history page with its cursor. POST is a read here.

Server: admit paired actor → validate optional cursor → call shared Credits history
action → return page. Requires shared Credits schema. Extra fields or a non-string
cursor return `invalid_request`; unavailable data returns `account_unavailable`.
Missing/revoked authority refuses. Creates no account or ledger entry.

## `points balance`

Read canonical Points without earning rewards. Route:
`GET /api/agent/v1/account/points`; no body inputs. Returns balance, today's earnings,
pending amounts, allowances, entries and whether more entries exist.

Server: admit paired actor → call shared Points summary → return the published
projection. Requires shared Points schema and pairing. Missing/revoked authority
refuses; unavailable data returns `account_unavailable`. Creates no account or reward.

## Command history and CLI handoff

9 October 2026: signed source added in `64d6cf8`. Draft reads now end in `show`:
`drafts revstake show` and `drafts memestake show`. The former bare names conflicted
with the `save` command groups and are not executable aliases. HTTP methods, routes,
operation IDs, inputs, responses and product gates are unchanged by this correction.

CLI change note: Autolaunch; renamed the two draft reads as above; no other commands
added or removed. Import the tested main commit with these descriptions. Source is
prepared for coordinated rollout; this correction performs no deployment and makes
no claim of native-agent success or successful writes under closed prelaunch.
