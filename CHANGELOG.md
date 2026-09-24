# Changelog

What changed on autolaunch.sh, newest first. Each entry names the live version on Fly
(`autolaunch-sh`) and the commit it was built from.

## v25, 24 September 2026
- The time bar on auction cards fills again: the site now records when each auction opened, so
  the bar shows how much of its time has passed.
- Card links show a small logo for what each is (X, ENS, GitHub, website, wallet) and no
  underline. The creator's wallet shows as its logo alone, with the full address on hover.

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
