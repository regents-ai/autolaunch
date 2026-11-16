# Earn — design note

Earn lets a person or an agent lend USDC on Base through Aave V3, watch the balance grow, and
take it back, all from Autolaunch. The site prepares the wallet steps; the wallet's own key signs
and sends them, Aave's contracts hold the funds, and the site holds nothing, sends nothing and
charges nothing. Built on `al/earn-1116` (15 November 2026), switched off by default.

## 1. The switch and the catalog

- **Switch.** `AUTOLAUNCH_EARN=true` turns Earn on (`config/runtime.exs`); unset is off, any
  other value stops the boot, and on needs `AUTOLAUNCH_BASE_DEPLOYMENT`. Everything reads
  `Autolaunch.Earn.Catalog.enabled?/0`.
- **Catalog.** Plain data in `config/config.exs` (`:earn_products`): id, chain id, protocol,
  market, asset, and the addresses of the pool and the asset. One product today, `aave-usdc`
  (Aave V3 Pool `0xa238…d1c5`, USDC `0x8335…2913`). Everything else — the market token, the
  rate, the flags, the cap, the totals — is read from the chain at the latest block on every ask.
- **Where it reads.** The site's Base deployment (`Autolaunch.Lab.current/0`): Base, or a local
  fork of Base carrying the same contracts at the same addresses. Any other chain is
  `base_deployment_mismatch`.
- **Nothing is stored.** No table, no migration, no cache. The chain is the record.

## 2. The reads (`Autolaunch.Earn.Chain`)

Two Multicall3 requests, both pinned to the latest block's own hash, so every figure in one
answer is from one block. The second needs the market token the first returns.

1. The pool: `getReserveData(USDC)` (fifteen words) and `getReserveNormalizedIncome(USDC)`.
   - Word 0, the configuration bitmap: decimals (bits 48–55), active (56), frozen (57),
     paused (60), supply cap in whole tokens (116–151, 0 for none). Every other field is ignored.
   - Word 2, the current liquidity rate: a simple yearly rate in ray (10^27), shown to two places,
     half up. It is "the rate now"; it changes.
   - Word 8, the market token (aUSDC). Word 12, what is owed to the treasury, in scaled units.
2. The market token and USDC: `totalSupply()` (supplied, interest included),
   `scaledTotalSupply()`, and USDC `balanceOf(aToken)` (what can be withdrawn now). For a
   wallet, its aUSDC `balanceOf` (its balance, interest included), its USDC `balanceOf` and its
   USDC `allowance` to the pool.

**Supply cap.** Aave counts against the cap every scaled balance plus the treasury's share at the
index of the block a deposit lands in (`ValidationLogic.validateSupply`). Earn reads that sum at
the latest block's index: `counted = rayMul(scaledTotalSupply + accruedToTreasury, index)`,
rounded half up as `WadRayMath.rayMul` is. The index only grows, so a deposit over the room at
this block is over it at every later one. Rounding can differ from the pool's by a unit or two
at the very edge of the cap.

**Available now.** USDC held by the aToken. Since Aave 3.1 the pool also keeps a virtual
balance; USDC sent straight to the aToken raises `balanceOf` above it. Reading `balanceOf` can
only overstate what is available, so Earn never blocks a withdrawal that would go through; at
worst a withdrawal it let through reverts.

## 3. The steps (`Autolaunch.Earn.Steps`)

Built on the server for a signer the caller has proved is one of the acting account's own wallets
(`Autolaunch.CoveredCalls.Signer`), each with the site's Builder Code at the end of its calldata
(`RegentChain.Review.step/3`):

| Kind | Steps | Notes |
| --- | --- | --- |
| Deposit | `usdc_approval`: USDC `approve(pool, amount)`; then `supply`: `supply(USDC, amount, signer, 0)` | The approval is exact and always its own step. `approved` says whether the chain already holds it; it is shown done and stays pressable. |
| Withdraw an amount | `withdraw`: `withdraw(USDC, amount, signer)` | Exactly that amount, even when it equals the balance. |
| Withdraw everything | `withdraw`: `withdraw(USDC, 2^256 − 1, signer)` | The whole balance as it stands when the step lands, interest to that moment included. |

An amount is a whole number of USDC's smallest units, 1 to 2^128 − 1. Zero, a fraction, text, or
`everything` on a deposit (or with an amount) is an input refusal, never a blocked step.

## 4. Blocked reasons

