# Simple Covered Calls — product spec

**Status:** Proposed · 28 October 2026  
**Codebase reviewed:** `regents-ai/autolaunch` at `65a51146b15812c1cc1f93075e454e5aa2df44da`

## Goal

**Make selling a covered call on a supported stock token simple.** A person or agent brings or buys the stock token, chooses a sale price and expiry, receives a buyer's option premium, and manages settlement from Autolaunch.

Covered calls are the first release. The complete flow works without borrowing, a token launch or staking. Aave is the optional financing integration described below.

## First release and user flow

Start with one qualified tokenized stock and one options execution/settlement integration; prefer Base. Use fully collateralized, physically settled calls with exercise only during a specified expiry window. Premium and strike payment are in USDC. Qualify the exact token, options contract and buyer/quote provider before enabling trading.

| Step | User experience |
| --- | --- |
| Choose stock and amount | Bring an existing supported stock balance, or buy through a qualified USDC route. Display the actual deliverable token and quantity. |
| Choose terms | Offer a small set of quoted strikes and expiries. Explain strike as the price at which the user agrees to sell. |
| Review and sell | Show premium after fees, expiry/exercise cutoff, capped upside and downside scenarios. Reserve the stock and sell to a funded counterparty. |
| Track | Show filled quantity, reserved stock, premium received, current position value and settlement status in the existing portfolio. |
| Settle and repeat | Exercise exchanges stock for strike payment; unexercised collateral becomes withdrawable after the exercise window closes. A new call requires a new quote and authorization. |

An executable quote needs an actual buyer; creating an offer earns no premium. If acquisition and sale are staged, show the stock held and recovery actions when the option sale fails. Early close is offered only with an executable buyback that extinguishes the obligation.

## Product requirements

- **Real coverage:** Reserve the exact deliverable units: option quantity multiplied by the contract's underlying-unit multiplier, accounting for decimals and rounding. Use actual stock tokens supplied by the owner; Memestock tokens and stock locked in launch liquidity do not provide this coverage.
- **Exclusive collateral:** Outstanding calls keep their required stock reserved onchain. Prevent uncovered fills, withdrawals, second calls or Aave pledges against the same units. Release unfilled collateral only after the relevant order can no longer execute.
- **Terms and quotes:** Bind chain, token, quantity, strike, option expiry, exercise window, minimum net premium, fees, recipient and quote deadline. Validate issuer/holder/contract permissions, token corporate-action treatment and fresh price references. Preview values are distinct from actual fills.
- **Execution:** Premium payment and creation of the covered obligation settle together. Contract/executor state enforces coverage, fill limits and replay protection, including partial fills and concurrent orders. Every prepared wallet-button press reaches the wallet, including repeats while pending.
- **Settlement:** Deliver the exact stock token only against the required USDC strike payment. Expiry alone does not release stock while exercise or settlement remains possible. Show open, settlement-pending, settled and withdrawable states; reconcile balances from receipts. Users can recover eligible assets through contracts independently of the site.
- **Performance:** Label premium as cash received. Show stock gains/losses, option liability or buyback cost, fees and combined performance separately. Explain retained stock downside and capped upside. For imported holdings, distinguish performance since opening from unknown historical cost basis.
- **Authority:** Reuse wallet ownership checks. A person or independently authorized agent signs; SIWA identity or pairing grants no spending authority. The position and proceeds belong to that owner; the website does not custody customer balances.

### Illustrative payoff

For one deliverable unit bought at 100 USDC, a 110 strike and 3 USDC premium, ignoring fees:

| Expiry outcome | Combined result |
| --- | --- |
| Stock at 80; call unexercised | Stock worth 80 plus 3 premium: loss of 17 |
| Stock at 105; call unexercised | Stock worth 105 plus 3 premium: gain of 8 |
| Stock at 120; call exercised | 110 sale proceeds plus 3 premium: gain of 13 |

These are payoff examples, not premium or return promises. Actual exercise follows the contract's rules.

## Fit with Autolaunch

Add a `/stock/covered-call` entry and qualified actions from existing `/stocks/:symbol` pages. Extend existing `/portfolio` with underlying stock balances and option positions, including external holders.

Implement a product-owned CoveredCalls domain, option quote/execution adapter and position/settlement tracking in the Phoenix/Ash platform. Reuse stock identity records, shared UI, `AutolaunchWeb.OnchainSteps`, chain reads and receipt tracking. Auction admission and the existing stock-to-CCA purchase adapter do not establish options eligibility or buy-and-write support.

Extend HTTP, WebMCP and `regents autolaunch` contracts together for quotes, positions and prepared actions; coordinate packaged CLI updates. Shared changes follow ash-template/library ownership. Enable advertised capabilities with the implemented feature.

Charge a disclosed fee on actual fills, with explicit failure/refund behavior and no duplicate charges. Route only collected platform fees through the verified USDC revenue path to REGENT staking. Stock collateral, option premiums owed to users and exercise proceeds remain user assets.

## Optional financing: Aave

Aave supplies optional lending; the options contract supplies the covered-call lifecycle. Core launch acceptance has no Aave dependency.

A later financed flow can borrow USDC against separate, already-eligible Aave collateral. Read the user's entire Pool position, current LTV/liquidation thresholds, health factor, modes, limits and liquidity. Display borrowing cost and liquidation exposure alongside option economics.

Borrowing against a future covered-call strategy share requires independent Aave listing, permissions, valuation net of short-call liabilities, and an executable liquidation/redemption route. Issuing a share does not make it eligible collateral. Do not pledge the stock reserved for calls to Aave.

## Acceptance and launch decisions

1. An external stock holder completes quote, covered sale, premium receipt, settlement and withdrawal without a loan or auction.
2. Buy-and-write failure leaves accurately reported, recoverable stock; partial fills and cancellations release only unencumbered quantities.
3. Fractional quantities, repeated presses and concurrent orders cannot oversell coverage or charge twice.
4. Falling-stock, unexercised-expiry and exercised-above-strike cases match the payoff rules; exercise requires strike payment and collateral stays reserved through the exercise window.
5. Supported early buyback shows its cost and releases collateral only after extinguishing the call.
6. Positions, proceeds and fees reconcile after reload; agent and human flows preserve the same ownership and coverage rules.

Before launch, select the token/chain, settlement implementation, buyer liquidity, quote source, expiry/corporate-action rules, fees and supported close route. Prove the complete option lifecycle before enabling. Additional stocks, automatic rolling, strategy vault shares and Aave financing follow this core product.

## References

- [Existing product](../../README.md) · [Wallet rules](../../AGENTS.md) · [Wallet steps](../lib/autolaunch_web/onchain_steps.ex)
- [Covered-call economics](https://www.optionseducation.org/strategies/all-strategies/covered-call-buy-write) · [Exercise mechanics](https://www.optionseducation.org/optionsoverview/exercising-options)
- [Aave Pool](https://aave.com/docs/aave-v3/smart-contracts/pool) · [Aave collateral configuration](https://aave.com/docs/aave-v3/smart-contracts/pool-configurator)
