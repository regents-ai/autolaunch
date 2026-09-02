# Autolaunch

[![Elixir 1.19](https://img.shields.io/badge/elixir-1.19-lightgrey)](https://elixir-lang.org)
[![Phoenix 1.8](https://img.shields.io/badge/phoenix-1.8-lightgrey)](https://www.phoenixframework.org)
[![Ash 3.29](https://img.shields.io/badge/ash-3.29-lightgrey)](https://ash-hq.org)
[![PostgreSQL 14](https://img.shields.io/badge/postgres-14-lightgrey)](https://www.postgresql.org)

Autolaunch is the Regents Labs site at autolaunch.sh: the place where a token auction is
created, bid on, and followed. It is a Phoenix, LiveView and Ash application with its own
PostgreSQL database, deployed separately from the rest of the platform.

> [!NOTE]
> This is the repository scaffold. It carries the application skeleton, the check suite, and
> the deployment package. The Autolaunch domain, sign-in, pages, and chain reads arrive in the
> units that follow, and the home page here is a placeholder they replace.

## Quickstart

You need Erlang, Elixir, Node, and PostgreSQL at the versions pinned in `.tool-versions`, and
Foundry's `cast` on the path for the chain work later units add.

```bash
mix setup
mix phx.server
```

The site is then at `http://localhost:4050`. `mix setup` fetches dependencies, installs the
npm packages, creates the `autolaunch_dev` database on loopback PostgreSQL, and builds the
assets.

## Repository layout

```text
lib/autolaunch/         Ash domains, the repository, the database configuration and the
                        release commands
lib/autolaunch_web/     Endpoint, router, layouts, controllers
contracts/              The OpenAPI contract; the chain-contract manifest joins it later
config/                 Compile-time and runtime configuration
assets/                 TypeScript and CSS, built with esbuild
priv/                   Migrations, static assets, generated resource snapshots
test/                   ExUnit suites and the Playwright browser suite
scripts/                The release build-context assembler
rel/                    Release overlays: the migrate and pending-migrations commands
```

## Checks

All three repository acceptance commands must pass before a change is proposed:

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

## Protected paths

These paths carry the boundary between the site and money. A change to any of them is a
protected change: it needs its own review and is never edited as a side effect of other work.

```text
contracts/                      the HTTP contract and, once it lands, the chain manifest
priv/repo/migrations/           applied schema history, never rewritten
lib/autolaunch/accounts/        identity and sign-in
lib/autolaunch/chain/           chain reads and the addresses they use
lib/autolaunch/launch_actions.ex
lib/autolaunch/bid_actions.ex
lib/autolaunch/subject_wallet_actions.ex
```

The three `*_actions.ex` files are the wallet boundaries: they build what a person's wallet is
asked to sign. Nothing else may build a transaction.

## Deployment

> [!WARNING]
> Deploying runs `/app/bin/migrate` as its release command, so a deploy writes database
> migrations. Every deployment must name its venue in `AUTOLAUNCH_DEPLOYMENT_ROLE`
> (`production` or `staging`); boot stops before any database URL is read if it does not.
> Production boot also fails unless `PHX_HOST` and a 64-byte `SECRET_KEY_BASE` are set.
> `/app/bin/pending-migrations` reports what a deployed database and the release image
> disagree about, without applying anything. Confirm the target and its secrets before
> running a deploy.

The image is built from `Dockerfile`, whose parent build context is assembled offline by
`scripts/build-release-context.sh` from a sealed supply directory. The Fly configuration lives
in `fly.toml` (`autolaunch-sh`) and `fly.staging.toml` (`autolaunch-staging`).

| Variable | Required | What it is for |
| --- | --- | --- |
| `AUTOLAUNCH_DEPLOYMENT_ROLE` | Always | The venue: `production` or `staging`. |
| `DATABASE_URL` | Always | The pooled PostgreSQL URL the web boot connects with. |
| `DATABASE_DIRECT_URL` | Always | The direct PostgreSQL URL the migrate command connects with. |
| `SECRET_KEY_BASE` | Always | At least 64 bytes. |
| `PHX_HOST` | Always | The public hostname the site generates URLs for. |
| `PORT` | Optional | The HTTP port; 4000 by default. |

`Autolaunch.DatabaseConfig` checks the shape of both database URLs and refuses a deployment
whose role is unset or unknown. What it does not yet check is which hosts a role may point at:
the two Fly applications and their database hostnames do not exist until they are created, so
the per-role host allowlist is an obligation of the deployment unit and is not in this
repository yet.