A step is blocked only when the chain at the latest block makes it certain to fail (rule 11's one
exception). A blocked answer still carries its steps, so an agent decides for itself and a page
button comes back as soon as a fresh read allows the step. The order is part of the contract —
first the market, then the wallet, then what the market can take or give now — and the first that
fails is the reason (`Autolaunch.Earn.States.blocked/1`). An approval still to land is never a
reason.

| Order | Check | Deposit | Withdraw | Page words |
| --- | --- | --- | --- | --- |
| 1 | Market status | `market_inactive`, `market_paused`, `market_frozen` | `market_inactive`, `market_paused` | This market is closed / paused / takes no deposits right now |
| 2 | What the wallet holds | `not_enough_usdc` (amount > wallet USDC) | `over_balance` (nothing lent, or amount > balance) | Not enough USDC on Base / More than your balance |
| 3 | What the market can take or give now | `over_supply_cap` (amount > room, or full) | `not_available_now` (amount, or the whole balance, > USDC available) | More than the market takes right now / Not that much is available to withdraw right now |

Agents get the same codes with a sentence each (`Autolaunch.Earn.Answer`).

## 5. Surfaces

- **`/earn`** (`AutolaunchWeb.EarnLive`, `AutolaunchWeb.EarnComponent`): the market's Rate,
  Supplied, Available and Room with the block read at, Refresh, the Deposit and Withdraw tabs
  (`?tab=withdraw`), the wallet panel (Balance, Wallet, Amount with Max, the button, and the
  review over the panel), and Risks. Off, the address is the site's 404 and its stylesheet is not
  served.
- **`/portfolio`, Earn** (`AutolaunchWeb.EarnPortfolioComponent`): signed in, each product's
  balance read now with the block, and Withdraw (a balance) or Deposit (none).
- **Rail and home.** An Earn row in the rail after Stocks, and a fourth home card ("rise"
  picture) while Earn is on.
- **Agents.** Four operations in `Autolaunch.Earn.Product`, each answer carrying its block:
  `earn_products` (`GET /api/v1/earn/products`, public), `earn_quote`
  (`POST /api/agent/v1/earn/quote`), `earn_positions` (`GET /api/agent/v1/earn/positions`),
  `prepare_earn` (`POST /api/agent/v1/earn/steps`), and the signed-in `GET /api/v1/me/earn`. The
  agent routes need a signed, paired agent. The same four are hosted MCP tools and browser tools
  (`priv/earn_tools.json`), described in `contracts/earn.openapiv3.yaml`, `priv/capabilities.json`,
  `/llms.txt`, `/llms-full.txt`, `/docs`, `/agents` and the skill, each only while Earn is on. The
  regents CLI has no commands yet (`docs/agent-parity.md`: Gap, regents-cli lane).

## 6. States

Every machine is derived from the chain as read at one block, or from what the page holds right
now, and stored nowhere. Each has one derive function matched in full, with no catch-all, and
what a state allows is decided in one place: `allows?/2` for the market and `blocked/1` for a
step. Nothing gates a wallet button beyond rule 11: the button is disabled only for a step the
latest block makes certain to fail, with its reason beside it.

### 6.1 Market status — `States.status/1`

| State | Derived from (reserve word 0) | Moves to | Allows (`allows?/2`) |
| --- | --- | --- | --- |
| `:open` | active, not paused, not frozen | any other, when Aave governance sets a flag | deposit, withdraw |
| `:frozen` | active, not paused, frozen | open, paused, inactive | withdraw only |
| `:paused` | active and paused (frozen ignored) | open or frozen when unpaused; inactive | nothing |
| `:inactive` | not active (the rest ignored) | open, frozen or paused when activated | nothing |

Only Aave governance moves it. The site sees a move at its next read: Refresh, a confirmed step,
the page coming back into view, a wallet change, or any agent call. Tests:
`test/autolaunch/earn/states_test.exs` (the order, the table), `steps_test.exs` (a market that is
not open blocks what it does not take), `earn_live_test.exs` (a frozen market disables Deposit
and lets a withdrawal out).

### 6.2 Deposit room — `States.room/1`

| State | Derived from | Moves to | Allows |
| --- | --- | --- | --- |
| `:uncapped` | cap 0 | room or full when governance sets a cap | any deposit the market and wallet allow |
| `{:room, left}` | cap × 10^decimals − counted > 0 | full as deposits and interest fill it; more room as withdrawals free it or the cap rises | a deposit up to `left` |
| `:full` | cap × 10^decimals − counted ≤ 0 | room when withdrawals free it or the cap rises | no deposit (`over_supply_cap`); withdrawals unaffected |

