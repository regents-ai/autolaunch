DRAFT, not approved

# Isolated Exposure to After-hours Stocks: AMZNc, weekly series

These are the terms of every weekly series opened with them: the keccak256 hash of this file's exact
bytes is each such series' `termsHash` on Base, so the text cannot change.

## The tokens

Each week's series takes AMZNc, Coinbase's Amazon stock token on Base, and issues two tokens against
it, named for the day the week ends (for example AMZNc-AH-1120 and AMZNc-MH-1120 for a week ending
on 20 November 2026):

- **AMZNc After-hours (AMZNc-AH-…)** gains or loses one share's dollar move from each close to the
  next open, weekends and market holidays included.
- **AMZNc Market-hours (AMZNc-MH-…)** gains or loses one share's dollar move from each open to the
  same day's close.

Depositing AMZNc gives the same amount of each. One of each can always be returned for exactly one
AMZNc. At the end of the series each token can be returned on its own for its share of AMZNc.

## The week

Each series runs for one trading week: from the last close before its Monday (normally Friday, 16:00
New York time) to the last close of that week (normally Friday, 16:00 New York time). Its prices are
that first close and then each trading day's open (09:30) and close (16:00, or 13:00 on an early
close): 11 prices in a normal week, fewer in a week with a market holiday. One week's last close is
the next week's first.

Nobody has to set a week up. A week's series opens with the week's first deposit, and anyone can
also open it without depositing. Deposits are taken from an hour after the week's first close until
its last close, and are limited to 40 AMZNc in total each week.

Market holidays and early closes come from a list the Regent governance Safe keeps. A closure or
early close missing from the list is treated as a normal trading day.

## Prices

Each open and close is the latest value of the Coinbase AMZN Chainlink price feed on Base at its
time, read from the version of the feed in use when the week's series opened. Nobody records
prices: from an hour after each time, the series reads that value from the feed's history itself,
whenever anyone deposits, returns unequal amounts or asks it to update. A value read late is the
same as one read on time.

These tokens follow those scheduled feed values, not the exchange's official opening and closing
prices. The feed updates when its price moves by 0.5% or more, or at least once a day while the
market is open, and it can lag, so a value can differ from the official price. A move the feed has
not shown yet is counted in whichever window it appears, which can shift value from one token to the
other. When the market is closed or the feed is paused for a corporate action, no move is counted.

## How each token's value moves

Both tokens start at half the AMZNc price. Each open adds the change since the last close to
After-hours; each close adds the change since the open to Market-hours. The two always add up to the
AMZNc price. At the start each token moves about twice as much as AMZNc in its own window, and this
changes as prices move. At the end each token is worth a fixed share of AMZNc (for example 104/170 of
one AMZNc), not a fixed number of dollars; its dollar value then moves with AMZNc.

## Ending early

A series ends at the values it had before an open or close, without that price, if at that time:

- the feed has no value at all;
- its latest value is more than 84 hours old;
- its value is zero or less, or too large to use; or
- the feed cannot be read, as seen by the series once and still seen 7 days later with no good read
  in between.

After an early end, one of each still returns exactly one AMZNc, and each token can be returned on
its own for its share at those values.

## Who controls what

The Regent governance Safe owns the factory that opens each week. It can only:

- change the stock, the price feed and its version, the deposit cap, the terms and the token names
  for weeks that have not opened yet;
- add or remove market holidays and early closes for weeks after the current one;
- pause the opening of new weeks, which leaves open weeks running to their end;
- hand the factory to another owner, or give it up.

It has no power over a series once it is open: it cannot change its prices, its days or its terms,
take its AMZNc, pause it or stop returns. A series has no owner.

## Risks

- **A token can lose everything.** If a price takes either token's value to zero or below, the
  series ends at that price and the other token receives all the AMZNc. Near zero, a move in the
  other window can also cost you.
- **The series can end early,** at its last values, for the reasons above.
- **Prices come from Chainlink**, not from the exchange, and differences can favour either token, as
  described above.
- **Holidays come from a list.** If the list misses a closure or an early close, a move during it
  can be counted in the other token.
- **Coinbase controls AMZNc.** It can pause transfers, block addresses, change how many shares each
  token represents, or take tokens. A blocked address cannot receive AMZNc from this series. If
  Coinbase takes AMZNc from the series, every later return is reduced by the same share. If
  Coinbase blocks the series itself, nobody can withdraw until it is unblocked.
- **Selling one token needs a buyer.** Before the end, a single token can only be sold to someone
  else; returning it for AMZNc needs one of each.
- Past returns of any stock in any window say nothing about future returns.

## Eligibility

Coinbase's stock tokens are only available to persons in eligible jurisdictions outside the United
States.
