# Local mobile layout fixes — 14 October 2026

Candidate branch: `sol/mobile-layout-1014`, based on main v125
`82ce36637dda848c3ecc78d90526f9b11066e2c9`. This work is local and unreleased.

## Done and scope

- [x] Auction names, tickers and outcomes remain readable at 320px and 390px.
- [x] Loaded Base AIFROG and Robinhood SANDY pool charts fit their containers.
- [x] Desktop table and chart dimensions match the pre-change baseline.
- [x] Opening the site's overlay panel moves focus inside it at phone, landscape
  and desktop widths; Escape closes it and returns focus to its trigger.
- [x] Assets build, TypeScript check, seven existing frontend tests and diff
  whitespace check pass.

Only two product stylesheets and the overlay focus condition changed. Navigation
sizes, contract economics, records, transaction controls, shared package pins and
wallet logic remain untouched. No new tests, migrations, production writes,
pushes or deployments were performed. Unrelated working changes were preserved.

## Review

| Before | After | Why |
| --- | --- | --- |
| At 320px every auction name had about 19.5px available; outcomes and optional wallet-action columns consumed the row. | Phone auction rows put the full token identity above actions and outcome. Names and tickers wrap, and failed-outcome text wraps. | Names remain recognizable even with visible action buttons. Desktop keeps its table layout. |
| Each loaded pool figure had a 216px container but a 288px grid track, producing a 340px page at 320px. | The track uses `minmax(0, 1fr)` and long axis labels wrap within their available width. | Both chains' loaded charts fit without concealing information or changing price calculations. |
| The panel overlays the page at every width, but focus moved inside only below 47.99rem. | Every opening moves focus inside; the existing scoped Escape handler returns it to the trigger. | Behavior follows this product's actual overlay composition. No global Escape handler or shared-shell fork was added. |

## Browser evidence and its limits

The configured read-only server on `localhost:4072` was preserved, including its
nonempty Privy configuration. Its isolated database has no auctions, so candidate
token routes cannot exercise these production records directly.

Public `/tokens/AIFROG/85e71` and `/tokens/SANDY/96468` were visited read-only.
Each capture waited for the actual `.token-next-range` component to arrive after
its chain reading. Their rendered public DOM and the auction list were saved as
local static layout fixtures, with scripts removed, forms inert and buttons
disabled, and styled by the candidate's rebuilt assets on port 4072. These are
representative local CSS checks, not proof that production runs the patch or that
the local token routes load real records.

At 320/390/1440px, the captured auction list and both loaded token layouts have
page width equal to viewport width. Pool tracks are respectively 216/270/1063px.
The baseline reproduces 340px pages and 288px tracks at 320px. Desktop name and
chart dimensions match baseline.

A separate explicitly synthetic variant adds visible disabled Withdraw and Bid
controls to captured table markup. At both phone widths, names remain readable,
buttons stay separate and on-screen, and no horizontal page overflow appears.
Their existing 36px button height is unchanged; this is layout evidence, not
wallet behavior or authenticated acceptance. The browser still exposes the table,
row groups, rows and token row headers.

Panel focus was tested on the real local `/upcoming-stocks` page at 390×844,
768×390 and 1440×900. Each opening focused `shell-aside`; Escape closed it and
focused `shell-aside-button`. CSS confirms it is a fixed overlay at every width.

Evidence is in the workspace artifact directory
`artifacts/mobile-ui-audit-2026-10-14/autolaunch/`: `fix-measurements.json`,
`panel-fix-checks.json`, `fix-build.log`, and the `*-fixed-*.png` screenshots.
Ignored preview fixtures are under `platform/priv/static/assets/sol-mobile-*`.
Do not package them in a release; clean release builds come from the Git archive.

## Guidance and remaining work

No text, API, CLI, tool schema, pricing, availability or agent instruction changed;
their guidance remains consistent. The static layout fixtures are development
artifacts, not public product documentation or a substitute for dynamic acceptance.
Shared blog-table adoption still awaits upstream publication; it was not folded
into this patch. The wordmark touch-height observation remains separate.

Production remains v125. Before any separately authorized release, verify the
exact integrated candidate and then recheck real token pages after their readings
arrive. Authenticated wallet flows and physical touch/screen-reader behavior were
not exercised. No sign-in, transaction, stake, claim, finish or earning action
was performed.
