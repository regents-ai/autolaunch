# Agent parity

An action only a person can do is a bug (founder rule, 28 October 2026). Every action an
account's owner can take on Autolaunch has a row here naming its five agent surfaces: the
website in a headless browser, WebMCP, hosted MCP at `/mcp`, the Claude connector, and the
regents CLI. Each surface calls the same Ash action with the same inputs, answers and
refusals. A missing surface is a gap with the lane that closes it.

Hosted MCP (`/mcp`) serves the tools `platform/priv/capabilities.json` marks hosted: the
auction counts, the four covered-call operations while covered calls are on, and the Claude
connector's identity tools. Every other hosted MCP cell is a gap
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
| Keep a connected app's identity, pair it and check in | `Autolaunch.Agents.Connection` (`register_identity`, `get_identity`, `pair_identity`, `check_in`) | `/pair`, Claude (switch on) | None: it belongs to a connected app | The four identity tools, for a connected app | The four identity tools | `regents autolaunch agents pair` and `agents status`, for an agent with its own wallet |

## Account

| Action | Operation | Browser | WebMCP | Hosted MCP | Claude connector | CLI |
| --- | --- | --- | --- | --- | --- | --- |
| Read my Points | `RegentPoints.summary` and the shared board | `/account/points` | `account_points` (`GET /api/v1/account/points`) | Gap: Autolaunch MCP lane | Gap: Autolaunch MCP lane | Gap: regents-cli lane. The regents-cli the site names (`fd325437`) asks `account points` at `/api/agent/v1/account/points`, an address the site no longer answers; it closes when the site names a regents-cli that asks `/api/v1/account/points` |

## Covered calls

Offered only while the site's covered-call switch is on (`AUTOLAUNCH_COVERED_CALLS=true`).
Off, no route, tool, guide section or command offers them. Every action is one operation in
`Autolaunch.CoveredCalls`, which the HTTP routes (and so the browser tools) and the hosted MCP
tools run alike; the site prepares wallet steps and the wallet's own key signs them.
CLI cells are gaps owned by the **regents-cli lane**, to be added to `cli/commands.json` when
the switch goes on, so the CLI never offers them while the site does not.

| Action | Operation | Browser | WebMCP | Hosted MCP | Claude connector | CLI |
| --- | --- | --- | --- | --- | --- | --- |
| Read a stock's listings and open bids | `covered_call_book` | `/stock/covered-call`, Buy (listings) and Sell (Bids) | `autolaunch_covered_call_listings` (`GET /api/v1/covered-calls/{symbol}`) | `covered_call_book` | `covered_call_book`, once paired with the agent permission | Gap: regents-cli lane |
| Quote a listing | `covered_call_quote` | `/stock/covered-call`, Sell | `autolaunch_covered_call_quote` (`POST /api/v1/covered-calls/{symbol}/quote`) | `covered_call_quote` | `covered_call_quote`, once paired with the agent permission | Gap: regents-cli lane |
| Read my listings, holdings and bids | `covered_call_positions` | `/portfolio`, Covered calls (bid rows included) | `autolaunch_my_covered_calls` (`GET /api/agent/v1/covered-calls/{symbol}/positions`) | `covered_call_positions` | `covered_call_positions`, once paired with the agent permission | Gap: regents-cli lane |
| List calls (sell) | `prepare_covered_call`, kind `list` | `/stock/covered-call`, Sell: List calls, then Approve, Confirm listing | `autolaunch_covered_call_prepare` (`POST /api/agent/v1/covered-calls/{symbol}/steps`) | `prepare_covered_call` | `prepare_covered_call`, once paired with the agent permission | Gap: regents-cli lane |
| Buy calls (fill) | `prepare_covered_call`, kind `fill` | `/stock/covered-call`, Buy: Buy calls, then Approve, Confirm purchase | `autolaunch_covered_call_prepare` | `prepare_covered_call` | `prepare_covered_call`, once paired with the agent permission | Gap: regents-cli lane |
| Cancel the unsold remainder | `prepare_covered_call`, kind `cancel` | `/portfolio`, Covered calls: Stop selling, then Confirm stop | `autolaunch_covered_call_prepare` | `prepare_covered_call` | `prepare_covered_call`, once paired with the agent permission | Gap: regents-cli lane |
| Exercise | `prepare_covered_call`, kind `exercise` | `/portfolio`, Covered calls: Exercise, then Approve, Confirm exercise | `autolaunch_covered_call_prepare` | `prepare_covered_call` | `prepare_covered_call`, once paired with the agent permission | Gap: regents-cli lane |
| Claim stock | `prepare_covered_call`, kind `claim` | `/portfolio`, Covered calls: Collect AMZNc, then Confirm collection | `autolaunch_covered_call_prepare` | `prepare_covered_call` | `prepare_covered_call`, once paired with the agent permission | Gap: regents-cli lane |
| Collect the strike | `prepare_covered_call`, kind `collect_strike` | `/portfolio`, Covered calls: Collect USDC, then Confirm collection | `autolaunch_covered_call_prepare` | `prepare_covered_call` | `prepare_covered_call`, once paired with the agent permission | Gap: regents-cli lane |
| Post a bid for calls | `prepare_covered_call`, kind `bid` | `/stock/covered-call?tab=bid`: Place bid, then Approve USDC, Confirm bid | `autolaunch_covered_call_prepare` | `prepare_covered_call` | `prepare_covered_call`, once paired with the agent permission | Gap: regents-cli lane |
| Raise a bid | `prepare_covered_call`, kind `raise_bid` | `/portfolio`, Covered calls: Raise, then Approve USDC, Confirm raise | `autolaunch_covered_call_prepare` | `prepare_covered_call` | `prepare_covered_call`, once paired with the agent permission | Gap: regents-cli lane |
| Cancel a bid | `prepare_covered_call`, kind `cancel_bid` | `/portfolio`, Covered calls: Stop, then Confirm stop | `autolaunch_covered_call_prepare` | `prepare_covered_call` | `prepare_covered_call`, once paired with the agent permission | Gap: regents-cli lane |
| Refund a bid's escrow | `prepare_covered_call`, kind `refund_bid` | `/portfolio`, Covered calls: Refund, then Confirm refund | `autolaunch_covered_call_prepare` | `prepare_covered_call` | `prepare_covered_call`, once paired with the agent permission | Gap: regents-cli lane |
| Sell calls into a bid | `prepare_covered_call`, kind `sell_to_bid` | `/stock/covered-call`, Sell, Bids: Sell, then Sell now, Approve AMZNc, Confirm sale | `autolaunch_covered_call_prepare` | `prepare_covered_call` | `prepare_covered_call`, once paired with the agent permission | Gap: regents-cli lane |

