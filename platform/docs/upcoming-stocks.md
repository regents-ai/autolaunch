# Onchain Stocks catalog

The public page is `/upcoming-stocks`. `/upcoming` permanently redirects there.
The page title and existing section names remain Onchain Stocks, Soon Available
and Available to Pair. Chainlink Feed Required contains the remaining prospects.

The catalog in `priv/stocks/upcoming-2026-10-14.json` was imported from Sean's
`autolaunch-unlaunched-tokens-2026-10-14.md`. It retains the source filename and
checksum, 127 chain/ticker records, exact addresses, company and stock-quote
links, pool observations and unresolved identities. The research snapshot has
35 previously available records, 14 upcoming records and 78 feed-required records.
Liquidity observations have their own dates; historical or missing figures are
never presented as current liquidity or zero.

Available to Pair still reads `Stocks.Assets`: only saved admitted stocks enter
that section. Research joins those stocks by chain and token address, not ticker.
The saved launchpad feed takes precedence over the research feed. Revoked or
unconfirmed former admissions appear under Soon Available. New admissions not
yet researched remain visible with their saved address and feed; missing links
and pool observations are explicit. This catalog does not configure routes,
admit tokens, grant trading eligibility or change launch checks.

Every stock card is a button. Clicking it, tapping it or pressing Enter or
Space opens a native modal dialog near the viewport's top. Hover never opens
it and does not add text. The existing LiveView dialog commands open and close
it; the browser handles Escape, focus containment and focus returning to the
stock button. Close also dismisses it. Narrow screens retain full, wrapped
addresses and a scrollable dialog. Address copies use the shared Regent copy
button. No additional hover helper or dependency is needed.

Pool 1 is the strongest pool in its recorded observation. Pool 2 is included
only where a separate pool exceeded $10,000 in that same observation. V4 entries
show a pool ID and PoolManager address separately; the ID is not a token or pool
contract address. Buy opens the supplied external pool market page, rather than
preparing or signing a trade. Unknown identities have no Buy link. Neither a
link nor a past liquidity observation guarantees a working swap or a current
price feed.

## Design review

- Before: stock cards showed only a ticker and short note.
- After: all sections offer the same details, with full addresses and links in
  a dialog opened by selecting the stock card.
- Why: visitors can inspect a stock without leaving the catalog, while dated
  research remains distinct from actual launchpad admission.
