# Agent parity

An action only a person can do is a bug (founder rule, 28 October 2026). Every action an
account's owner can take on Autolaunch has a row here naming its five agent surfaces: the
website in a headless browser, WebMCP, hosted MCP at `/mcp`, the Claude connector, and the
regents CLI. Each surface calls the same Ash action with the same inputs, answers and
refusals. A missing surface is a gap with the lane that closes it.

Hosted MCP (`/mcp`) serves the tools `platform/priv/capabilities.json` marks hosted: the
auction counts and the Claude connector's identity tools. Every other hosted MCP cell is a gap
owned by the **Autolaunch MCP lane**, closed as its operation becomes one action whose answer is
the browser tool's. The Claude connector is served from hosted MCP behind its switch
(`AUTOLAUNCH_CLAUDE_CONNECTOR_ENABLED`, off in production): a connected app calls as itself
with its identity tools, and, once paired with the agent permission, as that agent with its
hosted tools; its other cells are gaps owned by the same lane. The checks that prove each
surface are in `operations/FEATURES.md`.

## Hosted MCP

| Action | Operation | Browser | WebMCP | Hosted MCP | Claude connector | CLI |
| --- | --- | --- | --- | --- | --- | --- |
| Count live and graduated auctions | `auction_counts` (`Autolaunch.Auction`, `:counts`) | `/auctions`, the counts | `autolaunch_auction_counts` (`GET /api/v1/auction-counts`) | `autolaunch_auction_counts` | `autolaunch_auction_counts`, once paired with the agent permission | `regents autolaunch auctions counts` |
| Keep a connected app's identity, pair it and check in | `Autolaunch.Agents.Connection` (`register_identity`, `get_identity`, `pair_identity`, `check_in`) | `/account`, Pair New Agent: Claude (switch on) | None: it belongs to a connected app | The four identity tools, for a connected app | The four identity tools | `regents autolaunch agents pair` and `agents status`, for an agent with its own wallet |

## Covered calls

Offered only while the site's covered-call switch is on (`AUTOLAUNCH_COVERED_CALLS=true`).
Off, no route, tool, guide section or command offers them. Every action is one operation in
`Autolaunch.CoveredCalls`; the site prepares wallet steps and the wallet's own key signs them.
CLI cells are gaps owned by the **regents-cli lane**, to be added to `cli/commands.json` when
the switch goes on, so the CLI never offers them while the site does not.

| Action | Operation | Browser | WebMCP | Hosted MCP | Claude connector | CLI |
| --- | --- | --- | --- | --- | --- | --- |
| Read a stock's listings | `covered_call_book` | `/covered-calls`, Buy | `autolaunch_covered_call_listings` (`GET /api/v1/covered-calls/{symbol}`) | Gap: Autolaunch MCP lane | Gap: Autolaunch MCP lane | Gap: regents-cli lane |
| Suggested premium | `covered_call_quote` | `/covered-calls`, Sell | `autolaunch_covered_call_quote` (`POST /api/v1/covered-calls/{symbol}/quote`) | Gap: Autolaunch MCP lane | Gap: Autolaunch MCP lane | Gap: regents-cli lane |
| Read my listings and holdings | `covered_call_positions` | `/portfolio`, Covered calls | `autolaunch_my_covered_calls` (`GET /api/agent/v1/covered-calls/{symbol}/positions`) | Gap: Autolaunch MCP lane | Gap: Autolaunch MCP lane | Gap: regents-cli lane |
| List calls (sell) | `prepare_covered_call`, kind `list` | `/covered-calls`, Sell: List calls, then Approve, Confirm listing | `autolaunch_covered_call_prepare` (`POST /api/agent/v1/covered-calls/{symbol}/steps`) | Gap: Autolaunch MCP lane | Gap: Autolaunch MCP lane | Gap: regents-cli lane |
| Buy calls (fill) | `prepare_covered_call`, kind `fill` | `/covered-calls`, Buy: Buy calls, then Approve, Confirm purchase | `autolaunch_covered_call_prepare` | Gap: Autolaunch MCP lane | Gap: Autolaunch MCP lane | Gap: regents-cli lane |
| Cancel the unsold remainder | `prepare_covered_call`, kind `cancel` | `/portfolio`, Covered calls: Stop selling, then Confirm stop | `autolaunch_covered_call_prepare` | Gap: Autolaunch MCP lane | Gap: Autolaunch MCP lane | Gap: regents-cli lane |
| Exercise | `prepare_covered_call`, kind `exercise` | `/portfolio`, Covered calls: Exercise, then Approve, Confirm exercise | `autolaunch_covered_call_prepare` | Gap: Autolaunch MCP lane | Gap: Autolaunch MCP lane | Gap: regents-cli lane |
| Claim stock | `prepare_covered_call`, kind `claim` | `/portfolio`, Covered calls: Collect AMZNc, then Confirm collection | `autolaunch_covered_call_prepare` | Gap: Autolaunch MCP lane | Gap: Autolaunch MCP lane | Gap: regents-cli lane |
| Collect the strike | `prepare_covered_call`, kind `collect_strike` | `/portfolio`, Covered calls: Collect USDC, then Confirm collection | `autolaunch_covered_call_prepare` | Gap: Autolaunch MCP lane | Gap: Autolaunch MCP lane | Gap: regents-cli lane |

