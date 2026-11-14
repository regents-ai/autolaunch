# Isolated Exposure to After-hours Stocks, version 2, on Base

Nothing is deployed yet. Deploying `ExposureFactoryV2` is a protected action and needs Sean's go.

## The site's description

[`site-factory.json`](site-factory.json) is what the site reads. On release it is copied to
`platform/deployment/exposure.json` beside the other descriptions (`platform/fly.toml` places it
at `/app/deployment/exposure.json`). Until the two placeholders are filled, the site refuses to
start with Isolated Exposure switched on.

| Key | Value |
| --- | --- |
| `chain_id` | `8453` (Base). |
| `factory` | The `ExposureFactoryV2` address. **Fill after deploy.** |
| `first_week` | The week number the deploy printed as `current week`, as a JSON number. The site lists weeks from here on. **Fill after deploy.** |
| `usdc` | Base USDC, which each week's tokens trade against. |
| `pool_factory` | The Aerodrome pool factory the site finds each token's pool on. |
| `router` | The Aerodrome router buys and sells go through. |

The site reads everything else from the factory and from each week's series: the stock, feed and
phase, cap, terms, dates, tokens and prices. It lists no series: a week's series is whatever
`seriesOf(week)` answers, and a week not opened yet is shown at `predictSeries(week)`.

## Fill after deploy

1. Deploy the factory on Sean's go, with the terms hash of the approved version 2 terms.
2. Read `owner()`, `template()`, `currentWeek()` and `paused()` from Base and check them against
   what the deploy script printed.
3. Put the factory address in `factory` and the printed current week in `first_week` (a number,
   not text).
4. Name the approved terms file `platform/priv/exposure_terms/<terms hash>.md`, so the page links
   it. The site shows terms only for a hash it has a file for.
5. Copy this file to `platform/deployment/exposure.json` on the releasing machine and release.
