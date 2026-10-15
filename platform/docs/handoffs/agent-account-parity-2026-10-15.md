# Autolaunch agent account parity — 15 October 2026

## Scope and status

Local candidate on `sol/agent-account-parity-1015`, based on released `09b69da` (Fly 130). No push or deployment. The dependency rollout is complete and separate.

Done for this slice: copy ash-template's account projections, align the owning API/CLI/browser descriptions, review privacy and compatibility, and exercise representative reads without signatures or money movement. Successful signed account reads and draft writes remain acceptance gaps; this is not release clearance.

Design check: existing Ash actions/policies own reads and authorization; Phoenix JSON owns presentation; RegentPoints.Amount owns display units; existing shared SIWA owns transport. No new background work, state, transport or authorization abstraction.

## Changes

- `platform/lib/autolaunch_web/controllers/agent_account_controller.ex`: template Points decimal-text projection and reduced entry fields; template Credits history pagination; template balances and disabled-feature notes. Existing actor resolution, Ash policies, errors and input rejection remain intact.
- `platform/contracts/api-contract.openapiv3.yaml` and its exact `cli/docs/` copy: typed account response envelopes; public/private distinction; correct V2 allocation and token-address descriptions.
- `platform/priv/tool_manifest.json` and `cli/commands.json`: history instructions use `pagination.next_cursor`.
- `cli/COMMANDS.md` and `platform/lib/autolaunch_web/public_documents/agents.md`: actual response fields, display precision, pending event count and disabled notes.

Canonical implementation: ash-template `c720b2`, `platform/lib/ash_template_web/controllers/page_tools_controller.ex`. Points are truncated to two decimal places by the shared formatter. Pending is an event count. This changes presentation, never the ledger.

## Compatibility and privacy review

The signed account response change is intentionally visible to clients: `balance_micro`/`earned_today_micro` become `points`/`earned_today`; `allowances` becomes `daily_allowances`; `more?` becomes `more`; entry fields become `points`, `source`, `by`, `earned_at`. History's `more?`/`next` move to `pagination.has_more`/`pagination.next_cursor`. Balances no longer repeats account/pairing identifiers or top-level grant availability; availability remains under `spending_grant`.

Coordinate consuming clients before release. The installed unified CLI's public commands were exercised, but its signed-account field handling was not established. The five public operations retain their response shapes. OpenAPI's public API major is unchanged; these previously untyped private response changes require explicit compatibility review before publication.

No caller can supply an account owner or bypass pairing through these edits. Points no longer returns actor IDs or internal rule/reason identifiers. Credits history retains the shared library's restriction on another agent's private request data. Notes reflect existing flags; they do not toggle earning or grants.

## Verification matrix

| Flow | Evidence | Result / boundary |
| --- | --- | --- |
| Account projections | One-off source-derived projection check, real Phoenix JSON/shared formatter, synthetic summaries | Fractional/negative amounts, fields, disabled notes, cursor/end-page cases pass. This substitutes shared read results and is not a database or authentication test. |
| Unsigned account reads | Actual local Endpoint requests | Points and balances refuse with 401; no broker proof supplied. |
| Draft financial fields | Actual controller validation | Both draft kinds reject `chain` and `treasury` with 422 before data access. |
| Existing unpaired draft access | Separate read-only local policy probe | Both draft kinds refuse reads and saves through actual controller/Ash policies. No pairing is created, removed or revoked; this does not prove a revocation transition. |
| AIFROG auction/list/detail | Native browser WebMCP on production, fresh handles | 200, graduated, Base, auction `62d69bba-758b-47d9-b02d-de5e7019c11f`. |
| SANDY auction/list | Native browser WebMCP on production | 200, graduated, Robinhood, auction `2c2d3ccf-4545-4cc1-a045-fb3d46d1218c`. |
| AIFROG and SANDY tokens | Native browser WebMCP | Both listed, matching auction IDs and chains. |
| AIFROG closed-auction quote | Native browser read-only estimator | `auction_not_biddable`, inactive, estimated tokens zero; no wallet action. |
| Navigation | Auction → token page, refetch native handles, execute token read | Pass; no browser errors. Temporary tab closed. |
| Draft preparation | Native `prepare_agent_request` | Metadata produces PATCH bytes only; chain input refused. No signature or save attempted. |
| Installed CLI and HTTP | Regents CLI 1.10.2 public reads plus independent HTTP | AIFROG auction and SANDY token identities/pagination match browser results. |
| Private account success / positions | No signed private request executed | Unverified. Existing isolated test DB lacks both shared Credits and Points schemas. |
| Draft save / revocation transition | Mutation fixture script blocked before execution | Unverified; no retry. |
| Launch / bid / swap / stake / withdraw / claim | No matching executing agent commands in current manifest | Person-controlled website wallet flows, not agent acceptance. No signing or value movement. |

