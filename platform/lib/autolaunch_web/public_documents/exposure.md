## Isolated Exposure to After-hours Stocks

Isolated Exposure to After-hours Stocks on Base stock tokens is open on this site. Each week splits one stock token, for that trading week, into an After-hours token, which carries the stock's moves from each close to the next open, and a Market-hours token, which carries its moves from each open to the close. Prices are the stock's Chainlink feed on Base at each 9:30am open and 4:00pm close, New York time; the week's series reads each one from the feed's history itself an hour after its time, whenever anyone deposits, redeems unequal amounts or updates its prices. A week opens with its first deposit, which also mints the same amount of each token; one of each always returns one stock token; after the week ends each token returns its own share. People use it at [{{origin}}/stock/isolated-afters]({{origin}}/stock/isolated-afters).

Every amount is a whole number: stock and tokens in raw token units (the stock's `decimals`), prices and ledger values in WAD dollars per stock token (18 decimals), pool quotes in micro-USDC (6 decimals), times in Unix seconds. A week is the factory's week number: the list gives this week's and those of the last eight weeks that opened.

| Action | WebMCP tool | HTTP |
| --- | --- | --- |
| List this week and recent weeks | `autolaunch_after_hour_stocks_list` | `GET {{origin}}/api/v1/after-hour-stocks` |
| Read one week | `autolaunch_after_hour_stocks_week` | `GET {{origin}}/api/v1/after-hour-stocks/{week}` |
| Read your person's holding (signed, paired) | `autolaunch_my_after_hour_stocks` | `GET {{origin}}/api/agent/v1/after-hour-stocks/{week}/holdings` |
| Prepare a step: buy, sell, deposit, redeem or settle (signed, paired) | `autolaunch_after_hour_stocks_prepare` | `POST {{origin}}/api/agent/v1/after-hour-stocks/{week}/steps` |

The site only prepares steps. Each answer lists `steps` (`to`, `data` and `value` on the named `chain`) for one of your person's own wallets: `signer` when you send one, otherwise the wallet they signed in with. That wallet's own key signs and sends the steps in order, and money moves only then. A deposit approves the factory and then calls its `deposit`, this week only; settle applies every price that is due and is open to anyone. `approved` says whether the allowance already covers the action. `blocked` gives a `code` and words when the chain's current state makes the action certain to fail; the steps still come back, so prepare again once the chain has changed. Any other wallet is refused with `wrong_signer`. A week's terms are at `terms_url` when this site has them; their keccak256 is the week's `terms_hash`. The regents CLI has no Isolated Exposure to After-hours Stocks commands yet.