Page: "No cap", the amount left, or "Full". Agents: `room` null, units or 0, and `supply_cap` null
or whole tokens. Tests: `states_test.exs` (each boundary to the unit, and full past the cap),
`steps_test.exs` (the treasury's share and interest counted), `earn_live_test.exs` (a market at
its cap reads full; one without a cap says so).

### 6.3 Withdraw availability — `States.availability/2`

| State | Derived from | Moves to | Allows |
| --- | --- | --- | --- |
| `:available` | amount ≤ USDC held by the aToken | short when borrowing takes it | the withdrawal |
| `{:short, available_now}` | amount > USDC held by the aToken | available as borrowers repay or lenders deposit | nothing for that amount (`not_available_now`) |

For everything, the amount checked is the balance at this block. Tests: `states_test.exs`,
`steps_test.exs` (blocked past what the market has now).

### 6.4 Deposit readiness — `States.readiness/2`

| State | Derived from | Moves to | Allows |
| --- | --- | --- | --- |
| `:needs_approval` | allowance < amount | approved when an approval for at least the amount lands, or the amount is lowered | both steps, the approval first |
| `:approved` | allowance ≥ amount | needs approval when the supply spends it (the approval is exact), the amount is raised, or the allowance is changed elsewhere | both steps; the approval is shown done and still pressable |

Never a blocked reason, and never disables Confirm deposit (section 9.1). Tests:
`states_test.exs` (each boundary), `steps_test.exs` (follows the allowance against the amount as
it stands), `earn_live_test.exs` (an approval the chain holds shows as done; one for less does
not).

### 6.5 Withdraw amount kind — `States.withdrawal/1`

| State | Derived from | Moves to | Allows |
| --- | --- | --- | --- |
| `{:amount, units}` | a typed amount; an agent's `amount` | everything when Max is pressed | withdraw exactly `units` |
| `:everything` | Max on the Withdraw tab; an agent's `everything: true` with no amount | an amount as soon as the field is edited; empty after the tab changes or the withdrawal is done | withdraw `2^256 − 1`: the whole balance when it lands |

Everything is only ever asked for by name: a typed figure equal to the balance is that figure,
since interest keeps growing until the step lands. Everything is withdraw-only. Tests:
`states_test.exs`, `steps_test.exs` (an amount equal to the balance withdraws that amount),
`earn_live_test.exs` (Max on Withdraw asks for everything; only an edited figure is a figure).

### 6.6 Position — `States.position/1`

| State | Derived from | Moves to | Allows |
| --- | --- | --- | --- |
| `:none` | aUSDC balance 0 | held when a deposit lands | deposit; a withdrawal is `over_balance`; page "No balance yet", portfolio "Nothing lent yet." with Deposit |
| `{:held, balance}` | aUSDC balance > 0, one unit of dust included | grows with interest; smaller after a partial withdrawal; none after withdrawing everything | deposit, withdraw; portfolio shows the balance with Withdraw |

Tests: `states_test.exs` (only zero is none), `earn_live_test.exs` (nothing lent; the portfolio
cases), `earn_routes_test.exs` (positions).

### 6.7 Amount entry — `Autolaunch.Earn.Amount.entry/2`

| State | Derived from | Moves to | Allows |
| --- | --- | --- | --- |
| `:empty` | nothing typed | invalid or valid on a keystroke, or Max | a press says "Enter an amount above zero." and opens nothing |
| `{:invalid, reason}` | `:not_a_number`, `:too_precise` (more than 6 decimals), `:zero`, `:too_large` | another state on a keystroke | its words under the field; the button stays enabled, and a press repeats the words |
| `{:valid, units}` | digits with at most one dot, above zero, within 2^128 − 1 | another state on a keystroke; empty after the tab changes or the step is done | a quote and, on a press, a review |

Max writes the figure with `Amount.text/2`, which `entry/2` reads back exactly (property tests).
For agents the amount is an integer of smallest units; 0, a string or a fraction is
`invalid_request`, and `everything` on a deposit is `invalid_amount`. Tests: `reads_test.exs`
(three states, two properties), `earn_live_test.exs` (an amount that doesn't read is said under
the field and disables nothing), `steps_test.exs` (refused, never blocked).