Existing CLI checks pass: six CLI cases, one five-public-operation adapter comparison, exact contract copy. Scoped Elixir compilation with warnings treated as errors, formatting, frontend typecheck and whitespace checks pass. Points sample validates against JSON Schema 2020-12; all three new response schemas are structurally valid. No new test files or databases.

Evidence directory: `/Users/sean/Documents/regent/artifacts/autolaunch-agent-parity-1015/`. It contains projection source/log/response, parsed contract, unsigned refusal results, installed CLI and HTTP JSON, identity comparison, and the non-mutating unpaired probe. Native tool results are in this chat's browser tool trace; they were real host calls, not mocked registrations. The projection probe emits expected warnings because its shared read calls are replaced by fixed results; production compilation is warning-free.

## Remaining gaps

1. A successful authorized private account read, including a nonempty history page, is required before release clearance. No available local shared schemas or signed session was used for this.
2. Automatic approval review rejected the draft fixture script as destructive because it contained a deletion to simulate revoked pairing. It was not executed or retried. Draft mutation and actual revocation remain unverified.
3. Installed unified CLI must adopt the corrected history wording and validate the changed signed response fields. The standalone CLI supports public reads and owner-profile commands, not these signed account commands. A source description is not a published CLI release.
4. SANDY's live API reports minimum_raise `0.000000000026969531` SNDK while quote decimals are 18. This is suspicious, not yet a confirmed defect: verify the stored requirement against the chain before changing units or data. No production data was changed.
5. Token list has no canonical page URL or token-detail operation; details require website navigation. Agent positions use the owner's verified wallet, while the person can select another linked active wallet. These are existing product parity gaps, not repaired here.
6. Native and installed-CLI public reads passed. Signed private end-to-end acceptance, wallet flows and full creation/management parity did not. Base-only Revstake creation and Robinhood memestock-only creation remain unchanged; historical withdrawals and claims are preserved.

## Independent external acceptance reported by coordinator

At 04:38–04:40 UTC on 15 October, Contessa used an existing paired identity through CLI 1.10.2 (with a SOCKS dependency workaround): existing Memestock draft read passed; auction pagination preserved filters and returned a different record; an invalid limit returned a structured error and correct exit; Credits history returned two entries with the old deployed shape. These are live pre-candidate observations, not acceptance of this local response repair. The clean-install CLI dependency problem belongs to the shared CLI owner. No new identity, pairing or draft mutation was reported.

## Independent compatibility and privacy review

The coordinator relayed completion of the independent review by
`/root/keyfleet_notebook_security` on 15 October 2026. Reviewed candidate:
`32b96189abe16ee80f447b0637f85e594ef1e4fd`, against released `09b69da`.
The implementation patch matched SHA-256
`b5d67a78b97b48948a76cb2fd54921137c0ff1c13cc5fc8161aa6d200448e21f`.

No new authorization bypass or private-data disclosure was found in that diff.
The Points, balances and history projections match the explicit ash-template
`c720b2d` reference. This finding covers the reviewed source; it does not establish
successful signed execution or compatibility with every external consumer.

The material release dependency is confirmed: published unified CLI 1.10.2 still
describes a top-level history `next` cursor and has no automatic pagination
descriptor for this operation. Its generic renderer tolerates the new response
shape, but its guidance would be wrong after this candidate is deployed. The
candidate also intentionally removes repeated IDs, renames Points fields and
nests history pagination, as listed above.

