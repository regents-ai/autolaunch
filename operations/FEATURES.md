# Feature map

What a person or an agent can do on Autolaunch, and the automated check that proves it.
A check is a test (`file › test name`; ExUnit files under `platform/test/`, the TypeScript
one under `platform/assets/test/`, the CLI's under `cli/test/`) or a script. **Gap** means
nothing automated proves it today; it rests on manual review.

Map as of 27 October 2026. A release that adds or changes something here updates its line.

The agent journeys (`scripts/agent-journeys.sh`, specs in `platform/test/journeys/`) start a whole
local stack (a copy of Base with the v2 contracts as deployed, a sign-in service, this site and the
regents command line) and play both sides: the regents binary is the agent, and Playwright at 390 with
touch and at 1280 is its person. Run them for any release touching pairing, agent routes, drafts or
launches.

## Pages

| Page | What it does | Check |
| --- | --- | --- |
| `/` | Value line, Back a launch and Launch yours, Coming next (the auctions taking bids or opening soon, or one line saying none is), then the launches list: New, Live, Finished and Tokens tabs, filter, search, bid-volume row | Coming next and where Agent Tools opens: `autolaunch_web/live/home_next_test.exs` (all three cases); `autolaunch_web/live/quiet_pages_test.exs` › "the lists hear a bid-activity pass only when it changed an event or a figure", › "the price ticker sends a list only when it differs from the last one"; `autolaunch/home_market_test.exs` › "a list's link reads back as the same list", › "the search box keeps one tidy form of any text". Tabs and filter results: **gap**. Clear search keeps the other filters: `autolaunch_web/live/home_next_test.exs` › "Clear search drops only the search and keeps the other filters". The search line staying on Filter's row from 700 to 1700 wide, and the keyboard landing on Filter after Clear search: **gap** (seen in a headless browser at 390, 700, 1024, 1280 and 1700, light and dark, on 28 Oct) |
| `/auctions` | Every auction, with chain, status and Verified filters and search | Filter links: as `/`. Load more: `autolaunch_web/public_page_test.exs` › "a cursor pages on only the list it came from", › "an edited cursor is refused". Short figures (K, M, B, T): `autolaunch_web/components/market_card_test.exs` › "a short figure reads back within half a percent, in at most three digits". Verified filter presses (44 px on touch, normal with a mouse): `/Users/sean/Documents/regent/artifacts/autolaunch-backlog-2026-10-19/scripts/filter-presses.mjs`. One figure a row on a phone (raised while live, price once finished): **gap** (seen in a headless browser at 390px on 21 Oct). Filter results: **gap** |
| `/auctions/<TICKER>/<tail>` | One auction: figures, bid, Details and How it works tabs, Activity and Timeline tabs | `autolaunch_web/live/market_page_test.exs` (all four cases); `autolaunch_web/live/market_page_record_test.exs` › "each auction and token page links its own API record and describes it"; `quiet_pages_test.exs` › "an auction page reads its row again for a new reading of its own auction, and for no other's"; `autolaunch/auction_figures_test.exs` (all four cases). The tabs: **gap** |
| `/tokens` | Every launched token, with chain and Verified filters and search | As `/auctions` |
| `/covered-calls` | Covered calls on a Base stock, while switched on: Buy lists the calls for sale with a Buy panel under each (`?listing=<id>`); Sell lists calls, beside the reference price, shares per token, suggested premiums, the result at expiry and the terms. "Available to eligible people outside the US." under the title, there only. A press the panel can't build steps for (the chain unreadable just now, or an amount that doesn't read) says "That did not go through. Nothing was sent. Try again in a moment." Off, the site's 404 | `autolaunch_web/live/covered_calls_live_test.exs` (all nine cases); every press, at 390 and 1280: `test/journeys/covered_calls.spec.ts` › "covered calls: list, buy, stop selling, exercise through a pause, collect stock and USDC" |
| `/after-hour-stocks` | After-hours Exposure on a Base stock, while switched on: the series' stock, term, status, deposits against the cap and last price; both tokens with their value, share of the stock, how much they move in their window and their pool price; Mint and Return tabs; every price applied and the next one, with Record and Apply buttons; the terms and their fingerprint. "Available to eligible people outside the US." under the title. Off, the site's 404 | `autolaunch_web/live/exposure_live_test.exs` (all nine cases). Every press on a copy of Base at 390 and 1280: **gap** |
| `/after-hour-stocks/terms/{hash}` | A series' terms, the exact bytes whose keccak256 the series holds | `autolaunch_web/controllers/exposure_routes_test.exs` › "a series' terms are served as the exact bytes its fingerprint names", › "every terms file the site serves is named by the keccak256 of its own bytes" |
| `/portfolio` (Covered calls) | The signed-in wallet's sold and held covered calls, each with the wallet steps it allows now | `test/journeys/covered_calls.spec.ts` (as above) |
| `/portfolio` (After-hours Exposure) | The signed-in wallet's After-hours and Market-hours tokens in each series, their value at the last price and a link to Return; a wallet with none is pointed to `/after-hour-stocks` | `autolaunch_web/live/exposure_live_test.exs` › "the portfolio lists the tokens a wallet holds, their value and a way back to Return", "the portfolio points a wallet without tokens to the page" |
| Creator names (lists, auction and token pages, share pictures) | One name for a launch's creator: checked account, else short wallet | `autolaunch_web/live/creator_label_test.exs` (both cases); share pictures keep their layout: `autolaunch_web/share_card_test.exs` (both cases) |
| `/tokens/<TICKER>/<tail>` | One token: price, Swap, Stake and Unstake tabs, Make a payment (Revstake) | First screen order (figures, then chart, then the widget): `autolaunch_web/live/token_page_first_screen_test.exs` › "the price, market cap, change and creator come before the chart and the trade widget". Its API record link and structured data: as the auction page. `market_page_test.exs` › "a token page whose token cannot be read is the plain error page, not a 404 or a 503"; `autolaunch_web/token_details_test.exs` › "LONG_POOL_PRICES_ARE_CUT_NOT_PARSED"; `autolaunch/token_trades_test.exs`; `autolaunch/pool_price_test.exs` (all four cases); `autolaunch_web/components/token_display_test.exs` (all three cases, and the properties "a short amount keeps four digits and never rounds a refund up", "counted zeros write back to the same figure"). The tabs: **gap** |
| `/create` | Memestock launch form: draft autosave, paired stock, Base or Robinhood | `autolaunch_web/live/stocks_create_live_test.exs` › "autosaves each section and states the fixed minimum for the chosen stock", › "STOCK_LIST_UNREAD_SAYS_SO: a stock list that can't be read says so, with Try again"; `autolaunch/stocks/launch_draft_test.exs` › "another account can neither read nor update a Stocks draft". With an agent's whole draft, reviewed and signed on a copy of Base at 390 and 1280: `scripts/agent-journeys.sh`, `test/journeys/memestock_launch.spec.ts` |
| `/create/revstake` | Revstake launch form on Base | `autolaunch/launch_draft_test.exs` (both cases). The page itself: **gap** |
| `/stock-listing` | Stocks available to pair, each linking to its own page | `autolaunch_web/live/stock_listing_test.exs` (both cases) |
| `/stock-listing/<symbol>` | One stock: addresses, company links, dated pool research | As above |
| `/how-it-works` | Fixed contract rules, explained | **Gap** |
| `/portfolio` | The signed-in wallet's bids and tokens | `autolaunch_web/live/robinhood_pages_live_test.exs` › "/portfolio outlives a Robinhood feed's new block" |
| `/portfolio/bids/<id>` | One bid on its own page | **Gap** (its steps: see Wallet actions) |
| `/account` | This site's own sections first (Credits and Points activity, connected accounts), then who is signed in, the paired agents, Pair New Agent (`#account-pairing`; each agent keeps its own code until it expires), Credits, Points and the name people see | `autolaunch_web/live/account_live_test.exs` › "ACCOUNT_SHOWS_A_PAIRED_AGENT", › "PAIRING_CODE_KEPT_PER_AGENT", › "ACCOUNT_MENU_ON_EVERY_PAGE" (the page's order and the one pairing box); `browser/account_menu.spec.ts` › "the Account page shows this site's sections first, then the shared ones"; the agent's check-in time, and the agent leaving the list once it is unpaired on regents.sh: `scripts/agent-journeys.sh`, `test/journeys/pairing.spec.ts`. Saving the name people see: **gap** |
| Account menu (the account's button at the top right of every page) | Up to three paired agents (most recently active first), Pair New Agent (to `/account#account-pairing`), Manage Account and Sign out; at 320 wide the Credits balance moves into it | `autolaunch_web/live/account_live_test.exs` › "ACCOUNT_MENU_ON_EVERY_PAGE" (a LiveView page and one without); `autolaunch_web/menu_agents_test.exs` (which three); `browser/account_menu.spec.ts` (all cases, at 390 touch and 1280, and 320 and 2000 for where it hangs) |
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
| Stay signed in when the sign-in can't be read for a moment (Try again, nothing saved meanwhile) | `autolaunch_web/live/sign_in_read_test.exs` (all six cases); `autolaunch_web/sign_in_unread_panels_test.exs` (all four cases); `autolaunch_web/live/held_sign_in_writes_test.exs` (all six cases); the top bar then, on a phone: `browser/layout.spec.ts` › "the Regents Products name stays on screen with nothing to its right" |
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
| Bid on a Base auction | From the auction page with the person's own wallet, every press at least 44 px on a phone once the balance is read: `test/journeys/memestock_auction.spec.ts`, `test/journeys/memestock_launch.spec.ts` (L6); `autolaunch/bid_actions_test.exs` (every case); `autolaunch/bid_slippage_test.exs`; `autolaunch/chain/calls_test.exs` › "BATCH_IS_THE_REVIEWS_ONLY_WITH_EVERY_CALL"; `autolaunch/lab_bid_chain_client_test.exs` |
| Bid on a Robinhood auction, see its standing | `autolaunch_web/live/robinhood_stock_bid_component_test.exs` (both cases). The bid itself: **gap** |
| Add to, raise, or take back an outbid bid early | **Gap** |
| Withdraw or claim after an auction | `autolaunch/bid_settlement_actions_test.exs` (all five cases); a press before the card has its review is prepared and sent: `autolaunch_web/live/bid_settlement_press_test.exs` › "SETTLE_PRESS_BEFORE_REVIEW_SENDS", `onchain_steps.test.ts` › "a press with no review yet asks the server for one when the card prepares on press"; from the auction page with the person's own wallet: `test/journeys/memestock_auction.spec.ts` |
| Finish an ended auction | `autolaunch/auction_finish_test.exs` (all seven cases); `autolaunch/auction_finish_wallet_test.exs` |
| Launch a Memestock token | `autolaunch/stocks/launch_actions_test.exs` (and its property "REVIEW_SIGNS_ONLY_WHAT_WAS_REVIEWED"); `autolaunch/stocks/amounts_test.exs` (all three cases); `autolaunch/memestock_discovery_test.exs` (all five cases). A launch sent straight to the launchpad, as an agent sends one from its own wallet, is listed under that wallet with no account and only what passes the site's checks: `autolaunch/memestock_discovery_test.exs` › "a launch made outside the site is listed under the wallet that sent it, with only what passes the site's checks", `autolaunch/stocks/chain_launch_test.exs` › "CHAIN_LAUNCH_SHOWS_ONLY_WHAT_PASSES", › "a ticker with an invisible character inside reads as the letters it shows"; a ticker the site's rule refuses is not listed, a launch an earlier pass left unlisted is listed on the next while one on a retired launchpad stays unlisted, a launch seen only on another chain is never listed, a launch taken again that cannot be listed yet waits, and the two test launches the operator hid are never listed (`autolaunch/memestock_discovery_test.exs`); end to end, the agent's wallet owns it, is paid the creator allocation and the creator's fee share, and the site's own discovery lists it (`test/journeys/memestock_own_wallet.spec.ts`, L9), while a site launch stays its person's (`test/journeys/memestock_launch.spec.ts`). The press itself, from an agent's draft: the page's button hands the person's wallet exactly the reviewed launch, the launchpad records their wallet and the stock, and eight confirmations at once list it once (`scripts/agent-journeys.sh`, `test/journeys/memestock_launch.spec.ts`). The auction opening, taking a bid, ending and being finished from its page, graduated (with the bidder's claim) and failed: `test/journeys/memestock_auction.spec.ts` |
| Launch a Revstake token | `autolaunch/launch_discovery_test.exs` (all seven cases); `autolaunch/treasury_chain_client_test.exs` (both cases) |
| Swap a token | **Gap** |
| Stake, unstake, collect | `autolaunch/stocks/stake_actions_test.exs` › "settle on a Base Revstake launch is one collect(lp_token_id) step on the lp_locker". Stake and unstake: **gap** |
| Make a payment into a Revstake split | **Gap** |
| Sell fee shares on `/convert` | **Gap** |
| Lab line, header, account menu and phone menu in order on a lab site; the page stays put as they open and close; a jump to a heading stops under the header | `browser/layout.spec.ts` › "on a lab site the header, account menu and phone menu open under the lab line" (320, 390, 1280) |
| Phone navigation menu covers the bottom bar and makes the page and the bar inert until it closes | `browser/layout.spec.ts` › "on a phone, the open menu covers the bottom bar and makes it and the page inert" (320, 390) |
| Lab test funds (lab sites only) | `autolaunch/stocks/faucet_test.exs` (refused on a Base mainnet site and on a lab until it is open). Sending on a lab: **gap** |

Covered calls (`AutolaunchWeb.CoveredCallComponent`, steps built by `Autolaunch.CoveredCalls.Steps`):

| Action | Check |
| --- | --- |
| List calls (exact stock approval, then list), buy calls, stop selling, exercise, collect stock, collect USDC | `test/journeys/covered_calls.spec.ts` › "covered calls: list, buy, stop selling, exercise through a pause, collect stock and USDC" (on the copy of Base, at 390 and 1280, the buyer a wallet the site has never seen, unpaired and signing in for the first time: the 1% fee, a stock collection refused while the issuer pauses transfers with the words shown, the strike collected during the pause, both sides' stock collected after it) |
| The step for each action, with the reason a press is certain to fail | `autolaunch/covered_calls/steps_test.exs` (all eight cases) |
| Premium, strike and fee rounding, weekly expiries, typed amounts | `autolaunch/covered_calls/terms_test.exs` (four properties, three cases) |
| The contract itself | `contracts/covered-calls/bin/gate.sh` and its Base fork suite (`contracts/covered-calls/README.md`) |

After-hours Exposure (`AutolaunchWeb.ExposureComponent`, steps built by `Autolaunch.Exposure.Steps`):

| Action | Check |
| --- | --- |
| Mint (exact stock approval, then mint), return pairs, return each token after the end, record and apply a price | `test/journeys/exposure.spec.ts` (every press on a copy of Base at 390 with touch and 1280); End series on the copy: **gap** |
| A Record panel still open when the series ends says it has ended | `autolaunch_web/live/exposure_live_test.exs` › "a series that ends while the Record panel is open says it has ended" |
| After the end each token is shown as the stock it returns, on the page and in the portfolio | `autolaunch_web/live/exposure_live_test.exs` › "after the end each token is shown as the stock it returns" |
| An amount typed with a comma is refused with how to write it | `autolaunch_web/live/exposure_live_test.exs` › "an amount typed with a comma is refused and says how to write it" |
| End series is shown from the start, disabled with its reason until the price is overdue | `autolaunch_web/live/exposure_live_test.exs` › "End series is on the page from the start, disabled until the price is overdue" |
| A press blocked by time comes back when that time passes (the panel builds its steps again then, and its one timer is never stacked) | **Gap** (no clock-driven check) |
| The step for each action, with the reason a press is certain to fail, the round in force at a price's moment, and steps only for the account's own wallet | `autolaunch/exposure/steps_test.exs` (all thirteen cases) |
| The series arithmetic: ledgers always add up to the price, never go below zero, the series ends exactly when one would, and no return owes more than the stock behind it | `autolaunch/exposure/ledger_test.exs` (five properties, three cases) |
| The contracts themselves | `contracts/exposure/bin/gate.sh` and its Base fork suite (`contracts/exposure/README.md`) |

## Shared links

| Action | Check |
| --- | --- |
| Share picture of an auction or token | `autolaunch_web/launch_image_test.exs` (both cases); `autolaunch_web/share_card_test.exs` (both cases) keeps every word inside the part X's phone view shows. The rest of the picture's content: **gap** |
| Share picture of the home page (`platform/priv/static/images/og-image.png`, drawn by `node scripts/share-card/render.cjs` from `scripts/share-card/home.html`) | The drawing script refuses a word past X's narrow view or under X's title; `autolaunch_web/share_card_test.exs` › "SHARE_HOME_PICTURE: the home picture leaves X's title band clear" reads the committed picture |
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
| (all tools) | Chrome offers the tools only when the answer allows `tools` for this site and carries a live WebMCP origin-trial token for https://autolaunch.sh (valid to 29 Mar 2027) | `autolaunch_web/page_tools_headers_test.exs` › "pages, Markdown documents, refusals and API answers all allow the page tools"; `make readiness` checks the token on each page it opens. after each release `node scripts/webmcp-live.cjs` opens the live home page in headless Chromium, lists the tools Chrome holds against the manifest's site tools and runs `autolaunch_auction_counts` through Chrome's own `executeTool` |
| (all public reads) | Any website's page may read the six public `GET` routes; no account or agent route | `autolaunch_web/controllers/public_read_origin_test.exs` › "the public reads allow any origin, and no signed or account route does" |
| `autolaunch_auction_counts` | `GET /api/v1/auction-counts` | `auction_controller_test.exs` › "the counts give each launch type's live and graduated auctions on each chain" |
| `autolaunch_tokens` | `GET /api/v1/tokens` | `public_api_failures_test.exs` (same case); `autolaunch_web/controllers/token_controller_test.exs` › "a token's price and market cap read in REGENT and in dollars, list and detail alike"; `autolaunch/auction_figures_test.exs` › "a stated price keeps at most 18 significant digits and is the stored one rounded up" |
| `autolaunch_token` | `GET /api/v1/tokens/{id}` | As above; a Revstake token's revenue history: `token_controller_test.exs` › "a Revstake token gives its revenue history, newest first; a Memestock token has none", recorded from the splitter: `autolaunch/token_revenue_test.exs` › "a Revstake token's pass records its splitter's revenue with its trades" |
| `autolaunch_treasury` | `GET /api/v1/treasury-security/{address}` | `public_api_failures_test.exs` (same case); `treasury_chain_client_test.exs` (both cases) |
| `autolaunch_bid_quote` | `POST /api/v1/auctions/{id}/bid-quote` | `bid_actions_test.exs` › "LONG_STORED_PRICE: a bid estimate reads the whole stored price, never zero, and states it so a bid at it reaches it"; `public_api_failures_test.exs` (same case) |
| `agent_whoami` | `GET /api/agents/v1/whoami` | `autolaunch_web/controllers/agent_check_in_test.exs` (all four cases). Signed by the regents binary through a real sign-in service: `scripts/agent-journeys.sh`, `test/journeys/pairing.spec.ts` (P1, P2, P10) |
| `agent_status` | `GET /api/agents/v1/me` | `agent_check_in_test.exs` (all four cases); `autolaunch_web/controllers/agent_pairing_properties_test.exs` › "AN_AGENT_ACTS_ONLY_FOR_ITS_OWN_PERSON"; signed, and answered while the sign-in service is down and once it is back: `test/journeys/pairing.spec.ts` (P8), `test/journeys/pairing_refusals.spec.ts` |
| (CLI `agents pair`) | `POST /api/agents/v1/pair` | `account_live_test.exs` › "ACCOUNT_SHOWS_A_PAIRED_AGENT" pairs through the shared library; the rules for every input: `agent_pairing_properties_test.exs` › "PAIRING_CODE_WORKS_ONCE", › "PAIRING_CODE_ENDS_AT_TEN_MINUTES", › "ONLY_OFFERED_HARNESSES_PAIR", › "PAIR_TAKES_EXACTLY_CODE_NAME_AND_HARNESS", › "AGENT_LIMIT_IS_ONE_HUNDRED"; from the person's pairing box on their Account page to the agent's name on their screen, and the refusals, signed by the regents binary: `test/journeys/pairing.spec.ts` (P3 to P7), `test/journeys/pairing_refusals.spec.ts`; the steps the pairing message names: `agent_documents_test.exs` › "PAIRING_MESSAGE_STEPS_ARE_WHERE_IT_SAYS"; whoami, check-in and pairing answer only what the served contract documents: `agent_contract_test.exs` › "AGENT_ROUTES_ANSWER_AS_THE_CONTRACT_SAYS" |
| `autolaunch_revstake_draft`, `autolaunch_revstake_draft_save` | `GET` and `PATCH /api/agent/v1/drafts/revstake` | **Gap** |
| `autolaunch_memestock_draft`, `autolaunch_memestock_draft_save` | `GET` and `PATCH /api/agent/v1/drafts/memestock` | The whole draft (text, picture, chain, stock) saved by the regents binary, a too-long name refused whole, and the open create page naming every field with the stock's address copyable: `test/journeys/memestock_launch.spec.ts` (L2); `autolaunch_web/live/agent_draft_review_test.exs` › "AGENT_SET_ADDRESS_IS_COPYABLE" |
| (none) | Make a payment (Revstake token page): addresses from the launch's own record, read by the Base reader, canonical receiver only, on the launch's own network | `autolaunch/payment_card_test.exs` (all three cases). The wallet press itself: **gap** |
| `autolaunch_revstake_draft_save`, `autolaunch_memestock_draft_save` | `PATCH /api/agent/v1/drafts/{kind}` | `autolaunch/agent_drafts_test.exs` (all three cases); the create page names every agent-set field: `autolaunch_web/live/agent_draft_review_test.exs` › "the create page names what the agent set, and forgets a field the person changes", › "the launch review names every agent-set field and shows the community links". The signed request itself: **gap** |
| `autolaunch_my_positions` | `GET /api/agent/v1/positions` (and `GET /api/v1/me/positions` signed in) | Refusals: `agent_check_in_test.exs` › "AGENT_PAIRING_WITHOUT_ACCOUNT_IS_NOT_PAIRED", › "AGENT_PERSON_UNREAD_IS_503"; `sign_in_read_test.exs` › "a lost sign-in read is a 503 for the signed-in wallet's positions and share video". A working read for the paired person, and the refusal for an unpaired agent, signed by the regents binary: `test/journeys/pairing.spec.ts` (P9), `test/journeys/pairing_refusals.spec.ts`. `wallet_required` for an account with no wallet: **gap** (no one without a wallet can sign in here) |
| `account_balances` | `GET /api/agent/v1/account/balances` | Answers when paired, refused when not: `test/journeys/pairing.spec.ts` (P9), `test/journeys/pairing_refusals.spec.ts` |
| `account_credits_history` | `POST /api/agent/v1/account/credits/history` | **Gap** |
| `account_points` | `GET /api/agent/v1/account/points` | Refused when not paired: `test/journeys/pairing.spec.ts` (P2), `test/journeys/pairing_refusals.spec.ts`. The paired answer: **gap** |
| `prepare_agent_request` | In the page, sends nothing | **Gap** |
| `autolaunch_covered_call_listings` | `GET /api/v1/covered-calls/{symbol}` | `autolaunch_web/controllers/covered_calls_routes_test.exs` › "the public book shows each listing's stage and what is left, and the quote suggests a premium", › "the public routes refuse an unknown market, an expiry that is not a Friday close and unknown fields" |
| `autolaunch_covered_call_quote` | `POST /api/v1/covered-calls/{symbol}/quote` | As above |
| `autolaunch_my_covered_calls` | `GET /api/agent/v1/covered-calls/{symbol}/positions` (and `GET /api/v1/me/covered-calls/{symbol}` signed in) | `autolaunch_web/controllers/covered_calls_routes_test.exs` › "a signed agent's steps are built only for a wallet of the account it acts for" (the agent's read), › "the signed-in route needs a sign-in and reads only the signed-in wallet" |
| `autolaunch_covered_call_prepare` | `POST /api/agent/v1/covered-calls/{symbol}/steps` | `autolaunch_web/controllers/covered_calls_routes_test.exs` › "a signed agent's steps are built only for a wallet of the account it acts for" (fill and list, a wallet not the account's own refused, blocked until approved). Cancel, exercise, claim and collect strike over this route: **gap** (built by the same steps module) |
| (covered-call switch) | Off, every covered-call route is an unknown address and the site is what main serves: `/openapi.json` is the API contract exactly, and no tool, guide section, page, script or stylesheet names covered calls | `autolaunch_web/controllers/covered_calls_routes_test.exs` › "COVERED_CALLS_OFF_IS_NOT_FOUND: every covered-call route answers as an unknown address while covered calls are off", › "COVERED_CALLS_ADVERTISED_ONLY_WHEN_ON: tools, routes, guides and the tools handed to the page follow the switch"; `autolaunch_web/controllers/covered_calls_off_test.exs` › "COVERED_CALLS_OFF_OPENAPI: /openapi.json is the API contract built without covered calls", › "COVERED_CALLS_OFF_UNNAMED: no agent document or page names covered calls", › "COVERED_CALLS_OFF_NO_ASSET: the covered-call styles' address answers as an unknown asset"; every script and stylesheet four pages load, every built file the site serves, and the styles' address not found: `test/browser/switched_off.spec.ts`; the page registers them only when handed: `public_tools_features.test.ts` › "a page's own tools are registered and preparable only when the server hands them over" |
| `autolaunch_after_hour_stocks_list` | `GET /api/v1/after-hour-stocks` | `autolaunch_web/controllers/exposure_routes_test.exs` › "the public reads give the series' tokens, values, prices and schedule" |
| `autolaunch_after_hour_stocks_series` | `GET /api/v1/after-hour-stocks/{series}` | As above |
| `autolaunch_my_after_hour_stocks` | `GET /api/agent/v1/after-hour-stocks/{series}/holdings` (and `GET /api/v1/me/after-hour-stocks/{series}` signed in) | `autolaunch_web/controllers/exposure_routes_test.exs` › "a signed agent's steps are built only for a wallet of the account it acts for" (the agent's read). The signed-in route: **gap** |
| `autolaunch_after_hour_stocks_prepare` | `POST /api/agent/v1/after-hour-stocks/{series}/steps` | `autolaunch_web/controllers/exposure_routes_test.exs` › "a signed agent's steps are built only for a wallet of the account it acts for" (mint, a wallet not the account's own refused, blocked until approved, unknown fields refused). Redeem, update and end over this route: **gap** (built by the same steps module) |
| (After-hours Exposure switch) | Off, every route is an unknown address and nothing advertises them | `autolaunch_web/controllers/exposure_routes_test.exs` › "EXPOSURE_OFF_IS_NOT_FOUND: every route answers as an unknown address while switched off", › "EXPOSURE_ADVERTISED_ONLY_WHEN_ON: tools, routes, guides and the page's tools follow the switch" |
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
stake and unstake; Make a payment; selling fee shares; share picture content; the Revstake
draft routes, the paired Points and Credits history answers, and `prepare_agent_request`; an agent's
positions for an account with no wallet; the shared profile routes; the Robinhood second pass of the
agent journeys; covered calls' cancel, exercise, claim and collect strike over the agent route, and
their hosted MCP and CLI surfaces (`docs/agent-parity.md`).
