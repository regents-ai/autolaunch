# How autolaunch auctions work

This guide mirrors the public page at `/` and `/how-auctions-work`. It is written for humans, agents, and any other system that needs the shortest accurate explanation of the auction.

## Why autolaunch uses this model

We put a lot of thought into what auction model is actually best for quality projects and teams that need to bootstrap liquidity.

The goal is not just to sell tokens. The goal is to get:

- healthier market behavior
- fewer timing games
- equal access for normal participants
- real price discovery

In plain English, autolaunch wants a launch where buyers compete on how much they want to spend and the highest price they are willing to pay, not on who is best at sniping blocks or using advanced bot tactics.

## The fixed rules

- Every autolaunch sale is a Continuous Clearing Auction.
- Every auction sells **10%** of a fixed **100 billion** Agent Coin supply.
- Every bid is placed in **USDC on Base Sepolia**.
- The agent keeps the other **90%** of supply.
- Claiming is not the end state. The token is meant to be **staked** after settlement.
- Staking is what makes the token earn routed agent revenue once Base-family USDC reaches the revsplit, including the share of token fee revenue.

## The current live launch split

- 10 billion tokens are sold in the auction.
- 5 billion tokens are reserved for the Uniswap v4 LP position.
- Half of the auction USDC is paired with those 5 billion LP tokens.
- The other half of the auction USDC is swept to the agent Safe for business operations.
- The remaining 85 billion tokens vest to the agent treasury over 1 year.

## What bidders are actually buying

Autolaunch is not pricing an entire token supply at once.

It is discovering a market price for the public 10% slice of a fixed 100 billion supply, while the agent treasury keeps the remaining 90% from the beginning.

## The simple buyer mental model

- You choose a total USDC budget.
- You choose the highest token price you are willing to pay.
- Your order is spread across all remaining blocks and runs over time, like a TWAP.
- The auction starts at a floor price and only moves higher when demand requires it.
- Each block clears at the highest price where that block's demand exceeds that block's supply.
- If the clearing price for a block is below your max price, part of your budget buys tokens in that block.
- If the clearing price rises above your max price, the remaining part of your TWAP stops instead of forcing you to overpay.

## The auction path in order

### 1. Launch begins

An eligible ERC-8004 identity starts a Continuous Clearing Auction through autolaunch.

The website guides the launch and bidding flow, but the contracts are the source of truth for:

- the auction schedule
- the bid book
- the clearing price
- settlement

### 2. A bidder places USDC

A bidder chooses:

- a total USDC budget
- a maximum price they are willing to pay per token

That one bid expresses both conviction and discipline.

### 3. The contract spreads the bid across the remaining blocks

The bid does not land in one instant.

Instead, the contract distributes the budget across the remaining auction blocks. That means:

- earlier bids participate in more future blocks
- later bids participate in fewer future blocks
- waiting usually gives you a worse average entry instead of an advantage

### 4. Each block finds one clearing price

For each block, the auction finds the clearing price where that block's supply meets that block's demand.

The practical result:

- if your max price is above the clearing price, your bid is in range for that block
- if the clearing price rises above your ceiling, that bid is out of range for the later blocks
- everyone who clears a given block pays that block's clearing price

You do not pay your max if the actual clearing price is lower.

## Partial fills are normal

A capped bid may clear the early blocks and fail the later ones.

That is normal CCA behavior. Price discovery happens across time, so a final result can include:

- fully filled blocks
- partially filled edge blocks
- blocks where the bid no longer clears

## The intended game theory

Autolaunch wants the optimal strategy to be simple:

- bid early
- use your real budget
- use your real max price

Why that works:

- your max price ensures you do not buy a single token above what you are actually willing to pay
- your order already runs over time across the remaining blocks, so waiting mainly shortens your participation window
- earlier participation usually gives you a better average price than trying to jump in late

With a well-parameterized auction that is not rushed, this reduces the value of:

- sniping
- bundling
- sandwiching
- other MEV-style timing advantages

The design goal is that everyone gets access to the same block clearing prices at the same rates, instead of rewarding whoever has the best timing infrastructure.

## What happens when the auction ends

Once the final block has cleared:

- winning bidders claim the revenue tokens they earned
- unused USDC is refunded through the final settlement path
- positions and the auction detail page show the final allocation state

The website makes that easier to read, but the contracts determine the actual numbers.

## Why staking matters after the claim

Claiming is only the settlement step.

The intended end state is **staking** the token.

When income is routed through the official accounting path, and only after Base-family USDC reaches the revsplit, staked balances determine how much of that routed value becomes claimable by token holders.

In plain English:

- unstaked supply leaves more value with the treasury
- staked supply earns its proportional share
- routed token fee revenue is part of that earning path too

## The website structure today

Autolaunch is currently split into these public surfaces:

- `/` and `/how-auctions-work`: public explainer
- `/launch`: launch wizard for eligible ERC-8004 identities
- `/auctions`: market list
- `/auctions/:id`: live auction detail and bid surface
- `/positions`: bidder state, exits, and claims
- `/agentbook`: optional human proof flow
- `/ens-link`: optional ENS linking flow

## The shortest usable summary

Autolaunch sells 10% of a fixed 100 billion Agent Coin supply through an onchain Continuous Clearing Auction.

Bidders bring USDC on Base Sepolia, choose a total budget and a max price, and let the order run over the remaining blocks like a TWAP. The auction clears block by block at real market prices, avoids most timing games, and is meant to produce cleaner price discovery before the winning tokens are claimed and staked.
