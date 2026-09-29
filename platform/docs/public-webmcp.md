# Public WebMCP tools

Autolaunch registers five read-only tools when `document.modelContext.registerTool`
is available. Browsers without it retain the normal interface. This targets the
[4 September 2026 WebMCP Draft Community Group Report](https://webmachinelearning.github.io/webmcp/),
which is not a W3C Standard, and Chrome's
[imperative API guidance](https://developer.chrome.com/docs/ai/webmcp/imperative-api).
There is no older `navigator.modelContext` fallback.

| Tool | Input | Existing HTTP contract |
| --- | --- | --- |
| `autolaunch_auctions` | Optional `mode`, `sort`, integer `limit`, `after` | `GET /api/v1/auctions` |
| `autolaunch_auction` | Auction UUID `id` | `GET /api/v1/auctions/:id` |
| `autolaunch_tokens` | Optional integer `limit`, `after` | `GET /api/v1/tokens` |
| `autolaunch_treasury` | Treasury `address` | `GET /api/v1/treasury-security/:address` |
| `autolaunch_bid_quote` | Auction UUID `id`, decimal strings `amount`, `max_price` | `POST /api/v1/auctions/:id/bid-quote` |

Auction modes are `all`, `biddable`, `live`, `failed_minimum`, and `graduated`;
ordering is `newest` or `oldest`. List limits are safe JavaScript integers. The API
clamps auction limits to 1–50 and token limits to 1–100; the adapter does not clamp.
The quote API accepts positive decimal strings with optional fractional digits,
trims whitespace, and limits the trimmed input to 100 bytes. Its installed Decimal
parser also enforces its own bounds (currently 34 significant digits). The adapter sends the
original strings. It never converts monetary values through JavaScript numbers or
applies wallet-only decimal or integer limits. The API validates identifiers,
address checksums, decimal values, and auction rules. Dot-only path segments are
rejected before URL construction.

HTTP results are `{ok, status, body}`. `body` is the complete parsed API response,
including its `data` or `error`, exact strings, and warnings. For example, a closed
auction may still produce a quote with `auction_not_biddable`. A `supported_safe`
classification must not override `awaiting_current_chain_confirmation` or
`projector_refresh_not_integrated`.

Adapter failures are `{ok: false, error: {code, message}}`, with codes
`invalid_input`, `aborted`, `network_error`, or `invalid_response`. A non-JSON HTTP
response also includes `status`. Network exception details are not returned.

Tools read stored public projections with credentials omitted, same-origin mode,
and redirects refused. Quote POSTs calculate estimates; they do not prepare bids,
open wallets, submit transactions, or fetch chain data. No private account data or
portfolio operations are exposed by these public tools. Tool results
are marked read-only and untrusted, since public titles and summaries may contain
user-authored text. Output does not depend on which visual disclosures are open.

Installation is idempotent for the document. `pagehide` aborts registration signals
and outstanding reads; `pageshow` starts a fresh registration lifetime. Failed
registrations produce a console warning and are retried on the next page lifetime,
not on duplicate initialization. Late promise completion cannot alter newer tools.
Each execution also observes the agent's cancellation signal.

## Verification

Use the prepared worktree environment and its isolated local database. Run the
relevant controller tests and `mix assets.build` from `platform/` with the selected dependency paths.
The focused frontend checks are:

```sh
npm test -- assets/test/public_tools.test.ts
npm run typecheck
```

After the prepared database has been created and migrated, run through the same
worktree runner:

```sh
npx playwright test --config playwright.public-tools.config.ts
```

This dedicated configuration requires the prepared `PORT`, `MIX_TEST_PARTITION`,
and `PGDATABASE`, validates the local test database before seeding, and starts its
own server. It creates only synthetic records and stored stub treasury evidence;
it never contacts an RPC provider or clears other records.

The browser suite uses a simulated document registry with the draft's asynchronous
registration and abort contract, then executes the production adapter against the
real local HTTP routes. This proves the UI adapter and HTTP integration, not native
browser-agent discovery or permissions. Native API availability is reported
separately. Frontend tests cover duplicate installation, rejected/late registration,
malformed input, path normalization, network/API failures, and cancellation races.

## Complete listings

Auction and token responses include `pagination.has_more` and `pagination.next_cursor`.
Pass `next_cursor` unchanged as `after` with the same mode/sort to continue. The CLI
uses `--after`; the website has Next page and Back to newest links. Auction pages
retain the existing 50-row cap and token pages the 100-row cap. Cursors expire after
24 hours; a 400 means restart the listing. Ordering includes an ID tie-breaker and
handles nullable auction dates. New arrivals ahead of the cursor appear on restart;
continuation is not a frozen database snapshot.
