# Credits and Points adoption

Read-only summaries and activity live on `/profile`. Credits use the verified Privy identifier. Points resolve the shared account by that same identifier, never a local product account number. Missing accounts and failed reads are unavailable. Sign-out discards late private results. If session authority cannot be read while a result arrives, all private figures become unavailable; the page does not claim sign-out or retain an earlier balance. Signed agent balances use the shared `agent_budget` action and return its full result as `spending_grant`, including `grant_approvals_available`. The existing top-level `grant_approvals_available` also remains for compatibility.

Pins: elixir-utils `96fe9d3f386742ce93b04c6dfca183d99cc00787`; design-system `fe81f0b10a43690e556e8f8fb313e685b35ec0b3`; template reference `4c35436`.

## Spending and reward inventory

No product Credits charge, hold, refund or purchase adapter exists in Autolaunch. Auctions, bids, trades, staking and claims use the existing contracts and wallets. This integration assigns no Credits prices. Agent grant approvals stay disabled.

The shared proposed Points catalog includes `app.first_use.autolaunch`, `autolaunch.first_launch`, `autolaunch.first_graduation` and `autolaunch.first_settled_auction`. Autolaunch has no source adapters, approved rules or program start time. They do not earn. Account/social milestone adapters are also absent. A source, eligibility rule and activation date need approval before award integration.

This local adoption does not map historical accounts, migrate production, write real ledger entries, activate spending or awards, or deploy. Product account IDs and historical ownership stay intact.
