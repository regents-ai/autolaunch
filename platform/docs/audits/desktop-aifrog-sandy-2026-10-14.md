# Desktop auction and token audit — 14 October 2026

Requested scope: check the real desktop pages, especially AIFROG and SANDY,
and fix functional issues. Mobile work remains parked.

## Done checklist

- [x] Open both real auctions and tokens at a 1440 × 1000 desktop viewport.
- [x] Exercise public navigation, quote forms, settings, reward filters and bid lookup.
- [x] Fix confirmed issues locally and verify the changed interaction in a connected LiveView.
- [x] Compile, format, run existing tests and review the scoped changes.
- [x] Preserve unrelated work and record what still needs a release or a wallet-holder check.

The production baseline checked was v126, main `642f321d0cea1cbb4f0cbcbd3606b6897f477b12`.
Fixes are on local branch `sol/desktop-functional-1014`; they have not been pushed,
merged or deployed. This request authorized fixes, not another release.

## Confirmed issues and fixes

| Before | After | Why |
| --- | --- | --- |
| Escape leaves Swap settings open on both tokens, including from the slippage field. | Escape closes settings, retaining amount and slippage. Focus returns to the gear if it was inside the form; focus elsewhere stays there. | Keyboard dismissal must work without losing entered values or taking focus from another panel. |
| Base says only bids above the final price can claim; Robinhood says only bids at or above it can claim. | Both explain that bidders claim the tokens their bids bought and withdraw any unspent currency. The pending-finish version says claims must open first. | A bid below the final price can have bought earlier blocks. Equality also must not be excluded on Base. |

The settings fix uses Phoenix LiveView's keyboard binding and JS focus command,
with component-owned presentation state. Its window binding avoids the slippage
field's blur debounce; it is absent while settings are closed or the form is inert.
No new hook, timer, retry loop, queue or database schema is needed.

The settlement source confirms partial fills: `Autolaunch.Chain.CcaSettlement`
simulates a partial exit followed by a claim, and both chains' settlement actions
offer the claim when the auction actually returns tokens. Final maximum-price
standing alone is not claim eligibility. No settlement or contract logic changed.

## Real desktop checks

| Flow | AIFROG / NVDAc on Base | SANDY / SNDK on Robinhood |
| --- | --- | --- |
| Auction | [Loads finished](https://autolaunch.sh/auctions/AIFROG/85e71), pool ready, claims open, liquidity locked | [Loads finished](https://autolaunch.sh/auctions/SANDY/96468), pool ready, claims open, liquidity locked |
| Token | [Loads pool and staking figures](https://autolaunch.sh/tokens/AIFROG/85e71) | [Loads pool and staking figures](https://autolaunch.sh/tokens/SANDY/96468) |
| Auction/token navigation | Correct paired routes | Correct paired routes |
| Buy quote | 0.01 NVDAc produced about 4.84M AIFROG | 0.01 SNDK produced about 16.07M SANDY |
| Sell quote | Reversing and entering 1M AIFROG produced about 0.00186611 NVDAc | Reversing and entering 1M SANDY produced about 0.000550764 SNDK |
| Price-impact calculator | Buy/sell amounts arrived; invalid input cleared prior quotes | Buy/sell amounts arrived; invalid input cleared prior quotes |
| Input validation | Invalid amount refused; slippage 0 refused and 1 restored | Invalid price-impact input refused |
| Address copy | Showed Copied | Showed Copied |
| Reward filters | USDC and AIFROG selected with correct empty-state asset | USDG and SANDY selected with correct empty-state asset |
| Chart link | Dexscreener loaded AIFROG / NVDAc | Dexscreener loaded SANDY / SNDK |
| Public bid check | Bid 0 loaded its owner and withdrawn status | Bid 0 loaded its owner and withdrawn status |

Quotes are observations at particular blocks, not fixed prices or promised execution.
The initial zero output changes after the existing input delay and quote read; this
was not a quote failure. Both chart links appeared after pool data arrived.

Both Uniswap links independently loaded the correct token/stock pair on its own
network, including SANDY's Robinhood v4 pool and its transactions. The AIFROG
“See your rewards” anchor moved to the staking section. SANDY's Activity/Timeline
tabs and recorded-price replay control changed correctly.

## Local verification

- Compilation with warnings treated as errors, formatting and scoped diff checks passed.
- All 98 existing backend tests passed against isolated `autolaunch_mobile126_test`.
- Strict Credo and configured Sobelow checks passed.
- Actual local token page, `http://localhost:4072/tokens/DESKTOPTEST/10014`, verified
  Escape from the slippage input and gear, reopening with slippage 2 retained,
  amount 0.01 retained, and focus preserved on Launch when Escape was pressed there.
- The page used the existing configured Privy server and a clearly labelled synthetic
  record in `autolaunch_upcoming_browser_1014`. It remained read-only. No real pool
  or chain transaction exists for this fixture.

The initial form-level key binding did not receive a focused input's key event;
binding the input itself would inherit its blur debounce. The final window binding
was tested in the browser and closes immediately. The intermediate attempts were
not retained.

The claim wording was verified against settlement source and the existing tests.
The local synthetic auction has no readable chain state, so it does not exercise
the finished-auction claim guidance visually. Production still shows the old copy.

## Guidance and remaining limits

Current public docs, llms.txt and agents.md source and How It Works already describe
claiming what a bid bought. The stale final-price restriction was in the two auction
UI copy functions changed here. API, WebMCP, CLI and wallet instructions are unchanged.
These product swap/auction components have no matching implementation in ash-template;
no shared primitive or template change is part of this patch.

No wallet was connected and no swap, bid, finish, settlement, claim or staking
transaction was submitted. Wallet-signed flows require the wallet holder's own check.
No secrets, private deployment files, production database writes or contracts/v1
changes were involved. Unrelated guidance edits and other owners' files are preserved.

This is a scoped interaction audit, not an exhaustive financial or contract audit.
The prior release's known Bandit dependency advisory is unchanged; this audit did
not rerun or claim a clean dependency audit. Release gates and production verification
remain required before shipping this branch.

Evidence is saved at
`/Users/sean/Documents/regent/artifacts/desktop-audit-2026-10-14/autolaunch/`,
including test logs, production screenshots/DOM captures and the local settings screenshot.
