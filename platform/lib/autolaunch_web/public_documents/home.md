# Autolaunch

Where agents launch. Autolaunch is for backing long-term agents. Raise early funds through an auction. No early snipers here. If you are in the auction, you are early.

Autolaunch runs token auctions on Base and Robinhood Chain. Everyone in an auction pays the same clearing price, and most of the tokens are sold at the end, so bidding your true value in full, as early as you like, is never a disadvantage.

## Two kinds of launch

- **Revstake** (Base): an agent or a stablecoin-earning service raises early funds through an auction of {{revstake_auction}} priced in REGENT. Holders stake the token for their share of the stablecoin revenue sent to it.
- **Memestock** (Base and Robinhood Chain): a memecoin paired with a real onchain stock, sold in an auction of {{memestock_auction_base}} on Base or {{memestock_auction_robinhood}} on Robinhood Chain. Holders stake it to receive the stock from the token's trading fees.

## Browse

- [Auctions]({{origin}}/auctions): every auction, live, opening soon, waiting to be finished, failed or graduated.
- [Tokens]({{origin}}/tokens): tokens whose auctions succeeded, to trade and stake.
- [How Autolaunch works]({{origin}}/how-it-works): supply, trading fees and staking rewards for every token.
- [REGENT]({{origin}}/regent): the Regents Labs token and its staking figures.

## Principles

- **Fair price**: one price for every bidder. Bids above the clearing price all pay that price, not their own limit.
- **Locked liquidity**: liquidity no one can pull. It sits in a contract that can only collect trading fees.
- **Stock tokens**: every stock named exactly. Each stock shows its issuer and chain, and its exact address before you sign.
- **Your wallet**: your wallet signs everything. Autolaunch never holds your keys or your money.
- **Agents**: agents prepare, you sign. A paired agent can fill in your launch for you to check and sign.
- **Onchain**: figures from the chain. Auction prices, bids and amounts raised come from the auction contracts.

## For agents

Every public list and record can be read without an account, as JSON:

- `GET {{origin}}/api/v1/auctions`
- `GET {{origin}}/api/v1/tokens`

Start with the [developer guide]({{origin}}/docs), the [OpenAPI description]({{origin}}/openapi.json) or the [agent guide]({{origin}}/llms.txt). Bidding, launching and staking happen on the website with the person's own wallet; every step asks the wallet holder to sign.

[About]({{origin}}/about) · [Privacy]({{origin}}/privacy) · [Terms of Use]({{origin}}/terms) · [Sitemap]({{origin}}/sitemap.xml)
