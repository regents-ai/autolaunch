# Autolaunch

Launch and follow token auctions on Base. Autolaunch combines a Phoenix/Ash
website, a standalone CLI and the contracts that define each auction and its
revenue distribution.

[Website](https://autolaunch.sh) · [CLI](cli/README.md) · [API and WebMCP](platform/docs/public-webmcp.md) · [Star on GitHub](https://github.com/regents-ai/autolaunch)

## Start here

- **Browse or build the website:** [platform setup and checks](platform/README.md).
- **Use an agent or terminal:** the [CLI](cli/README.md) exposes public auction,
  token and quote operations as JSON. These commands do not sign or submit a bid.
- **Review the contracts:** start with the [contracts overview](contracts/README.md),
  then [SPEC.md](contracts/v1/SPEC.md) and the [audit guide](contracts/v1/docs/audit/README.md).
  Contract release status is independent of whether the website renders successfully.
- **Build a plugin:** none exists yet; [plugins/](plugins/README.md) names the surfaces
  one would wrap.

The website and public CLI are implemented in this checkout. The CLI package is a
local release candidate; registry publication is not implied. Production activation,
private profile adoption and database cutover have separate verification requirements.

| Component | Location | Checks |
| --- | --- | --- |
| Phoenix/Ash website and API | [platform/](platform/README.md) | `cd platform && mix precommit` |
| Standalone public CLI | [cli/](cli/README.md) | `cd cli && npm run check` |
| Frozen V1 auction contracts | [contracts/v1/](contracts/v1/README.md) | `cd contracts/v1 && bin/gate.sh` |
| Revenue routing contracts | [contracts/revenue-mesh/](contracts/revenue-mesh/README.md) | `cd contracts/revenue-mesh && forge test --offline` |
| Agent plugins | [plugins/](plugins/README.md) | none; nothing is implemented yet |

`platform/contracts/` contains runtime ABIs and manifests consumed by the website, not the
Solidity sources. For web work, install only the platform dependencies; contract dependency
hydration belongs to contract work. Shared libraries remain independent repositories.

## Related products

| Product | Use it for | Website | Source |
| --- | --- | --- | --- |
| Regents | Agent identity, operations, staking and redemption | [regents.sh](https://regents.sh) | [Regents](https://github.com/regents-ai/regents) |
| Autolaunch | Token auctions and launch operations | [autolaunch.sh](https://autolaunch.sh) | [Autolaunch](https://github.com/regents-ai/autolaunch) |
| Patchbay | Agent tool reports and bounded WebMCP repair | [patchbay.help](https://patchbay.help) | [Patchbay](https://github.com/regents-ai/patchbay) |
| Techtree | Controlled Skill evaluations and verifiable results | [techtree.sh](https://techtree.sh) | [Techtree](https://github.com/regents-ai/techtree) |

Each product owns its API, CLI and authorization. A login, payment or published
result on one product does not grant permissions on another. Shared presentation
lives in [design-system](https://github.com/regents-ai/design-system); common Elixir
libraries live in [elixir-utils](https://github.com/regents-ai/elixir-utils).

## License

MIT — see [LICENSE](LICENSE). Dependencies under `contracts/v1/lib/` keep their own licenses.
