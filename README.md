# Autolaunch

Autolaunch runs public auctions for new tokens. It then pays the people who stake those tokens a
share of every trade.

Anyone can launch a token and name the least the auction must raise. Anyone can bid. At each
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
trading pool. There is no creator allocation and no team treasury. Memestake
launches run on Base and on Robinhood Chain.

| | Revstake | Memestake |
| --- | --- | --- |
| Where | Base | Base and Robinhood Chain |
| You bid with | REGENT | a tokenised stock. You can also pay in dollars (USDC on Base, USDG on Robinhood Chain), converted into the stock in the same transaction |
| Total supply | 100 billion | 1 billion |
| Sold in the auction | 10% | 80% |
| Paired with the raise in the trading pool | 5% | 20% |
| Everything else | 85%, plus any unsold tokens, vests to the launcher's treasury over one year after graduation | none; unsold tokens are sent to a burn address |
| Where the raise goes | enough is paired with the token to open the pool; the rest goes to the launcher's treasury | all of it is locked in the trading pool |
| Bidding opens | about 10 minutes after launch | about 10 minutes after launch |
| Bidding lasts | about 48 hours | about 24 hours |

Launching is free apart from the network fee.

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
4. **The minimum.** Each auction must raise the amount its launcher set before it can graduate.
   The auction page shows how close it is, and the auction list shows a green check once an auction
   has reached its minimum.
5. **When bidding ends,** there are two outcomes:
   - **Graduated.** The minimum was reached. Bidders claim their tokens, and the token starts
     trading at the auction's final price in a Uniswap v4 pool.
   - **Failed.** The minimum was not reached. Every bidder takes back their full bid, and every
     token is sent to a burn address.

Refunds are paid by the Uniswap auction contract itself. Nothing in Autolaunch can hold them back.

## Where the fees go

Trades in a token's official pool pay two extra fees of 1% each, on top of the pool's usual 0.30%
trading fee:

- **1% goes to the token's staking pot.**
- **1% goes to Regent.** On Memestake pools it is converted to dollars first. On Base those dollars
  go to people who stake REGENT.

The pool's liquidity is locked in a contract that can only collect trading fees. Anyone can press
"collect", and the fees always go into the token's staking pot.

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
Robinhood Chain that means waiting about twelve seconds after staking.

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
- Revstake launchers receive 85% of the supply over a year, plus the part of the raise not needed
  for the pool. What they do with it is up to them.
- Memestake bids and earnings are in tokenised stocks. Their value moves with the stock market, and
  each stock token follows its issuer's rules.
- Staking earnings depend on trading and payments. They are not guaranteed.
- The contracts are new. No outside firm has audited them. They were reviewed by AI (GPT 6 Astra)
  using Trail of Bits' and Crytic's public security tools, and tested against the real Base
  contracts they rely on. Their source code is public, and the deployed Revstake contracts are
  verified on Basescan.

## Status (24 September 2026)

| | |
| --- | --- |
| Revstake on Base | Contracts deployed and verified on Basescan on 22 September 2026 ([addresses](contracts/v1/deployments/base-mainnet/README.md)). Launches opened on 24 September 2026, 15:00 UTC |
| Memestake on Base | Contracts deployed and verified on Basescan on 23 September 2026 ([addresses](contracts/README.md#base-8453-memestake)), with ten stocks added: AAPLc, AMZNc, GOOGLc, METAc, MSFTc, MSTRc, NVDAc, SNDKc, SPCXc and TSLAc. Launches opened on 24 September 2026, 15:00 UTC |
| Memestake on Robinhood Chain | Contracts deployed on 23–24 September 2026 ([addresses](contracts/robinhood/deployments/robinhood-mainnet/README.md)). Launches opened on 24 September 2026, 15:00 UTC |
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