**Release remains on hold** until the CLI adopts the corrected guidance or an
explicitly reviewed shared compatibility plan resolves that dependency. Other
external consumers and successful signed, nonempty history on this candidate
remain unverified. Do not describe this candidate as fully compatible or released.
The reviewed implementation is preserved unchanged; this follow-up only records
the review. Unchanged implementation checks were not rerun.

## Local cursor and installation follow-up

Follow-up base: `d14263d`; original implementation `32b96189` and its saved patch
remain unchanged. Adopted template cursor behavior from `a7bfd9b` and installation
guidance from `3d116822`. These template changes are local and unpublished.

- History now returns 422 `invalid_cursor` for a non-string `after`, Ash's
  invalid-after argument errors and invalid-keyset errors. Only nonempty nested
  lists consisting entirely of those errors qualify; unrelated, mixed and empty
  error classes keep the existing 503 `account_unavailable` response.
- The recovery message/hint matches the template. Autolaunch still rejects extra
  body fields with `invalid_request`; its POST route and exact signed bytes stay
  unchanged. Ash retains responsibility for length and keyset validation.
- Both browser input schemas and the OpenAPI request declare `maxLength: 2048`.
  CLI descriptions and guides explain the limit, `pagination.next_cursor`, and
  omitting `after` when the cursor is null. No automatic private pagination or
  new signed GET alias was invented.
- `agents.md` and `llms.txt` use the reviewed installation command
  `uv tool install --with 'httpx[socks]' regents-cli==1.10.2`, distinguish the extra
  from a repaired published wheel, and preserve signer/key-creation cautions.
  The guide records the same reviewed source revision and wheel hash as template.

Affected validation passed: scoped warning-free compilation and formatting,
frontend typecheck, the existing five-public-operation adapter comparison, exact
CLI contract copy and whitespace check. One-off diagnostics exercise actual Ash
2048/2049 input validation and malformed-keyset errors, nested/mixed/empty error
classification, five direct non-string controller refusals, extra-field refusal,
and the canonical recovery hint. The actual shared request-preparation adapter
accepts empty and 2048-character inputs, rejects 2049/non-string inputs and preserves
POST/path/body exactly. Local Endpoint requests serve the updated guide and OpenAPI;
JSON Schema 2020-12 validates the actual refusal JSON and input boundaries.

Evidence: `cursor-diagnostic.exs`/`.log`, `cursor-adapter-check.mjs`/`.log`,
`cursor-contract.json`, `cursor-error.json`, and `cursor-schema-check.txt` in the
existing artifact directory. These are local diagnostics, not successful signed
HTTP or private multi-page acceptance. No database fixtures, migrations, signing,
production changes or retries of the rejected deletion script occurred.

The installed CLI's help was read directly: 1.10.2 still tells users to use the
previous page's top-level `next`. Published CLI guidance/packaging and successful
signed candidate history across a page boundary remain explicit release holds.
The original response compatibility review does not clear this new follow-up.

### New template entry-schema finding

Do not copy the history entry fields from template `8e1a60e`: its required
`operation`, `available_delta` and `held_delta` do not match the final entries in
the pinned shared library. Immutable `28783ed:credits/lib/regent_credits/history.ex`
in `worktrees/ui-standardization/eu` confirms final entries contain `id`, `kind`,
`at`, `amount`, `direction` and nullable facts. Autolaunch's `b582404` behaves the
same. The template owner corrected this in local commit `5654a42`. Autolaunch retains
its valid generic shared-entry schema; importing more detailed typing is not
required for this candidate. The pagination envelope and cursor fix are unaffected.


## Final independent review and release hold

On 15 October 2026, the coordinator relayed the independent review of
`ef05f93ccbcce3e45b8faf68a157589ebbd2318d` against `d14263d`, matching follow-up patch
SHA-256 `5976a87c74e2687dc7047c3908fbba2e9952171c5096690f428823df4fccb217`.
No concrete regression was found. Review covered cursor-only error classification,
strict unknown-field rejection, unchanged account-unavailable/authentication/owner
behavior, 2048-character constraints and canonical installation guidance. The
generic history-entry schema is valid and needs no expansion for this candidate.

Both original `32b96189` and follow-up `ef05f93` remain local and held for release
and client adoption. Actual signed private history across a page boundary and
published CLI compatibility remain unverified. The coordinator will resolve
release authority separately. This documentation-only update preserves both
reviewed patches; no unchanged checks were rerun, and nothing was pushed or deployed.
Unrelated untracked work remains untouched.


