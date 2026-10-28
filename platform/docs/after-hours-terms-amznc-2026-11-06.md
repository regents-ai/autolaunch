# After-hours Exposure: AMZNc, 30 October to 6 November 2026

**Draft for Sean's approval.** The hash of this file's exact bytes is committed on chain as the
series' terms (`termsHash`), so any change to the wording means a new hash before the series is
created.

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

Each open and close is the value of the Coinbase AMZN Chainlink price feed on Base at 09:30 or 16:00
New York time. That feed moves when the price changes by 0.5%, so it can differ from the exchange's
official opening or closing price by up to about 0.5%; any difference is counted in the next window
instead. When the market is closed or the feed is paused for a corporate action, no move is counted.
A price must be recorded on chain within seven days of its time.

## How each token's value moves

Both tokens start at half the AMZNc price. Each open adds the change since the last close to
After-hours; each close adds the change since the open to Market-hours. The two always add up to the
AMZNc price. At the start each token moves about twice as much as AMZNc in its own window, and this
changes as prices move.

## Risks

- **A token can lose everything.** If a price takes either token's value to zero or below, the
  series ends at that price and the other token receives all the AMZNc. Near zero, a move in the
  other window can also cost you.
- **The series can end early.** If a price is not recorded within seven days of its time, anyone
  can end the series at the last recorded values.
- **Prices come from Chainlink**, not from the exchange, as described above.
- **Coinbase controls AMZNc.** It can pause transfers, block addresses, change how many shares each
  token represents, or take tokens. A blocked address cannot receive AMZNc from this series. If
  Coinbase takes AMZNc from the series, every later return is reduced by the same share. If
  Coinbase blocks the series itself, nobody can withdraw until it is unblocked.
- **Selling one token needs a buyer.** Before the end, a single token can only be sold to someone
  else; returning it for AMZNc needs one of each.
- Past returns of any stock in any window say nothing about future returns.

## Eligibility

Coinbase's stock tokens are only available to persons in eligible jurisdictions outside the United
States. (Final wording to be approved by Sean.)
