# Local Base-fork lab

This guide describes the historical v1 fork tooling. Its example allocations and
addresses are not the current launch terms. New launches use v2; see
[the contract map](../../contracts/README.md) for the deployed systems and mechanics.

The lab is the current site running against an isolated Anvil fork of Base (chain 31337)
that carries a locally deployed copy of the contract graph, so the launch, auction and bid
flow can be tried with test assets. Launching and bidding need `AUTOLAUNCH_LAUNCHES_OPEN=true`
(see "Prelaunch read-only mode" in [the platform README](../README.md)); without it a lab
site is read-only, lists what the fork holds and answers 404 on `/create`. Everything else
on a lab site is labelled rather than switched: the REGENT facts panel and
the Buy, Chart, Stake and Redeem links say they are public Base mainnet, subject staking and
payments show an explicit unavailable state, and treasury evidence is reported as
unavailable. Every page of a lab site carries the line
"Local Base fork · test assets · no mainnet value" (`Autolaunch.Lab.label/0` names the fork)
at the top of the screen, ending in "sign in with Privy" on an open site.

## Pieces

| Piece | Where | What it does |
| --- | --- | --- |
| Controller | `contracts/v1/bin/local-base-lab.py`, run from `contracts/v1` | Starts Anvil as a fork of Base, deploys the graph, funds wallets, mines to auction milestones, reports status, stops Anvil |
| Run record | `contracts/v1/reports/generated/local-base-lab/state.json` | Anvil PID, RPC URL, head block at start, local addresses; ignored by Git |
| Site config | `contracts/v1/reports/generated/local-base-lab/site-config.json` | `rpc_url`, `chain_id`, fourteen `addresses`, ten `abis`; the file `AUTOLAUNCH_BASE_DEPLOYMENT` names. An optional `public_rpc_url` (`https://` only) is the door wallets add as chain 31337; without it wallets are given the loopback `rpc_url`. The top level names the third Revstake factory's contracts, which new launches use. A `v2` section (`addresses` and `abis`, each of exactly `factory`, `strategy`, `hook` and `lp_locker`) names the second's own contracts where launches were made on it, and each launch is read through its own version's contracts. `contracts/stocks-v3/bin/ceremony.py site-config`, run from `contracts/revstake-v3`, writes it |
| Site integration | `Autolaunch.Lab`, `Autolaunch.AuctionMarket`, `Autolaunch.ChainHead`, `Autolaunch.LabProjection`, `Autolaunch.LabBidChainClient` | Validates the config, reads the fork every second, projects launched auctions into the database, verifies bids against the fork |

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

Run everything from `platform/` in the development environment. The site uses the local
database `autolaunch_dev`, serves HTTP on `PORT` and takes real Privy sign-in; it does not
start without the two Privy inputs below.

Build once:

```sh
cd platform
mix deps.get && npm ci --ignore-scripts && mix compile && mix assets.setup && mix assets.build
```

A database that does not exist yet needs its tables as well as the database: `mix db.setup`
creates `autolaunch_dev` and migrates it. Never drop, recreate or replay migrations on a
database another run may own; an existing database is reused as it is.

```sh
mix db.setup
```

Start the site:

```sh
cd platform
PORT=4050 \
AUTOLAUNCH_LAUNCHES_OPEN=true \
PRIVY_APP_ID=<the Privy app id> \
PRIVY_VERIFICATION_KEY="$(cat /absolute/path/to/privy-verification-key.pem)" \
AUTOLAUNCH_BASE_DEPLOYMENT=/absolute/path/to/contracts/v1/reports/generated/local-base-lab/site-config.json \
AUTOLAUNCH_BASE_DEPLOYMENT_ID=<run label> \
mix phx.server
```

| Variable | Meaning |
| --- | --- |
| `AUTOLAUNCH_BASE_DEPLOYMENT` | Absolute path of `site-config.json`, the Base deployment description, in every environment |
| `AUTOLAUNCH_LAUNCHES_OPEN=true` | Opens launching, bidding and the test-funds panel; without it the lab is read-only |
| `AUTOLAUNCH_BASE_DEPLOYMENT_ID` | A label for this deployment, required alongside the description; the Stocks admission scan reads a changed label as a new deployment |
| `PORT` | The port to serve on (default 4050) |
| `PRIVY_APP_ID` | The real public app id of the Privy application |
| `PRIVY_VERIFICATION_KEY` | The application's current public ES256 verification key as one PEM block. The Privy dashboard shows it, and Privy publishes it at `https://auth.privy.io/api/v1/apps/<app id>/jwks.json`. Sign-in and the shared profile API (`/api/v1/profile`) both verify each token against this key through `RegentPrivy` |

Then check `http://localhost:4050/`, `/auctions`, `/create` and `/api/v1/auctions`.

### Sign-in on a lab site

Open the site at `http://localhost:4050`, the origin the Privy application allows, not at
`127.0.0.1`. Sign in, `/account`, the shared profile API and sign out run through the
production verifier (`Autolaunch.Privy`) and session boundaries exactly as on the public
site: the browser's Privy state never establishes a session by itself, a session is written
only after the token pair verifies on the server, and a provider that is not ready or cannot
load never revokes one. Signed out, a person can still use the auction pages, the live panel
and the public API; `/create` explains that it needs a sign-in and keeps the visitor on the
page for after it.

Bridge import and provider readiness each have a bounded startup window. A failed
provider is unmounted; retries construct a new provider rather than reuse dead
callbacks. These failures preserve the local session. Only explicit actions show
failure feedback; passive reconciliation stays silent.

## Chain state, restarts and recovery

- **Restarting only the website is safe.** The site reads the same `site-config.json`,
  connects to the same Anvil and database, and each auction's reading job picks the fork up where it is.
- **A rewritten `site-config.json` needs a website restart.** The site reads each
  deployment description once, when it is first needed, and keeps it for as long as it runs.
- **Anvil keeps its chain in memory.** A plain `stop`, a crash or a new `start` loses every
  local block. To carry a fork across a restart, snapshot it first with `anvil_dumpState`
  (or run Anvil with `--dump-state PATH --state-interval 60`), then start the replacement with
  the same `--fork-url`, `--fork-block-number` and `--chain-id 31337` plus
  `--load-state PATH`. Compare block hashes and contract code before stopping the original;
  the recovery in September 2026 matched on every check.
- **A fresh lab keeps the same database.** The development environment has one database,
  `autolaunch_dev`, which still holds what an earlier fork projected into it. Do not drop or
  migrate the database of an existing run.

## Limits

- The lab's create and bid flow uses its explicit local treasury binding, not production
  Safe verification; nothing here changes production authorization.
- A pass that cannot read the fork is one warning line in the log, and is read again a minute later.
- Real Privy sign-in against a lab site needs a person with a wallet in a real browser.
