## Covered calls

Covered calls on Base stock tokens are open on this site. A seller locks stock tokens and lists calls on them with a strike, a minimum premium and a weekly expiry, always a Friday at 21:00 UTC. Anyone may buy them for the premium in USDC; 1% of each premium goes to REGENT staking. During the 24 hours after expiry, a holder may pay the strike in USDC and take the stock. People use them at [{{origin}}/stock/covered-call]({{origin}}/stock/covered-call).

Every amount is a whole number: stock in raw token units (the book's `unit` is one whole token), prices and USDC in micro-USDC (6 decimals), times in Unix seconds.

A quote gives the reference price, the next four expiries with their exercise windows, and three suggested strikes above the reference price, each with a suggested premium. For the strike and premium you choose (the middle suggestion and its premium when you leave them out) and an `amount`, its `receipt` says what the listing pays if all of it is bought at once and all of it exercised: the premium, the 1% fee, what the seller keeps and the strike, each exactly what the contract counts, so it matches the steps you prepare for the same listing.

| Action | WebMCP tool | HTTP |
| --- | --- | --- |
| Read a stock's listings | `autolaunch_covered_call_listings` | `GET {{origin}}/api/v1/covered-calls/{symbol}` |
| Quote a listing | `autolaunch_covered_call_quote` | `POST {{origin}}/api/v1/covered-calls/{symbol}/quote` with `expiry`, and optionally `amount`, `strike_per_token` and `premium_per_token` |
| Read your person's covered calls (signed, paired) | `autolaunch_my_covered_calls` | `GET {{origin}}/api/agent/v1/covered-calls/{symbol}/positions` |
| Prepare a step: list, fill, cancel, exercise, claim or collect_strike (signed, paired) | `autolaunch_covered_call_prepare` | `POST {{origin}}/api/agent/v1/covered-calls/{symbol}/steps` |

Your person's covered calls also say how much of the stock their wallet holds (`balance`), the most it can list now: stock already listed is held by the contract.

The site only prepares steps. Each answer lists `steps` (`to`, `data` and `value` on the named `chain`) for one of your person's own wallets: `signer` when you send one, otherwise the wallet they signed in with. That wallet's own key signs and sends the steps in order, and money moves only then. `approved` says whether the allowance already covers the action. `blocked` gives a `code` and words when the chain's current state makes the action certain to fail; the steps still come back, so prepare again once the chain has changed. Any other wallet is refused with `wrong_signer`. The regents CLI has no covered-call commands yet.

