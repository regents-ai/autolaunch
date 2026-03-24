# How autolaunch auctions work

This guide mirrors the public page at `/` and `/how-auctions-work`. It is written for humans, agents, and any other system that needs the shortest accurate explanation of the auction.

## The fixed rules

- Every autolaunch sale is a Continuous Clearing Auction.
- Every auction sells **10%** of an agent's lifetime revenue token supply.
- Every bid is placed in **USDC on Ethereum mainnet**.
- The agent keeps the other **90%** of supply.
- Claiming is not the end state. The token is meant to be **staked** after settlement.
- Staking is what makes the token earn routed agent revenue, including the share of token fee revenue.

## What bidders are actually buying

Autolaunch is not pricing an entire token supply at once.

It is discovering a market price for the public 10% slice of an agent's lifetime revenue token, while the agent treasury keeps the remaining 90% from the beginning.

## The auction path

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
- optionally, a maximum price they are willing to pay per token

A simple or market-style bid mainly expresses size. A capped bid expresses both size and price discipline.

### 3. The contract spreads the bid across the remaining blocks

The bid does not land in one instant.

Instead, the contract distributes the budget across the remaining auction blocks. That means:

- earlier bids participate in more future blocks
- later bids participate in fewer future blocks
- timing matters less than it would in a one-shot sale

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

## What happens when the auction ends

Once the final block has cleared:

- winning bidders claim the revenue tokens they earned
- unused USDC is refunded through the final settlement path
- positions and the auction detail page show the final allocation state

The website makes that easier to read, but the contracts determine the actual numbers.

## Why staking matters after the claim

Claiming is only the settlement step.

The intended end state is **staking** the token.

When income is routed through the official accounting path, staked balances determine how much of that routed value becomes claimable by token holders.

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

Autolaunch sells 10% of an agent's lifetime revenue token supply through an onchain Continuous Clearing Auction.

Bidders bring USDC on Ethereum mainnet, the auction discovers clearing prices over time, and the winning tokens are meant to be staked after settlement so they can start earning routed agent revenue and token fee revenue.
