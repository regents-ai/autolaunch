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
  market, asset, the asset's decimals (6), and the addresses of the pool and the asset. One
  product today, `aave-usdc` (Aave V3 Pool `0xa238…d1c5`, USDC `0x8335…2913`). Every amount is
  counted in the catalog's decimals, so the page and its panel need no reading to start, and
  every reading checks them against the reserve's own: a market naming others is refused as
  `invalid_chain_response` (section 2). Everything else — the market token, the
  rate, the flags, the cap, the totals — is read from the chain: the market's terms from a
  reading every visitor shares for at most ten seconds (section 2.1), and a wallet's figures, a
  preview and a step's build at the latest block on every ask.
- **Where it reads.** The site's Base deployment (`Autolaunch.Lab.current/0`): Base, or a local
  fork of Base carrying the same contracts at the same addresses. Earn switched off, no
  deployment the site can read, or one on any other chain is the refusal `earn_unavailable`
  (`Catalog.lab/1`; "Earn is not available right now.", 503).
- **Nothing is stored.** No table and no migration. The market's terms are kept in memory for at
  most ten seconds (section 2.1); the chain is the record.

## 2. The reads (`Autolaunch.Earn.Chain`)

Two Multicall3 requests, both pinned to the latest block's own hash, so every figure in one
answer is from one block. The second needs the market token the first returns.

**The pool's version.** Base's pool reports `POOL_REVISION()` 12, newer than Aave v3.7's 11. It
has virtual accounting (`getVirtualUnderlyingBalance`), custom errors (`SupplyCapExceeded`,
`0xf58f733a`) and the supply-cap rounding of v3.5 on, which the fork proof checked to the unit
(section 10).

1. The pool: `getReserveData(USDC)` (fifteen words), `getReserveNormalizedIncome(USDC)` and
   `getVirtualUnderlyingBalance(USDC)`.
   - Word 0, the configuration bitmap: decimals (bits 48–55), active (56), frozen (57),
     paused (60), supply cap in whole tokens (116–151, 0 for none). Every other field is ignored.
     Decimals other than the catalog's refuse the whole reading (`invalid_chain_response`).
   - Word 2, the current liquidity rate: a yearly rate in ray (10^27), before compounding, cut to
     two places and never rounded up (`Answer.yearly_percent/1`). The page says "a year at
     today's rate, before compounding. It changes."
   - Word 8, the market token (aUSDC). Word 12, what is owed to the treasury, in scaled units.
2. The market token: `totalSupply()` (supplied, interest included) and `scaledTotalSupply()`. For
   a wallet, its aUSDC `balanceOf` (its balance, interest included), its USDC `balanceOf` and its
   USDC `allowance` to the pool.

**Supply cap.** From v3.5 the pool checks a deposit as
`(scaledTotalSupply + rayDivFloor(amount, index) + accruedToTreasury).rayMulFloor(index) ≤ cap ×
10^decimals` (`ValidationLogic.validateSupply`), both roundings down. `States.capacity/1` solves
that for the largest amount at the read block's index, with the treasury's share as the pool last
stored it: at a block where the reserve is up to date the pool takes exactly the capacity and
refuses one unit more (fork proof). Between the read and the block a deposit lands in, interest
raises the index and the treasury's share, so the capacity there is smaller (about 0.3 USDC a
second on Base's market today): a deposit near the capacity can still be refused when it lands,
and one past it is refused at the read block. Rounding down can let a deposit one unit past the
cap through, and the capacity counts that unit. A deposit so small it scales to 0 at the index (1
unit, once the index is above 1) is refused by the pool as an invalid amount; Earn does not block
it.

**Available now.** The pool's virtual balance, `getVirtualUnderlyingBalance(USDC)`: the USDC the
pool counts as its own and can pay out. USDC sent straight to the aToken is not counted, so the
aToken's own `balanceOf` can be more than can be withdrawn (on the fork, 16,616,952.128271
against 16,621,868.424364).

### 2.1 The shared reading (`Autolaunch.Earn.SharedTerms`)

The market's terms (the `:terms` action) are one reading every visitor shares: the page and its
Refresh, `GET /api/v1/earn/products` and the products tools all read it. Standard tool: Cachex,
as the site's public auctions and stock list are kept, through `Cachex.fetch/4`, so visitors who
ask while a reading is being taken wait for that one reading instead of each starting their own.
No GenServer, no timer of Earn's own.