### 6.8 Blocked-reason derivation — `States.blocked/1`

An ordered function rather than a set of states; the order is section 4.

| Step | Deposit | Withdraw |
| --- | --- | --- |
| 1. `market/2` | `allows?(status, :deposit)` or the status's reason | `allows?(status, :withdraw)` or the status's reason |
| 2. `held/2` | amount ≤ wallet USDC, else `not_enough_usdc` | held and (everything, or amount ≤ balance), else `over_balance` |
| 3. `market_room/2` | room uncapped or amount ≤ left, else `over_supply_cap` | `availability(amount or balance, available)`, else `not_available_now` |
| Result | `:ok` or `{:blocked, reason}` | `:ok` or `{:blocked, reason}` |

The page disables the button with the reason beside it and re-reads on each change of amount, a
wallet change, the page coming back into view and after each press, so the button comes back once
the chain allows the step. Tests: `states_test.exs` (both orders, every reason),
`steps_test.exs`, `earn_live_test.exs` (a deposit past the
wallet's USDC is disabled with its reason and comes back once the chain allows it).

### 6.9 Terms read — `EarnLive`, one `AsyncResult` per product

| State | Derived from | Moves to | Shows |
| --- | --- | --- | --- |
| loading | the page opening, Refresh, or a confirmed step (`{:earn_changed, id}`) | loaded or failed | a waiting block; no figures, no status |
| loaded | `read_earn_terms` answered | loading on Refresh or a confirmed step | status, Rate, Supplied, Available, Room, "Read at block N"; the panel mounts on the first one |
| failed | the read refused or crashed | loading on Refresh | "The market couldn't be read just now." and no figures; before any read succeeded, no panel |

Between a confirmed step and the fresh read the terms show nothing: each read starts from loading,
so a figure from before the step never passes for a current one. The panel's own wallet figures
are a separate machine (section 7.1). Tests: `earn_live_test.exs` (no figures before the read,
the figures and block, a failed read and Refresh, a confirmed step reads the market again).

### 6.10 Review lifecycle — shared `AutolaunchWeb.OnchainSteps`, as covered calls

Earn uses the same server half (`OnchainSteps`, `RegentChain.Presses`) and browser half
(`assets/js/hooks/onchain_steps.ts`) as covered calls, with the same `steps/1`, `next_step/1`,
`confirmed/2` and `step_reverted/2` shape as `CoveredCallComponent`. Nothing is forked.

| State | Derived from | Moves to | Allows |
| --- | --- | --- | --- |
| none | `review: nil` | open when a press finds the step not blocked | the panel's button |
| open | `put_review/2` with a review built at the latest block for the active signer; each opening has its own id | in wallet on a press; none on Close, a tab change or another signer | each step's button, one at a time; the approval stays pressable |
| in wallet | the browser only: the pressed button is marked until the wallet answers | sent, or failed with nothing sent | further presses: every press reaches the wallet |
| sent / stalled | the newest press's outcome `:pending` (stalled after a long wait) | confirmed or reverted, read every two seconds | the next step's button at once |
| confirmed | outcome `:confirmed` | the review closes once every step landed once | re-reads the market and the wallet; the last step shows what moved and clears the amount |
| failed, nothing sent | `step_failed` (declined, wrong network, wallet changed, no fees, …) | open | a note beside the button; the same step is pressable again |
| failed, reverted | outcome `:reverted` | open with a review built again from the chain now, or none with the reason the chain now gives | "The step did not go through and nothing moved." |
| other | a transaction that is not the step this page prepared | as for a fresh press | the button shows again |

The cases the brief names:

- **The chain changes mid-review.** A review is fixed once built and is not rebuilt on a timer
  (covered calls does not use `refresh_later/1`; neither does Earn). A press still sends what is
  on the page. If it then reverts, `rebuild_reverted/4` builds the review again from the chain as
  it is now, once nothing else from that review is on its way, and the next press sends what the
  chain accepts now, or the panel says why nothing can be done. Outside the review, the button's
  quote is read again on focus, on a wallet change and after each press.
- **The wallet's account or network changes.** A new active wallet re-syncs the panel; a review
  built for another signer closes, since its steps were built for that wallet only. The network is
  known only at a press: the browser asks the wallet to switch to Base (adding it if needed), and
  if it still is not on Base nothing is sent and the note says to switch. A wallet that changes
  during a press sends nothing and says so.
- **A reload with a transaction pending.** Nothing is kept beyond the page, as on covered calls;
  there is no adoption of a pending transaction across a reload. The reloaded page reads the
  market and the wallet at the latest block, so the figures show the result once the transaction
  lands; an approval that landed shows as done in the next review.
- **A double press.** Each press reaches the wallet, including while the first is pending. The
  step shows its newest press; a step any press of which landed stays done. Two supplies that both
  land deposit twice, an accepted outcome under rule 11.

Tests: `earn_live_test.exs` (opens with the exact steps and closes on request; a confirmed step
re-reads and the last closes the review with what moved; a step that does not go through is
reviewed again, then closes with the reason; a review closes on another wallet or another tab);
the shared `test/autolaunch_web/onchain_steps_rebuild_test.exs` and covered calls' journeys.

### 6.11 Wallet — `OnchainSteps.signer/2` and `mismatch_note/2`; the network at the press

| State | Derived from | Moves to | Allows |
| --- | --- | --- | --- |
| signed out | the session has no account (`linked: nil`) | signed in | terms and risks; the panel offers Sign in |
| signed in, no wallet open | Privy reports no active wallet | on Base when one opens | figures for the account's own wallet; a press says to open one and opens nothing |
| on Base, may act | Privy's active wallet is one the account links | another of the account's wallets, an unlinked one, or none | quotes, reviews and presses for that wallet |
| account changed | the active wallet becomes another linked wallet | as on Base, for the new wallet | the open review closes; figures and quote follow the new wallet |
| a wallet the account does not link | the active wallet is not linked | as above | a note naming both; nothing may act; figures stay on the account's own wallet |
| wallets unread | the connection dropped while reading the account | read again on the next update | nothing may act; a press says to try again |
| on another network | known only at a press (`send_step.ts`) | Base once the wallet switches | the wallet is asked to switch; refused, nothing is sent and the note says so |

The network is not a server state on purpose: knowing it before a press would mean gating a button
by page state. Tests: `earn_live_test.exs` (no wallet open; a review closes when the wallet that
may act changes), the shared hook's journeys.

### 6.12 Switch × prelaunch

| | Prelaunch read-only | Open |
| --- | --- | --- |
| **Off** | `/earn` and every Earn route answer as an address with nothing at it; no tool listed or run; no document, rail row, home card, portfolio section or contract path names Earn | the same |
| **On** | the page, its terms and its wallet panel work as covered calls' do (the person's own wallet signs); products, quote and positions answer agents; the agent steps route is refused `prelaunch_read_only` (503) and `prepare_earn` is neither listed nor run | everything |

