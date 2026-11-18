
## Agent staking

A paired agent can have its person's staking steps on a launched token prepared for one of the person's own wallets: a stake, an unstake or a claim, exactly as the token page's Stake and Claim views offer them. The site only prepares them: your person's own wallet signs and sends each step. Autolaunch never holds a key and never signs or sends anything.

| Action | WebMCP tool | Hosted MCP tool | HTTP |
| --- | --- | --- | --- |
| Prepare a stake, unstake or claim (signed, paired) | `autolaunch_stake_prepare` | `prepare_stake` | `POST {{origin}}/api/agent/v1/tokens/{token_id}/stake/steps` |

`token_id` is the token's `id` as `autolaunch_tokens` lists it, on Base or Robinhood Chain. A token the site does not list is refused with `token_not_found` before any chain is read. Send `kind` as one of these:

- `stake` stakes the wallet's whole balance of the token, as the page does. When the wallet has not approved enough of the token for staking, a `token_approval` step comes first, then `stake`. A wallet that holds none of the token is refused with `nothing_to_stake`.
- `unstake` unstakes `amount`, a decimal in the token with at most 18 decimal places, in one `unstake` step. An amount that is not one, or is zero, is refused with `invalid_amount`; more than the wallet has staked, with `amount_above_stake`.
- `claim` first moves the trading fees waiting for stakers into the staking contract: a `settle` step when the pool holds stakers' fees, then a `collect_…` step for each locked position. Then it claims everything the wallet has waiting in one `claim` step. A wallet that has nothing waiting is still given the steps; its claim pays nothing.

Only `unstake` takes `amount`; sending one with `stake` or `claim`, or leaving it out of `unstake`, is refused with `invalid_request`. The steps are read from the token's own chain at the latest block exactly as the token page reads them, and are transactions on the network `chain` names with its `chain_id`, sent in order. The wallet must be on that network when it sends them. The site's pages ask a wallet to switch networks; an agent's own wallet tooling has to switch, or stop, by itself.

Every answer gives `kind`, `signer`, `token` (`id` and `address`), `chain`, the `block` it was read at, `steps` (each with `step`, `to`, `data` and `value`, its `data` ending with the site's Builder Code) and `facts`: the wallet's token `balance`, what it has `staked`, and what it can claim now in each asset (`claimable`), each an `amount` with its `symbol`, read at `block`. The wallet is `signer` when you send one of your person's own wallets, otherwise the wallet they signed in with; any other is refused with `wrong_signer`. Your person needs a verified wallet now, as `autolaunch_my_positions` does; without one, or with a `signer` that is not a wallet address, the steps are refused with `wallet_required`.

A refusal keeps its HTTP status and names its reason: 422 `invalid_request` or `invalid_amount` for input to fix; 401 `authentication_required`; 403 `agent_not_paired` or `wrong_signer`; 404 `token_not_found`; 409 `wallet_required`, `nothing_to_stake` or `amount_above_stake` while the wallet stands as it is; and 503 `chain_unavailable` or `stake_unavailable`, worth trying again in a moment. The hosted MCP tool at `{{origin}}/mcp` takes the same inputs, each under `input`, and gives the HTTP answer's `data` as its result; a refusal is its error, with the same code and words. The steps only come back once launches are open. The regents CLI has no staking command yet.
