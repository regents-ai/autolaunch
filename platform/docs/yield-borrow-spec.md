# Yield & Borrow — product spec

**Status:** Proposed · 27 October 2026  
**Repository reviewed:** `regents-ai/autolaunch` at `6478f162da389cb4835b2da60a5935a44a96507d`  
Market selection, fees, implementation and production activation remain separate decisions.

## Product direction

Extend Autolaunch with yield-bearing investment products and optional financing: buy or bring eligible assets, borrow USDC, reinvest, monitor and exit. Earn disclosed service fees contributing to REGENT staking.

A later issuer offering could distribute investment-strategy shares and arrange financing with lenders/curators. Strategy shares represent portfolio assets and liabilities; an operator's Revstake token participates in routed business revenue. Financing is enabled per eligible asset, never assumed for every launch.

## Proposed first release

Use **one existing yield-bearing asset and one funded lending market on Base**, with USDC debt. Morpho Blue is the recommended first integration. This tests demand and complete position management; it does not yet validate launching a new financeable strategy.

External lenders/curator vaults provide USDC. Positions belong to each user's address or user-controlled account in the underlying protocol. Autolaunch operates the interface and execution preparation.

| Surface | Required behavior |
| --- | --- |
| `/yield` | Show strategy, issuer, income source, yield period, borrowing cost, liquidity, fees and eligibility. |
| `/yield/:slug` | Buy or bring collateral; borrow; optionally reinvest; add collateral; repay and withdraw. |
| Existing `/portfolio` | Show collateral, accrued debt, equity, leverage, LTV, liquidation buffer, history and exit controls. |
| Agent interfaces | Read strategies/authorized positions, simulate outcomes and prepare actions using existing identity and ownership rules. |

Borrowing is independently useful. Reinvestment buys the same supported asset and adds it to the same position through confirmed steps. Interrupted flows show actual assets, debt and recovery actions.

## Product requirements

- **Admission:** Verify exact contracts, oracle, funded borrowing liquidity, yield entitlement while collateral is held, issuer/contract/liquidator permissions, valuation and redemption terms. Cap exposure against executable entry and stressed exit capacity.
- **Limits:** Choose operating loan-to-value (LTV) below the market's liquidation LTV (LLTV). For Morpho, use the actual immutable market parameters and approved LLTV choices; do not copy illustrative report thresholds.
- **Preview:** Show collateral, gross debt including financed fees, equity, LTV, liquidation buffer, current borrowing cost and all fees. Compare estimated income on equity with unlevered holding. Label periods/assumptions, separate incentives and price gains/losses, and avoid deducting embedded costs twice.
- **Preparation and wallet presses:** Use fresh, block-stamped state. Refuse to prepare unsupported or stale risk-increasing quotes with an explanation. Preserve existing wallet behavior: every prepared wallet-button press reaches the wallet, including repeats while pending. Enforce applicable amount, debt/LTV, slippage, recipient and expiry bounds in execution; reconcile actual receipts.
- **Authority:** A person or independently authorized agent signs with the eligible wallet. SIWA identity or pairing supplies no spending authority. Preserve account/wallet ownership checks and protocol-level repayment/withdrawal access independently of Autolaunch.
- **Exit:** Quote transaction order, USDC needed upfront, health after every step, proceeds and liquidity constraints. Locked collateral is not repayment cash; withdrawal headroom may disappear near liquidation. Offer complete exit only with a demonstrated executable route. Keep supported repayment/recovery accessible.

## Revenue and implementation

Define a USDC service fee with an explicit basis, rate and recipient. Route only collected platform fees through the verified USDC revenue path to REGENT staking. Principal, collateral, debt proceeds and user earnings remain separate; launchpad swap fees do not set this product's pricing.

Implement in the existing Phoenix/Ash platform, with a product-owned Carry domain and lending adapter. Reuse shared identity, UI, `AutolaunchWeb.OnchainSteps`, chain reads and receipt tracking. Shared changes follow ash-template/library ownership; avoid duplicate account or payment infrastructure.

Extend existing HTTP, WebMCP and `regents autolaunch` descriptors for read/simulate/prepare, coordinating packaged CLI updates. Advertise implemented capabilities only after runtime enablement. Basic lending can reuse supported protocol entrypoints; combined swap/loop/unwind execution needs separate integration. Begin behind a feature flag.

## Acceptance criteria

1. Buy and bring-existing-collateral paths both work; borrowing needs no auction or reinvestment.
2. Protocol ownership and continuing yield entitlement are demonstrated; balances reconcile after reload.
3. Reinvestment, cancellation, failure and repeated wallet presses retain accurate balances and recovery actions; repeated/stale execution cannot exceed the reviewed maximum debt/exposure.
4. Hypothetical 9% asset income, 5% borrowing cost and 3× exposure show 17% annual income on equity; 10% borrowing shows 7%, before fees and price changes.
5. Stale data, unsupported inputs, expired quotes and exceeded bounds are handled at preparation/execution without adding a wallet-button gate.
6. Partial repayment and complete exit reconcile with receipts and maintain protocol constraints at every intermediate step, with upfront cash requirements disclosed.
7. Fees match previews, are recorded once per confirmed payment and reconcile through the REGENT revenue path.

## Decisions and later work

Before enabling, select the asset/market/oracle; verify permissions; set LTV, exposure, freshness and fee parameters; demonstrate entry, failure recovery and stressed exit.

Later options: atomic looping, bounded automation, lender distribution and issuer-created strategies, including independently assessed covered-call shares. Native Revstake/Memestock collateral, pooled leverage, cross-chain flows and new lending protocols/tokens are outside this pilot. This proposal does not reprioritize existing stock or covered-call work.

## References

- [Existing product](../../README.md) · [Wallet rules](../../AGENTS.md) · [Wallet-step implementation](../lib/autolaunch_web/onchain_steps.ex)
- [Morpho markets](https://docs.morpho.org/learn/concepts/blue/) · [Execution](https://docs.morpho.org/developers/contracts/bundles/)
- [Borrow fees](https://docs.morpho.org/developers/borrow/guides/monetize-borrow-product/) · [Permissioned assets](https://docs.morpho.org/curate/concepts/permissioned-assets/)
