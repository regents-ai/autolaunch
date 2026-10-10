# Credits and Points adoption

Read-only summaries and activity live on `/profile`. Credits use the verified Privy identifier. Points resolve the shared account by that same identifier, never a local product account number. Missing accounts and failed reads are unavailable. Sign-out discards late private results. If session authority cannot be read while a result arrives, all private figures become unavailable; the page does not claim sign-out or retain an earlier balance. Signed agent balances use the shared `agent_budget` action and return its full result as `spending_grant`, including `grant_approvals_available`. The existing top-level `grant_approvals_available` also remains for compatibility.

Pins: elixir-utils `fd0719c3a1bcbb8906aea69302ede09d51b7e6ee`; design-system `fe81f0b10a43690e556e8f8fb313e685b35ec0b3`; template reference `29cfcfb50545aaeb856f8ba38c15fb4c366563fb`.

## Spending and reward inventory

No product Credits charge, hold, refund or purchase adapter exists in Autolaunch. Auctions, bids, trades, staking and claims use the existing contracts and wallets. This integration assigns no Credits prices. Agent grant approvals stay disabled.

The shared proposed Points catalog includes `app.first_use.autolaunch`, `autolaunch.first_launch`, `autolaunch.first_graduation` and `autolaunch.first_settled_auction`. Autolaunch has no source adapters, approved rules or program start time. They do not earn. Account/social milestone adapters are also absent. A source, eligibility rule and activation date need approval before award integration.

This local adoption does not map historical accounts, migrate production, write real ledger entries, activate spending or awards, or deploy. Product account IDs and historical ownership stay intact.

The current Points library preserves period-end NFT evidence and wallet history. This source adoption verifies the package migration only in the isolated local database. The shared production migration belongs to the separately authorized migration owner; this site does not rerun it or enable earning.
