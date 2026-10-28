# Autolaunch Covered Calls

`CoveredCallsV1` sells fully collateralized, physically settled covered calls on one Base stock
token, paid in USDC. Product spec: [yield-borrow-spec.md](../../platform/docs/yield-borrow-spec.md).
Design and measurements: [covered-calls-design.md](../../platform/docs/covered-calls-design.md).

Status: **not deployed.** A deployment is a protected action and waits for Sean's go naming it.

## How it works

One contract instance per stock. It has no owner, admin, oracle, upgrade or pause.

| Call | Who | What it does |
| --- | --- | --- |
| `list(amount, strikePerToken, premiumPerToken, expiry)` | seller | Locks `amount` raw stock and lists it as calls. `expiry` must be a Friday at 21:00 UTC (`expiry % 1 weeks == WEEKLY_EXPIRY_OFFSET`). |
| `fill(listingId, amount)` | any buyer | Pays the premium for `amount` of the listing: 99% to the seller, 1% into live REGENT staking (`depositUSDC`, tag `autolaunch-covered-calls`). Closes at expiry. |
| `cancel(listingId)` | seller | Stops the unsold remainder selling; it becomes the seller's to `claim`. Moves no tokens. |
| `exercise(listingId, amount)` | holder | During `[expiry, expiry + 24h)`, pays the strike in USDC; the stock becomes the holder's to `claim`. Moves only USDC. |
| `claim(listingId)` | anyone owed stock | Sends all the stock the caller is owed. For the seller, once the window has closed, that includes every unit not exercised. |
| `collectStrike(listingId)` | seller | Sends the strike USDC paid so far. |
| `claimable(listingId, account)` | read | All the stock `account` may claim now, including the seller's after-window return before it is booked. |

- Stock amounts are raw B20 units, so a split or a dividend (a multiplier change) never changes
  what a listing holds or owes. Dividends during the week stay with the tokens (Sean, 28 Oct 2026).
- Prices are USDC (6 decimals) per whole token (`10**decimals` raw units). Premium and strike round
  up, in the seller's favour; the 1% fee also rounds up, so splitting a fill never avoids it.
- Every expiry is a Friday at 21:00 UTC: the US close in winter and an hour after it in summer, so a
  series never expires while the market is open.
- `list` and `fill` refuse while the stock has a multiplier change scheduled before the listing's
  exercise window closes (`effectiveAt()` on the B20 token). If that read ever reverted, `list` and
  `fill` would stop while it did; everything else carries on.
- Each call moves at most one token, and every token leaves by its own party's pull, with no
  deadline. A pause or blocklist on one token or one account only delays that party's own pull of
  that token. The exercise window itself is a deadline: a holder who cannot pay USDC for all 24
  hours (a USDC pause, a Circle blacklist) cannot exercise.
- Every fill that carries a fee calls live REGENT staking; if staking refuses deposits, fills stop.
  Nothing else depends on it.

## Checks

```sh
bin/gate.sh
```

The offline gate: `forge fmt --check`, `forge build`, and the unit, recovery and invariant suites.
It builds against `../stocks-v2/lib` (forge-std and solady), filled by `stocks-v2/bootstrap-deps.py`.

The Base fork suite (`test/fork/`) runs the contract against the real AMZNc token, Base USDC and live
REGENT staking. Base stock tokens are B20 precompiles, so it needs Foundry 1.8.4 or later with the
Base network: start `anvil --network base --fork-url <Base RPC>`, then
`FOUNDRY_PROFILE=fork forge test --network base --fork-url http://127.0.0.1:<port>`. Foundry's local
B20 does not yet have the newer `effectiveAt()` read, so the fork suite stands in its live mainnet
value (0); everything else is the real token.
