# Feature map

What a person or an agent can do on Autolaunch, and the automated check that proves it.
A check is a test (`file › test name`; ExUnit files under `platform/test/`, the TypeScript
one under `platform/assets/test/`, the CLI's under `cli/test/`) or a script. **Gap** means
nothing automated proves it today; it rests on manual review.

Map as of 19 October 2026. A release that adds or changes something here updates its line.

## Pages

| Page | What it does | Check |
| --- | --- | --- |
| `/` | Value line, Back a launch and Launch yours, Coming next, then the launches list: New, Live, Finished and Tokens tabs, filter, search, bid-volume row | Coming next and where Agent Tools opens: `autolaunch_web/live/home_next_test.exs` (all three cases); `autolaunch_web/live/quiet_pages_test.exs` › "the lists hear a bid-activity pass only when it changed an event or a figure", › "the price ticker sends a list only when it differs from the last one"; `autolaunch/home_market_test.exs` › "a list's link reads back as the same list", › "the search box keeps one tidy form of any text". Tabs and filter results: **gap** |
| `/auctions` | Every auction, with chain, status and Verified filters and search | Filter links: as `/`. Load more: `autolaunch_web/public_page_test.exs` › "a cursor pages on only the list it came from", › "an edited cursor is refused". Short figures (K, M, B, T): `autolaunch_web/components/market_card_test.exs` › "a short figure reads back within half a percent, in at most three digits". Verified filter presses (44 px on touch, normal with a mouse): `/Users/sean/Documents/regent/artifacts/autolaunch-backlog-2026-10-19/scripts/filter-presses.mjs`. One figure a row on a phone (raised while live, price once finished): **gap** (seen in a headless browser at 390px on 21 Oct). Filter results: **gap** |
| `/auctions/<TICKER>/<tail>` | One auction: figures, bid, Details and How it works tabs, Activity and Timeline tabs | `autolaunch_web/live/market_page_test.exs` (all four cases); `autolaunch_web/live/market_page_record_test.exs` › "each auction and token page links its own API record and describes it"; `quiet_pages_test.exs` › "an auction page reads its row again for a new reading of its own auction, and for no other's"; `autolaunch/auction_figures_test.exs` (all four cases). The tabs: **gap** |
| `/tokens` | Every launched token, with chain and Verified filters and search | As `/auctions` |
| Creator names (lists, auction and token pages, share pictures) | One name for a launch's creator: checked account, else short wallet | `autolaunch_web/live/creator_label_test.exs` (both cases); share pictures keep their layout: `autolaunch_web/share_card_test.exs` (both cases) |
| `/tokens/<TICKER>/<tail>` | One token: price, Swap, Stake and Unstake tabs, Make a payment (Revstake) | First screen order (figures, then chart, then the widget): `autolaunch_web/live/token_page_first_screen_test.exs` › "the price, market cap, change and creator come before the chart and the trade widget". Its API record link and structured data: as the auction page. `market_page_test.exs` › "a token page whose token cannot be read is the plain error page, not a 404 or a 503"; `autolaunch_web/token_details_test.exs` › "LONG_POOL_PRICES_ARE_CUT_NOT_PARSED"; `autolaunch/token_trades_test.exs`; `autolaunch/pool_price_test.exs` (all four cases); `autolaunch_web/components/token_display_test.exs` (all three cases, and the properties "a short amount keeps four digits and never rounds a refund up", "counted zeros write back to the same figure"). The tabs: **gap** |
| `/create` | Memestock launch form: draft autosave, paired stock, Base or Robinhood | `autolaunch_web/live/stocks_create_live_test.exs` › "autosaves each section and states the fixed minimum for the chosen stock", › "STOCK_LIST_UNREAD_SAYS_SO: a stock list that can't be read says so, with Try again"; `autolaunch/stocks/launch_draft_test.exs` › "another account can neither read nor update a Stocks draft" |
| `/create/revstake` | Revstake launch form on Base | `autolaunch/launch_draft_test.exs` (both cases). The page itself: **gap** |
| `/stock-listing` | Stocks available to pair, each linking to its own page | `autolaunch_web/live/stock_listing_test.exs` (both cases) |
| `/stock-listing/<symbol>` | One stock: addresses, company links, dated pool research | As above |
| `/how-it-works` | Fixed contract rules, explained | **Gap** |
| `/portfolio` | The signed-in wallet's bids and tokens | `autolaunch_web/live/robinhood_pages_live_test.exs` › "/portfolio outlives a Robinhood feed's new block" |
| `/portfolio/bids/<id>` | One bid on its own page | **Gap** (its steps: see Wallet actions) |
| `/account` | Profile, sign out, paired agents, pair another | `autolaunch_web/live/account_live_test.exs` › "ACCOUNT_SHOWS_A_PAIRED_AGENT" |
| `/account/points` | Points balance and recent entries | **Gap** |
| `/regent` | REGENT facts and revenue sources | **Gap** |
| `/convert` | Memestock fee shares waiting to be sold, for the converter wallet | **Gap** |
| Search window (⌘ K) | Find an auction or token from any page | **Gap** |
| `/docs`, `/about`, `/contact`, `/privacy`, `/terms` | Guides and policies | `autolaunch_web/content_negotiation_test.exs` › "HTML pages reject JSON selected by Accept or _format", › "a browser or an Accept header with an HTML fallback still gets LiveView HTML" |
| `/blog`, `/blog/<slug>` | Posts | **Gap** |
| Error pages | Not found (404), Try again only for a lost database connection (503), plain error (500) | `market_page_test.exs` (all four cases); `autolaunch_web/controllers/old_link_controller_test.exs` (both cases) |

## Sign-in, account and Credits

| Action | Check |
| --- | --- |
| Sign in and sign out | `autolaunch_web/controllers/privy_session_controller_test.exs` (all three cases); `content_negotiation_test.exs` › "the existing session fetch still returns JSON" |
| Stay signed in when the sign-in can't be read for a moment (Try again, nothing saved meanwhile) | `autolaunch_web/live/sign_in_read_test.exs` (all six cases); `autolaunch_web/sign_in_unread_panels_test.exs` (all four cases); `autolaunch_web/live/held_sign_in_writes_test.exs` (all four cases); the top bar then, on a phone: `browser/layout.spec.ts` › "the Regents Products name stays on screen with nothing to its right" |
| Connect or remove X | `content_negotiation_test.exs` › "JSON account-link requests retain CSRF protection". The connect itself: **gap** |
| Buy Credits (Approve, then Buy) | Reading the wallet: `autolaunch_web/live/credits_panel_test.exs` › "CREDITS_PANEL_NO_NODE: a chain with no node reads as unavailable, with no crash". The wallet press: see Wallet actions. The purchase check: **gap** |

## Wallet actions

Every wallet button goes through the same sender, proved by `onchain_steps.test.ts`: "hands
the wallet the exact reviewed bytes from the reviewed signer and reports the hash once", "two
presses in a row both reach the wallet while the first is still there", "sends nothing from a
wallet other than the reviewed signer", "sends nothing while the wallet is on another chain",
"sends nothing when Privy changes the active wallet part-way", "reports a declined request and
a step the review does not have", and for batches "hands wallet_sendCalls exactly the reviewed
calls, atomically, after the chain read". What each action builds:

| Action | Check |
| --- | --- |
| Bid on a Base auction | `autolaunch/bid_actions_test.exs` (every case); `autolaunch/bid_slippage_test.exs`; `autolaunch/chain/calls_test.exs` › "BATCH_IS_THE_REVIEWS_ONLY_WITH_EVERY_CALL"; `autolaunch/lab_bid_chain_client_test.exs` |
| Bid on a Robinhood auction, see its standing | `autolaunch_web/live/robinhood_stock_bid_component_test.exs` (both cases). The bid itself: **gap** |
| Add to, raise, or take back an outbid bid early | **Gap** |
| Withdraw or claim after an auction | `autolaunch/bid_settlement_actions_test.exs` (all five cases) |
| Finish an ended auction | `autolaunch/auction_finish_test.exs` (all seven cases); `autolaunch/auction_finish_wallet_test.exs` |
| Launch a Memestock token | `autolaunch/stocks/launch_actions_test.exs`; `autolaunch/stocks/amounts_test.exs` (all three cases); `autolaunch/memestock_discovery_test.exs` (all five cases) |
| Launch a Revstake token | `autolaunch/launch_discovery_test.exs` (all seven cases); `autolaunch/treasury_chain_client_test.exs` (both cases) |
| Swap a token | **Gap** |
| Stake, unstake, collect | `autolaunch/stocks/stake_actions_test.exs` › "settle on a Base Revstake launch is one collect(lp_token_id) step on the lp_locker". Stake and unstake: **gap** |
| Make a payment into a Revstake split | **Gap** |
| Sell fee shares on `/convert` | **Gap** |
| Lab test funds (lab sites only) | `autolaunch/stocks/faucet_cooldown_test.exs` (both cases); `autolaunch/chain_mode_test.exs` (both cases) |

## Shared links

| Action | Check |
| --- | --- |
| Share picture of an auction or token | `autolaunch_web/launch_image_test.exs` (both cases); `autolaunch_web/share_card_test.exs` (both cases) keeps every word inside the part X's phone view shows. The rest of the picture's content: **gap** |
| Share video, everyone's or a wallet's own | `autolaunch_web/controllers/share_video_test.exs`; `share_video_failures_test.exs` (all ten cases); `autolaunch_web/share_video_queue_test.exs` (all six); `autolaunch_web/share_video_render_test.exs` |
| Old links (`/auctions/<id>`, `/tokens/<id>`, `/robinhood/...`) move to today's page | `old_link_controller_test.exs` (both cases) |

## Agents

Each WebMCP tool calls the HTTP route beside it, and the matching CLI command (`cli/commands.json`)
calls the same route. `make check-cli` checks the command descriptions against
`cli/commands.json` and the OpenAPI files. `cli/test/parity.test.js` › "all five public commands
match existing WebMCP requests and domain results" checks that the public CLI commands send the
same requests as the WebMCP tools, against a stand-in server (`npm run test:parity` in `cli/`).

| WebMCP tool | Route | Check |
| --- | --- | --- |
| `autolaunch_auctions` | `GET /api/v1/auctions` | `autolaunch_web/controllers/auction_controller_test.exs` › "a Robinhood auction's id from the list opens its detail"; `autolaunch_web/controllers/public_api_failures_test.exs` › "PUBLIC_API_FAILED_READS_ARE_LOGGED: each failed read is logged by kind and module only" |
| `autolaunch_auction` | `GET /api/v1/auctions/{id}` | As above |
| (all public reads) | Any website's page may read the six public `GET` routes; no account or agent route | `autolaunch_web/controllers/public_read_origin_test.exs` › "the public reads allow any origin, and no signed or account route does" |
| `autolaunch_auction_counts` | `GET /api/v1/auction-counts` | `auction_controller_test.exs` › "the counts give each launch type's live and graduated auctions on each chain" |
| `autolaunch_tokens` | `GET /api/v1/tokens` | `public_api_failures_test.exs` (same case); `autolaunch_web/controllers/token_controller_test.exs` › "a token's price and market cap read in REGENT and in dollars, list and detail alike"; `autolaunch/auction_figures_test.exs` › "a stated price keeps at most 18 significant digits and is the stored one rounded up" |
| `autolaunch_token` | `GET /api/v1/tokens/{id}` | As above; a Revstake token's revenue history: `token_controller_test.exs` › "a Revstake token gives its revenue history, newest first; a Memestock token has none", recorded from the splitter: `autolaunch/token_revenue_test.exs` › "a Revstake token's pass records its splitter's revenue with its trades" |
| `autolaunch_treasury` | `GET /api/v1/treasury-security/{address}` | `public_api_failures_test.exs` (same case); `treasury_chain_client_test.exs` (both cases) |
| `autolaunch_bid_quote` | `POST /api/v1/auctions/{id}/bid-quote` | `bid_actions_test.exs` › "LONG_STORED_PRICE: a bid estimate reads the whole stored price, never zero, and states it so a bid at it reaches it"; `public_api_failures_test.exs` (same case) |
| `agent_whoami` | `GET /api/agents/v1/whoami` | `autolaunch_web/controllers/agent_check_in_test.exs` (all three cases) |
| `agent_status` | `GET /api/agents/v1/me` | `agent_check_in_test.exs` (all three cases) |
| (CLI `agents pair`) | `POST /api/agents/v1/pair` | `account_live_test.exs` › "ACCOUNT_SHOWS_A_PAIRED_AGENT" pairs through the shared library; the signed request: **gap** |
| `autolaunch_revstake_draft`, `autolaunch_revstake_draft_save` | `GET` and `PATCH /api/agent/v1/drafts/revstake` | **Gap** |
| `autolaunch_memestock_draft`, `autolaunch_memestock_draft_save` | `GET` and `PATCH /api/agent/v1/drafts/memestock` | **Gap** |
| (none) | Make a payment (Revstake token page): addresses from the launch's own record, read by the Base reader, canonical receiver only, on the launch's own network | `autolaunch/payment_card_test.exs` (all three cases). The wallet press itself: **gap** |
| `autolaunch_revstake_draft_save`, `autolaunch_memestock_draft_save` | `PATCH /api/agent/v1/drafts/{kind}` | `autolaunch/agent_drafts_test.exs` (all three cases); the create page names every agent-set field: `autolaunch_web/live/agent_draft_review_test.exs` › "the create page names what the agent set, and forgets a field the person changes", › "the launch review names every agent-set field and shows the community links". The signed request itself: **gap** |
| `autolaunch_my_positions` | `GET /api/agent/v1/positions` (and `GET /api/v1/me/positions` signed in) | Refusals: `agent_check_in_test.exs` › "AGENT_PAIRING_WITHOUT_ACCOUNT_IS_NOT_PAIRED", › "AGENT_PERSON_UNREAD_IS_503"; `sign_in_read_test.exs` › "a lost sign-in read is a 503 for the signed-in wallet's positions and share video". A working read: **gap** |
| `account_balances` | `GET /api/agent/v1/account/balances` | **Gap** |
| `account_credits_history` | `POST /api/agent/v1/account/credits/history` | **Gap** |
| `account_points` | `GET /api/agent/v1/account/points` | **Gap** |
| `prepare_agent_request` | In the page, sends nothing | **Gap** |
| (none) | `/api/v1/profile` (shared profile) | **Gap** |

Guides and discovery for agents (`/llms.txt`, `/llms-full.txt`, `/agents.md`, `/skill.md`,
`/openapi.json`, `/sitemap.xml`, `/sitemap.md`, `/robots.txt`, `/capabilities`,
`/.well-known/security.txt`, `/.well-known/api-catalog`, `/healthz`): `make readiness`
(`scripts/readiness.sh`) and `autolaunch_web/controllers/health_controller_test.exs` ›
"HEALTH_NAMES_THE_COMMIT: a ready site answers ok with its build's commit". One regents-cli
release, the live prelaunch line and the short index's links: `autolaunch_web/agent_documents_test.exs`
(all three cases).

## Gaps, in one list

Home tabs and filter results; list filter results on `/auctions` and `/tokens`; the auction
and token page tabs; `/create/revstake`, `/stock-listing`, `/how-it-works`, `/account/points`,
`/regent`, `/convert`, `/blog` and the search window as pages; the bid page; connecting X; the
Credits purchase check; Robinhood bids; adding to, raising or taking back an outbid bid; swap;
stake and unstake; Make a payment; selling fee shares; share picture content; the signed
agent routes (pairing request, drafts, a working positions read, Credits, Points) and
`prepare_agent_request`; the shared profile routes.
