# Autolaunch CLI And Web App Comparison

This guide compares what an agent can do through `regents-cli` and what a human can do through the web app.

## Short Version

Use the CLI for agent-owned and operator-owned work:

- launch creation
- launch monitoring and finalization
- Agent Safe setup
- saved Agent identity
- scripted auction reads
- subject creation
- subject owner actions
- ENS and ERC-8004 preparation
- repeatable staking actions

Use the web app for human-owned work:

- browsing auctions
- bidding with a browser wallet
- seeing positions
- claiming and returning with a browser wallet
- subject staking with visual review
- `$REGENT` staking with visual review
- human profile
- X, ENS, and AgentBook connector flows

## Activity Matrix

| Activity | CLI | Web app | Notes |
| --- | --- | --- | --- |
| Browse live auctions | Yes | Yes | CLI is better for repeatable output. Web is better for visual review. |
| Inspect one auction | Yes | Yes | Use `regents autolaunch auction <id>` or `/auctions/:id`. |
| Bid in a live auction | Partial | Yes | Web can prepare and send from a browser wallet. CLI quotes and records the confirmed bid transaction. |
| Exit a live bid | Partial | Yes | CLI records the confirmed exit transaction. Web is the direct wallet surface. |
| Claim won auction tokens | Partial | Yes | CLI records the confirmed claim transaction. Web is the direct wallet surface. |
| See expired or failed auction returns | Yes | Yes | CLI lists returnable positions. Web is easier for wallet returns. |
| Create a full launch auction | Yes | Limited | The launch creation path is CLI-first. Web explains and monitors it. |
| Create an existing-token subject | Yes | No dedicated flow | CLI exposes the direct subject creation command. |
| Create a deferred Autolaunch subject | Yes | No dedicated flow | CLI exposes the direct deferred subject command. |
| Buy or sell graduated agent tokens | No native swap | No native swap | Autolaunch shows the token and linked market when available. Swaps happen outside Autolaunch. |
| Stake on another subject | Yes | Yes | CLI is repeatable. Web is clearer for wallet review. |
| Unstake from a subject | Yes | Yes | Both surfaces prepare the subject action. |
| Claim subject USDC | Yes | Yes | Both surfaces support subject reward claims. |
| Sweep an owned subject ingress account | Yes | Yes | Requires a wallet allowed to operate that subject or ingress path. |
| View subject revenue and staking | Yes | Yes | CLI is better for scripts. Web is better for humans. |
| Stake `$REGENT` | Yes | Yes | CLI supports `--submit`; web uses browser wallet review. |
| Claim `$REGENT` rewards | Yes | Yes | Includes claim and claim-and-restake flows. |
| Agent Safe setup | Yes | No dedicated flow | Use `regents autolaunch safe wizard` and `safe create`. |
| Pair a CLI agent to a web profile | Yes | Yes | Web creates the pairing code. CLI completes it. |
| Human profile | Read through pairing context | Yes | `/profile` is the human profile surface. |
| Agent profile and readiness | Yes | Yes | CLI has `agent` and `agent readiness`; web shows profile and subject context. |
| Mint or list ERC-8004 identities | Yes | No dedicated flow | Use `regents autolaunch identities list` and `mint`. |
| ENS and ERC-8004 linking | Yes | Yes | CLI prepares actions. Web gives a browser connector flow. |
| AgentBook trust | Yes | Yes | CLI can register, watch, and look up. Web is smoother for the human approval step. |
| X linking | No | Yes | Use `/x-link`. |
| Contract operator actions | Yes | Yes | CLI is repeatable. `/contracts` is better for visual review. |
| Payment link creation | Direct contract only | Direct contract only | No public CLI or web creation command today. |

## CLI-Only Or CLI-Better

The CLI is the only shipped surface for:

- `regents autolaunch safe wizard`
- `regents autolaunch safe create`
- `regents autolaunch prelaunch wizard`
- `regents autolaunch prelaunch validate`
- `regents autolaunch prelaunch publish`
- `regents autolaunch launch preview`
- `regents autolaunch launch run`
- `regents autolaunch launch monitor`
- `regents autolaunch launch finalize`
- `regents autolaunch jobs watch`
- `regents autolaunch vesting status`
- `regents autolaunch vesting release`
- `regents autolaunch vesting propose-beneficiary-rotation`
- `regents autolaunch vesting cancel-beneficiary-rotation`
- `regents autolaunch vesting execute-beneficiary-rotation`
- `regents autolaunch identities list`
- `regents autolaunch identities mint`
- direct subject creation commands

The CLI is also better for automation because it can produce repeatable command output and can be used from scripts.

## Web-Only Or Web-Better

The web app is the only shipped surface for:

- the human profile page
- browser wallet auction bidding
- browser wallet return and claim actions
- X linking
- the visual auction and position experience
- pairing-code creation for a signed-in human

The web app is also better when a person needs to compare auctions, check a wallet action, or review subject revenue without command output.

## Neither Surface Provides Native Swaps

Autolaunch does not currently provide a native CLI swap command or a native web swap form for graduated agent tokens.

The Autolaunch-native purchase path is the live auction bid. After graduation, use the linked external market when one is available.

## Payment Links

Payment links are contract-level tools today. They are documented for direct contract use, but there is no public CLI command or web creation button yet.

Read `/Users/sean/Documents/regent/autolaunch/docs/payment-links.md` before using them.
