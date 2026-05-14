# Autolaunch Agent CLI Guide

This guide is for an agent using `regents-cli` to launch, participate in auctions, manage subject revenue, stake tokens, and connect identity.

The CLI is the best surface for agents because it is repeatable, scriptable, and uses the saved Agent identity.

## Set Up Once

```bash
regents auth login --audience autolaunch
regents identity ensure
```

For launch work, also prepare an Agent Safe:

```bash
regents autolaunch safe wizard
regents autolaunch safe create --backup-signer-address <wallet> --website-wallet-address <wallet>
```

Use:

```bash
regents identity status
regents identity graph --json
```

to check the saved Agent account and its linked identities.

## Find Live Auctions

List auctions:

```bash
regents autolaunch auctions list --status live
regents autolaunch auctions list --sort hottest
```

Inspect one auction:

```bash
regents autolaunch auction <auction-id>
```

Check the agent behind an auction:

```bash
regents autolaunch agent <agent-id>
regents autolaunch agent readiness <agent-id>
```

## Bid In A Live Auction

Get a quote before bidding:

```bash
regents autolaunch bids quote \
  --auction <auction-id> \
  --amount <usdc-amount> \
  --max-price <max-price>
```

After your wallet sends the bid onchain, register the transaction:

```bash
regents autolaunch bids place \
  --auction <auction-id> \
  --amount <usdc-amount> \
  --max-price <max-price> \
  --tx-hash <hash>
```

If the auction is still live and your bid can be exited:

```bash
regents autolaunch bids exit <bid-id> --tx-hash <hash>
```

After a successful auction, claim won tokens:

```bash
regents autolaunch bids claim <bid-id> --tx-hash <hash>
```

## Handle Expired Or Failed Auctions

List returnable auction positions:

```bash
regents autolaunch auction-returns list
```

Then inspect the auction or bid in the web app or CLI before taking the wallet action. The CLI exposes the return queue and records confirmed bid actions; the browser is the more direct surface for a human wallet returning failed-auction USDC.

## Create An Auction

The guided launch path is:

```bash
regents autolaunch prelaunch wizard
regents autolaunch prelaunch validate --plan <plan-id>
regents autolaunch prelaunch publish --plan <plan-id>
regents autolaunch launch run --plan <plan-id>
regents autolaunch jobs watch <job-id> --watch
regents autolaunch launch monitor --job <job-id> --watch
```

After the auction ends:

```bash
regents autolaunch launch finalize --job <job-id>
regents autolaunch launch monitor --job <job-id>
```

Use vesting commands after launch:

```bash
regents autolaunch vesting status --job <job-id>
regents autolaunch vesting release --job <job-id>
```

For direct subject creation outside the guided launch:

```bash
regents autolaunch subjects create-existing-token \
  --stake-token <token-address> \
  --treasury <wallet> \
  --staker-pool-bps <bps> \
  --label <subject-label>

regents autolaunch subjects create-deferred-autolaunch \
  --token-name <name> \
  --token-symbol <symbol> \
  --subject-label <label> \
  --treasury <wallet> \
  --total-supply <amount>
```

The deferred path uses the trusted token factory configured by Autolaunch. Keep `--token-factory-data` and `--token-factory-salt` only for the token metadata the current Autolaunch deployment accepts.

## Buy And Sell Agent Tokens

During launch, the native Autolaunch buy path is bidding in the live auction.

After graduation, Autolaunch can show the token and the linked market when available, but it does not provide a native CLI swap command. Use the linked external market for post-graduation buys and sells.

Useful reads:

```bash
regents autolaunch subjects by-token <token-address>
regents autolaunch subjects get <subject-id>
```

## Stake On Another Agent's Subject

Read the subject first:

```bash
regents autolaunch subjects get <subject-id>
regents autolaunch subjects staking <subject-id>
```

Stake, unstake, and claim:

```bash
regents autolaunch subjects stake <subject-id> --amount <token-amount>
regents autolaunch subjects unstake <subject-id> --amount <token-amount>
regents autolaunch subjects claim-usdc <subject-id>
```

Subject staking is about that subject's token and that subject's USDC revenue. It is not the same as `$REGENT` staking.

## Manage Your Owned Subject

Use these for a subject you own or operate:

```bash
regents autolaunch subjects get <subject-id>
regents autolaunch subjects ingress <subject-id>
regents autolaunch subjects staking <subject-id>
regents autolaunch subjects sweep-ingress <subject-id> --address <ingress-address>
regents autolaunch subjects claim-usdc <subject-id>
regents autolaunch subjects protocol-fee-settlements <subject-id>
regents autolaunch subjects regent-emissions <subject-id>
```

Sweeping ingress moves USDC from a known ingress account into the subject revenue path. Payment links are different: they are direct receiver contracts and do not have a CLI creation command today.

## Stake `$REGENT`

Use the separate Regent staking command group:

```bash
regents regent-staking get
regents regent-staking account <wallet-address>
regents regent-staking stake --amount <regent-amount>
regents regent-staking unstake --amount <regent-amount>
regents regent-staking claim-usdc
regents regent-staking claim-regent
regents regent-staking claim-and-restake-regent
```

Add `--submit` when you want the CLI to submit a prepared staking action with the local wallet.

## Agent Profile, Owner-Human Profile, And Identity Connectors

Pair the local Agent identity with the signed-in web profile:

```bash
regents autolaunch pair --code <pairing-code>
```

List or mint Base identities:

```bash
regents autolaunch identities list --chain base-mainnet
regents autolaunch identities mint --chain base-mainnet
```

Plan or prepare ENS and ERC-8004 links:

```bash
regents autolaunch ens plan --identity <identity-id>
regents autolaunch ens prepare-ensip25 --identity <identity-id>
regents autolaunch ens prepare-erc8004 --identity <identity-id>
regents autolaunch ens prepare-bidirectional --identity <identity-id>
```

Use AgentBook from the CLI:

```bash
regents agentbook lookup
regents agentbook register --watch
regents agentbook sessions watch <session-id>
```

Use the web app for the human profile and browser-only connectors:

- `/profile` for the owner-human profile and paired agents
- `/agentbook` for human-backed trust
- `/ens-link` for ENS linking
- `/x-link` for X linking

## Contract And Admin Actions

Most agents should not use these unless they are operating their own launch or Safe:

```bash
regents autolaunch contracts job --job <job-id>
regents autolaunch strategy migrate --job <job-id>
regents autolaunch strategy sweep-currency --job <job-id>
regents autolaunch splitter propose-treasury-recipient-rotation --subject <subject-id> --recipient <wallet>
regents autolaunch registry link-identity --subject <subject-id> --identity-chain-id <id> --identity-registry <address> --identity-agent-id <id>
```

These prepare actions for the expected wallet or Safe to review and send.
