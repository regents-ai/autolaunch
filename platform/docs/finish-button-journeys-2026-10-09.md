# Finish button: wallet journeys (9 October 2026)

The Finish panel (`lib/autolaunch_web/live/finish_auction_component.ex`) sits on an
ended auction's page, Base (`auction_live.ex`) and Robinhood
(`robinhood_auction_live.ex`), until the auction's record says it graduated or failed.
It reads the launch with `Autolaunch.FinishActions.read/1`.

## 1. Controls

| Control | Opens the wallet | Sends |
| --- | --- | --- |
| Finish auction | Yes | The launch's `migrate`: `migrate(uint256 launchId)` on a Memestake launchpad (v1 or v2, Base or Robinhood), `migrate(address auction)` on the Revstake strategy |
| Finish auction (disabled) | No | Nothing; shown with its reason when the chain says the finish would fail |
| Check again | No | Reads a sent finish again |

## 2. Wallet situations

| Situation | Mark | Evidence |
| --- | --- | --- |
| Signed out | Not tried | The press sends nothing and says "Sign in to send this" (`OnchainSteps.failure_note/4`) |
| Active wallet not linked | Not tried | `OnchainSteps.mismatch_note/2` names both wallets |
| No wallet active | Not tried | Press says "Connect your wallet" |
| Second linked wallet | Not tried | A new review is built for it (`followed/1`) |
| Repeat press while the wallet is open | Not tried | The button stays pressable ("Finish auction again" once sent) |
| Wrong network, declined, no ETH for fees | Not tried | Shared hook and `failure_note/4` |
| Sped up or cancelled hash | Gap | Known gap 5 in the pattern |
| Browser extension, phone wallet | Not tried | Sean presses AGI with his own wallet after release |
| Smart wallet, Safe | Gap | Known gap 2 in the pattern |
| Waiting, then done, then the page refreshes | Not tried | On confirm the panel reads the launch again; the market feeds move the record to graduated or failed and the panel leaves the page |
| Slow chain, Check again | Not tried | Shared `SwapForm.wallet_step` |
| Reload | Not tried | The panel reads the chain again; nothing is kept |

## 3. Per control

| Case | Mark | Evidence |
| --- | --- | --- |
| Before the migration block | Works | Read on Base 9 Oct: the two hidden TEST auctions read running with their migration block ahead, so the button is disabled with "Finishing opens at block N" |
| After the migration block, running (AGI, Base v1) | Works | Read on Base: launch 3 on the v1 launchpad; on a private Base fork the finish succeeded (about 327,000 gas) and the read then said failed |
| Base v2 launchpad | Works | On the fork, past its migration block, the TEST auction's finish succeeded and read failed |
| Robinhood v1 (RDOG) | Works | Read on Robinhood Chain: graduated, so the button is disabled as finished |
| Base Revstake | Not tried | No Revstake auction exists yet; it reads the strategy's `distribution(address)`, as the automatic finisher does |
| Already finished | Works | BITE and RDOG read graduated |
| The chain cannot be read | Works | Page test: the line says "The auction could not be read just now." and the panel asks again every half minute |
| Finished record | Works | Page test: a failed auction's page shows no panel |

## 4. Beyond the buttons

- The status line is `role="status"` with `aria-live="polite"`, and keeps two lines of
  room so nothing below moves.
- No agent tool yet: agents cannot press Finish from the page.