## Bounded workflow completeness audit — 15 October 2026

Reviewed Autolaunch `b5bae84` (implementation remains `ef05f93`), its actual native-tool registration source, standalone CLI source, unified CLI descriptions and installed `regents 1.10.2` help. This is a read-only source/command-discovery audit; it adds no new signed, database or live-browser acceptance. Earlier native AIFROG/SANDY evidence above remains limited to the operations actually exercised. No product source changed.

Design check: Ash actions/policies own discovery and saved drafts; Phoenix exposes them through existing routes; shared SIWA transport owns per-request proof. This audit proposes no new queue, identity store, polling loop or wallet executor.

### Concrete gaps and smallest repairs

Paths below are relative to this repository unless marked template.

| Gap | Evidence and consequence | Smallest repair |
| --- | --- | --- |
| Token discovery has no canonical page URL and no single-token detail operation. | `platform/lib/autolaunch_web/controllers/token_controller.ex:26` returns only a summary, identifiers and treasury report. `router.ex:130` registers only the token list; native requests at `assets/js/public_tools.ts:218` and CLI descriptions at `cli/commands.json:192` do the same. Installed 1.10.2 `tokens --help` exposes only `list`. Meanwhile `lib/autolaunch/token.ex:179` already has the policy-filtered `public_by_id` read, and `live/token_live.ex:94` displays details, rewards, pool information and exact price. Agents cannot directly retrieve one token's structured detail or follow the advertised token `url`. | First return the existing canonical `Paths.token_url` in token summaries and its schema. Add a bounded public detail adapter over the existing public read, then mirror it in the manifest and CLI descriptions. Reuse existing pool reads only for fields explicitly included; distinguish unavailable/current versus stored data. Do not expose wallet writes or the unfiltered projection action. |
| The copied agent guide advertises financial tools that are not registered. | `public_documents/llms.md:31` says use tools on auction/token URLs to bid, trade, stake and launch. The same document at line 159 correctly says these controls are not agent tools. `live/how_it_works_live.ex:19` and `:28` copy this entire guide through Copy to Agent; `public_documents.ex:131` identifies its source. The manifest contains reads, metadata edits and proof preparation, not transaction tools. | Rewrite first step 3 as a handoff to the person's visible page controls. Point metadata preparation to the existing signed draft commands. Keep user signatures and owner-controlled creation gates explicit. Fix the shared guidance pattern in template first if it carries the same wording, then adopt locally. |
| Standalone profile documentation names nonexistent native profile tools. | `cli/docs/private-profile.md:4` advertises `profile_get`, `profile_sync`, `profile_update`; `cli/README.md:85` repeats native parity. None is in `platform/priv/tool_manifest.json`; `assets/js/public_tools.ts:230` registers only this manifest's supported entries. `/api/v1/profile` remains a separate owner-Privy route (`router.ex:121`), and the installed unified CLI explicitly excludes profile mutation. | Correct the two standalone documents to describe owner-credential CLI/HTTP access only. Do not register owner profile mutations as paired-agent tools merely to match stale prose. Use template's owner/agent distinction. |
| Pairing-code redemption is available to CLI/HTTP but absent from native tools. | `cli/commands.json:326` and installed `agents pair --help` expose the signed existing `/api/agents/v1/pair` operation. The native manifest has whoami/status but no pair operation (`tool_manifest.json:260`, `:316`, `:941`); signed preparation builds its operation set from that manifest (`assets/js/public_tools.ts:15`). Native-only callers cannot prepare/redeem the owner-issued code through this registry. Template currently has the same omission. | Coordinate the common decision with ash-template: either provide its existing signed pair operation in the canonical native manifest, retaining owner-issued code and proof checks, or clearly require the CLI/HTTP pairing step before native use. This is an adapter coverage limit, not evidence of an authorization bypass. No automatic pairing or new keys. |

### Coverage and intentional limits

