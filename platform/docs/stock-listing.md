# Onchain Stocks catalog

The public page is `/stock-listing`; the left menu calls it Stocks.
The page title and existing section names remain Onchain Stocks, Soon Available
and Available to Pair. Chainlink Feed Required contains the remaining prospects.

The catalog in `priv/stocks/upcoming-2026-10-14.json` was imported from Sean's
`autolaunch-unlaunched-tokens-2026-10-14.md`. It retains the source filename and
checksum, 127 chain/ticker records, exact addresses, company and stock-quote
links, pool observations and unresolved identities. The research snapshot has
35 previously available records, 14 upcoming records and 78 feed-required records.
Liquidity is written as every Regents amount is: dollars and cents with thousands separated, cut, never rounded up.
Observations have their own dates; historical or missing figures are
never presented as current liquidity or zero.

Available to Pair preserves the established 35-stock website list: 10 on Base
and 25 on Robinhood. Catalog membership determines the section, so unavailable
local chain settings or an empty admission cache cannot shrink it or move its
stocks into the preview. The additional research remains under Soon Available
and Chainlink Feed Required. Research does not add stocks to Available to Pair.
The launch picker and every launch/bid keep their existing admission checks.
This catalog does not configure routes, admit tokens or change those checks.

The pairing heading links Memestock to `/create`. Dual Stock Token remains
greyed out, with a Coming soon hover hint and accessible label. Launch is the
orange final sidebar item and also opens `/create`. The header links to
`/agents.md`; its badge counts the site-scoped tools in the existing manifest.
The badge uses the shared vgpu foil renderer and the template's canvas lifecycle,
with a readable still face when WebGPU is unavailable or reduced motion is requested.
The browser hook and canvas lifecycle are copied unchanged from ash-template
`2c984274571ebbdc575f0e1d73d9b95d4ad15827`; the existing Regent UI and vgpu pins are retained.

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

| Before | After | Why |
| --- | --- | --- |
| Stock cards showed a ticker and short note. | Clicking a card opens full addresses, links and dated pool observations. | Visitors can inspect a stock without leaving the catalog. |
| An empty local admission cache moved established stocks into Soon Available. | The 35 established pairing stocks retain their catalog membership. | Research previews must not shrink or expand the available list. |
