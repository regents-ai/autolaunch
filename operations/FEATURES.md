# Feature map

What a person or an agent can do on Autolaunch.

Map as of 27 October 2026. A release that adds or changes something here updates its line.

## Pages

| Page | What it does |
| --- | --- |
| `/` | Three product cards (Covered calls, Memestock, Revstake; a switched-off product has none), and Earn's fourth while Earn is switched on (two by two below 1200 px wide), each one link to its page and dark in both themes: a tall moving GPU panel of coloured glyphs in the product's own gradient (`HomeCells`: payoff, seam, columns and Earn's rise patterns, steered by the pointer; one still moment under reduced motion; a still frame of the panel, drawn by `npm run stills:home`, until it has drawn and without WebGPU), then the product's name in its colour beside its place in the row (01 / 03; none for a card alone or a very narrow one), one line saying what it is for, a sentence, and the action under a dashed rule, the launch links switched off with "Opens soon" before launches open; then one list chosen from Auctions, Tokens and Options: auctions with filter (Status, Network, Type, Creator verified), search and display; tokens with All, Memestock or Revstake; Options the covered calls for sale, each opening its Buy panel; Coming next and the bid-volume row under the list; then Principles, six value cards (Fair price, Locked liquidity, Stock tokens, Your wallet, Agents, Onchain), each one link to the page that explains it and dark in both themes, with a moving GPU panel in the card's own colours (`ValueCard`, the template's shared row) over a still frame drawn by `npm run stills:value-cards` |
| `/auctions` | Every auction, with chain, status and Verified filters and search |
| `/auctions/<TICKER>/<tail>` | One auction: figures, bid, Details and How it works tabs, Activity and Timeline tabs |
| `/tokens` | Every launched token, with chain and Verified filters and search |
| `/stock/covered-call` | Covered calls on a Base stock, while switched on: each tab is a trade ticket beside its receipt, opening on the stock's last 30 days of reference prices (`Autolaunch.CoveredCalls.PriceLine`, read every five minutes once for every open page) with the strike drawn across them, on Buy the break-even too, and on Sell a strike chosen or typed moved there at once in the browser; while the 30 days are unread or the last read failed, the same box with no line, and without WebGPU the caption alone. Sell: amount (its worth at the reference price under it; signed in, the wallet's stock at the latest block with a Max that fills the box in the browser at the press, so a press straight after carries it), one of the next four Friday expiries, a suggested or custom strike and the premium (the suggestion, or typed, with a way back), beside the receipt (under You receive, the share of the stock's worth kept if all sells, and in plain sight that the premium is paid only as each buyer buys) and three outcomes named by what the buyer does (Not exercised, Exercised, Unsold), then Risks: sold stock is locked until the window closes, the price can fall meanwhile and the gain above the strike goes to the buyer; all from the quote. Every ticket names its stock under its title by issuer, chain and address, every review starts with the same line, the reference price is labelled Reference with its age, the premium's suggestion is labelled Model, and under the premium the best open bid (Sell) or lowest listing (Bid) on the ticket's own Friday and strike shows with its size. Beside My calls a signed-in holder whose window is open or opens within three days reads when it closes. Buy lists the calls for sale; a listing's ticket opens under the list (`?listing=<id>`) with the amount, and its receipt: for the amount, what it costs, what a full exercise pays and the stock it delivers; per token, the strike and the break-even; then three outcomes. Under the Sell ticket, Bids lists the open bids (strike, premium, exercise window, still wanted), equal terms together and the best for a seller first (soonest expiry, then lowest strike, then highest premium, then oldest), and is absent with none; Sell on a row opens its Sell now ticket under the list (`?bid=<id>`): the amount (signed in, the wallet's stock with a Max of the lesser of it and what the bid still wants), the bid's strike on the price line, and the receipt led by You receive, the premium less the 1% fee counted as the contract counts it (signed out too; the prepared sale counts the same at the latest block), paid in the sale's own transaction, then Wanted, If exercised, the minimum when it is not one whole token (the bid's own, or all that is left when less is), the window and two outcomes. A link to a bid or listing still open on the chain that the list leaves out (less than a whole token left, an expiry the site doesn't list, outside the best 50) opens the same ticket, that one record read on its own at the latest block, with a line saying why it is not in the list; the list and its counts stay as they are. A link to one stopped, sold out, past its expiry or unknown (an id that isn't a number included) says which in one line and opens no ticket. A Buy / Bid switch tops Buy; Bid (`?tab=bid`) takes the Sell ticket's amount, expiry, strike and premium, beside a receipt of You pay (the escrow), To exercise, You get, Break-even and the window, the minimum sale (a whole token, or the whole bid when smaller) said only in the receipt's note, and three outcomes. A ticket keeps a line under its button for the reason it is disabled. "Available to eligible people outside the US." under the title, there only. Each panel's button reviews the ticket as it stands and opens the wallet steps over it, as Stake does: the USDC approval then the purchase (or the bid), the stock approval then the listing (or the sale into a bid), an approval already on the chain shown as done; disabled with the reason when the chain makes the action certain to fail; a review that can't be built (the chain unreadable just now, or an amount that doesn't read) says why and opens nothing. Off, the site's 404 Visible strike and premium figures retain all posted digits, open bids show nonstandard minimum sales, and the exercise comparison uses seller proceeds after fees. Off-list tickets are reread at expiry and a temporary read can be retried with Refresh. |
| `/stock/isolated-afters` | Isolated Exposure to After-hours Stocks on a Base stock, while switched on: a picker naming each series ("AMZNc · 2–6 Nov · Upcoming"); the series' stock, term, status, deposits against the cap, last price and next price (recordable from, or waiting to be recorded); before the first close one line that allocations are set then, and beside Split when splitting opens; each token's ledger value, stock claim per token (provisional, final after the end) and leverage, with "Trading opens when liquidity is added." until its pool has liquidity; an illustrative Example; Split and Redeem tabs; every applied price; terms; Series details with every address and Record price, Apply price and End after missing price The Stocks menu and sitemaps include the page while enabled. Buy and Sell preserve the explicitly selected token in the URL. |
| `/stock/isolated-afters/terms/{hash}` | A series' terms, the exact bytes whose keccak256 the series holds |
| `/portfolio` (Covered calls) | The signed-in wallet's sold and held covered calls, all read at one block, those whose exercise window is open first, each with its time left counted down in the browser from the chain's time at the reading (`Countdown`) over when it closes in the reader's time with UTC (a listing stopped before any sale reads "Stopped" and offers only the claim of its stock), each in parts with the step each part still has (Sold; Premium, what the sold part paid; For sale, then Unsold through the window, with Stop selling; Locked, the stock under calls sold and not exercised until the window closes, with no button; Exercised, with Collect USDC; Held, with Exercise, then Lapsed; To collect, with Collect <symbol>, only what the contract sends now, which once the window has closed is everything not exercised, said as "6 unsold, 3 not exercised"), under a line naming the stock and the contract by address, each row's window given as when it opens and closes in the reader's time until it opens; and each of the wallet's bids (Open, Stopped, Expired, or Closed once nothing is left to sell) in parts: Sold ("3 of 10 AMZNc", a closed bid "2 AMZNc") with Raise (an amount and its button) while open, Held (the premium behind the unsold part) with Stop while open, and Refund while there is any; each reviewed over the row before the wallet step and disabled with the reason while the chain makes it certain to fail The preceding reading stays available after a temporary wrong-chain response. |
| `/portfolio` (Isolated Exposure to After-hours Stocks) | The signed-in wallet's After-hours and Market-hours tokens in each series, their value at the last price and a link to Redeem; a wallet with none is pointed to `/stock/isolated-afters` |
| `/earn` | Earn, while switched on: lend USDC on Base through Aave from the person's own wallet. The market's terms, one reading every visitor and agent shares for at most ten seconds and taken again the first time each transaction that landed a step is reported, on any of the site's machines, with the block it was read at and its time named (Rate, a year at today's rate before compounding, cut to two decimals; Supplied; Available, what can be withdrawn now; Capacity under the supply cap, No cap or Full; the market's status), one line on where the interest comes from, and Risks in plain words; no figures before the first reading, a reading that fails says so, and Refresh reads again, starting nothing while a reading is under way. Beside them, from the start and whether or not a reading came, the wallet panel, as covered calls' panels work: Balance and the wallet's USDC, Deposit and Withdraw tabs, an amount with Max (the wallet's USDC on Deposit; on Withdraw everything, the balance as it stands when the step lands), the button reviewing the amount as it stands and opening the wallet steps over the panel (an exact USDC approval, then Confirm deposit; Confirm withdrawal), disabled only when the chain makes the step certain to fail, with the reason beside it, and coming back when it allows it (the preview read again on each settled amount, wallet change, return to the page, press, Refresh and landed step, and never held by an earlier reason while the chain is read again); another wallet starts from an empty amount; an amount that does not read said under the field, disabling nothing; signed out a Sign in button, no wallet open or another network said on the press. A confirmed step reads the market again on every open page and the wallet again, once for each transaction, and says the exact amount moved, as the review gives it; a switched-off site answers its 404 |
| `/portfolio` (Earn) | While Earn is switched on, the signed-in wallet's balance in each Earn product read at the latest block, with Withdraw; Deposit for a wallet with nothing lent; a balance that could not be read says so; Refresh reads it again; signed out, no section |
| Creator names (lists, auction and token pages, share pictures) | One name for a launch's creator: checked account, else short wallet |
| `/tokens/<TICKER>/<tail>` | One token: price, chart by Trades or Time, Swap, Stake and Unstake tabs, Make a payment (Revstake) |
| `/create` | Memestock launch form: draft autosave, paired stock, Base or Robinhood |
| `/agent-business` | Revstake launch form on Base: Still needed and Review launch follow typing, each field saves when left; a creator with no checked X account, GitHub or ENS (`Autolaunch.Accounts.connected?/1`) types a warning before the review |
| `/stocks` | The stock products' cards as on `/` (Memestock, and Covered calls while switched on), then the searchable directory by name, ticker or token address, with network and availability filters in the URL. Available to Pair, Soon Available and Feed Required keep their established membership. Each stock links to its details |
| `/stocks/<symbol>` | One stock: issuer and chain, addresses with the proper explorer or copy-only pool ID, company links, dated liquidity observations and a link to covered calls when the open market matches that token |
| `/how-it-works` | Fixed contract rules, explained; each auction's length and a Memestock creator's release worked out from the launch's blocks on its chain |
| `/portfolio` | The signed-in wallet's bids and tokens |
| `/portfolio/bids/<id>` | One bid on its own page |
| `/account` | One column: this site's connected accounts first, then who is signed in, the paired agents, Pair New Agent (`#account-pairing`; each agent keeps its own code until it expires) and the name people see |
| Account menu (the account's button at the top right of every page) | Up to three paired agents (most recently active first), Pair New Agent (to `/account#account-pairing`), Manage Account and Sign out |
| `/account/points` | The total with today, yesterday and place; every action under its site, done wherever it was earned, a daily one with today's count, the ones this site earns left to do with where to do them, and the shared daily limit while a daily action earns here; the leaderboard by name or wallet, the reader's row marked; the NFT bonus; recent entries |
| `/regent` | REGENT facts and revenue sources |
| `/convert` | Memestock fee shares waiting to be sold, for the converter wallet |
| Search window (⌘ K) | Find an auction or token from any page |
| `/docs`, `/about`, `/privacy`, `/terms` | Guides and policies |
| `/blog`, `/blog/<slug>` | Posts |
| `/unavailable` | Where the site's edge sends a visitor whose region a page is not offered in (the redirect rule in `operations/edge-rules.md`): the message inside the shell, top bar and rail, and Return to Autolaunch |
| Error pages | Not found (404), Try again only for a lost database connection (503), plain error (500) |

## Sign-in and account

- Sign in and sign out
- Stay signed in when the sign-in can't be read for a moment (Try again, nothing saved meanwhile)
- Connect or remove X
- A sign-in refreshes the account's own GitHub, Farcaster or X link to the account Privy lists in one write, updating the names and the time of the check, never when it was linked; when the account does not hold that link, whatever another sign-in just did, the sign-in links it
- Several accounts may link the same X account at sign-in, and a later link takes nothing from the others; a GitHub or Farcaster account another account holds is reported as already connected and not linked
- Only the site itself may list the accounts, links and X connections the Points start run reads, find which account holds an X account, or refresh a link; a signed-in person and a visitor with no sign-in are refused

## Wallet actions

Every wallet button goes through the same sender. It hands the wallet the exact reviewed
bytes from the reviewed signer and reports the hash once; two presses in a row both reach the
wallet while the first is still there; it sends through the active wallet when it answers for
another account, alone or in a batch; it sends nothing with no active wallet; it reports a
declined request and a step the review does not have; and for a batch it hands
`wallet_sendCalls` exactly the reviewed calls, atomically, after the chain read. A wallet off the
step's network is asked to switch through Privy's own switch on every press, for a Base or a
Robinhood step, alone or in a batch, and once the switch resolves the same press sends, naming
the step's chain, with no read of the chain after it to refuse the press; a declined switch is
told apart from a failed one, sends nothing, is counted and noted like any failed press, and the
next press asks again. Every reason a press may be reported with has words beside the buttons,
whatever wallets the panel holds. Privy is given every network the site's steps go to, Base
first or none at all, and the page carries public doors only: Privy's own Base, viem's Robinhood
Chain and a lab chain on the lab's own door, and no network settings for a site without a wallet
chain.

Accepted, not a fault (founder's ruling, 17 Nov 2026: the wallet swap does not happen, and it is
not guarded): the page never compares the wallet's account with the account a step was prepared
for. After the switch resolves, the step's chain rests on the chain id its request carries
(`chainId` on `eth_sendTransaction`, and on `wallet_sendCalls` for a batch). A step keeps the
address it was prepared for, as `from` and inside its call, so a press that a wallet signs from a
different active account pays from that account, while every call that names the prepared address
still names it, and the page shows that transaction as not the one it prepared. The calls that name
it: Earn's deposit credits it (`supply`'s `onBehalfOf`, `autolaunch/earn/steps.ex`) and Earn's
withdrawal pays it (`withdraw`'s `to`); Isolated Exposure's Buy and Sell pay it (the swap's
recipient, `autolaunch/exposure/steps.ex`); a Base bid in the auction's own currency is owned by
it (`submitBid`'s owner, `autolaunch/bid_actions.ex`). No other step's call names the prepared
address: it acts on a contract, a listing or a bid by its id, or on the sender itself, and a Base
launch names the treasury typed into its form.

A press while the page's connection is down, or before the server that took over answers,
still reaches the wallet with the review the page holds, and the rejoin asks that server for a
fresh one. A step that did not go through has its panel's review built again from the chain. A
button held because its step is certain to fail sends nothing, alone or in a batch. Every amount
a review shows is the exact raw amount, the largest uint256 amounts digit for digit.
What each action builds:

- Bid on a Base auction
- Bid on a Robinhood auction, see its standing
- Add to, raise, or take back an outbid bid early
- Withdraw or claim after an auction (a bid's status only moves forward: active, returnable, awaiting claim, claimable, then returned or claimed)
- Finish an ended auction
- Launch a Memestock token
- Launch a Revstake token
- Swap a token
- Stake, unstake, collect
- Make a payment into a Revstake split
- Sell fee shares on `/convert`
- Lab line, header, account menu and phone menu in order on a lab site; the page stays put as they open and close; a jump to a heading stops under the header
- Phone navigation menu covers the bottom bar and makes the page and the bar inert until it closes
- Each bid and trade in the bottom bar is a press as tall as the bar's Pause, 44 px, with its 32 px pill drawn at the middle as before; the bar holds the whole press, the Pause and the pill's focus ring under its 1 px top line
- Lab test funds (lab sites only)

Covered calls (`AutolaunchWeb.CoveredCallComponent`, steps built by `Autolaunch.CoveredCalls.Steps`):

- List calls (exact stock approval, then list), buy calls, stop selling, exercise, collect stock, collect USDC
- The step for each action, with the reason a press is certain to fail
- Premium, strike and fee rounding, weekly expiries (Fridays NYSE is shut or closes early left out), typed amounts
- Post a bid (exact USDC approval of its escrow, then bid), raise it, cancel it, take its refund, sell calls into it (exact stock approval, then sellToBid)
- Listings and bids read many to a request, settled ones read once, one reading shared by everyone asking, open bids best for a seller first
- A bid's escrow, a raise's cost, a sale into a bid less its fee and what a cancel frees, as the contract counts them
- The contract itself (CoveredCallsV2)
- The contract on Base, with the real AMZNc, USDC and REGENT staking

Isolated Exposure to After-hours Stocks (`AutolaunchWeb.ExposureComponent`, steps built by `Autolaunch.Exposure.Steps`):

- Buy a token with USDC and sell it back (exact approval to the Aerodrome router, then a swap through the token's pool taking at least its quote less 2%), once a pool has liquidity
- A swap is only ever built to take more than nothing: with no pool to quote it (`no_liquidity`), or a quote that comes to nothing less 2% (`too_small`), a buy or sell has no steps at all and no minimum, and on the page Buy or Sell and its approval are disabled with the reason and a press sends nothing
- Split (exact stock approval, then split), redeem pairs, redeem each token after the end, record and apply a price (from Series details)
- A failed press is counted and said beside the buttons, and a reason no page sends leaves the panel as it was
- A Record panel still open when the series ends says it has ended
- After the end each token is shown as the stock it returns, on the page and in the portfolio
- An amount typed with a comma is refused with how to write it
- End series is shown from the start, disabled with its reason until the price is overdue
- A press blocked by time comes back when that time passes (the panel builds its steps again then, and its one timer is never stacked)
- The step for each action, with the reason a press is certain to fail, the round in force at a price's moment, and steps only for the account's own wallet
- The series arithmetic: ledgers always add up to the price, never go below zero, the series ends exactly when one would, and no return owes more than the stock behind it
- The contracts themselves

Earn (`AutolaunchWeb.EarnComponent`, steps built by `Autolaunch.Earn.Steps` from Aave's pool on Base, read at the latest block):

- Deposit USDC (exact USDC approval to Aave's pool, then supply for the wallet) and withdraw it (an amount, or everything as the largest amount), each step ending with the Builder Code
- The reason a press is certain to fail (market closed, paused or frozen for deposits; not enough USDC; past the supply cap, counted as the pool counts it, each rounding down at the income index and the treasury's share included (checked against the pool on a local copy of Base by hand, 15 Nov); past the balance; more than the market has now), checked in a fixed order, the steps still returned
- The market's word read bit by bit (decimals, flags, supply cap), the rate as a yearly percentage cut to two decimals, typed and pasted amounts up to 9,007,199,254,740,991
- A confirmed step reads the market again on every open page and the wallet again, and closes the review with the exact amount moved
- The same transaction reported again, or checked again while it is still being read, starts no second check
- A new reading drops the reason that held the button, so it can be pressed until the chain answers again; the page drawn again with nothing new for the panel reads nothing again
- The wallet panel is there while the market can't be read, and says why a preview couldn't be had without disabling anything
- The market's terms are one reading shared for ten seconds: readers at the same moment wait for one reading, a landed step moves on to a new one once for each transaction however often or however many at once it is reported, a machine that hears of a step from another counts it once before its pages read, a cache that can't be used refuses the reading and a landed step is logged and still told, a failed reading is not kept; Refresh during a reading starts no second one
- A paused or closed market disables both steps with the reason, and Refresh reads the panel's preview again so the button comes back
- Another wallet starts from an empty amount with Max off; a change with no amount or a check of a hash that is not text leaves the panel as it is
- Earn that can't be read is refused with its own code and words: no deployment to read it on (`earn_unavailable`), a node answering for another network, with what isn't a number or with what isn't a block, a market whose asset has other decimals than the catalog gives it

## Shared links

- Share picture of an auction or token
- Share pictures of the home page and `/how-it-works` (`platform/priv/static/images/og-image.png` and `og-how-it-works.png`, drawn by `node scripts/share-card/render.cjs` from `scripts/share-card/home.html` and `how-it-works.html`; neither states a length of time)
- Share video, everyone's or a wallet's own
- Old links (`/auctions/<id>`, `/tokens/<id>`, `/robinhood/...`) move to today's page

## Background reads

- The stock list's market read: a chain node that does not answer is one warning, the stock's turn moves on and nothing it found before is changed; an answer in another shape fails the read
- Stock dollar quotes omit malformed, nonpositive and stale feed answers while keeping good quotes. The weekly volume scheduler selects admitted stocks only.

## Points awards

Earning opens in production at 16 November 2026 17:00 UTC for every rule below (platform/config/prod.exs), the five account rules every Regent site offers from their release on (founder decision "31 a"); everywhere else it is closed (no start time, no rule approved). A trade, a stake or a covered-call sale is offered to Points only when it is first saved, so one saved while its rule is not approved is never offered later; the one exception is a rebuild of a token's trades after the chain changed, which saves each trade again and offers it again then. A stake the chain later took back stays saved, and so does a covered-call sale the chain later dropped, which keeps what it earned (founder decision "5 a": the reader logs one warning and carries on). A rebuild asks the node again for the sender of every trade in the token's history, one lookup per transaction, four at a time, at most 40 transactions a pass, so a busy history is read over several passes. An account, link, X connection or pairing is offered when it is made or replaced here. At most once a day the start run (`RegentPoints.StartAwards`) records what no offer did, such as a link made while the account rules were not approved: this site's GitHub and Farcaster links and profile X connections, and the accounts and first pairings in the tables every Regent site shares, so it can record an account or a first pairing made on another site that no site has recorded yet. What came before the start earns at the start, what came after at its own time, and each earns once. A site still in read-only mode runs no jobs, so it approves no rule and offers nothing (platform/config/runtime.exs); the start run records what it holds once the site is open.

- A launch the site saves earns First Autolaunch launch once for the account whose verified wallets held the launching wallet then, however many launches follow; saving the same launch again offers nothing
- Autolaunch auction created earns once each UTC day, a second launch that day counting at nothing
- A launch's token saved once it graduated earns its creator First Autolaunch graduation once; seeing the same graduation again offers nothing
- A launch from a wallet no account held is still saved and earns nothing, refused as not linked; a hidden launch earns nothing
- While no rule is approved a launch or graduation queues and writes nothing for Points
- A Base bid the site saves as its bidder's position, from the bidder's page or the auction's reader, whichever comes first, earns Autolaunch auction bid once each UTC day for the account whose verified wallets held the bidding wallet then; a second bid that day counts at nothing
- A bid's position saved again, seen again by the auction's reader, or kept through a rebuild of the auction's activity keeps its row and award and offers nothing more
- A bid from a wallet no account held is still saved and earns nothing, refused as not linked; a bid on a hidden or unlisted launch earns nothing; a launch's creator bidding on it earns like anyone
- While earning is closed the auction's reader still saves each bid and queues and writes nothing for Points
- A Robinhood bid earns nothing: the site saves no position for it (`Autolaunch.Robinhood.Positions` reads them from the chain)
- A trade the token's reader saves, with the wallet that sent its transaction as its trader, earns Autolaunch token trade once each UTC day for the account whose verified wallets held that wallet at the trade's block time; a second trade that day counts at nothing
- Reading the same block again keeps each saved trade and its trader and offers nothing more; a rebuild after the chain changed saves each trade again under the same key, and Points records it once
- A trade from a wallet no account held is still saved and earns nothing, refused as not linked; a trade saved before the site recorded traders, or in a hidden launch's token, earns nothing
- A pass asks the node who sent a transaction only when the transaction holds a trade not saved yet: a caught-up pass reading its head block again asks nothing, and a saved trade keeps its trader
- A pass asks the node about at most 40 new transactions at once: with more, it reads the first half of its blocks instead, down to one block, before asking anything, and the next passes read on, so a busy range or a rebuild is read in several passes with every trade's trader
- Trader lookups that fail for a pass wider than one block read its first half instead, in the same pass, and the cursor moves only that far
- One block holding more than 40 new transactions is asked about whole, with three seconds for each round of four lookups, and saved
- A trader lookup the node refuses, does not know the transaction for, or does not answer in time, in a pass of one block, saves nothing, logs one warning and is read again a minute later. Each lookup gets five seconds, each round of four three, and all of a pass's asks sixty together
- A trader lookup that crashes ends the pass the same quiet way, never as a fault: the lookups run apart from the job
- While earning is closed the token's reader still saves each trade with its trader and queues and writes nothing for Points
- A stake of a launched token in its launch's splitter, read by the token's reader over the same blocks as its trades, is saved once and earns Autolaunch token staked once for the account whose verified wallets held the staking wallet at the stake's block time, however often it stakes again; unstaking is not read
- A stake read again, or kept through a rebuild of the token's trades after the chain changed, keeps its row as first saved and offers nothing more
- A stake from a wallet no account held is still saved and earns nothing, refused as not linked; a stake of a hidden launch's token earns nothing
- While earning is closed the token's reader still saves each stake and queues and writes nothing for Points
- A splitter read the node refuses as too wide narrows the pass to its first half, down to one block, and the next passes read on, so trades, revenue and stakes keep moving
- A stake log from another block than the one read under its number (the chain moved between the two reads) saves nothing, logs one warning and is read again a minute later
- A `Staked` log of nothing is skipped and the pass goes on; the site saves no stake of nothing
- Revstake and Memestock launches, on Base and on Robinhood Chain, name their splitter to the token's reader
- A covered call that changes hands, bought from a listing or sold into a bid, is saved once by the market's reader and earns First Autolaunch covered call once for its seller's account and once for its buyer's, each the account whose verified wallets held that side's wallet at the sale's block time; more sales earn nothing more
- An account on both sides of a sale, selling into its own bid, earns First Autolaunch covered call once
- A sale read again, by the next pass and by the one that reads its block for the last time, keeps its row as first saved, offers nothing more and warns of nothing
- A sale with a side no account held is still saved, and only the linked side earns; the other is refused as not linked, and a sale not saved earns nothing
- While earning is closed the market's reader still saves each sale and queues and writes nothing for Points
- With covered calls off, or their contracts not described, the chain watch makes no sales job and the reader asks the chain nothing
- The chain watch run twice leaves each covered-call market one reading job
- A saved sale the chain moved to another block, changed or dropped stays as first saved with what it earned: the pass that reads its block for the last time logs one warning naming the contract and the transaction, and the reader carries on; wherever the chain puts it later it is neither saved, offered nor named again
- A node failing any read (the deployment block, the head, the log search, a block, the other sides) logs one warning and the reader waits a minute, with nothing saved and the cursor where it was; the next pass that is answered saves the sale
- Every pass that read the head reports the reader's lag, saved or not, so a reader its node holds up shows the lag growing
- A log that does not read as a sale is skipped with one warning when its block is first read, and the pass saves the rest
- A pass whose cursor moved under it saves nothing and reads again at once; the first pass opens at the contract's deployment block, and each log search covers at most 10,000 blocks, the last 300 read again
- A sign-in that creates the shared Regent account earns Account activated once, under the Regents name every site gives it, so it earns once whichever site saw it first; signing in again to the same account offers nothing
- A GitHub or Farcaster account Privy lists earns its linked award once when a sign-in first links it here; a later sign-in with the same account only refreshes the link and offers nothing; another account of the same kind in its place is linked anew and offered, and the person keeps their one award; an X account Privy lists offers nothing
- The person's own X, connected with the Account page's X button, earns X account linked once for that X account; a company X offers nothing, and disconnecting then connecting the same X again earns nothing more
- The first agent a person pairs earns First paired agent once; a second agent paired before that award was checked is recorded too and ends capped with no entry of its own; unpairing and pairing again once it earned records nothing more; the award names the agent's wallet, and the Points page shows that agent's name
- The start run records what no offer did: an account, a GitHub link, a profile X connection and a pairing made before the start earn dated at the start, and a GitHub link made after the start while its rule was not approved earns dated when it was linked; a company X is left out, and so is an account any site already recorded for that rule; a second run before the first one's offers are checked queues nothing more, each offer still waiting being the same job, and one event and one entry are left for each account and rule; a later run records nothing more
- A GitHub or X account another Regent site already rewarded earns nothing here: Points records it and holds it to nothing, the X button keeping the same X user id Privy gives that account
- While the account rules are not approved, signing in, linking, connecting X and pairing all work and queue and write nothing for Points

## Agents

Each WebMCP tool calls the HTTP route beside it, and the matching CLI command (`cli/commands.json`)
calls the same route. `make check-cli` checks the command descriptions in `cli/commands.json`
against the API's OpenAPI copy (`cli/docs/api-contract.openapiv3.yaml`).

| WebMCP tool | Route |
| --- | --- |
| `autolaunch_auctions` | `GET /api/v1/auctions` |
| `autolaunch_auction` | `GET /api/v1/auctions/{id}` |
| (all tools) | Chrome offers the tools only when the answer allows `tools` for this site and carries a live WebMCP origin-trial token for https://autolaunch.sh (valid to 29 Mar 2027) |
| (all public reads) | Any website's page may read the six public `GET` routes; no account or agent route |
| `autolaunch_auction_counts` | `GET /api/v1/auction-counts` |
| `autolaunch_tokens` | `GET /api/v1/tokens` |
| `autolaunch_token` | `GET /api/v1/tokens/{id}` |
| `autolaunch_treasury` | `GET /api/v1/treasury-security/{address}` |
| `autolaunch_bid_quote` | `POST /api/v1/auctions/{id}/bid-quote` |
| `agent_whoami` | `GET /api/agents/v1/whoami` |
| `agent_status` | `GET /api/agents/v1/me` |
| (CLI `agents pair`) | `POST /api/agents/v1/pair` |
| `autolaunch_revstake_draft`, `autolaunch_revstake_draft_save` | `GET` and `PATCH /api/agent/v1/drafts/revstake` |
| `autolaunch_memestock_draft`, `autolaunch_memestock_draft_save` | `GET` and `PATCH /api/agent/v1/drafts/memestock` |
| (none) | Make a payment (Revstake token page): addresses from the launch's own record, read by the Base reader, canonical receiver only, on the launch's own network |
| `autolaunch_revstake_draft_save`, `autolaunch_memestock_draft_save` | `PATCH /api/agent/v1/drafts/{kind}` |
| `autolaunch_my_positions` | `GET /api/agent/v1/positions` (and `GET /api/v1/me/positions` signed in) |
| `account_points` | `GET /api/v1/account/points` |
| (every signed browser tool) | A signed tool takes only its input; with no agent signer in the browser it sends nothing and answers `agent_auth_required`, naming `regents browser`; with one, the page sends exactly the request the signer signed, with its proof and no cookie |
| `autolaunch_covered_call_listings` | `GET /api/v1/covered-calls/{symbol}` |
| `autolaunch_covered_call_quote` | `POST /api/v1/covered-calls/{symbol}/quote` |
| `autolaunch_my_covered_calls` | `GET /api/agent/v1/covered-calls/{symbol}/positions` (and `GET /api/v1/me/covered-calls/{symbol}` signed in) |
| `autolaunch_covered_call_prepare` | `POST /api/agent/v1/covered-calls/{symbol}/steps` |
| (covered-call switch) | Off, every covered-call route is an unknown address and the site is what main serves: `/openapi.json` is the API contract exactly, and no tool, guide section, page, script or stylesheet names covered calls |
| `autolaunch_after_hour_stocks_list` | `GET /api/v1/after-hour-stocks` |
| `autolaunch_after_hour_stocks_series` | `GET /api/v1/after-hour-stocks/{series}` |
| `autolaunch_my_after_hour_stocks` | `GET /api/agent/v1/after-hour-stocks/{series}/holdings` (and `GET /api/v1/me/after-hour-stocks/{series}` signed in) |
| `autolaunch_after_hour_stocks_prepare` | `POST /api/agent/v1/after-hour-stocks/{series}/steps` |
| (Isolated Exposure to After-hours Stocks switch) | Off, every route is an unknown address and nothing advertises them |
| `autolaunch_earn_products` | `GET /api/v1/earn/products` |
| `autolaunch_earn_quote` | `POST /api/agent/v1/earn/quote` |
| `autolaunch_earn_positions` | `GET /api/agent/v1/earn/positions` (and `GET /api/v1/me/earn` signed in) |
| `autolaunch_earn_prepare` | `POST /api/agent/v1/earn/steps` |
| (Earn switch) | Off, every Earn route, the page and its stylesheet are unknown addresses, `/openapi.json` carries none of Earn's contract, and no guide, page, rail or portfolio names Earn; on, they all do and the contract gains only Earn's own parts |
| `autolaunch_bid_prepare` | `POST /api/agent/v1/bids/steps` |
| `autolaunch_bid_settlement_prepare` | `POST /api/agent/v1/bids/{bid}/steps` |
| (agent bids switch) | Off, as every environment starts (`AUTOLAUNCH_AGENT_BIDS`), both routes are unknown addresses, `/openapi.json` carries none of their contract, no guide or page names them, and every guide says bidding and settlement stay with the person, in the words it had before agent bids; on, the agent guides name them, no guide says an agent cannot prepare a bid or its settlement, every page registers their browser tools and the contract gains only their own parts |
| `autolaunch_robinhood_bid_prepare` | `POST /api/agent/v1/robinhood/bids/steps` |
| `autolaunch_robinhood_bid_settlement_prepare` | `POST /api/agent/v1/robinhood/bids/{bid}/steps` |
| (agent Robinhood bids switch) | Off, as every environment starts (`AUTOLAUNCH_AGENT_ROBINHOOD_BIDS`), both routes are unknown addresses, `/openapi.json` carries none of their contract, and no guide or page names them; on, the agent guides name them, every page registers their browser tools and the contract gains only their own parts. In each of the four ways the Base and Robinhood Chain agent bid switches stand, every guide names exactly the chains offered and their sections, and the bids on the chain not offered as staying with the site's pages; with neither on, every guide says bidding and settlement stay with the person |
| `autolaunch_launch_prepare` | `POST /api/agent/v1/launches/{draft}/steps` |
| (agent launches switch) | Off, as every environment starts (`AUTOLAUNCH_AGENT_LAUNCHES`), the route is an unknown address, `/openapi.json` carries none of its contract, no guide or page names it, and every guide says a draft an agent filled in is launched by the person on the create page, in the words it had before agent launches; on, the agent guides name it, every guide says an agent can prepare the launch step, every page registers its browser tool and the contract gains only its own parts. In each of the four ways the two agent bid switches stand, with agent launches off or on, every guide names exactly the bid chains offered and the sections that say how |
| `autolaunch_finish_prepare` | `POST /api/agent/v1/auctions/{auction_id}/finish/steps` |
| (agent finishes switch) | Off, as every environment starts (`AUTOLAUNCH_AGENT_FINISH`), the route is an unknown address, `/openapi.json` carries none of its contract, and no guide or page names it, every guide in the bytes it had before agent finishes; on, the agent guides name it, the guides with sections gain Finishing auctions, after Agent launches when those are on too, every page registers its browser tool, the site map and API catalog are unchanged and the contract gains only its own parts |
| `autolaunch_stake_prepare` | `POST /api/agent/v1/tokens/{token_id}/stake/steps` |
| (agent staking switch) | Off, as every environment starts (`AUTOLAUNCH_AGENT_STAKING`), the route is an unknown address, `/openapi.json` carries none of its contract, and no guide or page names it; on, the agent guides name it, the guides with sections gain Agent staking, after Finishing auctions when those are on too, every page registers its browser tool, the site map and API catalog are unchanged and the contract gains only its own parts |
| (agent switches with a wallet step) | The guides' sentences on who does what (`/`, `/docs`, `/llms.txt`, `/llms-full.txt`, `/agents.md`, `/skill.md`) are made from the agent bids, agent Robinhood bids, agent launches, agent finishes and agent staking switches that are on: in each of the 32 ways they stand, every guide is whole, names what each switched-on feature lets a paired agent prepare for the person's own wallet to sign, points to its section where the guide points to sections, names no switched-off feature as an agent's, and never says that what a switched-on feature prepares stays with the person, is not exposed or is not registered as an agent tool. With all five off, with only the two agent bid switches on, and with agent launches on too, as live, every guide reads as it did before, but for the home page's sentence, which also names a bid's return and claim |
| (none) | `GET` and `PATCH /api/v1/profile` (shared profile): the person signed in here, a change only with the forms token; a paired agent signing with its own key, for its person only; nobody else |

Guides and discovery for agents: `/llms.txt`, `/llms-full.txt`, `/agents.md`, `/skill.md`,
`/openapi.json`, `/sitemap.xml`, `/sitemap.md`, `/robots.txt`, `/capabilities.json`,
`/.well-known/security.txt`, `/.well-known/api-catalog` and `/healthz`. `make readiness`
(`scripts/readiness.sh`) checks them against a local development server.

## Hosted MCP and the Claude connector

An action only a person can do is a bug (founder rule, 28 October 2026). Which way in offers
each action an agent can take (a page's tool, hosted MCP at `/mcp`, the API, the Claude
connector and regents-cli) is the Agent access table in `/docs`, `/llms-full.txt` and
`/agents.md`, made from `platform/priv/capabilities.json` for the switches that are on
(`AutolaunchWeb.PublicDocuments`). A "No" there is a gap. On hosted MCP and the connector the
**Autolaunch MCP lane** closes it, as its operation becomes one action whose answer is the
browser tool's; in the CLI the **regents-cli lane** does, adding the command to
`cli/commands.json` when its switch goes on, so the CLI never offers what the site does not.

`POST /mcp` runs the tools `platform/priv/capabilities.json` marks hosted (its `hosted_tool`), each as its Ash action
under its policies (`AutolaunchWeb.Capabilities`, checked when it compiles). The connector's switch, `AUTOLAUNCH_CLAUDE_CONNECTOR_ENABLED`,
is off in production.

- A paired agent's signed call lists the hosted tools offered now and runs `autolaunch_auction_counts`, with the API's answer; an agent no person paired is refused `agent_not_paired`
- The guides' Agent access table has one row per action offered while its switch is on, and each cell is what that way in serves: the page's tools, the tools a paired agent is listed, the router's routes, regents-cli's commands and, while the connector is on, Claude; switching a feature off takes its rows out of `/docs`, `/llms-full.txt` and `/agents.md`
- Before Autolaunch opens, the table says Opens soon on every way in that offers an action whose route the site refuses until then (the draft saves and the covered-call, Exposure, Earn, agent bid, agent Robinhood bid, agent launch, agent finish and agent staking steps), and on no other; a listed hosted tool for one is refused `prelaunch_read_only`
- One read through each way in (the page tool's route, regents-cli's request and the hosted tool) gets the same answer, for a public read and a paired one
- The hosted market reads (a token, a treasury report, a bid estimate), a paired agent's two drafts and their saves, and its bids and holdings give their route's `data`; the auction and token lists give their route's whole page (`data`, `pagination` and `robinhood_unavailable`), one auction its route's whole answer (`data` and `robinhood_unavailable`), and Points, whose route answers without `data`, its whole answer; refusals are the route's in the same code and words, a bid estimate's for any amount and highest price (property) by the route's own code; in prelaunch read-only mode a draft save is refused with the route's whole answer
- `autolaunch_auctions` has the API's own auction-list budget, six calls a minute for each agent as for each address, through the same limiter and with the same 429
- All of one person's signed agents spend their account's 120 calls a minute on `/mcp`, the budget its connected apps spend: across two agents of one account the 121st call is refused 429, the person's connected app is then refused with the same answer, and the signed routes still answer the same agent from their own budget
- All of one person's signed agents spend their account's own 120 requests a minute on the signed routes (`"agent"`), apart from `/mcp`'s budget: across two agents of one account the 121st request is refused 429 with `Retry-After`, in the words an address past its own limit gets; another person's agent, and the same agents on `/mcp`, still go on
- A request refused for its signature (401) or its pairing (403) spends nothing of a person's budget on the signed routes: after 121 such requests, forged ones naming the paired agent's wallet among them, the paired agent's own request is answered with 119 of its 120 left
- A paired agent's bids and holdings, on its route and its hosted tool, are read from the account its pairing named, by that account's id, never found again by its person's sign-in id
- A person's drafts and their saves, bids and holdings, Points and Exposure holding, as the hosted tools run them, are allowed to the agent paired with them by each action itself; a signed-in person, a connected app calling as itself and no one are refused
- A person's covered calls and Earn balances (`covered_call_positions`, `earn_positions`) are allowed, by each action itself, to that person signed in (their `GET /api/v1/me/...` route) and to the agent paired with them, a connected app calling as that agent included; an Earn preview and the wallet steps (`earn_quote`, `prepare_covered_call`, `prepare_earn`, `autolaunch_after_hour_stocks_prepare`) to that agent alone; a connected app calling as itself, the site's system actor and no one are refused
- A paired agent's After-hours, covered-call and Earn steps, and Earn's preview, need its person's wallet proof to hold now: lapsed (no primary wallet and none listed) or not holding together (wallets listed but no primary among them), each is refused `wallet_required` (409) in the code and hint an agent's bid gets, with or without a signer named, on the route and the hosted tool alike
- The auction list's read that raises inside its cache, and the cache while it restarts, are refused `internal_error` on the route and `autolaunch_auctions` alike; a hosted tool whose read raises gives that same refusal with nothing of the raise
- `autolaunch_auctions` and `autolaunch_tokens` read every page: a call with more entries than its `limit` gives `pagination.next_cursor`, and that cursor as `after` gives the rest, none repeated, the same page the route gives for that cursor
- Both hosted lists and `autolaunch_auction`, for a Robinhood auction, give `robinhood_unavailable` as their routes do, each answer the route's: `false` while Robinhood's head reads, `true` once its last read failed
- All declared hosted tools in `platform/priv/capabilities.json` are called, a connected app's own as that app, and each one listed as read-only writes no row; only the draft saves, an agent's launch step (whose review the site keeps) and a connected app's registration, pairing and check-in are listed as writing
- While Isolated Exposure to After-hours Stocks is on, its three hosted reads follow their routes. A paired agent can prepare existing wallet steps on hosted MCP with the same inputs, chain steps, blocked reasons and refusals as the signed route. Off, none are listed or run. Prelaunch keeps the reads and holds preparation.
- A site started with an Exposure description on another chain than its Base deployment, or with an empty Base deployment id, refuses Exposure with a 503 naming that fault (`base_deployment_mismatch`, `missing_deployment_id`) in the same code and words on the list route and `autolaunch_after_hour_stocks_list`, each a code `platform/contracts/exposure.openapiv3.yaml` documents for that answer; the start refuses every other fault in either description
- The guides and the server's own instructions name every hosted tool a paired agent is served and no other, with every switch off and every switch on; while the connector is on they also name a connected app's own tools
- A signed call is checked by the sign-in service for `POST /mcp` at the host the request reached, as every signed request names its site
- A signature beside a token, a refused signature, and no credential at all are refused in the site's shape
- A query string or another site's page is refused before any signature is checked, for any query and any host
- One call a request; input a tool cannot take, an `input` of `null` or `false` included, gets the API's `invalid_request`; only `POST /mcp` is served, a GET for an event stream answers 405 and a body that is not JSON 415
- 120 requests a minute from one address, 600 with a token
- A paired agent's answer, a read or a save, is replaced with `agent_not_paired` when its pairing ends while the request runs: on every signed route, on an agent's signed `/mcp` call and on a connected app calling as its paired agent
- Switch off: the connector's sign-in is not found, `/mcp` takes no app's token, Claude is neither offered nor shown (no `/agents/claude`, its skill or its line on `/agents`), and an agent pairs as before
- Switch on: Claude in the pairing box, `/agents/claude` and its skill, and its lines on `/agents`, in `/llms.txt`, `/agents.md` and the sitemap
- Switch on: a connected app pairs one hosted agent with its own account's code only, checks in, keeps its identity when its token is refreshed, and loses access when it disconnects or is unpaired; calling as itself it lists and runs none of a paired agent's tools; Claude connects by its published identity, which is read at consent and never again for its token or refresh
- Switch on: an app whose published identity signs its requests with its own key (`private_key_jwt`, a `jwks_uri` on its own host) connects: discovery lists `none` and `private_key_jwt` with RS256 and ES256, consent reads only the document, the code is refused `invalid_client` (401) without a client assertion and trades for working tokens with one, a refresh names the app by its assertion alone, and its keys are read once. The library refuses a wrong, expired or reused assertion, keys on another host or inline, and a public client that sends one
- Switch on, with the agent permission: a paired app lists every tool a paired agent has and reads the auction counts as its agent, and doing so never counts as a check-in; never as another account's agent; the identity's wallet is read once, and once while the signer is down
- While covered calls are on, `covered_call_book`, `covered_call_quote`, `covered_call_positions` and `prepare_covered_call` run the same operations as the covered-call routes and answer with their `data`, refusals in the same code and words; off, none is listed or run
- Covered-call positions and steps are only for the paired agent's own person and wallets: another wallet is `wrong_signer`, an agent no person paired is `agent_not_paired`; a value of another JSON type than an input takes is refused, as on the routes
- A site started with a covered-calls description on another chain than its Base deployment, or with an empty Base deployment id, refuses covered calls with a 503 naming that fault (`base_deployment_mismatch`, `missing_deployment_id`) in the same code and words on the route and the hosted tool, each a code `platform/contracts/covered-calls.openapiv3.yaml` documents for that answer; the start refuses every other fault in either description
- In prelaunch read-only mode `prepare_covered_call` is neither listed nor run, as the steps route answers `prelaunch_read_only`; a connected app calling as itself neither lists nor runs any covered-call tool; the guides name the covered-call tools only while covered calls are open
- While Earn is on, `earn_products`, `earn_quote`, `earn_positions` and `prepare_earn` run the same operations as the Earn routes and answer with their `data` and the block they were read at, refusals in the same code and words; off, none is listed or run; an agent no person paired is `agent_not_paired`
- In prelaunch read-only mode `prepare_earn` is neither listed nor run while `earn_quote` still answers; the guides name the Earn tools only while Earn is open
- While agent bids are on, `prepare_bid` and `prepare_bid_settlement` run the same operations as the agent bid routes and answer with their `data`, refusals in the same code and words; they prepare only for the paired agent's own person's wallets and bids (`wrong_signer`, `not_your_bid`, `agent_not_paired`), and only for that agent or a connected app calling as it, never the person signed in, a connected app as itself or the site; a person's account that cannot be read prepares nothing, and a person with no verified wallet now is refused `wallet_required`; off, neither is listed, and a call to either, well formed or not, is answered as one to a tool that does not exist
- In prelaunch read-only mode neither `prepare_bid` nor `prepare_bid_settlement` is listed or run, as both routes answer `prelaunch_read_only`
- While agent Robinhood bids are on, `prepare_robinhood_bid` and `prepare_robinhood_bid_settlement` run the same operations as the agent Robinhood bid routes and answer with their `data`, refusals in the same code and words; they prepare only for the paired agent's own person's wallets and bids (`wrong_signer`, `not_your_bid`, `agent_not_paired`), another person's bid, a bid that does not exist and a bid on an auction the site does not list answered alike, and only for that agent or a connected app calling as it, never the person signed in, a connected app as itself or the site; a person's account that cannot be read prepares nothing, and a person with no verified wallet now is refused `wallet_required`; off, neither is listed, and a call to either, well formed or not, is answered as one to a tool that does not exist
- In prelaunch read-only mode neither `prepare_robinhood_bid` nor `prepare_robinhood_bid_settlement` is listed or run, as both routes answer `prelaunch_read_only`
- While agent launches are on, `prepare_launch` runs the same operation as the agent launch route and answers with its `data`, refusals in the same code and words; it prepares only the paired agent's own person's draft for their own wallets (`launch_draft_not_found`, `wrong_signer`, `agent_not_paired`), and only for that agent or a connected app calling as it, never the person signed in, a connected app as itself or the site; a person's account that cannot be read prepares nothing, and a person with no verified wallet now is refused `wallet_required`; off, it is not listed, and a call to it, well formed or not, is answered as one to a tool that does not exist
- In prelaunch read-only mode `prepare_launch` is neither listed nor run, as the route answers `prelaunch_read_only`
- While agent finishes are on, `prepare_finish` runs the same operation as the agent finish route and answers with its `data`, refusals in the same code and words; it prepares only for the paired agent's own person's wallets (`wrong_signer`, `agent_not_paired`), and only for that agent or a connected app calling as it, never the person signed in, a connected app as itself or the site; a person's account that cannot be read prepares nothing, and a person with no verified wallet now is refused `wallet_required`; switched on it is listed as read-only, and off it is not listed, and a call to it, well formed or not, is answered as one to a tool that does not exist
- In prelaunch read-only mode `prepare_finish` is neither listed nor run, as the route answers `prelaunch_read_only`
- While agent staking is on, `prepare_stake` runs the same operation as the agent staking route and answers with its `data`, refusals in the same code and words; it prepares only for the paired agent's own person's wallets (`wrong_signer`, `agent_not_paired`), and only for that agent or a connected app calling as it, never the person signed in, a connected app as itself or the site; a person's account that cannot be read prepares nothing, and a person with no verified wallet now is refused `wallet_required`; switched on it is listed as read-only, and off it is not listed, and a call to it, well formed or not, is answered as one to a tool that does not exist
- In prelaunch read-only mode `prepare_stake` is neither listed nor run, as the route answers `prelaunch_read_only`
- The consent page and its redirect back to Claude
- Switch on: each app an account connects keeps an identity of its own, unpaired until it pairs with its own code, so a second app never acts as the agent the first one paired, even with the agent permission

### Stock product follow-ups

- An open Robinhood auction shows its finished card and links to its token when the site records graduation, even with the rollup clock unchanged.
- Stock filters survive the detail-page return, and filtered pages hide empty groups. The same detail URL serves Markdown with the token issuer, addresses and dated liquidity.
- An eligible stock opens the existing Memestock form with its network selected. Replacing a saved pair is an explicit action. Draft terms and readiness require a currently admitted stock, while historical auctions still resolve.
- Covered-call and After-hours reads keep useful results during a partial outage. Covered-call orders show the available amount, and agents get market-specific recovery and exact offer links when the desk supports them.
- Earn names the available withdrawal liquidity and remaining deposit capacity separately.
- Regents CLI 1.10.33 supports the existing reads and unsigned wallet preparation for Covered Calls, After-hours Stocks and Earn. The installed wheel's public reads were checked on production.
