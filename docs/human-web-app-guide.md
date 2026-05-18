# Autolaunch Human Web App Guide

This guide is for a person using the Autolaunch web app with a browser wallet.

Use the web app when you want to browse auctions, bid, claim, stake, manage your profile, connect identity, and review wallet actions visually.

## Start

Open the app and connect your wallet.

Useful pages:

- `/auctions` for live and recent auctions
- `/positions` for your bids, claims, and returns
- `/tokens` for graduated subject tokens
- `/subjects/:id` for one subject's revenue and staking
- `/regent-staking` for `$REGENT` staking
- `/profile` for your human profile and paired agents
- `/launch` for the launch guide
- `/contracts` for operator actions
- `/agentbook`, `/ens-link`, and `/x-link` for identity connectors

## Join A Live Auction

Go to `/auctions`.

Use the filters to find:

- live auctions
- biddable auctions
- recently finished auctions
- auctions that missed their minimum

Open an auction to see its status, current price, bid state, and next available action.

To bid, enter the $REGENT amount and price limit, review the wallet action, and send it from your wallet.

## Handle Expired Or Failed Auctions

Go to `/auction-returns` or `/positions`.

Use these pages to find auctions where $REGENT can be returned or a bid needs attention. Open the position, review the wallet action, and send it from your wallet.

## Claim Won Tokens

Go to `/positions` after a successful auction.

Claimable positions show the action needed to receive the won agent tokens. Review the wallet action and send it from your wallet.

## Create An Auction

Go to `/launch`.

The web app explains the launch path and points you to the CLI-first flow. A full agent launch is created through `regents-cli`, because launch setup depends on the Agent identity, Agent Safe, launch plan, and operator run.

Use:

```bash
regents autolaunch prelaunch wizard
regents autolaunch prelaunch publish --plan <plan-id>
regents autolaunch launch run --plan <plan-id>
```

The web app remains useful during launch for public review, auction monitoring, profile pairing, and final wallet actions.

## Buy And Sell Agent Tokens

During launch, the web app buy path is bidding in the auction.

After graduation, Autolaunch shows the token and its subject page. When a supported Base market is available, the web app can show a Base USDC trade for wallet review. The linked external market remains available for manual buying and selling.

## Stake On A Subject

Open `/subjects/:id`.

Use the subject page to:

- read the subject's revenue state
- see the stake token
- stake subject tokens
- unstake subject tokens
- claim subject USDC
- sweep known ingress accounts when your wallet is allowed to do so

Subject staking uses that subject's token and that subject's USDC revenue.

## Manage Your Owned Subject

Open your subject page at `/subjects/:id`.

If your wallet is allowed to operate the subject, the page can show actions for:

- staking your subject token
- unstaking
- claiming USDC
- sweeping ingress accounts
- reviewing revenue and staker state

For deeper owner or recovery actions, use `/contracts` or the CLI.

## Stake `$REGENT`

Go to `/regent-staking`.

Use this page to:

- view the staking pool
- view your wallet's staking state
- stake `$REGENT`
- unstake `$REGENT`
- claim USDC rewards
- claim `$REGENT` rewards
- claim and restake `$REGENT` rewards

`$REGENT` staking is separate from subject staking.

## Profile And Paired Agents

Go to `/profile`.

Use this page to:

- see the connected wallet profile
- see paired Agent identities
- create a pairing code for `regents-cli`
- review holdings, positions, and history
- open identity connector pages

To pair an agent from the CLI:

```bash
regents autolaunch pair --code <pairing-code>
```

## Identity Connectors

Use:

- `/agentbook` for human-backed trust
- `/ens-link` for ENS and ERC-8004 linking
- `/x-link` for X linking

These flows are browser-oriented because they depend on human approval, wallet review, or account login.

## Operator Actions In The Web App

Use `/contracts` only when you know the wallet is the expected owner, operator, or Safe signer.

This page is for reviewing and sending sensitive actions such as settlement, ownership acceptance, splitter updates, registry updates, ingress updates, and fee actions.

For repeatable operator work, use the CLI.

## Payment Links

Payment links are not a web creation flow today.

Direct contract usage is documented in `/Users/sean/Documents/regent/autolaunch/docs/payment-links.md`.
