# Changelog

What changed on autolaunch.sh, newest first. Each entry names the live version on Fly
(`autolaunch-sh`) and the commit it was built from.

## v35, 25 September 2026 (025f9a6)
- A shared How it works link shows its own picture, "how autolaunch works" with Revstake and
  Memestake supply and auction length, and its own title and description.
- Every page's link preview carries the X title and description as well.

## v34, 25 September 2026 (4fc881a)
- Withdrawing and claiming after an auction ends works on Base and Robinhood. Before, every press
  showed "That did not go through. Try again in a moment.", and a bid priced out by the final
  price could not get its unspent money back.
- An ended auction says how long ago it ended, such as "Ended 24m ago", instead of how long ago
  it was listed.
- The site reports its health (indexer lag, job age, wallet send failures, database wait) to
  Fly Sentinel on a private port.

## v33, 25 September 2026 (45c99c5)
- The API, the command-line tool and the browser tools for AI agents call the two launch types
  `revstake` and `memestake`, in what they return as well as in the filter. The old names
  `agent` and `stocks` are gone.
- Two database indexes the auction list no longer uses were removed (run 11:29 UTC).

## v32, 25 September 2026 (8eb7841)

### Sharing
- Auction and token pages have readable addresses, such as `/auctions/BITE/80be8`: the ticker,
  then the last five characters of the auction's address. Old links, including ones already
  posted on X, go to the new address.
- Each auction and token has its own share picture: its image, name, ticker, chain, a price line,
  and the FDV with the time left (or the price, once trading). X shows it large under the post.
- "Share on X" after a bid or a stake opens a window with the post to edit, the picture X will
  show, and "Open X to share". Nothing is posted until you post it on X.

### Portfolio
- The portfolio takes the create page's look: no diamond headings or dotted lines.
- Your bids and your tokens are rows like the auctions list, each with a small picture, the name
  in white and the ticker with its pair in orange, such as `BITE / AAPLc`.
- Under each bid: Auction (or Token once it has launched), Withdraw or Claim tokens when the
  auction allows it, and Bid more while bidding is open. Under each token: Token, Buy, Sell and
  Stake. Each opens the same window the auction and token pages use.
- A withdraw note now shows only under a bid that is outbid, not under every open bid.
- Past bids are folded under "Past bids".

### Fixes
- Bid, withdraw and Buy/Sell windows stay open while prices update behind them; before, an
  update could close them.
- Finishing a Buy or Sell from a home page card no longer breaks the home page.
- The bottom ticker's Robinhood trades are read from where each auction starts, and one shared
  reader feeds every open page.

### For agents
- The API, CLI and browser tools list auctions and tokens with the website's own search,
  filters and sort, and each auction carries its page address, time left, amounts raised and
  how much of its minimum is met.

## v31, 25 September 2026 (972b492)
- After you launch a memestock, "Launch memestock" starts from an empty form instead of showing
  the token you just launched.
- While your Memestake auction is live, the form is grayed out under "Only one Memestake auction
  can be live per account". It opens again once that auction ends.
- Every change to the site is now checked and test-built on GitHub before release.

## v30, 25 September 2026 (fe84aea)
- Search works as you type. Every word you type must appear somewhere in the auction: its name,
  ticker, paired stock, description, addresses, or the creator's X, GitHub or ENS name. A $ in
  front of a ticker and extra spaces are ignored. Typing in the search box on any other page
  opens the results on the home page.
- Agentic Revenue Launch: "Minimum REGENT Raised to Launch" is optional, with an info icon
  explaining why a minimum helps backers. Left blank, the launch uses 0.00001 REGENT.
- The token image on the Agentic Revenue Launch page is a file you upload, like the memestock
  page; pasting an image link is gone.
- X and GitHub show Connect, or Disconnect once connected; ENS keeps Change.
- The connections section starts with "Start Here" and a line on gaining credibility, and the
  preview reads "This auction and the resulting token will show these identities".

## v29, 25 September 2026 (6fbff12)
- The Create page is now "Launch memestock": one short form beside a summary card of the token
  it makes. There's no longer a first step asking which kind of launch you want.
- A Base / Robinhood switch picks where the token trades, with a blue or green wash across the
  form as it changes. The paired stock is a dropdown of that chain's stocks, each with its logo.
- The token image is a file you upload; pasting an image link is gone.
- A Telegram community link and a website are optional in the main form. X, GitHub and ENS sit
  under a folded "Socials" section. A Telegram link shows on the auction and token pages.