| Workflow | Source chain / coverage | What remains unproven or intentionally excluded |
| --- | --- | --- |
| Auction/token search, filters and pagination | `MarketPage.read/2` (`market_page.ex:18`) calls `HomeMarket.read_records`; `home_market.ex:78` and `:86` use Ash `:home_market` reads. Both list controllers, native manifest and both CLI descriptions cover these reads. Earlier actual native/public CLI evidence covers AIFROG and SANDY. | No new broad live-list acceptance in this audit. Public default `state=all` is explicitly documented, whereas the website defaults to live; the filter exists and this is not missing capability. |
| Auction details, bid estimate and treasury observation | `auction_controller.ex:59` uses existing listed auction domain reads; `:75` calls `Autolaunch.quote_auction_bid`. Native requests at `public_tools.ts:218` and CLI descriptions expose these reads. | Bid estimates remain Base-only by explicit contract; a quote never authorizes or submits a bid. No new estimate or chain correctness claims. |
| Saved draft read/create/edit | Controller `agent_account_controller.ex:15`, `:24`, `:59` reads the owner's existing draft and creates only if absent. Revstake actions `launch_draft.ex:97`–`:119` and Memestock `stocks/launch_draft.ex:114`–`:136` use owner-scoped reads, partial validation and current pairing. Both kinds have native show/save and installed CLI show/save. | Read responses intentionally include metadata only (`agent_account_controller.ex:187`). Pictures, chain/stock choice, treasury, terms and launch readiness are not returned; their modification remains person-controlled. The guide promises metadata, not complete launch preparation. Successful candidate save/read round-trip and revocation transition remain unproven; no new fixture or deletion attempt occurred. |
| Positions and account | `my_positions_controller.ex:34` uses the paired owner's primary account wallet; `:75` uses `:agent_mine_by_wallet`. Human portfolio source also explicitly reads the signed-in wallet only (`live/portfolio_live.ex:3`, `:893`), so this audit does not substantiate the earlier suggested active-wallet coverage gap. Balances, history and Points are present in both interfaces. | Prior account response and cursor fixes remain frozen and held for adoption. No signed candidate history page-boundary proof. No spend approval or Points enablement. |
| Profile and pairing management | Account UI delegates profile/pairing management to regents.sh (`live/account_live.ex:98`, `:128`); owner profile HTTP remains separate. Pairing identity/status are native tools; redemption is an existing CLI command. | Owner profile edits, issuing/revoking pairings and wallet actions are deliberate human gates, not missing agent write capabilities. |
| Copy-to-agent onboarding | Copy to Agent exists on `/how-it-works` and copies `llms.txt`, which links to signed instructions; therefore it is not absent. Template's published `79c39d6` additionally contains `AgentStart` and `/start` with agent-specific copy instructions. Autolaunch has no `/start` route. | The concrete copied-text defect is listed above. Adopting the template's focused onboarding would improve shared consistency; it is a separate UI adoption, not a prerequisite for existing CLI access. No clipboard or new authenticated browser acceptance was performed. |

### Verification and release boundary

Read installed CLI version and help for Autolaunch, token commands, Memestock draft reads and pairing; all are discovery-only calls. Compared source registration and routes, rather than treating a manifest or help entry as proof of successful signed execution. Standalone npm publication remains unverified. Existing published CLI 1.10.2 history-cursor wording and SOCKS-install limitation remain as recorded above.

No tests, fixtures, signatures, transactions, Points settings, database contents or product source were changed. The automatically rejected deletion script was not retried. Findings propose follow-up work only; `ef05f93` and both immutable review patches remain unchanged. Shared pairing/onboarding changes belong in ash-template before site adoption.


### Targeted UnexpectedFailure logger check

Autolaunch does not use `UnexpectedFailure` in the reviewed candidate or published `09b69da` application source. Candidate `agent_account_controller.ex:136` handles returned history errors by classifying cursor failures; unrelated or mixed errors go directly to `unavailable/1`, which returns a fixed 503 message. `api_error.ex:16` serializes that fixed response and does not log the underlying error. Published `09b69da` likewise sends failed history results directly to the fixed unavailable response. No matching helper or call was found in application source.

Therefore the reported template/Patchbay returned-error logger leak does not apply to this Autolaunch history path, and no helper adoption is queued solely for it. If later template adoption introduces unexpected-error logging, use the corrected canonical class/correlation-only implementation. This narrow source check does not assess framework exception logging or all dependencies and establishes no live incident. No private/live logs were read and no product code changed.


