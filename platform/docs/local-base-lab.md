# Local Base-fork lab

The lab is the current site running against an isolated Anvil fork of Base (chain 31337)
that carries a locally deployed copy of the contract graph, so the launch, auction and bid
flow can be tried with test assets. Only those two paths, launch and bid, read from and send
to the fork; in the default chain mode (`AUTOLAUNCH_CHAIN_MODE=base`, see
[fork-preview.md](fork-preview.md) for the hosted `fork` mode) the site refuses a fork
endpoint that is not a loopback URL answering as chain 31337. Everything else on a lab site
is labelled rather than switched: the REGENT facts panel and
the Buy, Chart, Stake and Redeem links say they are public Base mainnet, subject staking and
payments show an explicit unavailable state, and treasury evidence is reported as unavailable
instead of drawn from the test fixture. Every page of a lab site carries the line "Local Base
fork · test assets · no mainnet value · launches and bids only", ending in "sign in with
Privy" when real sign-in is configured (below) and "sign-in unavailable" otherwise
(`Autolaunch.ChainMode.label/0` names the fork; a hosted preview reads "Preview on a Base fork").

## Pieces

| Piece | Where | What it does |
| --- | --- | --- |
| Controller | `contracts/v1/bin/local-base-lab.py`, run from `contracts/v1` | Starts Anvil as a fork of Base, deploys the graph, funds wallets, mines to auction milestones, reports status, stops Anvil |
| Run record | `contracts/v1/reports/generated/local-base-lab/state.json` | Anvil PID, RPC URL, head block at start, local addresses; ignored by Git |
| Site config | `contracts/v1/reports/generated/local-base-lab/site-config.json` | `rpc_url`, `chain_id`, thirteen `addresses`, nine `abis`; the file `AUTOLAUNCH_LAB_CONFIG` names. An optional `public_rpc_url` (`https://` only) is the door wallets add as chain 31337; without it wallets are given the loopback `rpc_url` |
| Site integration | `Autolaunch.Lab`, `Autolaunch.LabMarketFeed`, `Autolaunch.LabProjection`, `Autolaunch.LabBidChainClient` | Validates the config, reads the fork every second, projects launched auctions into the database, verifies bids against the fork |

## Starting a fresh lab

The controller needs Foundry (`anvil`, `forge`, `cast`) and the read-only public Base RPC
`https://mainnet.base.org` (chain 8453) as its upstream. It checks that the upstream answers
as 8453 and that the Anvil it starts answers as 31337 on a loopback address; the upstream is
only ever read.

```sh
cd contracts/v1
REGENT_BASE_RPC_URL=https://mainnet.base.org python3 bin/local-base-lab.py start
python3 bin/local-base-lab.py status
```

`start --fork-block N` pins the fork block. Other commands, all read from the run record:
`fund`, `advance`, `pace`, `status [--auction ADDR]`, `stop`. Anvil mines only when something
is sent, so `advance` or `pace` moves an auction through its milestones.

## Running the site from this checkout

Run everything from `platform/` in the test environment. It gives the site a partition
database of its own, a plain connection pool and HTTP on `PORT`. Sign-in is either off (the
fixture verifier, which has no interactive login) or real Privy, as chosen below.
Strip any ambient database URLs, and point Mix at the sibling dependency checkouts with
`REGENT_DEPS_ROOT` (the directory that holds `design-system`, `elixir-utils` and `regents`).

Build once:

```sh
cd platform
env -u DATABASE_URL -u DATABASE_DIRECT_URL MIX_ENV=test \
    REGENT_DEPS_ROOT=/absolute/path/to/repos \
    sh -c 'mix deps.get && npm ci --ignore-scripts && mix compile && mix assets.setup && mix assets.build'
```

Start the site (this example uses the partition `_lab`, so the database is
`autolaunch_lab_test`). A fresh disposable partition needs its tables as well as the
database: `mix ecto.create` alone creates an empty database, so prepare a new partition
with the ordinary Ash setup, scoped to that partition, before the first start:

```sh
env -u DATABASE_URL -u DATABASE_DIRECT_URL MIX_ENV=test \
    REGENT_DEPS_ROOT=/absolute/path/to/repos MIX_TEST_PARTITION=_lab mix ash.setup
```

Run it only against a partition of your own. Never drop, recreate or replay migrations on
a database another run may own; an existing lab database, such as the one a recovered run
already uses, is reused as it is.

```sh
cd platform
env -u DATABASE_URL -u DATABASE_DIRECT_URL MIX_ENV=test \
    REGENT_DEPS_ROOT=/absolute/path/to/repos \
    MIX_TEST_PARTITION=_lab PORT=4050 \
    AUTOLAUNCH_BROWSER_TEST=1 AUTOLAUNCH_DB_POOL_SIZE=3 \
    PRIVY_APP_ID=browser-test-public-id \
    AUTOLAUNCH_LAB_CONFIG=/absolute/path/to/contracts/v1/reports/generated/local-base-lab/site-config.json \
    AUTOLAUNCH_FORK_RUN_ID=<run label> \
    mix phx.server
```

