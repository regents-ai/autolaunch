# Public WebMCP tools

Autolaunch registers five read-only tools when `document.modelContext.registerTool`
is available. Browsers without it retain the normal interface. This targets the
[4 September 2026 WebMCP Draft Community Group Report](https://webmachinelearning.github.io/webmcp/),
which is not a W3C Standard, and Chrome's
[imperative API guidance](https://developer.chrome.com/docs/ai/webmcp/imperative-api).
There is no older `navigator.modelContext` fallback.

| Tool | Input | Existing HTTP contract |
| --- | --- | --- |
| `autolaunch_auctions` | Optional `q`, `state`, `sort`, `chain`, `kind`, boolean `x`, `ens`, `github`, integer `limit`, `after` | `GET /api/v1/auctions` |
| `autolaunch_auction` | Auction UUID `id`, or a Robinhood auction's address | `GET /api/v1/auctions/:id` |
| `autolaunch_tokens` | Optional `q`, `chain`, `kind`, boolean `x`, `ens`, `github`, integer `limit`, `after` | `GET /api/v1/tokens` |
| `autolaunch_treasury` | Treasury `address` | `GET /api/v1/treasury-security/:address` |
| `autolaunch_bid_quote` | Auction UUID `id`, decimal strings `amount`, `max_price` | `POST /api/v1/auctions/:id/bid-quote` |

The list options are the website's own, read through the same discovery as its
auction and token lists (`Autolaunch.HomeMarket`), with the same names and meanings in
the API, the CLI and these tools:

| Option | Values | Lists |
| --- | --- | --- |
| `q` | The website search: every word in a name, ticker, stock, description, address or verified account; a leading `$` is ignored; the API collapses spaces and keeps the first 80 characters | auctions, tokens |
| `state` | `all`, `created` (opening soon), `active` (live), `ended` (waiting to be finished), `failed`, `graduated` (launched) | auctions |
| `sort` | `newest` (most recently listed), `ending` (live only, closing soonest; the website's Closing), `volume` (highest dollar bid volume, unrecorded last; the website's Highest) | auctions |
| `chain` | `all`, `base`, `robinhood` | auctions, tokens |
| `kind` | `all`, `revstake` (entries with kind `agent`), `memestake` (entries with kind `stocks`) | auctions, tokens |
| `x`, `ens`, `github` | `true` keeps only creators verified on that account; several must all hold | auctions, tokens |

The API refuses an unknown parameter, a repeated or list-shaped one, or a value outside
these with a 400 `invalid_request`; the tools refuse them first as `invalid_input`.
Booleans are JSON booleans in the tools and exactly `true` or `false` in the API. List limits are safe JavaScript integers. The API
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
Each execution also observes the agent's cancellation signal when the host passes
one as `signal` on the second argument, native or polyfilled (anything with a
boolean `aborted` and abort-event listeners). Hosts that pass no second argument,
a client object without `signal`, or `{signal: undefined}` still execute; only the
page lifetime can then cancel the read.

## Verification

From `platform/`, after `mix assets.build`: `npx tsc --project assets/tsconfig.json --noEmit`.
From `cli/`, `npm run test:parity` imports this adapter, registers it through a
simulated `document.modelContext` and compares every tool's request and result with
the CLI against a local HTTP fixture. That proves the adapter and CLI agree, not
native browser-agent discovery or permissions; native API availability is reported
separately.

## Auction figures

Every auction entry, listed or read alone, carries the figures the website's cards
show, from the same stored record and the same code:

- `url`: the auction's page on the site.
- `estimated_end_at`: when bidding is expected to close, from the end block.
- `token_allocation`: whole tokens sold (10 billion for a Revstake, 800 million for a Memestake).
- `bid_volume`, `bid_volume_usd`: everything bid so far, in quote-token units and in dollars.
- `minimum_raise`, `currency_raised`, `percent_met`: the launch threshold, what is raised, and
  the whole percent met (rounded down, capped at 100).
- `record_updated_at`: when the site last wrote its stored record. The site's own scheduling
  of chain reads writes it too, so it is not the time of the latest chain reading; the site
  keeps no such time.

Amounts are exact decimal strings. A figure the record does not hold is null, and
`unavailable` maps it to `not_recorded_yet` (the chain readers have not recorded it),
`chain_unreadable` (Robinhood's last chain read failed, so an amount it never recorded
cannot be read now) or `no_usd_price` (the volume was recorded without a dollar price).
Base's reader does not report a failed read separately, so its missing figures are always
`not_recorded_yet`.

## Complete listings

Auction and token responses include `pagination.has_more` and `pagination.next_cursor`.
Pass `next_cursor` unchanged as `after` with the same options to continue; a cursor
read with other options is refused. The CLI
uses `--after`; the website has Next page and Back to newest links. API auction pages contain at most 50 entries across both chains (24 on the website);
token API pages retain the 100-row cap. Every option applies to both chains. When Robinhood cannot be read, `robinhood_unavailable`
is true and its entries show what was last read from it. Cursors expire after
24 hours; a 400 means restart the listing. Ordering includes an ID tie-breaker and
handles nullable auction dates. New arrivals ahead of the cursor appear on restart;
continuation is not a frozen database snapshot.
