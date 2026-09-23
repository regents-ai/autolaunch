# How the Autolaunch contracts work

This page explains what each Autolaunch contract does, where your money sits at each step, and who
can change what. For the product itself, start with the [main README](../README.md).

## What is deployed

| Launch type | Chain | Status | Details |
| --- | --- | --- | --- |
| Revstake | Base | Deployed on 22 September 2026 and verified on Basescan. Launches are not open yet | [addresses and transactions](v1/deployments/base-mainnet/README.md) |
| Memestake | Base | Deployed on 23 September 2026. Launches are not open yet, and no stock has been added yet | [addresses and transactions](stocks/deployments/base-mainnet/README.md), [contract notes](stocks/README.md) |
| Memestake | Robinhood Chain | Not deployed yet | [contract notes](robinhood/README.md) |

Every contract here is fixed once deployed. None can be upgraded, and none has an owner who can
change a launch after it starts.

## The life of a launch

### 1. Launch

The launcher sends one transaction to the **launchpad**. It asks for a name, symbol, description,
website, image and the minimum raise. A Revstake launch also asks for a treasury address. Launching
costs nothing but gas. The launchpad then:

- creates the token with its whole supply at once. The token has no owner, cannot mint more, and
  has no transfer tax or blocklist;
- creates a Uniswap continuous clearing auction for the auction share of the supply. Bidding opens
  about ten minutes later, on a fixed schedule the launcher cannot change;
- holds the rest of the supply until the auction ends.

### 2. Bidding

Bids go straight into the **Uniswap auction contract**, which Uniswap wrote and which Autolaunch
uses unchanged. Your bid, and anything it has not spent, stays there until you take it back or claim
your tokens.

On Memestake you can pay in dollars. A **bid helper** turns your USDC (Base) or USDG (Robinhood
Chain) into the stock and places the bid in the same transaction. Nothing is left in the helper
afterwards.

### 3. The auction ends

Once bidding closes, anyone can press **finish** (the `migrate` call). The result depends on
whether the minimum was reached.

**Minimum reached (graduated):**

- A Uniswap v4 pool opens at the auction's final price.
- The pool's starting liquidity goes to the **liquidity locker**. The locker can do exactly one
  thing: collect the trading fees on that liquidity and pay them into the token's staking contract.
  It cannot withdraw, move or sell the liquidity, and nobody controls it.
- The token's **staking contract** is created.
- Revstake only: the part of the raise not needed for the pool goes to the launcher's treasury. The
  remaining 85% of supply, plus any unsold tokens, starts vesting to that treasury over 365 days in
  the **vesting contract**. A **payment address** is created so the project can send revenue to
  stakers.
- Memestake only: the whole raise goes into the locked pool, split across two positions. Unsold
  tokens go to a burn address. There is no treasury and no vesting.

**Minimum not reached (failed):**

- Every token, including the held-back supply, goes to a burn address.
- No pool, staking contract or vesting is created.
- Every bidder takes back their full bid from the Uniswap auction contract. Nothing in Autolaunch
  sits in that path, so nothing can hold a refund back.

### 4. Trading

Every swap in the official pool pays the usual 0.30% pool fee plus two fees of 1%, both charged by
the **fee hook**:

| Launch type | Staker 1% | Regent 1% |
| --- | --- | --- |
| Revstake | paid straight into the token's staking contract | paid straight to the Regent Safe |
| Memestake on Base | collected in the stock; anyone can press "settle" to pay it into the staking contract | collected in the stock, converted to USDC and paid to REGENT stakers |
| Memestake on Robinhood Chain | same as Base | collected in the stock, converted to USDG and held for Regent |

The hook has no pause and no fee setting. Other people can add their own liquidity to the pool as
usual; only the locked position's fees go to stakers.

### 5. Staking

Each graduated token has its own staking contract. It accepts three currencies: the token itself,
the currency the token trades against (REGENT, or the stock), and dollars (USDC, or USDG on
Robinhood Chain). Every amount paid in is shared out the moment it is paid in:

- **2% to Regent.** On Base the dollar part goes to people who stake REGENT; on Robinhood Chain it
  is held for Regent. The token and stock parts go to the Regent Safe, or to the Robinhood Safe on
  Robinhood Chain.
- **Memestake: the other 98% to stakers**, in proportion to their stake. If nobody is staked, it
  goes to Regent instead.
- **Revstake: stakers get the share of the 98% that matches the share of the whole supply they
  stake.** The launcher's treasury gets the rest. So if 30% of all tokens are staked, stakers share
  30% of the 98%.