## Isolated Exposure to After-hours Stocks

Offered only while the site's switch is on (`AUTOLAUNCH_EXPOSURE=true`). Off, no route, tool,
guide section or command offers them. Every action is one operation in `Autolaunch.Exposure`;
the site prepares wallet steps and the wallet's own key signs them. CLI cells are gaps owned by
the **regents-cli lane**, to be added to `cli/commands.json` when the switch goes on.

| Action | Operation | Browser | WebMCP | Hosted MCP | Claude connector | CLI |
| --- | --- | --- | --- | --- | --- | --- |
| List this week and recent weeks | `exposure_weeks` | `/stock/isolated-afters`, Past weeks | `autolaunch_after_hour_stocks_list` (`GET /api/v1/after-hour-stocks`) | Gap: Autolaunch MCP lane | Gap: Autolaunch MCP lane | Gap: regents-cli lane |
| Read a week | `exposure_week` | `/stock/isolated-afters` (this week), `/stock/isolated-afters?week={week}` | `autolaunch_after_hour_stocks_week` (`GET /api/v1/after-hour-stocks/{week}`) | Gap: Autolaunch MCP lane | Gap: Autolaunch MCP lane | Gap: regents-cli lane |
| Read my holding | `exposure_holdings` | `/stock/isolated-afters`, Deposit and Redeem panels | `autolaunch_my_after_hour_stocks` (`GET /api/agent/v1/after-hour-stocks/{week}/holdings`) | Gap: Autolaunch MCP lane | Gap: Autolaunch MCP lane | Gap: regents-cli lane |
| Buy one token with USDC | `prepare_exposure`, kind `buy` | `/stock/isolated-afters?tab=buy`: After-hours or Market-hours, Approve USDC, Buy | `autolaunch_after_hour_stocks_prepare` (`POST /api/agent/v1/after-hour-stocks/{week}/steps`) | Gap: Autolaunch MCP lane | Gap: Autolaunch MCP lane | Gap: regents-cli lane |
| Sell one token for USDC | `prepare_exposure`, kind `sell` | `/stock/isolated-afters?tab=sell`: Approve the token, Sell | `autolaunch_after_hour_stocks_prepare` (`POST /api/agent/v1/after-hour-stocks/{week}/steps`) | Gap: Autolaunch MCP lane | Gap: Autolaunch MCP lane | Gap: regents-cli lane |
| Deposit the stock for a pair (opens the week on its first deposit) | `prepare_exposure`, kind `deposit` | `/stock/isolated-afters?tab=deposit`: Approve the stock, Deposit | `autolaunch_after_hour_stocks_prepare` (`POST /api/agent/v1/after-hour-stocks/{week}/steps`) | Gap: Autolaunch MCP lane | Gap: Autolaunch MCP lane | Gap: regents-cli lane |
| Redeem tokens for the stock | `prepare_exposure`, kind `redeem` | `/stock/isolated-afters?tab=redeem`: Redeem | `autolaunch_after_hour_stocks_prepare` | Gap: Autolaunch MCP lane | Gap: Autolaunch MCP lane | Gap: regents-cli lane |
| Apply every price that is due | `prepare_exposure`, kind `settle` | `/stock/isolated-afters`, Prices: Update prices | `autolaunch_after_hour_stocks_prepare` | Gap: Autolaunch MCP lane | Gap: Autolaunch MCP lane | Gap: regents-cli lane |

The browser cells name the pages the covered-call pages lane is building; a headless walk with
an agent's own wallet through each one is still to be added to `operations/FEATURES.md`.
