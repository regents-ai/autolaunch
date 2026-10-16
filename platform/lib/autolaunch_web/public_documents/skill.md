---
name: autolaunch
description: Use autolaunch.sh for your person to understand Revstake and Memestock launches, research auctions, review their bids and claimable tokens, and watch auctions and stored prices. Covers WebMCP and Regents CLI reads and quotes, person-controlled transactions, and deadline-aware checks.
---

# Autolaunch: understand launches and track your person's positions

Start with [/agents.md]({{origin}}/agents.md): install regents-cli, sign in and pair with
your person's account. [/capabilities]({{origin}}/capabilities) lists every browser tool,
[/openapi.json]({{origin}}/openapi.json) every HTTP operation, and [/docs]({{origin}}/docs)
the errors and limits.

## Purpose and benefit

Autolaunch runs token launches through auctions. A Revstake token tokenizes an agent or a
service that earns stablecoins, and its stakers share what it earns. A Memestock token pairs
a memecoin with a tokenized stock. Revstake launches are created on Base only; Memestock
auctions run on Base or Robinhood Chain. Check each existing position's own chain and terms.

For you, public auction data and your person's private positions answer what is live, what
they bid on and what may be claimable. For your person, this means fewer missed deadlines and
account facts kept apart from promotion. Explain price units, launch state and how fresh each
figure is. No auction, treasury report or staking guarantees a return.

Use this skill for research, bid estimates, metadata drafts and watching. Bidding, trading,
claiming, staking and settlement stay with your person's own wallet; no agent tool or command
does them.

## Access and tool selection

Check `regents --version` and the command's `--help` before use. Every command below is in
regents-cli 1.10.12. A listed command, a listed tool and an answer that succeeded are different
evidence; say which you saw. Do not silently downgrade or replace an installed client.

Use your own SIWA signer and your current pairing for private reads. A missing signer or a
revoked pairing blocks private work; ask your person before making a new key. Never use their
browser sign-in, their cookies, their keys or another agent's identity. Signing in and pairing
grant no wallet or spending authority.

In a browser that offers WebMCP tools, open the site and read the tools it registers. Public
reads take their declared inputs. For a private tool, call `prepare_agent_request` with its
operation and input, sign the exact request it returns with your own SIWA signer, then call
the tool with `input`, `request` and `proof`. Keep the proof private. Without browser signing,
use the CLI command instead; never invent a tool or work around a refusal. Send private CLI
input as JSON on stdin, never in a command line.

## CLI and WebMCP map

Prefix each command with `regents autolaunch`. Read each input schema before you fill in real
ids.

| Goal | CLI | WebMCP |
| --- | --- | --- |
| Find auctions | `auctions list` | `autolaunch_auctions` |
| Read one auction | `auction ID` | `autolaunch_auction` |
| Estimate a bid (Base auctions) | `bids quote --auction UUID --amount DECIMAL --max-price DECIMAL` | `autolaunch_bid_quote` |
| Browse tokens | `tokens list` | `autolaunch_tokens` |
| Read one token | `token ID` | `autolaunch_token` |
| Read a treasury report | `treasury security ADDRESS` | `autolaunch_treasury` |
| Check your identity and pairing | `agents whoami` | `agent_whoami` |
| Read your person's positions | `positions` | `autolaunch_my_positions` |
| Read or save draft text | `drafts revstake show` / `save`, `drafts memestock show` / `save` | `autolaunch_revstake_draft`, `autolaunch_revstake_draft_save`, `autolaunch_memestock_draft`, `autolaunch_memestock_draft_save` |
| Read your person's account | `account balances`, `account credits-history`, `account points` | `account_balances`, `account_credits_history`, `account_points` |

`agents status` (`agent_status`) checks in and records the time, which your person sees; it is
not a passive identity check. Use `agents whoami` for that. A draft save needs a pairing and
the site's launch gate to be open; it never submits a launch or sets treasury, wallet, stock
or chain settings.

## Auctions, bids and claims

1. Settle the watchlist, your person, the chains that matter and where private reports go.
   Read public auctions first, filter with the command's own options, and page with
   `--after` set to the previous `pagination.next_cursor` while `pagination.has_more` is
   true. Use each record's own `url`; never build page addresses yourself.
2. Read the auction's `state`, `quote_token` (address, symbol, decimals), `minimum_raise`,
   `clearing_price`, `record_updated_at` and `estimated_end_at`. The end time is an estimate
   from block times and can move. `record_updated_at` is when the site last wrote its record,
   not when it last read the chain. The clearing price is in the quote token, not a live
   dollar price.
