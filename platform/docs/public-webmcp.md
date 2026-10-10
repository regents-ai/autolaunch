# Autolaunch browser tools

The deployed `/agents.md` is the signed-access guide. `priv/tool_manifest.json` is the source of registered native tools and their exact input schemas. Public tools omit cookies. Private reads and metadata writes use the shared `regent_agent_access` transport, an independent SIWA signer and current pairing. Browser owner credentials never become agent authority.

`prepare_agent_request` fixes the method, trusted origin, path and exact bytes before signing. Execute a signed operation with the prepared request, original input and fresh proof headers. No signer means no private tool execution. A missing response to a draft save has an unknown outcome; read the same draft before retrying. Pairing redemption requires a chosen agent name and real harness.

Person-controlled profile and wallet UI remains available, but its cookie and LiveView actions are not registered as agent tools. No native tool can launch, trade, stake, settle, claim, approve budgets or move funds.

The list options are the website's own, read through the same discovery as its
auction and token lists (`Autolaunch.HomeMarket`), with the same names and meanings in
the API, the CLI and these tools:

| Option | Values | Lists |
| --- | --- | --- |
| `q` | The website search: every word in a name, ticker, stock, description, address or verified account; a leading `$` is ignored; the API collapses spaces and keeps the first 80 characters | auctions, tokens |
| `state` | `all`, `created` (opening soon), `active` (live), `ended` (waiting to be finished), `failed`, `graduated` (launched), `finished` (graduated or failed) | auctions |
| `sort` | `newest` (most recently listed), `ending` (live only, closing soonest; the website's Closing), `volume` (highest dollar bid volume, unrecorded last; the website's Highest) | auctions |
| `chain` | `all`, `base`, `robinhood` | auctions, tokens |
| `kind` | `all`, `revstake`, `memestake` | auctions, tokens |
| `x`, `ens`, `github` | `true` keeps only creators verified on that account; several must all hold | auctions, tokens |

Native host acceptance is a separate verification step. Registered descriptors and local HTTP tests do not establish that Hermes, Grok or Muse can sign and execute successfully.
