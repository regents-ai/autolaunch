## Covered calls

Covered calls on Base stock tokens are open on this site. A seller locks stock tokens and lists calls on them with a strike, a minimum premium and a weekly expiry, always a Friday at 21:00 UTC. Anyone may buy them for the premium in USDC; 1% of each premium goes to REGENT staking. During the 24 hours after expiry, a holder may pay the strike in USDC and take the stock. People use them at [{{origin}}/covered-calls]({{origin}}/covered-calls).

Every amount is a whole number: stock in raw token units (the book's `unit` is one whole token), prices and USDC in micro-USDC (6 decimals), percentages in basis points, times in Unix seconds.

The site offers sellers three strikes for each of the next four Fridays: the reference price plus 1%, 3% and 5%, rounded up to `strike_step`, each with a suggested premium from a fixed volatility. A suggestion is a guide, not a buyer's offer, and is null while the price is more than four days old. The contract takes any strike, and so does the prepare step.

| Action | WebMCP tool | HTTP |
| --- | --- | --- |
| Read a stock's listings | `autolaunch_covered_call_listings` | `GET {{origin}}/api/v1/covered-calls/{symbol}` |
| Read the strikes and suggested premiums | `autolaunch_covered_call_quote` | `GET {{origin}}/api/v1/covered-calls/{symbol}/quote` |
| Read your person's covered calls (signed, paired) | `autolaunch_my_covered_calls` | `GET {{origin}}/api/agent/v1/covered-calls/{symbol}/positions` |
| Prepare a step: list, fill, cancel, exercise, claim or collect_strike (signed, paired) | `autolaunch_covered_call_prepare` | `POST {{origin}}/api/agent/v1/covered-calls/{symbol}/steps` |

The site only prepares steps. Each answer lists `steps` (`to`, `data` and `value` on the named `chain`) for one of your person's own wallets: `signer` when you send one, otherwise the wallet they signed in with. That wallet's own key signs and sends the steps in order, and money moves only then. `approved` says whether the allowance already covers the action. `blocked` gives a `code` and words when the chain's current state makes the action certain to fail; the steps still come back, so prepare again once the chain has changed. Any other wallet is refused with `wrong_signer`. The regents CLI has no covered-call commands yet.

