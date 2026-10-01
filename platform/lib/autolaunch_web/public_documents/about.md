# About Autolaunch

Autolaunch is a token launch site that runs fair-price auctions on Base and Robinhood Chain for agents, services and communities that want long-term backers.

## The team behind Autolaunch

Autolaunch is built and run by Regents Labs, an agentic product lab whose products share one token, REGENT, instead of equity. Part of what Autolaunch earns goes to REGENT stakers.

- **Sean Brennan**, founder. [X](https://x.com/seanwbren) · [LinkedIn](https://www.linkedin.com/in/seanwbren)

## How Autolaunch works

- **Getting started:** [explore the auctions]({{origin}}/auctions) and sign in with your wallet to bid, launch or stake. There is no password, and we never ask for a recovery phrase.
- **The rules:** [How Autolaunch works]({{origin}}/how-it-works) lists every fee, split and step.
- **Getting help:** email [build@regents.sh](mailto:build@regents.sh) or use the [contact page]({{origin}}/contact).
- **For agents:** start with [/llms.txt]({{origin}}/llms.txt) and the [developer guide]({{origin}}/docs).

## Key facts

| Fact | Detail |
| --- | --- |
| Company name | Regents Labs, Inc. |
| Type | Token launch and auction site |
| Founder | Sean Brennan |
| Website | {{origin}} |
| Core offering | Fair-price token auctions for agents, services and communities, with staking for backers |
| Pricing | Launching is free apart from the network fee. Trades in a Revstake pool pay 1% to its stakers and 1% to Regent; trades in a Memestake pool pay 3% to its stakers, 1% to Regent and 0.3% to its creator. Both are on top of the pool's 0.30%; Regent keeps 2% of each token's staking income |
| Networks | Base (Revstake and Memestake) and Robinhood Chain (Memestake) |
| Services | Revstake launches, Memestake launches, auctions, token staking |
| Communication | [build@regents.sh](mailto:build@regents.sh) |
| Social | [X @regents_sh](https://x.com/regents_sh) · [GitHub](https://github.com/regents-ai/autolaunch) · Founder: [X](https://x.com/seanwbren), [LinkedIn](https://www.linkedin.com/in/seanwbren) |
| Token | REGENT, on Base. Revstake auctions are priced in REGENT |
| Token contract | `0x6f89bcA4eA5931EdFCB09786267b251DeE752b07` |
| Staking | On Base, Regent's share of Autolaunch fees goes to people who stake REGENT on [regents.sh](https://regents.sh/stake) |

Bidding, trading and staking involve contract, network and financial risk. No return is guaranteed.

## What Autolaunch does

### Revstake tokens

An agent, or any service that earns stablecoins, raises early backing in a 48-hour auction priced in REGENT, on Base. The launcher promises to pass the revenue it earns through the token's staking contract, where stakers receive a share; that promise is a trust assumption. Whatever is sent is shared out automatically: stakers receive a share in line with how much of the supply is staked, and the rest goes to the token's treasury.

### Memestake tokens

A memecoin paired with a real onchain stock, on Base or Robinhood Chain. The auction runs for 24 hours and sells half the supply; the other half is locked in the pool with everything raised. There is no creator or team allocation: the creator earns 0.3% of trades, and stakers receive the stock from the token's trading fees.

### Token staking

Stake a launched token on its page to earn a share of everything that reaches its staking pot: trading fees, locked liquidity fees and, for Revstake tokens, customer payments. Earnings arrive in the currencies that came in.

## What makes Autolaunch different

### One price for every bidder

Autolaunch uses Uniswap's continuous clearing auction, which sells tokens a little at a time. Bids above the clearing price buy at that price, not at their own limit, so there are no early snipers: if you are in the auction, you are early.

### A minimum raise, or everyone gets their money back

Each auction must raise the amount its launcher set before it can graduate. If it falls short, every bidder takes back their full bid, and the refunds are paid by the Uniswap auction contract itself, so nothing in Autolaunch can hold them back.

### Liquidity that can't be pulled

The trading pool's liquidity is locked in a contract that can only collect trading fees. Anyone can press "collect", and the fees always go into the token's staking pot.

### Free to launch

Launching costs nothing apart from the network fee. Trading fees and staking rewards are fixed in the contracts.

### Your wallet signs everything

Autolaunch never holds your keys. Every bid, claim, launch, trade and stake is signed by your own wallet.

## Who uses Autolaunch

- Agents and services that earn stablecoins and want backers who share in that revenue.
- Communities launching a memecoin backed by a real onchain stock.
- People who want to back an agent or project early at the same price as everyone else.
- Stakers who earn from a launched token's trading fees and revenue.

## Frequently asked questions

### What's the difference between Revstake and Memestake?

Revstake is for agents and services that earn stablecoins: 20% of the supply is sold in a 48-hour auction priced in REGENT, and stakers share the revenue the launcher sends. Memestake pairs a memecoin with an onchain stock: 50% is sold in a 24-hour auction, with no team allocation.

### Why does everyone pay the same price?

The auction has one clearing price at any moment, set by the bids competing for the tokens released so far. Bids above it buy at that price, so nobody pays more than anyone else buying at the same moment.

### What happens if an auction doesn't reach its minimum?

It fails: every bidder takes back their full bid, and every token is burned. The Uniswap auction contract pays the refunds directly.

### What does it cost to launch?

Nothing apart from the network fee.

### Is Revstake revenue guaranteed?

No. The launcher promises to send revenue to the staking contract, but can stop, send only part of it or go out of business. Whatever does arrive is shared out automatically: stakers receive a share in line with how much of the supply is staked, and the rest goes to the token's treasury.

### Does Autolaunch hold my money or keys?

No. Every bid, claim, launch, trade and stake is signed by your own wallet, and refunds come from the auction contract.

## Who operates the service

Regents Labs, Inc. is the operator named in the [Privacy Policy]({{origin}}/privacy) and [Terms of Use]({{origin}}/terms). The source code is public at [github.com/regents-ai/autolaunch](https://github.com/regents-ai/autolaunch).
