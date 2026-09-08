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

- Create expands two disabled planned options: Agent Revshare and Onchain Stock Pair.
- Creation, bids, payments, staking and account changes are disabled in the UI.
- `/create` and its descendants return 404 before a draft can mount. Auth callbacks,
  session/account APIs and other write-method requests are refused server-side.
- Existing browser sessions are not adopted, write-capable LiveComponents are not
  mounted, and auth/identity browser integrations are not initialized.
- The indexer and local market projection workers do not start in this mode. Stored
  public listings remain readable; the database itself is not changed or locked.

`Autolaunch.Prelaunch.read_only?/0` is fail-closed: missing or malformed configuration
keeps the site read-only. Only an explicit `config :autolaunch, prelaunch_read_only: false`
and a full application restart enable writes. Do not enable this before contract
addresses, chain configuration and real user journeys have been accepted. The two
planned sidebar options remain disabled independently; contract deployment does not
implement those products automatically. Deployment and migrations are separate approvals.

## Shared database namespace

`AUTOLAUNCH_DB_SCHEMA` defaults to `public` for ordinary development and tests.
The shared-database cutover selects `autolaunch_app` after importing a complete
schema and its migration ledger. With no existing Autolaunch source tables,
initialize the historical migrations in an isolated staging database first, then
relocate and preserve that whole schema. Regents' historical `autolaunch` schema
remains separate.

The release migration and status commands preserve this selection when switching
to `DATABASE_DIRECT_URL`. They read the selected ledger; migration refuses missing
historical entries. Do not run unprefixed `mix ecto.*` commands against the shared
database or regenerate migrations without reconciling the imported snapshot baseline.
Runtime grants, production cutover and contract activation remain separate work.

## Shared dependencies

From a directory containing sibling product repositories, acquire the shared libraries:

```sh
git clone https://github.com/regents-ai/design-system.git
git clone https://github.com/regents-ai/elixir-utils.git
git clone https://github.com/regents-ai/regents.git
```

The expected layout is `<workspace>/<product>/platform`,
`<workspace>/design-system/regent_ui`, `<workspace>/elixir-utils/` and
`<workspace>/regents/identity`.
From this component directory, `REGENT_DEPS_ROOT` may point at `<workspace>` when
it is elsewhere. Individual packages may instead be selected with `REGENT_UI_PATH`,
`REGENT_PRIVY_PATH` and `REGENT_IDENTITY_PATH`. Record all three repository commit IDs with check results;
release builds and isolated agent worktrees must use their selected immutable
revisions, rather than updating sibling checkouts during verification.
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
test/                   ExUnit suites and the Playwright browser suite
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
| `npm run test:browser` | Builds assets and runs the Playwright browser suite on port 4050. Needs the browser binary once: `npx playwright install chromium`. |
| `npm run test:budgets` | Enforces the built-asset size budgets. |
| `mix test.external` | Runs the Docker build-context test. Excluded from `mix precommit` because it needs a Docker daemon. |

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
  --env AUTOLAUNCH_DB_SCHEMA=autolaunch_app \
  --rm
fly deploy --app autolaunch-sh --config fly.toml \
  --image registry.fly.io/autolaunch-sh@sha256:<digest> --ha=false
```

`autolaunch-sh-migrations` has no service or standing machine and holds only
`DATABASE_DIRECT_URL`. `autolaunch-sh` must not hold that secret. The serving app holds
`DATABASE_URL`, `BASE_READ_RPC_URL`, `PHX_HOST`, and `SECRET_KEY_BASE`; the migration app
does not.

The image is built from `Dockerfile`. The context contains the application and
three selected shared packages; Docker installs `mix.lock` and `package-lock.json`
dependencies for the target Linux architecture. Host caches and native binaries
are excluded. The Fly configurations remain `fly.toml` (`autolaunch-sh`) and
`fly.staging.toml` (`autolaunch-staging`).

Run the assembler from `platform/` with package paths set to the selected
checkouts and each corresponding revision set to that checkout's exact commit.
Use clean dependency checkouts when preparing a release:

- `REGENT_PRIVY_PATH` and `REGENT_PRIVY_REVISION`: `elixir-utils/privy` and its repository commit.
- `REGENT_IDENTITY_PATH` and `REGENT_IDENTITY_REVISION`: `regents/identity` and its repository commit.
- `REGENT_UI_PATH` and `REGENT_UI_REVISION`: `design-system/regent_ui` and its repository commit.

```sh
bash scripts/build-release-context.sh /absolute/new-context arm64
docker build --platform linux/arm64 -f /absolute/new-context/Dockerfile -t autolaunch-candidate /absolute/new-context
```

Use `amd64` for an x86 Linux image. Assembly is local and does not need a sealed
supply directory; the image build needs network access for locked packages and
build tools. `BUILD-INPUTS.txt` records shared revisions and lockfile hashes.
Existing destinations are refused, so interruption or a repeated command cannot
remove an earlier context. Build and run the exact image before release; local
source tests alone do not verify Linux native dependencies or production sign-in.

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

`Autolaunch.DatabaseConfig` checks the shape of both database URLs and refuses a deployment
whose role is unset or unknown. What it does not yet check is which hosts a role may point at:
the two Fly applications and their database hostnames do not exist until they are created, so
the per-role host allowlist is an obligation of the deployment unit and is not in this
repository yet.

## Shared private profile

`/profile` uses the shared Regent UI and Regents-owned Ash identity domain.
The private `/api/v1/profile` contract provides `GET`, `PATCH`, and `POST /sync`;
the product CLI and browser WebMCP use the same actions and response schema.
Personal X verification comes from signed Privy evidence. Product sessions,
permissions and existing payout identities remain product-owned.

Resolve `REGENT_IDENTITY_PATH`, `REGENT_PRIVY_PATH` and `REGENT_UI_PATH` to the
recorded dependency snapshots for isolated work. Run `mix assets.build` after
changing a shared package. All deployments must use one Privy application and
one PostgreSQL destination before profiles can be shared between sites.
Regents owns the explicit identity migration; consumers do not run it on startup.
Do not repoint existing databases or replay migration histories: legacy identity
mappings, schema collisions and a recovery copy require a separate verified cutover.
See the identity package README and CLI private-profile contract for proof handling.