Derived from `Catalog.enabled?/0` (`Autolaunch.Earn.Checks.Offered` for the operations, the
router and the documents) and `Autolaunch.Prelaunch.read_only?/0` (`AutolaunchWeb.Prelaunch`, and
`LaunchesOpen` on `prepare_answer`). Tests: `earn_off_test.exs` (no route, unnamed everywhere,
the contract adds only Earn's parts), `earn_routes_test.exs` (preview before opening, steps only
after), `earn_mcp_test.exs` (listed only while on; prelaunch hides `prepare_earn`; the guides).

### 6.13 Agent flow — stateless

| Call | Reads at the latest block | Answers | Refusals |
| --- | --- | --- | --- |
| `earn_products` | the market | each product's terms, risks and block | `chain_unavailable` |
| `earn_quote` | the market and the signer's wallet | amount, `everything`, `approved`, `blocked`, the wallet's figures, block; no calls | `unknown_product`, `invalid_amount`, `invalid_request`, `wrong_signer`, `wallet_required`, `chain_unavailable`, `agent_not_paired` |
| `prepare_earn` | the same | the quote plus the steps, even when blocked | the quote's, and `prelaunch_read_only` before opening |
| `earn_positions` | each product for the signed-in wallet | position, balance, USDC, allowance, block | `agent_not_paired`, `chain_unavailable` |

The server keeps nothing between calls: no session, no reservation, no pending step. An agent
reads products, quotes, prepares, has its person's wallet send each step in turn, and reads
positions to see the result. A step built at block N may be stale when sent; the agent prepares
again. Every surface (HTTP routes, browser tools, hosted MCP tools) runs the same operation, so
answers and refusals match word for word. Tests: `earn_routes_test.exs`, `earn_mcp_test.exs`.

