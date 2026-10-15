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
