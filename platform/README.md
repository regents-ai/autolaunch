# Autolaunch

[![Elixir 1.19](https://img.shields.io/badge/elixir-1.19-lightgrey)](https://elixir-lang.org)
[![Phoenix 1.8](https://img.shields.io/badge/phoenix-1.8-lightgrey)](https://www.phoenixframework.org)
[Ash](https://ash-hq.org)
[![PostgreSQL 14](https://img.shields.io/badge/postgres-14-lightgrey)](https://www.postgresql.org)

Autolaunch is the Regents Labs site at autolaunch.sh: the place where a token auction is
created, bid on, and followed. It is a Phoenix, LiveView and Ash application with its own
PostgreSQL repository. The application is released separately from the other products.

The checkout implements auction/token pages, launch and bid flows, Privy sign-in,
portfolio views, a public JSON API and matching browser-tool adapters. See the
[public API/WebMCP contract](docs/public-webmcp.md) and [CLI](../cli/README.md).
An implemented route does not establish a deployed or activated mainnet launch;
the contract gates and release configuration remain authoritative.

## Prelaunch read-only mode

The website defaults to a read-only preview before contract deployment. Explore,
public records, search, filters and the public read APIs remain available. The
existing bid-quote POST is a read-only calculation and remains available too.

- The Create button is shown disabled, titled "Available after contract deployment".
- Creation, bids, payments, staking and account changes are disabled in the UI.
- `/create` and its descendants return 404 before a draft can mount. Auth callbacks,
  session/account APIs and other write-method requests are refused server-side.
- Existing browser sessions are not adopted, write-capable LiveComponents are not
  mounted, and auth/identity browser integrations are not initialized.
- The indexer and local market projection workers do not start in this mode. Stored
  public listings remain readable; the database itself is not changed or locked.

`Autolaunch.Prelaunch.read_only?/0` is fail-closed: missing or malformed configuration
keeps the site read-only. Only `AUTOLAUNCH_LAUNCHES_OPEN=true` (or fork chain mode) and a full
application restart enable writes; any other value of that variable stops the boot. Do not enable this before contract
addresses, chain configuration and real user journeys have been accepted. The two
planned sidebar options remain disabled independently; contract deployment does not
implement those products automatically. Deployment and migrations are separate approvals.

## Chain mode

`AUTOLAUNCH_CHAIN_MODE` selects the chain a build runs against (`Autolaunch.ChainMode`):

| Value | What it is |
| --- | --- |
| `base` (default when unset) | Real Base. Exactly the behaviour above: production is read-only until the explicit configuration change, and the lab configurations are refused in production. |
| `fork` | A hosted Base fork (chain 31337) carrying the lab contract graph, for a public preview with test assets and no mainnet value. Admitted in every environment, production included. Both lab configurations are required, `prelaunch_read_only` resolves to `false` without any script, the Base log ledger stays off, both lab market feeds run, and the test-funds faucet applies a per-wallet, per-asset cooldown. |

Any other value stops the boot. The fork mode's two RPC doors, its environment, its
faucet cooldown and how a preview image is built are in [docs/fork-preview.md](docs/fork-preview.md).

## Database schema

Every Autolaunch table, sequence and the migration ledger live in the
`autolaunch_app` schema of the database, in every environment; the shared
production database holds other products' tables beside it. Migrations run under
that prefix and never name a schema themselves. `mix autolaunch.schema.create`
creates the schema on a freshly created database (the `setup` and `test` aliases
run it between creating the database and migrating), and the release's
`/app/bin/migrate` creates it the same way, so a new database needs no separate
initialisation. Regents' identity tables live in their own schema and are
installed by `mix autolaunch.identity.migrate` locally.

## Shared dependencies

Shared Regent libraries come from GitHub: `mix.exs` pins each one to an exact commit
of `elixir-utils`, `design-system` or `regents`, and `mix deps.get` fetches them. To move
a pin, change its ref at the top of `mix.exs` and run `mix deps.update <name>`.
`make check-required-fixes` from the repository root checks every pin against
ash-template's list of required fixes (it needs `gh auth login`).
Do not clone recursive Solidity submodules for a web-only change.

## Quickstart

You need Erlang, Elixir, Node, and PostgreSQL at the versions pinned in `.tool-versions`, and
Foundry's `cast` for checks that exercise chain tooling. Run the following from `platform/`.

```bash
mix setup
mix phx.server
```

The site is then at `http://localhost:4050`. `mix setup` fetches dependencies, runs
`npm ci` against the platform lockfile (React, Privy, and the TypeScript
tooling the browser bundle needs), creates the `autolaunch_dev` database on loopback
PostgreSQL, and builds the assets. A clean checkout can run `npm ci` on its own
before `npm run typecheck` or `npm test`.

## Repository layout

```text
lib/autolaunch/         Ash domains, the repository, the database configuration and the
                        release commands
lib/autolaunch_web/     Endpoint, router, layouts, controllers
contracts/              The OpenAPI contract; the chain-contract manifest and runtime ABIs
config/                 Compile-time and runtime configuration
assets/                 TypeScript and CSS, built with esbuild
priv/                   Migrations, static assets, generated resource snapshots
core_tests/             The kept Elixir and JavaScript cases (see core_tests/README.md)
scripts/                The release build-context assembler
rel/                    Release overlays: the migrate and pending-migrations commands
```

## Checks

Use the checks appropriate to the changed component. The full platform gate is:

```bash
mix precommit
npm run typecheck
npm test
```

`mix precommit` compiles with warnings as errors, checks unused dependency locks and
formatting, runs Credo in strict mode and Sobelow, holds the compile-connected `xref` graph
under its limit, runs the test suite with warnings as errors, and verifies the Ash codegen is
up to date.

| Command | What it does |
| --- | --- |
| `npm run typecheck` | Type-checks the TypeScript assets. |
| `npm test` | Runs the Vitest unit suite. |

The test database name carries whatever `MIX_TEST_PARTITION` holds, just before its `_test`
ending. Setting it is required, not advisory, whenever more than one test run can happen on a
machine: every writer and every working tree gives it its own value, an underscore followed by
a short id, so that the runs use separate databases. `MIX_TEST_PARTITION=_regent_uiq_2` gives
the database `autolaunch_regent_uiq_2_test`.

## Local Base-fork lab

The site can run against an isolated Anvil fork of Base (chain 31337) that carries a locally
deployed copy of the contract graph, so the create, launch, auction and bid flow can be tried
with test assets and no mainnet value. The controller, the environment the site needs, the
run commands, how to switch on real Privy sign-in for the lab site, and the restart and
recovery rules are in [docs/local-base-lab.md](docs/local-base-lab.md).

The Stocks lab extends that fork with the Stocks launchpad, fixture stock tokens and routes.
Set `AUTOLAUNCH_BASE_STOCKS_DEPLOYMENT=/abs/path/stocks-site-config.json` alongside the Base
description variables, in every environment (it is refused without `AUTOLAUNCH_BASE_DEPLOYMENT`
and must name the same Base description). This turns on `/create/stocks`, USDC
bids on Stocks auctions, the Stocks market feed and the test-funds panel. Details are in
[docs/stocks.md](docs/stocks.md). The same two files, with the fork's private and public RPC
doors, drive a hosted preview in `fork` chain mode ([docs/fork-preview.md](docs/fork-preview.md)).

## Protected paths

These paths carry the boundary between the site and money. A change to any of them is a
protected change: it needs its own review and is never edited as a side effect of other work.

```text
contracts/chain-contracts.yaml  the chain-contract manifest
priv/repo/migrations/           applied schema history, never rewritten
lib/autolaunch/accounts/        identity and sign-in
lib/autolaunch/chain/           chain reads and the addresses they use
lib/autolaunch/*_actions.ex     the wallet boundaries
```

The `*_actions.ex` files are the wallet boundaries: they build what a person's wallet is asked
to sign. Nothing else may build a transaction.

## Deployment

> [!WARNING]
> Database migrations run from the separate `autolaunch-sh-migrations` Fly app, never
> from a serving machine. Every deployment and migration must name its venue in `AUTOLAUNCH_DEPLOYMENT_ROLE`
> (`production` or `staging`); boot stops before any database URL is read if it does not.
> Production boot also fails unless `PHX_HOST` and a 64-byte `SECRET_KEY_BASE` are set.
> `/app/bin/pending-migrations` reports what a deployed database and the release image
> disagree about, without applying anything. Confirm the target and its secrets before
> running a deploy.

Run the exact candidate image once in the migration app, then deploy that same digest to
the serving app:

```sh
fly machine run registry.fly.io/autolaunch-sh:<revision-tag> /app/bin/migrate \
  --app autolaunch-sh-migrations \
  --region iad \
  --vm-memory 1024 \
  --env AUTOLAUNCH_DEPLOYMENT_ROLE=production \
  --rm
fly deploy --app autolaunch-sh --config fly.toml \
  --image registry.fly.io/autolaunch-sh@sha256:<digest> --ha=false
```

`autolaunch-sh-migrations` has no service or standing machine and holds only
`DATABASE_DIRECT_URL`. `autolaunch-sh` must not hold that secret. The serving app holds
`DATABASE_URL`, `BASE_READ_RPC_URL`, `PHX_HOST`, and `SECRET_KEY_BASE`; the migration app
does not.

The image is built from `Dockerfile` with the repository root as its context. Docker
installs `mix.lock` and `package-lock.json` dependencies, including the pinned shared
libraries from GitHub, for the target Linux architecture. Host caches and native binaries
are excluded. The Fly configurations remain `fly.toml` (`autolaunch-sh`) and
`fly.staging.toml` (`autolaunch-staging`); `fly.preview.toml` (`autolaunch-preview`) and
`Dockerfile.preview` describe the fork preview ([docs/fork-preview.md](docs/fork-preview.md)).

The Platform GitHub workflow compiles, checks and tests the application and builds the
Linux release image (without pushing) whenever application or blog files change.

```sh
docker build --platform linux/arm64 -f platform/Dockerfile -t autolaunch-candidate .
```

Run it from the repository root, and use `amd64` for an x86 Linux image. The build
needs network access for locked packages and build tools. Build and run the exact
image before release; local source tests alone do not verify Linux native
dependencies or production sign-in.

### Creator connections and bid activity

The creator form connects X through the existing X OAuth configuration, GitHub
through the configured Privy application, and ENS through an Ethereum read.
ENS must be controlled by and resolve to the signed-in wallet. The optional
`:ens_rpc_url` application setting defaults to `https://ethereum.publicnode.com`.
No resolver write or wallet signature is made to connect an ENS name.

Auction and token lists filter these verified connections in PostgreSQL before
cursor pagination. Selected connections combine with AND. Auction volume ordering
uses confirmed bid commitments valued at the latest available USD price; it is
not net funds raised or a historical execution price. Unknown or incomplete totals
sort last. Closing time is estimated from the contract's block clock.

Migration `20260924134726_auction_activity` adds the bid projection and indexed
auction totals. When the site is open and database startup is enabled, a bounded
reader updates those rows and notifies LiveViews. Separate live and historical
queues advance persisted cursors without a lifetime auction cap. The footer shows
up to 20 confirmed bids from the last hour, with pause and reduced-motion support;
it stays absent when none are available. A changed cursor block invalidates that
auction's derived bids for replay. This reader does not submit transactions.

See [the candidate handoff](docs/astra-user-journeys-2026-09-24.md) for local
verification and the remaining release checks.

### Environment

| Variable | Required | What it is for |
| --- | --- | --- |
| `AUTOLAUNCH_DEPLOYMENT_ROLE` | Always | The venue: `production` or `staging`. |
| `DATABASE_URL` | Serving app only | The PostgreSQL URL the web boot connects with. |
| `DATABASE_DIRECT_URL` | Migration app only | The direct PostgreSQL URL the migrate command connects with. Never install it on the serving app. |
| `SECRET_KEY_BASE` | Serving app only | At least 64 bytes. |
| `PHX_HOST` | Serving app only | The public hostname the site generates URLs for. |
| `BASE_READ_RPC_URL` | Serving app only | The Base endpoint the site reads one canonical `safe` block through. |
| `PORT` | Optional | The HTTP port; 4000 by default. |
| `AUTOLAUNCH_CHAIN_MODE` | Optional | `base` (default) or `fork`; see "Chain mode" above and [docs/fork-preview.md](docs/fork-preview.md) for the variables fork mode adds. |

`Autolaunch.DatabaseConfig` refuses an unset or unknown deployment role. Production
serving credentials must target `regents_prod` on `regents-platform-prod`, using
`autolaunch-runtime`; wrong-cluster, wrong-database and administrative runtime logins
fail before connecting. `DATABASE_DIRECT_URL` on the serving process is also a boot
error. Migration execution remains separate and rejects the PgBouncer endpoint,
because migrations use session-level advisory locks.

The serving connection currently uses the direct endpoint with Ecto's bounded
client pool. TLS verifies both the certificate chain and hostname. Connections
rotate after a randomized 8–9 minute lifetime once idle, with 15-second idle
checks, exponential reconnect backoff, and bounded TCP/TLS handshakes. Serving
sessions identify themselves as `autolaunch-web`; statement, lock and
idle-in-transaction timeouts are separate from migration settings. These limits
do not authorize retrying an interrupted write transaction. PgBouncer connections
do not send these arbitrary startup session settings: transaction-pooled server
settings require a separate provider/pooler review before switching endpoints.

`/healthz` is database readiness, not a process-only heartbeat: it checks access
to the configured auction relation without reading rows. An unavailable database,
missing relation or exhausted query deadline returns HTTP 503 with no internal
error details. The response is not cacheable. Fly's existing health check uses
this route. Prelaunch write, authentication, indexer and automation gates remain
unchanged.

The site's health numbers (bid and trade delay, blocks behind per indexer, oldest
waiting job, chain requests with no answer, database connection wait and wallet
sends not made or not confirmed) are listed in `AutolaunchWeb.Telemetry`. In
production they are served at `/metrics` on port 9091, which `fly.toml`'s `[metrics]`
section names for Fly's managed Prometheus. That port is not a Fly service, so it is
reachable only over Fly's private network; the public site has no `/metrics` page.
Fly Sentinel reads them from Prometheus under its site health set.

## Shared private profile

`/profile` uses the shared Regent UI and Regents-owned Ash identity domain.
The private `/api/v1/profile` contract provides `GET`, `PATCH`, and `POST /sync`;
the product CLI and browser WebMCP use the same actions and response schema.
Personal X verification comes from signed Privy evidence. Product sessions,
permissions and existing payout identities remain product-owned.

Run `mix assets.build` after moving a shared library's pin. All deployments must use one Privy application and
one PostgreSQL destination before profiles can be shared between sites.
Regents owns the explicit identity migration; consumers do not run it on startup.
Do not repoint existing databases or replay migration histories: legacy identity
mappings, schema collisions and a recovery copy require a separate verified cutover.
See the identity package README and CLI private-profile contract for proof handling.