## 7. Implicit machines found

1. **The panel's wallet figures** (`held`, keyed by `{wallet, held_reads}`): nothing, reading,
   read. Read again for each new wallet shown and each ask (focus, wallet change, after a press,
   a confirmed step); a new ask cancels the read still running; a failed read shows "—". Unlike
   the terms, the earlier figures stay on screen until the fresh read lands, including right after
   a confirmed step. Nothing is built from them: every review is prepared fresh.
2. **Quote freshness** (`quote`, `current/1`): a quote counts only for the amount and signer it
   was read for, and an answer for an earlier amount or wallet is dropped. Until the fresh one
   lands the button shows no reason; a press reviews from a fresh read anyway.
3. **The approval shown done**: an approval step is `:done` when the review was built with
   `approved`, or once one of its presses landed, whatever a later press does.
4. **Max** (`max`): on Withdraw, Max asks for everything until the field is edited; on Deposit
   it only fills in the wallet's USDC.
5. **The tab**: Deposit or Withdraw from `?tab=`. A change clears the amount, Max and the notice,
   and closes an open review.
6. **The portfolio read**: loading, read or failed for the section; per product, a balance,
   nothing lent, or "Couldn't be read just now."
7. **The done note** (`done`): none, or what the last step moved, until dismissed.

None of these gates a wallet button.

Catch-all clauses kept, none of them a state derivation: `Earn.reason/1` (any error that is not
an Earn refusal reads as `chain_unavailable`), `refusal_words/1` (every refusal but two says Base
could not be reached), `step_state/1`'s `:other`, `Steps.asked/2` and `Catalog.product/1` (input
that is not an amount or a product), and Max with no figures read. A refusal reason outside
`EarnAnswer`'s table raises, as covered calls' does; only deployment errors (`earn_off`,
`base_deployment_mismatch`, a missing deployment) can produce one.

## 8. What is not there

- No "earned so far" figure: the balance includes interest, and the site keeps no history to
  subtract from it.
- No rewards or incentives shown: only the supply rate the market itself pays.
- No second place to lend yet; the catalog takes more products as data.
- No health-factor check: a wallet that borrows against its aUSDC elsewhere can have a withdrawal
  revert. Earn does not read that and does not block it.
- No permit, batching or atomic sending: approval and supply are two transactions, as covered
  calls' panels send them.
- No regents CLI commands, no changelog entry, no migration.

## 9. Where the brief and covered calls differ

1. **Deposit after its approval.** The brief asks for Deposit to be disabled until its approval
   is on the chain, "exactly as covered calls' Buy does". Covered calls' Buy is not disabled: its
   approval is a step of the review, Confirm purchase shows the moment the approval is sent, and
   its test says so. Earn follows covered calls, and rule 11, under which a pending approval is
   never a reason to block. Exposure is the page that disables its step with "Approve first".
2. **A reload with a pending transaction.** The brief names "adopt". The shared code keeps nothing
   beyond the page, and `OnchainSteps.adopt/1` reads the account's wallets; it does not take over a
   transaction. Earn follows covered calls: the reloaded page reads the chain.
3. **Prelaunch.** Swap and stake panels close during prelaunch; covered calls' panel stays usable
   on the page while its agent steps route waits. Earn follows covered calls.

## 10. Tests and evidence

- `test/autolaunch/earn/`: `states_test.exs` (9), `reads_test.exs` (6, two properties),
  `steps_test.exs` (12).
- `test/autolaunch_web/`: `controllers/earn_routes_test.exs` (5), `controllers/earn_off_test.exs`
  (3), `earn_mcp_test.exs` (6), `live/earn_live_test.exs` (18). Each is in `test/manifest.json`.
- The chain double is `test/support/earn_chain.ex`.
- Fork proof, 15 November 2026, on anvil forking Base at block 58035867 with anvil's first test
  account: a 250 USDC deposit prepared as approval then supply, both sent and landed with the
  Builder Code; aUSDC 249999999 after; 250996324 thirty fork-days later; a 1000 USDC withdrawal
  blocked `over_balance`; withdraw everything landed, leaving 1000996327 USDC and 0 aUSDC; and
  withdraw everything again blocked `over_balance`.

## 11. Open items

- Section 9.1 is the founder's to settle.
- A headless browser walk of `/earn` against a fork (FEATURES marks it a gap; proved by hand).
- regents CLI commands, when the switch goes on.