- Required raise (0.00001) and starting price (0.00000001) are filled in and sit under
  "Advanced".
- The summary card shows the chain, paired stock, trading fees (1% to stakers, 1% to Regent),
  when bidding opens, auction length, required raise, starting price, liquidity locked forever
  and no launch fee.
- The agent revenue launch has its own page, "Agentic Revenue Launch", linked from the top right
  of the memestock page.
- Each account keeps one memestock draft, which carries across the Base / Robinhood switch.

## v28, 25 September 2026 (59cd771)
- Gallery cards no longer show the description. The space under the links is a quarter of its old
  height, so every card is shorter. Hovering a card shows the bid volume, with how much of the
  launch threshold is met, over the launch threshold, beside the FDV.
- The count under the gallery reads "1 auction" or "1 token" when there is one.
- Once you're signed in, every bid, payment, launch and staking box uses the wallet you signed in
  with straight away, after moving between pages and after a reload. None of them asks you to
  connect or choose a wallet first. If your browser wallet is on a different address, a note
  beside the button names both. Pressing a button when your signed-in wallet isn't connected
  opens the connect step; press again once it is.

## v27, 25 September 2026 (d5f4bff)
- The profile page shows only your connected accounts: the name, wallet and X box above them is
  gone.
- A connected GitHub account can be changed or disconnected, like X.
- Account names in the connections list are no longer underlined.
- The connections on the profile page respond again: before, their buttons could stop working
  once the page finished loading.

## v26, 24 September 2026 (40327e4)
- The bid box is laid out like a swap: a Max budget box with the currency beside the figure, a
  Max FDV box with a slider, and a Receive box showing about how many tokens the budget buys.
  The slider starts a quarter above the price to start buying, and its tip shows the price per
  token. On Base stock auctions, a USDC or stock switch sits above the currency.
- "Place a bid" has a ? beside it with a short note on how bidding works. The wallet line, the
  balance list, the price mode choice and the Advanced section are gone.
- The bid help under the auction book uses the new wording on budget, max price, per-block
  buying, withdrawals and returned bids.
- Clicking an auction no longer sends up fire.
- Treasury security shows only on Revstake auctions and tokens, not on Memestake.
- Auction figures explain themselves: in the table, FDV, Bid volume and Launch threshold each
  have an info icon that opens a short note on hover; in the gallery, hovering one of those
  three numbers opens the same note.
- On the create page, X, GitHub and ENS each sit in one row of the same shape: logo, name or
  "not connected", and a Connect or Change button.
- The token image is one box: upload a file on one side, paste an image link on the other,
  split by OR.
- Text boxes on the create page have a cut top-right corner. Website and Required raise line
  up, and the dollar value of the typed REGENT shows under Required raise.
- Revstake: creator connections come first. Memestake: they come after the token details,
  folded away as optional.
- Launching a Revstake token with no X, GitHub or ENS connected first asks the creator to type
  a sentence accepting that the auction may not appear in the gallery or list.
- Explore, Portfolio, Create and Learn are header-style buttons with larger text and no icons:
  the corner marks close into a full outline on hover and stay closed on the page you are on.
  On phones the four sit two by two, always visible, and settle in one after another.
- Switching blockchain or token type on the create page no longer moves the page: the space
  for the description and the Robinhood note stays the same height for every choice.
- On phones, the header is the $REGENT crown beside Sign in. Tapping the crown opens Buy on
  Uniswap, View Chart and Follow on X, and the header Buy, Follow and Create buttons are gone.
  Wider screens keep the full header, in this order: + Create, Buy $REGENT, Follow on X, the
  crown, GitHub, Sign in.
- The treasury section no longer shows a technical note under a verified recipient.
- Portfolio shows every Base bid made from your wallet, including bids placed outside this
  site or whose confirmation the site missed: the site now records each bid the auction
  announces. A bid saved on an auction launched without a creator account no longer breaks the
  portfolio page.

## v25, 24 September 2026 (864624e)
- The time bar on auction cards fills again: the site now records when each auction opened, so
  the bar shows how much of its time has passed.
- Card links show a small logo for what each is (X, ENS, GitHub, website, wallet) and no
  underline. The creator's wallet shows as its logo alone, with the full address on hover.
- Changing a gallery setting (sort, chain, type, Auctions or Tokens) no longer blanks the
  gallery for a moment: the cards shown stay until the new ones replace them.
- A stock price that could not be read is tried again after one second, then two, four and so
  on, instead of staying missing for ten minutes.