## Proposed token detail projection — not implemented

A material limit surfaced while tracing the proposed adapter: existing
`Autolaunch.get_public_token/1` → `Token.:public_by_id` is Base-only when Robinhood
is configured. `Token.Preparations.SiteCreatedAuctionOnly` explicitly excludes
that chain. The earlier audit's suggestion to reuse this read does not, by itself,
cover SANDY. Do not route Robinhood through an unfiltered read or silently claim
both chains.

Minimal existing-action proposal: `GET /api/v1/tokens/{id}` with one token UUID,
using `get_public_token(id, actor: nil)`, explicitly documented as Base-only.
Unknown, hidden, external-origin or Robinhood records remain 404. Malformed UUID
and extra parameters retain structured input errors. No endpoint is implemented
or approved here. Before choosing this limited surface, decide whether a useful
first release must support both chains; that would require a separately reviewed
read action with the existing `ListedAuction` and `ShownAuction` preparations,
not broadening existing callers or bypassing their policies.

| Public field | Existing source | Cost / meaning |
| --- | --- | --- |
| Current token summary fields, including `url` | Existing `TokenController.public_token` projection; `Paths.token_url(token.auction)` | Reuse the loaded token, its listed auction and safe treasury projection. No struct serialization. |
| `auction_url` | `Paths.auction_url(token.auction)` | Existing canonical path helper; no extra chain read. |
| `price_quote`, `price_updated_at` | Public stored Token attributes | Decimal string or null, with nullable recording timestamp. A stored observation, not a current executable quote. |
| `quote_token` (`address`, `symbol`, `decimals`) | Loaded auction's public quote-token fields | Same explicitly projected denomination as auction API. |
| `token_supply` | Loaded auction's public `token_supply` | Exact whole-token decimal string or null. |

This first projection needs one bounded Ash record read, its existing relationship
loads and canonical path-tail calculation (which may perform the existing batched
peer lookup). It performs no RPC, live pool read, polling, new cache or background
job. It excludes swaps, rewards/claimability, current liquidity, transaction data,
creator account IDs, trade-index cursors and raw treasury records. Native/CLI
adapters and OpenAPI must be added together only after the action/chain scope is
settled. No new generic detail framework is proposed.


## Local guidance and token URL follow-up

Prepared a separate follow-up above `b5bae84`; earlier `ef05f93` is unchanged.
The copied guide now sends the person to visible financial/launch controls and
points agents to metadata-only draft commands. Standalone profile documents now
accurately describe owner Privy credentials, without claiming native or unified
paired-agent profile tools. No registrations, permissions or signing changed.

Token summaries now include `url: Paths.token_url(token.auction)`. Their existing
auction relationship uses `:listed`, which already loads `:path_tail`; no new
relationship load, RPC or database query was added. The owning OpenAPI Token
schema and exact bundled CLI copy require the new URI field. There is still no
token-detail endpoint; the proposal above is deliberately unimplemented.

Validation: platform compilation passed; rebuilding dependencies emitted an
existing ErrorTracker navbar `target` attribute warning. Scoped formatter and
whitespace checks passed. CLI contract-copy check passed. The actual canonical
path helper returned the expected AIFROG and SANDY URLs. The generated Copy to
Agent document contains the corrected boundary and no obsolete financial-tool
instruction. These final checks initialized Phoenix endpoint URL metadata without
an HTTP listener, database, application jobs or wallet actions. Two initial local
check setup errors (endpoint not initialized, then the PubSub start API) were
corrected before the successful check; they were not product failures.

No new tests or fixtures were added. No new live HTTP, signed-save or full token
controller/database acceptance is claimed. Existing native and CLI adapters pass
response JSON through unchanged; external consumers validating the old closed
Token schema may reject the added field and must adopt the updated contract.
Published/deployed content still needs the separately authorized release.
Shared pairing and `/start` decisions remain outside this candidate. The exact
misleading financial/profile wording was not found in the template guidance
searched, so these prose fixes stay product-local. The earlier audit findings are
historical; only these named guidance issues and token URL are addressed here.
