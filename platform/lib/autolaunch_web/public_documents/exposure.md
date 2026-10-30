## Isolated Exposure to After-hours Stocks

Isolated Exposure to After-hours Stocks on Base stock tokens is open on this site. A series splits one stock token, for a fixed term, into an After-hours token, which carries the stock's moves from each close to the next open, and a Market-hours token, which carries its moves from each open to the close. Prices are the stock's Chainlink feed on Base at 9:30am and 4:00pm New York time, recorded on chain by anyone an hour after each time. Depositing stock mints the same amount of each token; one of each always returns one stock token; after the series ends each token returns its own share. People use it at [{{origin}}/after-hour-stocks]({{origin}}/after-hour-stocks).

Every amount is a whole number: stock and tokens in raw token units (the stock's `decimals`), prices and ledger values in WAD dollars per stock token (18 decimals), pool quotes in micro-USDC (6 decimals), times in Unix seconds.

| Action | WebMCP tool | HTTP |
| --- | --- | --- |
| List every series | `autolaunch_after_hour_stocks_list` | `GET {{origin}}/api/v1/after-hour-stocks` |
| Read one series | `autolaunch_after_hour_stocks_series` | `GET {{origin}}/api/v1/after-hour-stocks/{series}` |
| Read your person's holding (signed, paired) | `autolaunch_my_after_hour_stocks` | `GET {{origin}}/api/agent/v1/after-hour-stocks/{series}/holdings` |
| Prepare a step: mint, redeem, update or end (signed, paired) | `autolaunch_after_hour_stocks_prepare` | `POST {{origin}}/api/agent/v1/after-hour-stocks/{series}/steps` |

The site only prepares steps. Each answer lists `steps` (`to`, `data` and `value` on the named `chain`) for one of your person's own wallets: `signer` when you send one, otherwise the wallet they signed in with. That wallet's own key signs and sends the steps in order, and money moves only then. `approved` says whether the allowance already covers the action. `blocked` gives a `code` and words when the chain's current state makes the action certain to fail; the steps still come back, so prepare again once the chain has changed. Any other wallet is refused with `wrong_signer`. A series' terms are at `terms_url`; their keccak256 is the series' `terms_hash`. The regents CLI has no Isolated Exposure to After-hours Stocks commands yet.