- The Robinhood feather is always Robinhood green.
- Table view: each row reads the name, then the ticker in gray on the same line, with no check
  mark. A live auction's status is a time bar in its chain's colour with the time left under it,
  such as "5d 21h 48m". Times left no longer show seconds anywhere.
- Sorting is a three-way switch: Recent, Closing and Highest. "Oldest first" is gone.
- Grid and Table are shown as icons.
- The Filter menu is only as wide as its choices, with a tick beside each chosen one and one
  choice per group: status, network (All, Base, Robinhood), type, and which account the creator
  has verified. "Reset filters" is gone. The menu closes when you click outside it or press Escape.

## v24, 24 September 2026 (b97e278)
- A launch threshold met many times over reads "100% met" instead of a huge percentage.

## v23, 24 September 2026 (f3fef43)

### Explore, Portfolio, Create, Learn
- The menu has four places: Explore, Portfolio, Create and Learn. Explore holds the auctions and
  tokens lists, with links to search all of either.
- "Token details" is now "How Autolaunch works" at `/how-it-works`, since the old name sounded
  like one token's page. The old address is gone.
- Plainer wording: "auction" instead of "CCA auction", and "trading fee" instead of "Uniswap
  hook fee".

### Portfolio shows what you can do now
- Money available to withdraw, tokens ready to claim, tokens available to stake and rewards
  available come first, each with its button, and appear only when there is something in them.
  Other bids follow below.

### Who's behind a launch, and the launch itself
- Auction and token pages on both chains show two separate parts. "Who's behind it" lists the
  launch wallet and the creator's X, ENS and GitHub, each marked as ownership checked, and says
  plainly that a checked account is not an endorsement. "The launch itself" lists the launch
  type, the token, auction, treasury and locker contracts, how the supply is split, and the
  liquidity status.
- Liquidity reads "Reserved for liquidity, not yet deposited" until the auction launches, and
  "Deposited and locked", with the amounts, once the pool has been read from the chain. A note
  explains why Uniswap's numbers can differ.

### Auction and token cards
- Cards show the ticker as `BITE / AAPLc`, the FDV at the floor price, and the bid volume and
  launch threshold on hover.
- A time bar shows how far the auction has run. Until the launch threshold is met, a second bar
  above it shows how much of the threshold is met.
- The Tokens tab uses the same card. Every card is the same height and shows at most six links;
  the rest are on the token's own page.
- A card lifts slightly when you point at it.
- On phones, links sit in two columns and the description stops at four lines, so cards are
  shorter.

### Bidding
- A bid shows as outbid once the auction's price has passed its maximum, and the banner links to
  "See my outbid bid".
- Each outbid bid says in one line when its unspent money can come back: now; after the minimum
  is reached (with the amount still to go and the end time); after one extra wallet
  confirmation that records the new price; or, when its limit equals the price, that it is still
  buying until the end.
- While bidding is still open, the withdraw button records the auction's new price first when
  that is needed, then sends the unspent money back. Anyone can record the price, and it moves
  no money.
- Every press of a bid, settlement or launch button reaches the wallet. A new review no longer
  cancels an earlier one.
- Auction pages open on the price chart, with a window for the full details, and fit a 375px
  phone.

### Live trades
- The bottom ticker shows token buys and sells from each launched token's pool next to the bids.

### Database changes
Five, all applied before the switch-over:
- `20260924171619_auction_market_figures`: amount raised, floor price and token supply for each
  auction.
- `20260924183803_token_trades`: the trades table behind the ticker.
- `20260924183957_allow_many_open_bid_reviews` and
  `20260924191532_allow_many_open_settlement_and_launch_reviews`: remove the one-open-review
  limits.
- `20260924193836_record_the_auction_price`: lets a settlement include the step that records
  the price.

## v22, 24 September 2026 (e517da2)
- Each auction page lists its bids with wallets, a price-over-time chart, and bids placed against
  sold so far.
- Amount fields accept values like ".01".

## v21, 24 September 2026 (ae5f53b)
- Auctions record the wallet that launched them. Pages show a "Created by" block with X, ENS and
  GitHub.
- Base and Robinhood chips on cards and pages; the bid form sits right under the auction card.

## v20, 24 September 2026 (008d3fd)
- Fixed a crash, about once a second after the opening, in the updates for the Robinhood
  auction's bid activity.

## v19, 24 September 2026 (136f579)
- Launches opened at 15:00 UTC on Base and Robinhood.