- **Lifetime.** Ten seconds (`:earn_terms_kept_ms`, 10_000; 0 in the tests, which reads live).
  Cachex's own expiry drops it. A reading that fails is not kept.
- **A landed step, once for each transaction.** `SharedTerms.changed(id, hash)` marks the
  transaction landed and bumps the product's landed count in one step: `Cachex.get_and_update/3`
  on the key `{:landed, id, hash}` runs under the cache's own lock, and only when the mark is
  absent does it `Cachex.incr` the count and commit the mark, kept for an hour (far past a
  reading's ten seconds). Cachex has no put-if-absent of its own; this is its atomic form, never a
  get then a put. The reading's key carries the count, so every later ask takes a new reading,
  the one still being taken included. Only the first report broadcasts `{:earn_changed, id,
  hash}` on `"earn:" <> id`; a report of the same transaction again, from any page, bumps nothing
  and tells nobody, so a replayed `step_sent` cannot make every page read the chain again.
- **More than one machine.** Each keeps its own readings and marks. A page that hears
  `{:earn_changed, id, hash}`, perhaps from another machine, first calls `SharedTerms.heard/2`,
  the same mark-and-bump on its own machine, and then reads: the first page on a machine to hear
  it counts it, the rest find it counted, so every open page takes a reading from after the step.
  A machine with no page of the product open hears nothing; its kept reading is at most ten
  seconds old, its block named.
- **Faults are refusals.** A reading that cannot be taken or kept because of the cache itself (a
  `Cachex.get` or `fetch` that answers `{:error, _}`, the cache stopped, say) is
  `{:error, :chain_unavailable}`, as a chain that cannot be read. A mark or bump that fails logs one
  warning ("autolaunch earn landed step not counted") and still broadcasts, so pages read again.
  No rescue anywhere.
- **The panel's own checks.** A `step_sent` for a transaction the panel already follows starts no
  second check (the shared code would start one, and LiveView keeps both running), and Check
  again reads only a step the page stopped reading, as its button is shown for. Both are guarded
  in `EarnComponent`; `OnchainSteps` and regent_chain are unchanged.
- **"Read at block …" stays truthful.** Every reading carries its block's number, hash and time,
  and every surface shows or returns that block, so a kept reading never passes for a newer one.
- **Live every time.** A wallet's position, a quote and a step's build read the chain at the
  latest block on every ask; only the market's terms are shared.

## 3. The steps (`Autolaunch.Earn.Steps`)

Built on the server for a signer the caller has proved is one of the acting account's own wallets
(`Autolaunch.CoveredCalls.Signer`), each with the site's Builder Code at the end of its calldata
(`RegentChain.Review.step/3`):

| Kind | Steps | Notes |
| --- | --- | --- |
| Deposit | `usdc_approval`: USDC `approve(pool, amount)`; then `supply`: `supply(USDC, amount, signer, 0)` | The approval is exact and always its own step. `approved` says whether the chain already holds it; it is shown done and stays pressable. |
| Withdraw an amount | `withdraw`: `withdraw(USDC, amount, signer)` | Exactly that amount, even when it equals the balance. |
| Withdraw everything | `withdraw`: `withdraw(USDC, 2^256 − 1, signer)` | The whole balance as it stands when the step lands, interest to that moment included. |

An amount is a whole number of USDC's smallest units, 1 to 9,007,199,254,740,991, the largest
whole number a JSON reader holds exactly. The operations (`Product`'s `@amount`), the tools'
schemas (`priv/earn_tools.json`) and the page's field (`Amount`) take the same bound. Zero, a
fraction, text, or `everything` on a deposit (or with an amount) is an input refusal, never a
blocked step.

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
| 3 | What the market can take or give now | `over_supply_cap` (amount > capacity, or full) | `not_available_now` (amount, or the whole balance, > USDC available) | More than the market takes right now / Not that much is available to withdraw right now |

Agents get the same codes with a sentence each (`Autolaunch.Earn.Answer`).

## 5. Surfaces

- **`/earn`** (`AutolaunchWeb.EarnLive`, `AutolaunchWeb.EarnComponent`): the market's Rate,
  Supplied, Available and Capacity with the block read at, Refresh, the Deposit and Withdraw tabs
  (`?tab=withdraw`), the wallet panel (Balance, Wallet, Amount with Max, the button, and the
  review over the panel), and Risks. Off, the address is the site's 404 and its stylesheet is not
  served.
- **Figures.** Supplied, Available, Capacity, Balance and Wallet are shortened by
  `RegentFormat.token_amount/2`, which cuts (two decimals from 1 up, three significant digits
  below 1) and never rounds up, so no figure shows more than is there. The review's Amount and the
  note of what moved give the exact amount, every digit (`Amount.text/2`, "100.123456 USDC").
- **`/portfolio`, Earn** (`AutolaunchWeb.EarnPortfolioComponent`): signed in, each product's
  balance read now with the block, and Withdraw (a balance) or Deposit (none).
- **Rail and home.** An Earn row in the rail after Stocks, and a fourth home card ("rise"
  picture) while Earn is on.
- **Agents.** Four operations in `Autolaunch.Earn.Product`, each answer carrying its block (the
  products from the shared reading, section 2.1):
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
the page coming back into view, a wallet change, or any agent call; the terms within the shared
reading's ten seconds. Tests:
`test/autolaunch/earn/states_test.exs` (the order, the table), `steps_test.exs` (a market that is
not open blocks what it does not take), `earn_live_test.exs` (a frozen market disables Deposit
and lets a withdrawal out).

### 6.2 Deposit capacity — `States.capacity/1`

With `scaled` = `scaledTotalSupply + accruedToTreasury`, `C` = cap × 10^decimals, `I` the income
index and `R` = 10^27: `most = ⌊((C + 1)·R − 1) / I⌋`, the largest scaled total whose balance,
rounded down, is within the cap; `left = ⌊((most − scaled + 1)·I − 1) / R⌋`, the largest deposit
whose scaled amount, rounded down, still fits (section 2).

| State | Derived from | Moves to | Allows |
| --- | --- | --- | --- |
| `:uncapped` | cap 0 | a capacity or full when governance sets a cap | any deposit the market and wallet allow |
| `{:left, left}` | `left` > 0 | full as deposits and interest fill it; more as withdrawals free it or the cap rises | a deposit up to `left` |
| `:full` | `most` < `scaled`, or `left` = 0 | a capacity when withdrawals free it or the cap rises | no deposit (`over_supply_cap`); withdrawals unaffected |

Page: Capacity, "No cap", the amount left, or "Full". Agents: `capacity` null, units or 0, and
`supply_cap` null or whole tokens. Tests: `states_test.exs` (each boundary to the unit at an index
of 1, the pool's rounding at 1.5, and a property against the pool's own check at any index),
`steps_test.exs` (the treasury's share and the index counted), `earn_live_test.exs` (a market at
its cap reads full; one without a cap says so); the fork proof checks it against the pool.

### 6.3 Withdraw availability — `States.availability/2`

| State | Derived from | Moves to | Allows |
| --- | --- | --- | --- |
| `:available` | amount ≤ the pool's virtual balance | short when borrowing takes it | the withdrawal |
| `{:short, available_now}` | amount > the pool's virtual balance | available as borrowers repay or lenders deposit | nothing for that amount (`not_available_now`) |

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
| `{:valid, units}` | digits with at most one dot, above zero, within 9,007,199,254,740,991 | another state on a keystroke; empty after the tab changes, the wallet changes or the step is done | a quote and, on a press, a review |

Max writes the figure with `Amount.text/2`, which `entry/2` reads back exactly (property tests).
Spacing at the edges, a non-breaking space or a new line included, is dropped; inside the figure
it is not an amount, and neither are digits from other scripts or an exponent ("1e3"). More digits
than the bound has is `:too_large` before anything is read as a number, so a very long string
costs nothing. The field takes at most 32 characters and sends its amount 300 ms after the last
key (`phx-debounce`).
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
| 3. `market_capacity/2` | capacity uncapped or amount ≤ left, else `over_supply_cap` | `availability(amount or balance, available)`, else `not_available_now` |
| Result | `:ok` or `{:blocked, reason}` | `:ok` or `{:blocked, reason}` |

The page disables the button with the reason beside it and reads the preview again, at the latest
block, on each settled change of amount, a wallet change, the page coming back into view, after
each press, and each time the page reads the terms (Refresh, or a step landed on this page or
another), so the button comes back once the chain allows the step. A new preview stops the one
still being read (`cancel_async`) and drops the one before, so while the chain is read again the
button is enabled: it is never held by a reason from an earlier reading, and never disabled
because a preview is under way. The preview is read only when the amount (its tab included), the
wallet that may act, the page's `reads` or the panel's `held_reads` changed (`quoted_for`), so the
page drawing the panel again with nothing new reads nothing. This matches covered calls (section
9.5). Tests: `states_test.exs` (both orders, every reason), `steps_test.exs`,
`earn_live_test.exs` (a deposit past the wallet's USDC is disabled with its reason and comes back
once the chain allows it; a paused or closed market disables both steps with the reason, and
Refresh brings the button back once it opens; a new reading drops the reason that held the button
until the chain answers again; the page drawn again with nothing new for the panel reads nothing
again).

### 6.9 Terms read — `EarnLive`, one `AsyncResult` per product

| State | Derived from | Moves to | Shows |
| --- | --- | --- | --- |
| loading | the page opening, Refresh, or the first report of a transaction that landed a step, from any page on any machine (`{:earn_changed, id, hash}`, counted here first by `SharedTerms.heard/2`) | loaded or failed | a waiting block; no figures, no status |
| loaded | `read_earn_terms` answered | loading on Refresh or a landed step | status, Rate, Supplied, Available, Capacity, "Read at block N" |
| failed | the read refused or crashed | loading on Refresh | "The market couldn't be read just now." and no figures |

The panel is there from the first render in every state: its decimals are the catalog's, so it
waits on no reading. Refresh while a product is loading starts nothing for it; a landed step stops
the reading under way and starts a new one. Each reading bumps the page's `reads` count, which the
panel takes to read its wallet and preview again. Between a confirmed step and the fresh read the
terms show nothing: each read starts from loading, so on a page open when the step lands, on any
machine, a figure from before it never passes for a current one. A page opened just after on a
machine that had none open may show a reading up to ten seconds old, its block named (section
2.1). The panel's own wallet figures are a separate machine (section 7.1). Tests:
`earn_live_test.exs` (no figures before the read, the figures and block, a failed read with the
panel still there and Refresh, the panel working signed in while the market can't be read,
Refresh pressed during a reading starts no second one, a confirmed step reads the market again on
every open page, a step heard of from another machine is counted here before the page reads),
`shared_terms_test.exs` (one reading for readers at the same moment; kept; left behind by a
landed step; a transaction reported again, or forty times at once, moves readers on and tells the
pages once; a machine that hears of a step counts it once before its pages read; a cache that
can't be used refuses the reading and a landed step is logged and still told; never kept when it
fails).

### 6.10 Review lifecycle — shared `AutolaunchWeb.OnchainSteps`, as covered calls

Earn uses the same server half (`OnchainSteps`, `RegentChain.Presses`) and browser half
(`assets/js/hooks/onchain_steps.ts`) as covered calls, with the same `steps/1`, `next_step/1`,
`confirmed/2` and `step_reverted/2` shape as `CoveredCallComponent`. Nothing is forked.

| State | Derived from | Moves to | Allows |
| --- | --- | --- | --- |
| none | `review: nil` | open when a press finds the step not blocked | the panel's button |
| open | `put_review/2` with a review built at the latest block for the active signer; each opening has its own id | in wallet on a press; none on Close, a tab change or another signer | each step's button, one at a time; the approval stays pressable |
| in wallet | the browser only: the pressed button is marked until the wallet answers | sent, or failed with nothing sent | further presses: every press reaches the wallet |
| sent / stalled | the newest press's outcome `:pending` (stalled after a long wait) | confirmed or reverted, read every two seconds | the next step's button at once; the same transaction reported again starts no second check, and Check again reads only a stalled step |
| confirmed | outcome `:confirmed` | the review closes once every step landed once | re-reads the market and the wallet; the last step shows what moved and clears the amount |
| failed, nothing sent | `step_failed` (declined, the network switch declined or failed, no wallet open, no fees, …) | open | a note beside the button; the same step is pressable again |
| failed, reverted | outcome `:reverted` | open with a review built again from the chain now, or none with the reason the chain now gives | "The step did not go through and nothing moved." |
| other | a transaction that is not the step this page prepared | as for a fresh press | the button shows again |

The cases the brief names:

- **The chain changes mid-review.** A review is fixed once built and is not rebuilt on a timer
  (covered calls does not use `refresh_later/1`; neither does Earn). A press still sends what is
  on the page. If it then reverts, `rebuild_reverted/4` builds the review again from the chain as
  it is now, once nothing else from that review is on its way, and the next press sends what the
  chain accepts now, or the panel says why nothing can be done. Outside the review, the button's
  quote is read again on focus, on a wallet change, after each press and on each reading of the
  terms.
- **The wallet's account or network changes.** A new active wallet re-syncs the panel; a review
  built for another signer closes, since its steps were built for that wallet only, and the amount
  and Max are cleared. The first wallet the panel hears of keeps what was typed. The network is
  known only at a press: the browser asks Privy's own switch to move the wallet to Base, which
  adds the network first in a wallet app that lacks it, on every press, and once the switch
  resolves the press sends. A declined or failed switch sends nothing, its note asks the person
  to switch to Base, and the next press asks again. The press goes to the account the wallet has
  active, which is not checked against the review's signer (founder's ruling, 17 Nov 2026): the
  deposit still credits, and the withdrawal still pays, the wallet the review was built for
  (`operations/FEATURES.md`, Wallet actions).
- **A reload with a transaction pending.** Nothing is kept beyond the page, as on covered calls;
  there is no adoption of a pending transaction across a reload. The reloaded page reads the
  market and the wallet at the latest block, so the figures show the result once the transaction
  lands; an approval that landed shows as done in the next review.
- **A double press.** Each press reaches the wallet, including while the first is pending. The
  step shows its newest press; a step any press of which landed stays done. Two supplies that both
  land deposit twice, an accepted outcome under rule 11.

Tests: `earn_live_test.exs` (opens with the exact steps and closes on request; a confirmed step
re-reads and the last closes the review with what moved; a step that does not go through is
reviewed again, then closes with the reason; a review closes on another wallet or another tab;
a change with no amount or a check of a hash that is not text leaves the panel as it is; a step
reported again, or checked again while it is still being read, starts no second check); the
shared `test/autolaunch_web/onchain_steps_rebuild_test.exs` and covered calls' journeys.

### 6.11 Wallet — `OnchainSteps.signer/2` and `mismatch_note/2`; the network at the press

| State | Derived from | Moves to | Allows |
| --- | --- | --- | --- |
| signed out | the session has no account (`linked: nil`) | signed in | terms and risks; the panel offers Sign in |
| signed in, no wallet open | Privy reports no active wallet | on Base when one opens | figures for the account's own wallet; a press says to open one and opens nothing |
| on Base, may act | Privy's active wallet is one the account links | another of the account's wallets, an unlinked one, or none | quotes, reviews and presses for that wallet |
| account changed | the active wallet becomes another linked wallet | as on Base, for the new wallet | the open review closes; the amount and Max are cleared; figures and quote follow the new wallet |
| a wallet the account does not link | the active wallet is not linked | as above | a note naming both; nothing may act; figures stay on the account's own wallet |
| wallets unread | the connection dropped while reading the account | read again on the next update | nothing may act; a press says to try again |
| on another network | known only at a press (`send_step.ts`) | Base once the wallet switches | Privy's switch asks the wallet on every press, and the press sends once it resolves; declined (`switch_declined`) or failed (`network_mismatch`), nothing is sent and the note asks for the switch |

The network is not a server state on purpose: knowing it before a press would mean gating a button
by page state. Tests: `earn_live_test.exs` (no wallet open; a review closes when the wallet that
may act changes; another wallet starts from an empty amount with Max off), the shared hook's
journeys.

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

| Call | Reads | Answers | Refusals |
| --- | --- | --- | --- |
| `earn_products` | the market, from the shared reading (section 2.1) | each product's terms, risks and block | the chain's |
| `earn_quote` | the market and the signer's wallet, at the latest block | amount, `everything`, `approved`, `blocked`, the wallet's figures, block; no calls | `unknown_product`, `invalid_amount`, `invalid_request`, `wrong_signer`, `wallet_required`, `agent_not_paired`, and the chain's |
| `prepare_earn` | the same | the quote plus the steps, even when blocked | the quote's, and `prelaunch_read_only` before opening |
| `earn_positions` | each product for the signed-in wallet, at the latest block | position, balance, USDC, allowance, block | `agent_not_paired`, and the chain's |

The chain's refusals, each a 503 with its own code: `earn_unavailable` ("Earn is not available
right now."), and `chain_unavailable`, `invalid_chain_response`, `invalid_block_header` or
`wrong_chain` ("Earn could not be read from the chain just now."). The page says each in its own
words. The server keeps nothing per caller between calls: no session, no reservation, no pending
step; only the market reading every caller shares for up to ten seconds. An agent
reads products, quotes, prepares, has its person's wallet send each step in turn, and reads
positions to see the result. A step built at block N may be stale when sent; the agent prepares
again. Every surface (HTTP routes, browser tools, hosted MCP tools) runs the same operation, so
answers and refusals match word for word. Tests: `earn_routes_test.exs`, `earn_mcp_test.exs`.

## 7. Implicit machines found

1. **The panel's wallet figures** (`held`, keyed by `{wallet, held_reads, reads}`): nothing,
   reading, read. Read again for each new wallet shown, each ask of the panel's own (focus, wallet
   change, after a press) and each reading of the terms (`reads`: Refresh, a landed step); a new
   ask cancels the read still running; a failed read shows "—". Unlike the terms, the same
   wallet's earlier figures stay on screen until the fresh read lands, including right after a
   confirmed step; another wallet's are never shown. Nothing is built from them: every review is
   prepared fresh.
