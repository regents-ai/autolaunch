## Earn

Earn is open on this site. A person or agent lends USDC on Base to a market such as Aave V3 on Base from their own wallet, sees the balance grow as borrowers pay interest, and withdraws it when they choose. Autolaunch never holds the funds and charges nothing: the wallet deals with the market's contracts directly. People use it at [{{origin}}/earn]({{origin}}/earn).

Every figure is read from the chain at the latest block each time, and every answer names that `block` (`number`, `hash`, `timestamp` and `read_at`). Amounts are whole numbers in the asset's smallest units: USDC has 6 decimals, so `1000000` is 1 USDC. `rate_now` is the market's yearly rate right now (`yearly_percent`, and `ray`, the market's own figure in units of 10^27), a simple rate that changes as borrowing changes; nothing is promised. There is no figure for interest earned so far.

| Action | WebMCP tool | Hosted MCP tool | HTTP |
| --- | --- | --- | --- |
| List the products, their terms now and their risks | `autolaunch_earn_products` | `earn_products` | `GET {{origin}}/api/v1/earn/products` |
| Preview a deposit or withdrawal (signed, paired) | `autolaunch_earn_quote` | `earn_quote` | `POST {{origin}}/api/agent/v1/earn/quote` with `product`, `kind`, and `amount` or `everything` |
| Read your person's balances (signed, paired) | `autolaunch_earn_positions` | `earn_positions` | `GET {{origin}}/api/agent/v1/earn/positions` |
| Prepare a deposit or withdrawal (signed, paired) | `autolaunch_earn_prepare` | `prepare_earn` | `POST {{origin}}/api/agent/v1/earn/steps` with `product`, `kind`, and `amount` or `everything` |

A deposit is two steps: an exact USDC approval to the market's pool (`usdc_approval`), then `supply`, which credits the wallet. A withdrawal is one step, `withdraw`, which sends the USDC to the wallet; `everything: true` withdraws the whole balance as it stands when the step lands, interest to that moment included, and an `amount` equal to the balance withdraws exactly that amount. `approved` says whether the allowance already covers a deposit; the approval step comes back either way, and the deposit can be sent once the approval is on the chain.

`blocked` gives a `code` and words when the chain's state at that block makes the step certain to fail, the first that applies in this order: the market (`market_inactive`, `market_paused`, or `market_frozen` for a deposit: a frozen market lets every balance out), then the wallet (`not_enough_usdc` for a deposit, `over_balance` for a withdrawal), then what the market can take or give right now (`over_supply_cap`, `not_available_now`). The steps still come back, so prepare again once the chain has changed. A zero or unreadable amount is refused as `invalid_amount`, never blocked.

A preview reserves nothing, and nothing is kept between calls: a step built at one block may be stale by the time it is sent, and the wallet's own key decides. The hosted MCP tools at `{{origin}}/mcp` take the same inputs, each under `input`, and give the HTTP answer's `data` as their result; a refusal is their error, with the same code and words. The steps only come back once launches are open.

The site only prepares steps. Each answer lists `steps` (`to`, `data` and `value` on the named `chain`) for one of your person's own wallets: `signer` when you send one, otherwise the wallet they signed in with. That wallet's own key signs and sends the steps in order, and money moves only then. Each step's `data` ends with the site's Builder Code. Any other wallet is refused with `wrong_signer`.

The risks: the rate changes; a withdrawal depends on how much USDC is available at that moment; the market's contracts, or the assets borrowers pledge, could fail and money could be lost. The regents CLI has no Earn commands yet.
