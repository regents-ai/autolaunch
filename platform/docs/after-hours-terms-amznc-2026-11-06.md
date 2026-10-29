# After-hours Exposure: AMZNc, 30 October to 6 November 2026

These are the series' terms: the keccak256 hash of this file's exact bytes is its `termsHash` on
Base, so the text cannot change.

## The tokens

This series takes AMZNc, Coinbase's Amazon stock token on Base, and issues two tokens against it:

- **AMZNc After-hours (AMZNc-AH-1106)** gains or loses one share's dollar move from each close to
  the next open, weekends included.
- **AMZNc Market-hours (AMZNc-MH-1106)** gains or loses one share's dollar move from each open to
  the same day's close.

Depositing AMZNc gives the same amount of each. One of each can always be returned for exactly one
AMZNc. At the end of the series each token can be returned on its own for its share of AMZNc.

## The term

From the close on Friday 30 October 2026 (16:00 New York time) to the close on Friday 6 November 2026
(16:00 New York time): 11 prices, the first close and then each open and close from Monday 2 to
Friday 6 November. This first series is a small live demonstration: deposits are limited to 0.4
AMZNc in total.

## Prices

Each open and close is the latest value of the Coinbase AMZN Chainlink price feed on Base at 09:30 or
16:00 New York time, read from the version of the feed in use when this series was set up. These
tokens follow those scheduled feed values, not the exchange's official opening and closing prices.
The feed updates when its price moves by 0.5% or more, or at least once a day while the market is
open, and it can lag, so a value can differ from the official price. A move the feed has not shown
yet is counted in whichever window it appears, which can shift value from one token to the other.
When the market is closed or the feed is paused for a corporate action, no move is counted. A feed
value more than four days old is not used, and a price must be recorded on chain within seven days
of its time.

## How each token's value moves

Both tokens start at half the AMZNc price. Each open adds the change since the last close to
After-hours; each close adds the change since the open to Market-hours. The two always add up to the
AMZNc price. At the start each token moves about twice as much as AMZNc in its own window, and this
changes as prices move. At the end each token is worth a fixed share of AMZNc (for example 104/170 of
one AMZNc), not a fixed number of dollars; its dollar value then moves with AMZNc.

## Risks

- **A token can lose everything.** If a price takes either token's value to zero or below, the
  series ends at that price and the other token receives all the AMZNc. Near zero, a move in the
  other window can also cost you.
- **The series can end early.** If a price cannot be recorded within seven days of its time,
  including when the feed has stopped updating for more than four days, anyone can end the series at
  the last recorded values.
- **Prices come from Chainlink**, not from the exchange, and differences can favour either token, as
  described above.
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
