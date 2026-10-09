# Autolaunch

Autolaunch runs public auctions for new tokens. It then pays the people who stake those tokens a
share of every trade.

Anyone can launch a token with the fixed v2 terms. Anyone can bid. At each
moment the auction has one clearing price, and every bid still buying pays it. If the auction
raises its minimum, the token graduates: it starts trading in a Uniswap pool whose liquidity is
locked forever. If it falls short, every bidder takes their full bid back. After graduation,
trading fees on the token flow to the people who stake it.

[Website](https://autolaunch.sh) · [How the contracts work](contracts/README.md) · [Command-line tool](cli/README.md) · [API and agent tools](platform/docs/public-webmcp.md)

## Two kinds of launch

**Revstake** tokens are for agents and projects that earn money. The launcher raises REGENT for
their project. Stakers share the token's trading fees and any payments the project routes to them.
Revstake launches run on Base.

**Memestake** tokens are memecoins paired with a tokenised stock, such as Tesla or Apple. Bids are
paid in that stock. Nobody keeps what the auction raises: every unit goes into the token's locked
trading pool, apart from a rounding remainder routed to the protocol fee lane. The creator receives
0.5% of the token supply over 30 days and 0.3% of the stock side of trades. There is no team treasury. Memestake
launches run on Base and on Robinhood Chain.

| | Revstake | Memestake |
| --- | --- | --- |
| Where | Base | Base and Robinhood Chain |
| You bid with | REGENT | a tokenised stock. You can also pay in dollars (USDC on Base, USDG on Robinhood Chain), converted into the stock in the same transaction |
| Total supply | 100 billion | 1 billion |
| Sold in the auction | 20% | 49.75% |
| Reserved for the trading pool | Up to 10% | 49.75% |
| Everything else | 70%, plus unpaired reserve and rounding leftovers, vests to the treasury over 365 days from graduation | 0.5% vests to the creator over 30 days from graduation; remaining rounding leftovers are retired |
| Where the raise goes | Up to half funds the locked pool; at least half goes to the treasury | All funds the locked pool, apart from rounding dust credited to the protocol fee lane |
| Bidding opens | about 10 minutes after launch | about 10 minutes after launch |
| Bidding lasts | about 48 hours | about 24 hours |

Launching is free apart from the network fee.

These are the terms for new v2 launches. The four existing v1 Memestake auctions
(AGI, JollyB, BITE and RDOG) keep their 80% auction / 20% reserve allocation, no creator
allocation, and two 1% hook fees. New v1 launches are paused; existing withdrawals,
claims, trading and staking remain supported.

## How an auction works

Autolaunch uses Uniswap's continuous clearing auction. It sells the tokens a little at a time over
the whole auction, not all at once at the end.

1. **You place a bid.** You choose how much to spend and the highest price you will pay per
   token.
2. **One price for everyone.** At any moment the auction has a single clearing price, set by the
   bids competing for the tokens released so far. Bids priced above it buy at the clearing price,
   not at their own limit, so at that moment nobody pays more than anyone else. Your average
   price depends on when your bid was buying.
3. **If the price passes your limit,** your bid stops buying. You keep the tokens it already bought
   and take back the rest of your money.
4. **The minimum.** Every v2 auction uses the lowest floor the auction permits. Its minimum
   is the whole sale allocation at that floor, rounded up; the launcher chooses neither.
   The auction page shows how close it is, and the auction list shows a green check once an auction
   has reached its minimum.
5. **When bidding ends,** there are two outcomes:
   - **Graduated.** The minimum was reached and the sale allocation sold, apart from rounding.
     Bidders claim their tokens, and the token starts
     trading at the auction's final price in a Uniswap v4 pool.
   - **Failed.** The minimum was not reached. Every bidder takes back their full bid, and every
     token is retired to the dead address, including the creator allocation. Retirement does not
     reduce the token's reported total supply.

Refunds are paid by the Uniswap auction contract itself. Nothing in Autolaunch can hold them back.

## Where the fees go

Trades in a v2 token's official pool pay hook fees on top of the pool's **0.30% LP fee**:

| Launch | Hook fee | Destinations |
| --- | --- | --- |
| Revstake on Base | 3% | 2% enters the launch's revenue splitter; 1% goes directly to REGENT staking when collected in REGENT, or to the Regent Safe when collected in the launch token |
| Memestake on Base | 4.3% of the gross stock side | 3% enters the launch's staking splitter; 1% converts to USDC for REGENT staking; 0.3% pays the creator in stock |
| Memestake on Robinhood Chain | 4.3% of the gross stock side | 3% enters the launch's staking splitter; 1% converts to USDG held in the protocol inbox; 0.3% pays the creator in stock |

The Robinhood-to-Base bridge is not built; protocol USDG stays in the inbox until a
bridge adapter is configured. Memestake fees wait in the hook until settlement;
anyone can settle creator and token-staker fees, while protocol conversion requires
the authorized executor. Revstake hook fees are routed during the swap.

Each v2 hook rounds its total fee once, then assigns the rounding remainder to the
launch's splitter share after calculating the other lanes.

The pool's liquidity is locked in a contract that can only collect trading fees. Anyone can press
"collect", and the fees always go into the token's staking pot.

Both pool types open at the auction's final clearing price. Revstake locks one
full-range position. Memestake locks a full-range position funded by the stock
raise and the tokens it pairs, plus a token-only position above the opening token
price when reserve remains. Those tokens become available as the price rises.

Revstake projects can also send customer payments to the pot. Each Revstake token comes with its
own payment address, and money sent there is shared out the same way.

## How staking works

Stake a token on its page to earn a share of everything that reaches its staking pot: trading fees,
locked liquidity fees and, for Revstake tokens, payments. Earnings arrive in the currencies that
came in: the token itself, the stock or REGENT it trades against, and dollars.

- **Regent keeps 2%** of everything that arrives. On Base, dollars from that 2% go to people who
  stake REGENT.
- **Memestake:** stakers share the other 98% in proportion to their stake. If nobody is staked, it
  goes to Regent instead.
- **Revstake:** stakers earn according to how much of the *whole supply* they stake. For example,
  if you stake 1% of all tokens, you earn 1% of the 98%, however many other people are staking. The
  part not earned by stakers goes to the project's treasury.

You can claim earnings or unstake at any time after the block in which you last staked. On
Robinhood Chain that means waiting for a later block; its nominal block time is 0.1 seconds.

## Is it safe?

Autolaunch's contracts are built so that the promises above do not depend on trusting anyone.

**What nobody can do, including Regent:**

- withdraw a token's locked liquidity. The contract that holds it can only collect trading fees and
  pay them into the token's staking pot;
- create more of a token, tax its transfers, block a holder, or change the token after launch;
- change a live auction's terms, or stop a refund;
- change the fee rates, or take stakers' tokens or earnings;
- upgrade the contracts. They cannot be changed once deployed.

**What Regent can do:**

- pause or reopen *new* launches. A pause never touches auctions already running, refunds,
  claims, trading, staking or payments;
- for Memestake, choose which stocks new launches can use. Removing a stock stops only new
  launches with it;
- for Memestake, choose who converts Regent's 1% share of the fees into dollars. The contracts do
  not check the conversion price: whoever converts sets the least they will accept, and the website
  offers 95% of the stock's Chainlink price as that minimum.

**The website never holds your funds.** Bids, stakes and earnings sit in public contracts, and
every bid, trade, stake and claim is a transaction you approve in your own wallet.

**Risks you should know about:**

- New tokens are speculative. A token's price can fall to nothing. Only bid what you can afford to
  lose.
- Revstake treasuries receive 70% of the supply plus leftover tokens over 365 days, and at least
  half the raise at graduation. What they do with it is up to them.
- Memestake bids and earnings are in tokenised stocks. Their value moves with the stock market, and
  each stock token follows its issuer's rules.
- Staking earnings depend on trading and payments. They are not guaranteed.
- The contracts are new. No outside firm has audited them. They were reviewed by AI (GPT 6 Astra)
  using Trail of Bits' and Crytic's public security tools, and tested against the real Base
  contracts they rely on. Their source code is public, and the deployed Revstake contracts are
  verified on Basescan.

## Status (9 October 2026)

| | |
| --- | --- |
| Revstake on Base | V2 deployed and open for new launches ([deployment records](contracts/revstake-v2/deployments/base-mainnet/README.md)) |
| Memestake on Base | V2 deployed and open, with ten admitted stocks ([deployment records](contracts/stocks-v2/deployments/base-mainnet/README.md)) |
| Memestake on Robinhood Chain | V2 deployed and open, with 25 admitted stocks ([deployment records](contracts/robinhood-v2/deployments/robinhood-mainnet/README.md)) |
| autolaunch.sh | Live. Launching, bidding and trading opened on 24 September 2026, 15:00 UTC. What changed in each release is in [CHANGELOG.md](CHANGELOG.md) |
| Command-line tool | Read-only: lists auctions and tokens and gives bid quotes. It cannot sign or send anything. Not yet published to npm |

## More

- [How the contracts work](contracts/README.md): each contract, what it controls, and who can
  change what.
- [Command-line tool](cli/README.md) and [API and agent tools](platform/docs/public-webmcp.md):
  public auction and token data for scripts and AI agents.
- Developers: [website](platform/README.md) and [contracts](contracts/README.md)
  setup.

Autolaunch is part of the Regent family, with [Regents](https://regents.sh),
[Patchbay](https://patchbay.help) and [Techtree](https://techtree.sh). An account or payment on one
product grants nothing on another.

## License

MIT. See [LICENSE](LICENSE). Libraries under `contracts/v1/lib/` and `contracts/stocks/lib/` keep
their own licenses.
