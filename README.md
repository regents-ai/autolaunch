# Autolaunch

Autolaunch auctions new tokens and puts them to work for the people who stake them. A launcher
names a token and the raise it needs; bidders name a price; a continuous clearing auction settles
at one price. A launch that reaches its raise graduates into a Uniswap v4 pool whose liquidity is
locked for good, and one that does not refunds every bidder in full. From then on the pool's
trading fees, and any payments made to the launch, flow to the token's stakers.

This repository holds the Solidity contracts for each launch type, the autolaunch.sh website, a
public command-line client and the home of future agent plugins.

[Website](https://autolaunch.sh) · [Contracts](contracts/README.md) · [CLI](cli/README.md) · [API and WebMCP](platform/docs/public-webmcp.md)

## Three launch types

| | Base Revstake | Base Memestake | Robinhood Memestake |
| --- | --- | --- | --- |
| Chain | Base (8453) | Base (8453) | Robinhood Chain (4663) |
| What you bid with | REGENT | one admitted tokenised stock, such as AAPLc; a bidder may also pay USDC and have it converted inside the bid | one admitted tokenised stock, paid for in USDG inside the bid |
| Token supply | 100 billion: 10% auctioned, 5% liquidity reserve, 85% vests to the launch treasury over 365 days | 1 billion: 80% auctioned, 20% liquidity reserve | 1 billion: 80% auctioned, 20% liquidity reserve |
| Auction | opens 300 blocks after launch, runs 86,401 blocks | opens 300 blocks after launch, runs 43,200 blocks (about a day) | opens 6,000 blocks after launch, runs 864,000 blocks (about a day at 0.1-second blocks) |
| Where liquidity goes | one full-range position, owned forever by `RevstakeLPLocker` | two positions, owned forever by `MemestockLPLocker`; unsold tokens are retired | two positions, owned forever by `MemestockLPLocker`; unsold tokens are retired |
| Swap fees | two 1% lanes on every swap: one to the Regent Safe, one into the launch's staking contract | two 1% lanes of the stock side of every swap: one converted to USDC for REGENT staking, one into the launch's staking contract | two 1% lanes of the stock side of every swap: one converted to USDG into the protocol inbox, one into the launch's staking contract |
| How stakers earn | every inflow is skimmed 2%, then split between stakers (by their staked share of the total supply) and the treasury; the locked position's fees and payments through `PaymentReceiverV1` arrive the same way | every inflow is skimmed 2%; the other 98% goes to stakers pro rata, in USDC, the token and the stock; no treasury | every inflow is skimmed 2%; the other 98% goes to stakers pro rata, in USDG, the token and the stock; no treasury |
| Contracts | [contracts/v1](contracts/v1/README.md) | [contracts/stocks](contracts/stocks/README.md) | [contracts/robinhood](contracts/robinhood/README.md) |

There is no launch fee on any launch type: a launch costs only gas. The launcher chooses the
required raise. Revstake launches exist only on Base; Robinhood Chain hosts Memestake launches
only. The full picture, including which contract does what, is in the
[contracts overview](contracts/README.md).

## The website

autolaunch.sh is a Phoenix, LiveView and Ash application ([platform/](platform/README.md)). Signed
in with Privy, a person can:

- create a launch: either type on Base, Memestake on Robinhood; the page autosaves a draft, shows
  the fixed terms in words, then asks the wallet to sign one launch transaction;
- bid on an auction, with the price aligned to the auction's tick, and afterwards return an
  unfilled bid or claim the tokens from the portfolio page;
- follow auctions and tokens, buy or sell a token from its page, stake it, claim what it has
  earned, and collect the locked liquidity's trading fees into the staking contract.

Every wallet action is sent exactly as pressed; the site never blocks or defers one because of
page state. The public records are also served as JSON (`GET /api/v1/auctions`,
`GET /api/v1/auctions/:id`, `POST /api/v1/auctions/:id/bid-quote`, `GET /api/v1/tokens`,
`GET /api/v1/treasury-security/:address`), registered as five read-only
[WebMCP tools](platform/docs/public-webmcp.md) in browsers that support them, and mirrored by
the [CLI](cli/README.md). Until it is switched on with the deployment addresses, the production site
is read-only: reads and quotes work, wallet actions are switched off.

## Status

| Part | What exists | Deployed | What comes next |
| --- | --- | --- | --- |
| Base Revstake contracts | Complete against a frozen specification, with an offline gate, Base fork evidence, and a deployment packet that names the deployer and the eight predicted addresses | Deployed on Base on 22 September 2026; the eight addresses are in [the deployment record](contracts/v1/deployments/base-mainnet/README.md). Launches are still paused | The Governance Safe opens the factory to launches |
| Base Memestake contracts | Implemented with its own gate; the launchpad, bid adapter and one route for each of ten stocks | Deployed on Base on 23 September 2026; the addresses are in [the deployment record](contracts/stocks/deployments/base-mainnet/README.md). Launches are still paused | The Governance Safe admits the ten stocks and names the hook executor, then opens launches at website activation |
| Robinhood contracts | Implemented with its own gate; the packet carries the code identity but no deployer selection; no production stock route contract exists yet | Nothing | Its own track: six creations on Robinhood Chain and one on Base, once a route, a bridge adapter and the chain bindings are supplied |
| Revenue mesh | An offline foundation for USDC payment routes over CCTP into a launch's payment receiver | Nothing; every route is an unverified candidate | Admission requirements listed in its README |
| Website | Auction, token, launch, bid, portfolio and staking flows; public API and WebMCP tools; a local Base-fork lab | Serves in read-only preview until contract addresses are configured | Deployment addresses rendered from the contracts' deployed records |
| CLI | The public read-only `autolaunch` command, a local release candidate (0.1.0) | Not published to a registry | Publication once registry authority is established |
| Plugins | None; the folder marks the intended home | Nothing | A plugin would wrap the CLI and the public API |

## Work on it

| Component | Location | Check |
| --- | --- | --- |
| Website and API | [platform/](platform/README.md) | `cd platform && mix precommit && npm run typecheck && npm test` |
| Public CLI | [cli/](cli/README.md) | `cd cli && npm run check` |
| Base Revstake contracts | [contracts/v1/](contracts/v1/README.md) | `cd contracts/v1 && bin/gate.sh`, after the one-time setup in its README |
| Base Memestake contracts | [contracts/stocks/](contracts/stocks/README.md) | `cd contracts/stocks && bin/gate.sh`, after `bootstrap-deps.py` has filled `lib/` |
| Robinhood contracts | [contracts/robinhood/](contracts/robinhood/README.md) | `cd contracts/robinhood && bin/gate.sh` |
| Revenue mesh | [contracts/revenue-mesh/](contracts/revenue-mesh/README.md) | `cd contracts/revenue-mesh && forge fmt --check && forge build && forge test -vvv` |
| Agent plugins | [plugins/](plugins/README.md) | none; nothing is implemented yet |

`platform/contracts/` holds the runtime ABIs, the chain-contract manifest and the OpenAPI
contract the website consumes, not the Solidity sources. Web work needs only the platform
dependencies; the contract dependency closure (about 6 GB of git history) is fetched only for
contract work. Shared libraries remain separate repositories.

## Related products

| Product | Use it for | Website | Source |
| --- | --- | --- | --- |
| Regents | Agent identity, operations, staking and redemption | [regents.sh](https://regents.sh) | [Regents](https://github.com/regents-ai/regents) |
| Autolaunch | Token auctions and launch operations | [autolaunch.sh](https://autolaunch.sh) | [Autolaunch](https://github.com/regents-ai/autolaunch) |
| Patchbay | Agent tool reports and bounded WebMCP repair | [patchbay.help](https://patchbay.help) | [Patchbay](https://github.com/regents-ai/patchbay) |
| Techtree | Controlled Skill evaluations and verifiable results | [techtree.sh](https://techtree.sh) | [Techtree](https://github.com/regents-ai/techtree) |

Each product owns its API, CLI and authorization. A login, payment or published result on one
product does not grant permissions on another. Shared presentation lives in
[design-system](https://github.com/regents-ai/design-system); common Elixir libraries live in
[elixir-utils](https://github.com/regents-ai/elixir-utils).

## License

MIT — see [LICENSE](LICENSE). Dependencies under `contracts/v1/lib/` and `contracts/stocks/lib/` keep their own licenses.
