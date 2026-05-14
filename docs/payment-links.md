# Autolaunch Payment Links

This guide describes the intended payment-link flow for agents and humans.

A payment link gives an agent a simple Base USDC address it can share when it wants to receive revenue for an Autolaunch subject. The link is not a new revenue pool. It is a small receiver that forwards USDC into the subject's current revenue contract so the payment can be counted by the normal Autolaunch revenue rules.

## What The Link Is For

Use a payment link when an agent wants to accept Base USDC from a customer, sponsor, service buyer, or another agent without asking that payer to understand the full Autolaunch revenue system.

The payer sees a normal payment destination:

- a Base USDC address
- optionally, a fixed USDC amount
- optionally, a payment reference if the payer is using the metadata-aware payment call

The agent gets a revenue path that still follows the existing subject rules:

- payments are for one Autolaunch subject
- USDC becomes subject revenue only after it reaches that subject's revenue contract
- the subject staker and treasury split is whatever the subject revenue contract uses at the time the payment is moved in
- the expected Regent share still goes into the shared REGENT staking rail

## Prerequisites

An agent needs these before creating a payment link:

- A Regents CLI install with a local wallet configured.
- Base ETH in that local wallet to pay the link deployment gas.
- A Base RPC URL configured for the target network.
- An Autolaunch subject ID.
- The Autolaunch payment-link factory deployed on that network.
- Base USDC as the payment token.

Production links use Base mainnet. Rehearsal links should use Base Sepolia.

If the agent did not launch through Autolaunch, it must first create an existing-token revenue subject. That path requires an existing stake token contract and a treasury address. There is no no-token revenue subject path today.

Autolaunch sign-in is optional for creating the onchain link, but useful. When the CLI has Autolaunch authentication, it can ask Autolaunch to record the confirmed link so it appears in the user's profile.

## What Gets Created

Each payment link deploys a new receiver contract for one subject.

The receiver stores:

- the subject ID
- the subject registry it trusts
- the Base USDC token address
- the creator that paid for deployment
- a label or reference for display

The receiver does not store an owner-controlled payout address. Its destination is the subject's current revenue contract, read from the subject registry. If the subject later rotates to a new revenue contract, the link follows the current subject destination rather than staying pinned to a retired one.

The receiver should expose a read function named `destination()` so humans, agents, and apps can confirm where the next sweep or metadata payment will go.

## How Payment Becomes Revenue

A simple USDC transfer to the payment-link address does not automatically count as subject revenue. ERC-20 transfers do not cause the receiver to run forwarding code.

So the flow is:

1. The payer sends Base USDC to the payment-link address.
2. The USDC waits at that address.
3. Anyone can call `sweepUSDC()`.
4. The receiver sends the full USDC balance into the subject's current revenue contract using that contract's normal deposit path.
5. Autolaunch records it as direct subject revenue.

There is also an optional metadata-aware path:

1. The payer calls `depositUSDC(amount, paymentRef)`.
2. The receiver pulls the payer's USDC.
3. The receiver emits payer and reference metadata.
4. The receiver moves its full USDC balance into the subject's current revenue contract.

Use the metadata-aware path when the payer is already using a wallet flow that can call the receiver directly. Use the simple transfer path when the goal is the broadest wallet support.

## What It Is Not

A payment link is not:

- a way to receive ETH
- a way to receive arbitrary tokens
- a replacement for the subject revenue contract
- a separate staking pool
- a way to create an agent revenue subject without a token
- an x402 seller flow
- proof that the payer identity is known

Payer identity is known only when the payer is already authenticated somewhere else, or when the payer uses the metadata-aware payment call with a reference the agent can interpret.

## Human Checklist

Before sharing a link, check:

- The link is on the expected Base network.
- The destination shown by the link matches the subject's current revenue contract.
- The subject is the intended agent or token.
- The payment token is Base USDC.
- The amount is correct if the link includes an amount.
- You understand that simple transfers may need a sweep before they appear as subject revenue.

## Agent Checklist

Before creating a link, an agent should verify:

- The local wallet has enough Base ETH for deployment gas.
- The configured RPC URL works.
- The subject ID exists.
- The subject is active.
- The payment-link factory is the expected Autolaunch factory for the network.
- The payment URI uses Base USDC and the receiver address, not the subject revenue contract address.
- The CLI stored the local receipt after confirmation.
- If authenticated, Autolaunch accepted the confirmed link record.

Before relying on received funds, an agent should verify:

- The receiver has a Base USDC balance, or the metadata-aware deposit transaction succeeded.
- A sweep transaction was confirmed if the payer used a simple transfer.
- The subject revenue totals increased after the sweep or deposit.

## Will This Work As Intended?

Yes, with one important correction: the receiver must move USDC into the subject revenue contract by calling the revenue contract's deposit path. It cannot just transfer USDC to that contract and stop there.

With that correction, the design works for the intended first version:

- any wallet can deploy a payment link for any subject if it pays the gas
- the link can receive simple Base USDC transfers
- anyone can sweep waiting USDC into the subject revenue path
- the optional metadata-aware payment call can track payer context
- links can follow subject revenue contract rotations
- the normal subject split and Regent share still apply

The design does not make every incoming transfer count instantly. Simple transfers count after sweep. If instant recognition is required for a specific payer flow, that flow should use the metadata-aware payment call instead of a plain transfer.
