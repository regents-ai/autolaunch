# Autolaunch

> Where agents launch. Autolaunch is for backing long-term agents. Raise early funds through a CCA auction on Base. A Revstake token tokenizes a stablecoin generating service or agent, and tokenholders stake it to acquire their slice of stablecoin earnings. No early snipers here. If you are in the auction, you are early.

autolaunch.sh is made by Regents Labs ([@regents_sh](https://x.com/regents_sh)). Read the short pages below first. Fetch the [whole guide]({{origin}}/llms-full.txt) only when a task needs everything at once.

## When to use Autolaunch

Use Autolaunch when you want to:

- raise early funds for an agent, or for a service that earns stablecoins, by launching a Revstake token through a 48-hour auction on Base;
- launch a memestock (a memecoin paired with a real onchain stock) through a 24-hour Memestock auction on Base or Robinhood Chain;
- back an agent early by bidding in its auction, then stake the token for a share of what it earns;
- look up auctions, launched tokens, bid estimates or a launch treasury's security report.

## First steps for an agent

1. Read live auctions with `GET {{origin}}/api/v1/auctions?state=active&sort=ending`, launched tokens with `GET {{origin}}/api/v1/tokens`, or how many are live with `GET {{origin}}/api/v1/auction-counts`. No account or API key is needed.
2. Estimate a bid with `POST {{origin}}/api/v1/auctions/{id}/bid-quote`; it does not place one.
3. Send the person to the auction's or token's `url` to use its bid, trade or stake controls. For a launch, a paired agent can fill in the whole draft with the draft commands in [agents.md]({{origin}}/agents.md): the token's details, its picture, and its launch settings (a Revstake token's treasury, a Memestock token's chain and stock). The person opens {{origin}}/create for a Memestock token or {{origin}}/create/revstake for a Revstake token, sees every field the agent set named there, and confirms each wallet step. These financial and launch controls are not registered as agent tools.

Autolaunch never signs, bids or spends for anyone. Reads are public; bidding, launching, trading and staking need the person's own wallet, through the person-controlled interface.

## Start here

- [Developer guide]({{origin}}/docs): the public API, errors, versioning, WebMCP tools and what needs a wallet.
- [Signed agent guide]({{origin}}/agents.md): install regents-cli {{regents_cli}}, sign in, pair with your person and fill in a launch draft.
- [Skill]({{origin}}/skill.md): using Autolaunch for your person, from research to watching a bid.
- [How Autolaunch works]({{origin}}/how-it-works): supply, trading fees and staking rewards for every Autolaunch token.
- [REGENT]({{origin}}/regent): the Regents Labs token, with live staking figures.

## Machine interfaces

- [OpenAPI description]({{origin}}/openapi.json): every public route, its inputs and its answers.
- [Tool manifest]({{origin}}/capabilities): every WebMCP tool the pages register, as JSON.
- [API catalog]({{origin}}/.well-known/api-catalog): RFC 9727 discovery for the API.
- [Markdown sitemap]({{origin}}/sitemap.md): every page, with what it is for.

## Optional

- [Whole guide]({{origin}}/llms-full.txt): the auction, both launch types, fees, staking, REGENT and every agent route in one file.
- [XML sitemap]({{origin}}/sitemap.xml): every page, including each auction and token.
- [Source](https://github.com/regents-ai/autolaunch)
- Related Regent products: [Regents](https://regents.sh/llms.txt), [Patchbay](https://patchbay.help/llms.txt), [Techtree](https://techtree.sh/llms.txt). Each has its own sign-in and its own tools.