| Variable | Meaning |
| --- | --- |
| `AUTOLAUNCH_LAB_CONFIG` | Absolute path of `site-config.json`; development and test only in `base` chain mode, required in `fork` chain mode |
| `AUTOLAUNCH_FORK_RUN_ID` | A label for this run, required alongside the config; it travels in every envelope's lab binding |
| `PORT` | The port to serve on (test default 4050) |
| `AUTOLAUNCH_DB_POOL_SIZE` | Database connections for this site (default 10); a long-lived lab site should ask for a few, such as 3, because several test servers share one local PostgreSQL |
| `AUTOLAUNCH_BROWSER_TEST=1` | Test environment only: serve HTTP and use a plain connection pool instead of the sandbox |
| `PRIVY_APP_ID` | Public Privy app id. Without real sign-in any placeholder such as `browser-test-public-id` will do; with it, the real id |
| `MIX_TEST_PARTITION` | Names the database `autolaunch<partition>_test` |

Then check `http://127.0.0.1:4050/`, `/auctions`, `/create` and `/api/v1/auctions`.

While a lab config is set, the test environment does not install the subject-wallet and
launch fixture clients: launch and bid resolve to their lab clients and answer from the fork,
subject-wallet preparation stays unavailable, the treasury fixture remains for the launch and
bid flows while every treasury panel reports its evidence as unavailable, and the production
indexer stays off.

### Sign-in on a lab site

Without further configuration a lab site is for public browsing: the test environment
verifies sessions with `Autolaunch.TestPrivyVerifier`, which has no interactive login, so the
notice line ends in "sign-in unavailable". Pressing Sign in with a placeholder app id reports
"Sign in couldn't start" and `/profile` offers its Sign in button; neither waits forever.

Real Privy sign-in is switched on explicitly, with three more inputs, none of them secret:

```sh
AUTOLAUNCH_LAB_AUTH=privy \
PRIVY_APP_ID=<the Privy app id> \
PRIVY_VERIFICATION_KEY="$(cat /absolute/path/to/privy-verification-keys.pem)" \
... mix phx.server
```

| Variable | Meaning |
| --- | --- |
| `AUTOLAUNCH_LAB_AUTH=privy` | Test environment only. Selects the production verifier `Autolaunch.Privy`, admits `http://localhost:PORT` as a site origin alongside `http://127.0.0.1:PORT`, and names `localhost` as the site host. The boot stops if `AUTOLAUNCH_LAB_CONFIG` or either input below is missing: explicit real sign-in never falls back to the fixture verifier |
| `PRIVY_APP_ID` | The real public app id of the Privy application |
| `PRIVY_VERIFICATION_KEY` | The application's public ES256 verification keys as PEM blocks, one after another in this one variable (at most four). Privy publishes them at `https://auth.privy.io/api/v1/apps/<app id>/jwks.json`; the dashboard shows the current one. During rotation, configure the published keys together. Sign-in and the shared profile API (`/api/v1/profile`) independently verify each token against the same bounded configured set through `RegentPrivy`; single-key configuration remains supported |

Open the site at `http://localhost:4050`, the origin the Privy application allows, not at
`127.0.0.1`. Sign in, `/profile`, the shared profile API and sign out then run through the
production verifier and session boundaries exactly as on the public site: the browser's
Privy state never establishes a session by itself, a session is written only after the
token pair verifies on the server, and a provider that is not ready or cannot load never
revokes one. Test tokens are not accepted on such a site. Signed out, a person can still use
the auction pages, the live panel and the public API; `/create` explains that it needs a
sign-in and keeps the visitor on the page for after it.

Bridge import and provider readiness each have a bounded startup window. A failed
provider is unmounted; retries construct a new provider rather than reuse dead
callbacks. These failures preserve the local session. Only explicit actions show
failure feedback; passive reconciliation stays silent.

## Chain state, restarts and recovery

- **Restarting only the website is safe.** The site reads the same `site-config.json`,
  connects to the same Anvil and database, and the market feed picks the fork up where it is.
- **Anvil keeps its chain in memory.** A plain `stop`, a crash or a new `start` loses every
  local block. To carry a fork across a restart, snapshot it first with `anvil_dumpState`
  (or run Anvil with `--dump-state PATH --state-interval 60`), then start the replacement with
  the same `--fork-url`, `--fork-block-number` and `--chain-id 31337` plus
  `--load-state PATH`. Compare block hashes and contract code before stopping the original;
  the recovery in September 2026 matched on every check.
- **A fresh lab is a fresh database.** After a new `start`, run the site against a new
  disposable partition prepared with `mix ash.setup` as above, holding no auctions from an
  earlier fork. Do not drop or migrate the database of an existing run.

## Limits

- The lab's create and bid flow uses its explicit local treasury binding, not production
  Safe verification; nothing here changes production authorization.
- The market feed logs nothing when a poll fails.
- Real Privy sign-in against a lab site needs a person with a wallet in a real browser; no
  automated check signs in.