## After-hours Exposure

Offered only while the site's switch is on (`AUTOLAUNCH_EXPOSURE=true`). Off, no route, tool,
guide section or command offers them. Every action is one operation in `Autolaunch.Exposure`;
the site prepares wallet steps and the wallet's own key signs them. CLI cells are gaps owned by
the **regents-cli lane**, to be added to `cli/commands.json` when the switch goes on.

| Action | Operation | Browser | WebMCP | Hosted MCP | Claude connector | CLI |
| --- | --- | --- | --- | --- | --- | --- |
| List every series | `exposure_series_list` | `/after-hour-stocks` (series list) | `autolaunch_after_hour_stocks_list` (`GET /api/v1/after-hour-stocks`) | Gap: Autolaunch MCP lane | Gap: Autolaunch MCP lane | Gap: regents-cli lane |
| Read a series | `exposure_series` | `/after-hour-stocks` | `autolaunch_after_hour_stocks_series` (`GET /api/v1/after-hour-stocks/{series}`) | Gap: Autolaunch MCP lane | Gap: Autolaunch MCP lane | Gap: regents-cli lane |
| Read my holding | `exposure_holdings` | `/after-hour-stocks`, Mint and Return panels | `autolaunch_my_after_hour_stocks` (`GET /api/agent/v1/after-hour-stocks/{series}/holdings`) | Gap: Autolaunch MCP lane | Gap: Autolaunch MCP lane | Gap: regents-cli lane |
| Mint a pair | `prepare_exposure`, kind `mint` | `/after-hour-stocks`, Mint: Approve, Mint | `autolaunch_after_hour_stocks_prepare` (`POST /api/agent/v1/after-hour-stocks/{series}/steps`) | Gap: Autolaunch MCP lane | Gap: Autolaunch MCP lane | Gap: regents-cli lane |
| Return tokens for the stock | `prepare_exposure`, kind `redeem` | `/after-hour-stocks?tab=return`: Return | `autolaunch_after_hour_stocks_prepare` | Gap: Autolaunch MCP lane | Gap: Autolaunch MCP lane | Gap: regents-cli lane |
| Record and apply the next price | `prepare_exposure`, kind `update` | `/after-hour-stocks`, Prices: Record price, Apply price | `autolaunch_after_hour_stocks_prepare` | Gap: Autolaunch MCP lane | Gap: Autolaunch MCP lane | Gap: regents-cli lane |
| End a series whose price was missed | `prepare_exposure`, kind `end` | `/after-hour-stocks`, Prices: End series (disabled with its reason until the price is overdue) | `autolaunch_after_hour_stocks_prepare` | Gap: Autolaunch MCP lane | Gap: Autolaunch MCP lane | Gap: regents-cli lane |

The browser cells name the pages the covered-call pages lane is building; a headless walk with
an agent's own wallet through each one is still to be added to `operations/FEATURES.md`.
