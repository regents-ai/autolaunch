# Public WebMCP tools

Autolaunch registers its tools when `document.modelContext.registerTool` is
available. Browsers without it retain the normal interface. This targets the
[4 September 2026 WebMCP Draft Community Group Report](https://webmachinelearning.github.io/webmcp/),
which is not a W3C Standard, and Chrome's
[imperative API guidance](https://developer.chrome.com/docs/ai/webmcp/imperative-api).
There is no older `navigator.modelContext` fallback. Pages send
`Permissions-Policy: tools=(self)`, so only this site's own pages may offer tools.

Every tool a page registers is described once, in
[`priv/tool_manifest.json`](../priv/tool_manifest.json): its name, title,
description, input schema, annotations, what it needs, whether it changes
anything, the HTTP route behind it and its `scope`: `site` for a tool every page
offers, otherwise the pages that offer it. The developer guide at `/docs`
and the agent guide at `/llms.txt` build their tool tables from it. There are
four kinds:

- **Reads on every page.** `assets/js/public_tools.ts` registers the `site`
  `autolaunch_` tools, adding only each tool's request. Five are public reads; the
  sixth, `autolaunch_my_positions`, reads the signed-in wallet's own bids and tokens.
- **Profile tools.** The three `profile_` entries describe the shared profile
  tools, which register through the shared identity package
  (`assets/js/shared_profile.ts`) and need the person's sign-in.
- **Wallet tools on the pages that have the card.** `assets/js/agent_wallet_tools.ts`
  registers each wallet tool while a card that answers it is on the page
  (see [Wallet tools](#wallet-tools)).
- **Launch tools on the create pages.** The same file registers the tools that
  read and fill the launch forms on `/create` and `/create/revstake` and press
  their launch button (see [Launch tools](#launch-tools)).

The list options are the website's own, read through the same discovery as its
auction and token lists (`Autolaunch.HomeMarket`), with the same names and meanings in
the API, the CLI and these tools:

| Option | Values | Lists |
| --- | --- | --- |
| `q` | The website search: every word in a name, ticker, stock, description, address or verified account; a leading `$` is ignored; the API collapses spaces and keeps the first 80 characters | auctions, tokens |
| `state` | `all`, `created` (opening soon), `active` (live), `ended` (waiting to be finished), `failed`, `graduated` (launched) | auctions |
| `sort` | `newest` (most recently listed), `ending` (live only, closing soonest; the website's Closing), `volume` (highest dollar bid volume, unrecorded last; the website's Highest) | auctions |
| `chain` | `all`, `base`, `robinhood` | auctions, tokens |
| `kind` | `all`, `revstake`, `memestake` | auctions, tokens |
| `x`, `ens`, `github` | `true` keeps only creators verified on that account; several must all hold | auctions, tokens |

The API refuses an unknown parameter, a list-shaped one (`kind[]=`), or a value outside
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

The public reads use stored public projections with credentials omitted,
same-origin mode, and redirects refused. Quote POSTs calculate estimates; they do
not prepare bids, open wallets, submit transactions, or fetch chain data. Read results
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

## The signed-in read

`autolaunch_my_positions` calls `GET /api/v1/me/positions` with the site's own
session cookie (`credentials: same-origin`), so it reads only the person signed in
on this site in this browser, and only the one wallet they signed in with, as the
verified session names it; the account's other wallets are not read. Signed out it answers 401 `authentication_required` with a hint to
sign in. It reads the site's records and the chain at call time; when any of those
reads fails, the whole answer is a 503 `chain_unavailable`, never a partial list.

`bids` lists Base and Robinhood bids with `bid` (the id `autolaunch_settle_bid`
takes), `standing` and `can` (`early_return`, `withdraw`, `claim` or null), and the
auction `page`. `tokens` lists holdings with `held`, `staked` (cut to four decimal
places) and `claimable` (cut to twelve significant digits), never rounded up.

## Wallet tools

`autolaunch_bid`, `autolaunch_settle_bid`, `autolaunch_buy`, `autolaunch_sell`,
`autolaunch_stake`, `autolaunch_unstake` and `autolaunch_claim_rewards` press a
card's own button for the agent. A card names the tools it answers in
`data-agent-tools` (a settlement card also names its bid in `data-agent-bid`), and
a tool is registered while such a card is on the page and removed when the last
one goes. The bid and trade cards carry them on the auction and token pages only,
not in the swap dialogs or outbid prompts.

A call pushes `agent_press` to the card's LiveView component. The component
prepares exactly what its button would send for those values, the same server
code and the same checks, and pushes that step with `send` and an `agent` call id
(`AutolaunchWeb.AgentPress`); the browser then presses it at once, which opens the
person's wallet. When the card cannot prepare anything (signed out, bidding ended,
nothing left to settle, a value the card refuses) it answers `agent-tools:refused`
in the card's own words, and nothing reaches the wallet.

Nothing is gated or merged: a second call while the first is with the wallet opens
the wallet again, and the same values with a step already prepared send that step
again. A call with different values prepares afresh, as changing the card's
values would, and replaces the review the card had open: a step of the earlier
review still with the wallet can still be confirmed there, but the page no longer
follows it.

Results are `{outcome, transaction_hash?, message}`:

- `sent` with the hash, and a message naming any steps still to send (an approval
  comes first). The card offers the next step once this one lands, so a call
  with the same values before then asks for this step again.
- `not_sent` when nothing reached the chain: the card refused, the input did not
  match the schema, the signed-in wallet is not connected in this tab, the wallet
  is on another account or network, the person declined the network switch or
  the step, or the page lost its connection or the sign-in changed before the
  wallet opened.
- `unknown` when the wallet may have sent it but did not say, or the page changed
  or the call was cancelled after the card began preparing it.

Paying an agent's revenue and the public upkeep buttons are not tools yet.

## Launch tools

An agent launches a Memestake token on `/create` or a Revstake token on
`/create/revstake` with the page open in the person's browser:

1. `autolaunch_launch_form` reads the form: every field as saved, whether a
   picture is chosen, the stocks on offer (Memestake), the problems with any
   field, and `next`, what is left and who does it.
2. `autolaunch_fill_memestake` or `autolaunch_fill_revstake` saves the given
   fields through the same saves as typing them (`AutolaunchWeb.StocksCreateLive`,
   `AutolaunchWeb.CreateLive`): to the account's draft when signed in, otherwise
   in this browser tab until the person signs in. The result is
   `{outcome: saved | not_saved, message?, form}`, where `form` is what
   `autolaunch_launch_form` reads. Input that does not match the schema answers
   `{outcome: invalid_input, message}` and saves nothing.
3. On `/create/revstake` off the test network, `autolaunch_verify_treasury`
   checks the treasury Safe from three of its Base transactions, as the card's
   own verification form does.
4. `autolaunch_launch` presses the launch card's button: the card opens the
   launch review "Review launch" would open and the browser sends its one step at
   once, so the person's wallet opens. It is a [wallet tool](#wallet-tools) and
   answers the same way.

The form element (`#memestock-form`, `#autolaunch-create`) and the treasury
check carry the `AgentTools` hook (`assets/js/hooks/agent_tools.ts`); a call
pushes `agent_call` to their LiveView or component, and the reply is the tool's
result. While the launch review is open, or the account's Memestake auction is
live, the form is locked for the agent as it is for the person.

Some steps stay with the person: signing in, choosing the picture, typing the
single-key treasury warning and the warning a Revstake launch with no X, GitHub
or ENS connection needs, making the Safe, and confirming in the wallet.

## Verification

From `platform/`, after `mix assets.build`: `npm run typecheck`.
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