2. **Quote freshness** (`quote`, `quoted_for`, `current/1`): a preview is read for one key, the
   amount as it stands (its tab included), the wallet that may act and the page's and panel's
   reading counts, and only when that key changed; an answer for an earlier key is dropped. A new
   preview cancels the one still being read and drops the one before, so until the fresh one
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
8. **The terms' Refresh** (`EarnLive`): a product whose reading is under way is not read again
   by Refresh; a landed step replaces the reading under way.
9. **The shared reading** (`SharedTerms`): none, being taken (later asks wait for it), kept for
   ten seconds, or left behind by a landed step. Each landed transaction is unmarked, then marked
   on a machine for an hour, the first report or hearing of it moving that machine's readers on.

None of these gates a wallet button.

`Earn.reason/1` and the page's `refusal_words/1` name every refusal they can meet, with no
catch-all: an error that is not an Earn refusal or an input error raises. Every refusal the
operations can give has an entry in `EarnAnswer`'s table, the deployment's included
(`earn_unavailable`).

What reaches `Earn.reason/1`, from the page's terms, the panel's preview and review, the inner
calls of the agent answers and the HTTP routes:

- Reachable: `Ash.Error.Unknown` holding one `Earn.Refused` (every operation names its refusal as
  an atom), and `Ash.Error.Invalid` (HTTP input outside an argument's constraints).
- Not reachable, left to raise: `Ash.Error.Forbidden` from `Earn.Checks.Offered` (the routes are
  not there while Earn is off, `admit_earn/2`), from the connected-app rule (only the hosted MCP
  server calls as a connected app, and it words its own errors), from `LaunchesOpen` (the steps
  route is refused before the router in prelaunch read-only mode, `AutolaunchWeb.Prelaunch`; both
  switches are set when the site starts) and from `actor_present` (the page's panel always calls
  as a person, the private routes always as an agent); `Ash.Error.Unknown` holding anything but a
  refusal (Ash raises again what an action raises, and no operation answers anything but an atom).

What reaches the panel's `refusal_words/1`: `wrong_signer` (the account's wallets changed),
`authentication_required`, `earn_unavailable`, `chain_unavailable` (also a preview that crashed),
`invalid_chain_response` (also decimals other than the catalog's), `invalid_block_header` and
`wrong_chain`, each with its words. Not reachable: `invalid_request` (its arguments are always
within their constraints), `unknown_product` (always the catalog's id), `invalid_amount` (built
from an amount that reads above zero, or everything on a withdrawal) and `wallet_required` (the
signer is always one of the account's wallets, a whole address).

Catch-all clauses kept, none of them a state derivation: `step_state/1`'s
`:other`, `Steps.asked/2` and `Catalog.product/1` (input that is not an amount or a product), and
Max with no figures read.

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
   Settled on 15 November 2026: keep as built.
2. **A reload with a pending transaction.** The brief names "adopt". The shared code keeps nothing
   beyond the page, and `OnchainSteps.adopt/1` reads the account's wallets; it does not take over a
   transaction. Earn follows covered calls: the reloaded page reads the chain.
3. **Prelaunch.** Swap and stake panels close during prelaunch; covered calls' panel stays usable
   on the page while its agent steps route waits. Earn follows covered calls.
4. **Refresh while a reading is under way.** Covered calls' Refresh starts a reading on every
   press. Earn's starts nothing for a product still being read, as its review asked.
5. **How a blocked button comes back.** Covered calls' panel previews again whenever the page
   renders it with new assigns: a new Book reading after Refresh, a landed press (the component
   drops its Book reading and the page broadcasts on `"covered_calls:" <> symbol`, so every open
   page reads again), its due timer and a tab change; and on the browser hook's `refresh_funds`
   (focus, a wallet change, after a press) and on typing. Earn matches it: Refresh and every
   reading of the terms (a landed step broadcasts on `"earn:" <> id`) pass the panel a new `reads`
   count, which reads its wallet and preview again; `refresh_funds` and typing do too. Earn has no
   due timer, as a market has no deadline.
6. **Odd events.** Covered calls' panel takes a `change` with any params (`Map.take(params,
   ["amount"])`), and Earn's does the same. Covered calls' `check_again` matches only a text
   hash, so a non-text one crashes its panel; Earn's acts only on a text hash naming a step it
   stopped reading, and leaves the panel as it is otherwise. Covered calls' is left as it is
   (outside this work).
7. **The tools' bounds at build time.** Comparing each hosted tool's `minimum` and `maximum` with
   its browser tool's (`AutolaunchWeb.Capabilities`) is a one-line change, but it fails the build
   for covered calls' quote and prepare tools: their hosted inputs take up to 2^128 − 1 and
   2^64 − 1 where their browser schemas say 9,007,199,254,740,991. The comparison is left as it
   was; Earn's tools agree on 9,007,199,254,740,991 on every surface.
8. **A transaction reported again.** Covered calls' panel passes every `step_sent` and
   `check_again` to the shared code, so the same transaction reported again starts another check
   beside the one running, and once it reads as landed, its `confirmed` drops the Book reading and
   broadcasts on `"covered_calls:" <> symbol` again, so every open page reads the chain again.
   Earn counts each transaction once (section 2.1) and starts no second check. Covered calls' is
   left as it is (outside this work).
9. **Decimals.** Covered calls' panel takes its token unit from configuration and is mounted
   without waiting for a reading; Earn now does the same with the catalog's decimals, checked
   against the market's own on every reading.

## 10. Tests and evidence

- `test/autolaunch/earn/`: `states_test.exs` (11, one property), `reads_test.exs` (8, two
  properties), `steps_test.exs` (14), `shared_terms_test.exs` (7).
- `test/autolaunch_web/`: `controllers/earn_routes_test.exs` (7), `controllers/earn_off_test.exs`
  (3), `earn_mcp_test.exs` (6), `live/earn_live_test.exs` (27). Each is in `test/manifest.json`.
- The chain double is `test/support/earn_chain.ex`.
- Fork proof, 15 November 2026, on anvil forking Base at block 58065118 with anvil's first test
  account: the pool at revision 12; Available read as the pool's virtual balance,
  16616952128271, below the 16621868424364 USDC the aToken holds; a 250 USDC deposit prepared as
  approval then supply, both sent and landed with the Builder Code; aUSDC 249999999 after;
  250990674 thirty fork-days later; a 1000 USDC withdrawal blocked `over_balance`; withdraw
  everything landed, leaving 10000990675 USDC and 0 aUSDC; and withdraw everything again blocked
  `over_balance`.
- Supply-cap proof on the same fork: the market's cap set to 188,134,814 USDC and the reserve
  brought up to date at block 58065127; Earn read a capacity of 87103662 units there, and the
  pool itself, asked at that block (whose calls run at the block's own time), took a supply of
  87103662 and refused 87103663 with `SupplyCapExceeded`.
- Screenshots in `/tmp/al-earn-shots/` (desktop and phone): the terms with Capacity and the
  rate's words, the review and the note of what moved with the exact amount (100.123456 USDC),
  and the blocked button on the phone with its reason directly under it.

## 11. Open items

- Covered calls' `check_again` crash on a non-text hash, its tools' bounds and its handling of a
  transaction reported again (sections 9.6, 9.7 and 9.8) are outside Earn and left as they are.
- A headless browser walk of `/earn` against a fork (FEATURES marks it a gap; proved by hand).
- regents CLI commands, when the switch goes on.