You can stake at any time. You can claim or unstake from the block after your latest stake. On
Robinhood Chain that is about twelve seconds. Your staked tokens are never counted as earnings and
cannot be paid to anyone else.

### Payments (Revstake)

Each Revstake token has a **payment address**. A project can send payments there, for example from
its customers, and they are shared out exactly as above. Anyone can also create an extra payment
address that pays a referrer up to 2.5% before the rest goes to the staking contract. Plain ETH sent
to these addresses is refused. Other tokens sent by mistake can only be forwarded to the treasury.

## Who can change what

The only admin is Regent's Safe wallet, and it controls only these things:

| What | Revstake | Memestake |
| --- | --- | --- |
| Pause or reopen new launches | yes | yes |
| Choose which stocks new launches can use | — | yes. Removing a stock never affects a launch that already uses it |
| Choose who converts Regent's 1% fee share into dollars | — | yes. The conversion must come within 5% of the stock's Chainlink price, and the price reading must be less than 7 days old |
| Move dollars collected for Regent from Robinhood Chain to Base | — | yes, for the Robinhood Safe |

A pause stops only new launches. Running auctions, refunds, claims, trading, staking, payments and
vesting carry on.

Nobody, including Regent, can:

- change a running auction, its minimum or its schedule;
- withdraw the locked liquidity;
- mint tokens, change a token, or block a holder;
- change any fee rate or where the fees go;
- take bids, refunds, staked tokens or earnings;
- upgrade or replace any of these contracts.

## Checking it yourself

- The Base Revstake contracts are verified on Basescan as exact matches of the source in
  [v1/src](v1/src). The addresses and the transactions that created them are in the
  [Base deployment record](v1/deployments/base-mainnet/README.md).
- The full rules for Revstake are in [v1/SPEC.md](v1/SPEC.md), and for Memestake in the
  [Base](stocks/README.md) and [Robinhood](robinhood/README.md) notes.
- Contracts are audited using the Trail of Bits and Crytic skills, using GPT 6 Astra. They were
  also tested against the real Uniswap, Permit2 and REGENT contracts on a copy of Base. The review
  notes are in [v1/docs/audit](v1/docs/audit/README.md).

## Contract names

For readers following along on Basescan:

| Plain name | Revstake (Base) | Memestake (Base) | Memestake (Robinhood Chain) |
| --- | --- | --- | --- |
| Launchpad | `RegentsAutolaunchFactoryV1` with `RegentLBPStrategy` | `StocksLaunchpadV1` | `RobinhoodStocksLaunchpadV1` |
| Token maker | `UERC20Factory` | `UERC20Factory` | `UERC20Factory` |
| Liquidity locker | `RevstakeLPLocker` | `MemestockLPLocker` | `MemestockLPLocker` |
| Fee hook | `RegentFeeHook` | `StocksFeeHookV1` | `RobinhoodFeeHookV1` |
| Staking contract | `SubjectSplitterV1` | `MemestockSplitterV1` | `RobinhoodMemestockSplitterV1` |
| Vesting contract | `ConditionalVestingEscrowV1` | — | — |
| Payment address | `PaymentReceiverV1` | — | — |
| Bid helper | — | `StockBidAdapterV1` | `RobinhoodStockBidAdapterV1` |
| Stock-to-dollar converter | — | `AerodromeStockRouteV1`, one per stock | `UniswapV3StockRouteV1`, one per stock |
| Regent's dollar collection | — | — | `RobinhoodProtocolRevenueInboxV1`, and `RobinhoodBaseRevenueReceiverV1` on Base |

[revenue-mesh/](revenue-mesh/README.md) holds early work on payment routes from other chains into a
Revstake payment address. None of it is deployed.

## Building and checking the contracts

Each folder is its own Foundry project and is checked from inside that folder:

| Folder | Check |
| --- | --- |
| [v1/](v1/README.md) | `cd v1 && bin/gate.sh`, after the one-time setup in its README |
| [stocks/](stocks/README.md) | `cd stocks && bin/gate.sh`, after `python3 bootstrap-deps.py <checkout>` has filled `lib/` |
| [robinhood/](robinhood/README.md) | `cd robinhood && bin/gate.sh`, with `../stocks/lib` in place |
| [revenue-mesh/](revenue-mesh/README.md) | `cd revenue-mesh && forge fmt --check && forge build && forge test -vvv` |

The website's copies of the contract interfaces live in [`platform/contracts/`](../platform/contracts/).
