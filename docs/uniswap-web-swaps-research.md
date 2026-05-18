# Uniswap Web Swaps Research

This note researches how Autolaunch can add native web-app swaps for graduated agent tokens using the Uniswap Trading API.

## Current Autolaunch State

Autolaunch already records and displays a Uniswap token URL after a launch graduates.

Current product behavior:

- `/tokens` lists graduated revsplit tokens.
- `/auctions/:id` links to the token page and, when present, the external Uniswap page.
- Autolaunch stores `uniswap_url` on launch jobs, auctions, and revsplit token rows.
- The current web app has wallet transaction buttons for prepared Autolaunch actions.
- There is no native Autolaunch swap form today.

The current link builder sends users to:

```text
https://app.uniswap.org/explore/tokens/<network>/<token-address>
```

That is good as a fallback link, but it does not let Autolaunch show a quote, route, expected output, price impact, or in-app wallet action.

## What The Uniswap Trading API Supports

Uniswap's current Trading API supports a quote-first swap flow:

1. Check whether the wallet needs approval.
2. Request a quote.
3. Use the quote's route to decide the next step.
4. Build the swap transaction or create a gasless order.
5. Ask the user wallet to sign and send what was returned.
6. Track the transaction or order status.

Official docs:

- [Uniswap swapping workflow](https://api-docs.uniswap.org/guides/swapping)
- [Uniswap integration guide](https://api-docs.uniswap.org/guides/integration_guide)
- [Uniswap quote endpoint](https://api-docs.uniswap.org/api-reference/swapping/quote)
- [Uniswap check approval endpoint](https://api-docs.uniswap.org/api-reference/swapping/approval)
- [Uniswap swap endpoint](https://api-docs.uniswap.org/api-reference/swapping/create_protocol_swap)
- [Uniswap swap routing guide](https://api-docs.uniswap.org/guides/swap_routing)
- [Uniswap swapping FAQ](https://developers.uniswap.org/docs/trading/swapping-api/faqs)

Important API facts:

- Base mainnet `8453` and Base Sepolia `84532` are listed as supported chain IDs for quote and approval requests.
- `/quote` requires token addresses, chain IDs, amount, trade type, swapper wallet, and slippage settings.
- `/quote` can return routes through `V2`, `V3`, `V4`, `UNISWAPX_V2`, or `UNISWAPX_V3`.
- To force Autolaunch's first-version path, request only `V4`.
- To allow UniswapX, include UniswapX protocols and then branch on the quote's `routing` value.
- `CLASSIC`, `WRAP`, `UNWRAP`, and `BRIDGE` routes go to `/swap`.
- `DUTCH_V2`, `DUTCH_V3`, and `PRIORITY` routes go to `/order`.
- The API key belongs on the server, not in browser JavaScript.
- The default API key rate limit is 6 requests per second.
- Permit2 is the default approval path, but Autolaunch can send `x-permit2-disabled: true` and use normal approval transactions.

## Recommended First Version

Start with normal wallet-sent Uniswap v4 pool swaps only.

For Autolaunch, that means:

- Base-only swaps.
- Exact-input swaps only.
- USDC to agent token.
- Agent token to USDC.
- Protocols limited to `V4`.
- No UniswapX in the first version.
- No bridging in the first version.
- No native ETH input in the first version.

This keeps the wallet flow close to the existing Autolaunch transaction button model: prepare a transaction, show it to the user, send it from the browser wallet, then record or refresh after confirmation.

## Proposed Web Flow

On `/tokens` and `/positions`:

1. User chooses buy or sell.
2. User enters an amount.
3. Autolaunch asks the server for a quote.
4. Server calls Uniswap `/check_approval` if the input token is an ERC-20.
5. Server calls Uniswap `/quote` with `protocols: ["V4"]`.
6. If the route is not `CLASSIC`, Autolaunch rejects it for the first version.
7. Server rejects the quote if any route step is not a v4 pool.
8. Server calls Uniswap `/swap` with the quote.
9. Browser sends any needed approval, then sends the returned swap transaction.
10. Autolaunch refreshes the token and wallet position state.

## Proposed Product API Shape

Because the Uniswap API key must stay server-side, the web app should not call Uniswap directly.

Add Autolaunch app routes:

```text
POST /v1/app/swaps/quote
POST /v1/app/swaps/prepare
```

The source of truth for these routes must be `docs/api-contract.openapiv3.yaml`.

Suggested request shape:

```json
{
  "chain_id": 8453,
  "side": "buy",
  "token_address": "0x...",
  "amount": "100",
  "swapper": "0x...",
  "slippage_bps": 100
}
```

Suggested quote response:

```json
{
  "side": "buy",
  "chain_id": 8453,
  "token_in": "0x...",
  "token_out": "0x...",
  "amount_in_raw": "1000000",
  "amount_out_raw": "12345",
  "minimum_amount_out_raw": "12221",
  "price_impact_percent": "0.42",
  "gas_fee": "123456789",
  "route_label": "Uniswap v4",
  "approval": null
}
```

Suggested prepare response:

```json
{
  "swap": {
    "quote": {},
    "wallet_action": {
      "chain_id": 8453,
      "to": "0x...",
      "data": "0x...",
      "value": "0x0",
      "expected_signer": "0x..."
    }
  }
}
```

Do not add agent CLI swap commands in the first web patch unless the CLI contract is updated at the same time.

## Server Responsibilities

The server should:

- hold the Uniswap API key
- validate that both token addresses are the expected USDC or the selected live agent token
- validate that the token belongs to a graduated Autolaunch subject
- call Uniswap `/check_approval`, `/quote`, and `/swap`
- limit the first version to Base mainnet and Base Sepolia
- limit routing to `V4`
- return the same `wallet_action` shape used by the rest of Autolaunch
- rate-limit quote refreshes per wallet and token pair

## Browser Responsibilities

The browser should:

- connect the wallet
- show quote, route, minimum received, price impact, and estimated network cost
- ask the wallet to send approval transactions when needed
- ask the wallet to send the swap transaction
- show clear success or failure state
- refresh balances after confirmation

Autolaunch already has `WalletTxButton` for simple transaction sending. Native swaps use a richer hook because buys and sells may need an approval transaction before the final swap.

## Safety Rules

Only allow swaps where one side is the selected agent token and the other side is Base USDC.

Reject:

- tokens that do not belong to a graduated Autolaunch subject
- unsupported chains
- cross-chain quotes
- native ETH routes
- non-v4 pool routes
- bridge routes
- UniswapX routes in the first version
- quotes whose route changes away from the user's selected pair
- quotes with missing transaction data
- stale quotes
- very high price impact unless the user explicitly confirms

The app should display the external Uniswap link when native quoting fails, but it should not silently switch the user to an external swap.

## Open Questions

1. Should price impact above a threshold block the action or require an extra confirmation?
2. Should the app store swap records, or only refresh wallet balances from chain after confirmation?
3. Should a later version add ETH-to-USDC preparation before buying agent tokens?

## Suggested Patch Order

1. Add the API contract routes and response shapes.
2. Add a small Uniswap client module on the server.
3. Add quote and prepare endpoints for app users only.
4. Add a swap panel to graduated token surfaces.
5. Add a browser hook for approval plus final transaction sending.
6. Add tests with a mocked Uniswap client for quote success, no route, stale quote, wrong token, wrong chain, and high price impact.
7. Keep the external Uniswap link visible as the manual backup path.