3. A bid estimate uses stored figures and places nothing. Report its warnings and the amount
   and maximum price you assumed. It is never an executable quote or a placed bid. Robinhood
   auctions answer `estimate_not_offered`; read their figures with `auction ID`.
4. For private positions, check your pairing and that your person has signed in to Autolaunch
   at `/account`. `positions` reads their verified primary wallet, not every linked wallet.
   Report bids and each token's `held`, `staked` and `claimable` only as returned, with chain,
   token and units attached. If the chain cannot be read, say the read failed, never that the
   portfolio is empty.
5. Track each bid by its `bid` id, `amount`, `max_price`, `standing` and `can`. A `standing`
   of `claim_ready` or `withdraw_ready`, or a `can` value, says what the bid's card offers
   now; it is not permission, and it does not mean any money moved.
6. When a bid needs your person, give them its `bid_page`: it shows what is theirs, the one
   button for what comes next and each transaction. No agent command claims, withdraws or
   bids. After your person reports a confirmed transaction, read the position again. Never
   report completion from a sent or pending transaction, and never resend one.

Draft edits are separate from this read-only loop. Only on an explicit request: read the
draft, save only the allowed text fields, then read it back. If a save loses its answer,
read before trying again. Respect `prelaunch_read_only` and every other refusal.

## Price movement without misleading comparisons

A token read can carry a stored price (`price_quote`, in quote-token units) and a nullable
`price_updated_at`. Call it a stored observation, not a live quote; a missing time does not
mean it is fresh. For a price alert, agree on chain, token contract, pool or source, quote
currency, maximum data age, baseline period and threshold first. Use a timestamped source and
compare like with like. A symbol alone does not identify a token.

For a valid positive baseline, the change is `100 × (current / baseline − 1)` percent. A
missing or zero baseline, an unknown time, a different quote asset or a stale reading gives
no defensible percentage. Never compare an auction clearing price with a pool price. Alert
once per threshold crossing or reset your person sets. With no agreed threshold, report
readings and ask for one; never choose trades for your person.

## Follow-up contract

The intervals below are starting points, not service promises or permission to run forever.
A request to read once ends after one report. Set up or update a recurring check only when
your person asks to watch, monitor or check back, with your host's own scheduler. Record the
scope, interval, stop condition, private destination and what you may do; reuse a matching
job. A watch request allows checks and alerts, not posts, spending or wallet signatures.

Autolaunch has no event feed: time checks from returned deadlines such as
`estimated_end_at`. Keep cursors, record ids and timestamped readings private to you and your
person. Read every page before moving a checkpoint; on an expired cursor (400), start the
listing again and say there may be a gap. [/docs]({{origin}}/docs) gives the request
limits; on 429, wait the `Retry-After` seconds, and back off on repeated failures. Stop
private work when the pairing is revoked. Alert only for a meaningful change, a decision or a
blocker. Never say a schedule exists until your host confirms it.

## When to check again

| Use | Suggested interval | Deadline or event handling |
| --- | --- | --- |
| Browsing new launches | Every 6–24 hours | Alert only for launches that match your person's criteria. |
| Watching a live auction or an existing bid | Every 15–30 minutes; every 5 minutes in the final hour if asked | Read changed end times, bid standing and warnings. Offer reminders 1 hour and 10 minutes before the current end; never bid. |
| Bidding just ended, auction not finished | Every 5–15 minutes at first; hourly while still waiting | Wait for a final state and the position's own standing. Ended is not finished or claimable. |
| Tokens to claim or money to withdraw | When it becomes ready, then daily while it waits | Alert once when newly ready. Do not invent a deadline or keep urging. Stop once your person confirms it is done or dismissed. |
| Price movements | Every 15–60 minutes for an active watch; daily for a portfolio summary | Use your person's threshold and the source's freshness. A 5-minute watch needs a source that changes that often and your person's explicit interest. |
| After your person's confirmed wallet action | Once, then every 1–5 minutes until it shows, up to a set limit | Report a mismatch between the chain and the site; never resend. |

Report private positions with what they cover and when they were read, changed auction and
claim states, valid price comparisons, links and any decision for your person. Never publish
a portfolio to a room or forum.

## References

- [Autolaunch]({{origin}}/), [/agents.md]({{origin}}/agents.md) for install, sign-in and
  pairing, [/capabilities]({{origin}}/capabilities), [/docs]({{origin}}/docs) and
  [/llms.txt]({{origin}}/llms.txt).
- [regents-cli](https://github.com/regents-ai/regents-cli).
