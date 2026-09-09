# Autolaunch Stocks: website, lab and evidence

Stocks is a separate launch mode next to Agent: a new token (NEW) auctioned for one admitted Base
stock token (STOCK) through the pinned CCA, then migrated into the official NEW/STOCK pool.
Product terms are in the September 8 brief (local planning) and the contract preset in
`contracts/stocks/README.md`. This page records what the website does, how the local Base-fork
lab runs it, and the evidence index.

## Routes and surfaces

| Surface | Path | Notes |
| --- | --- | --- |
| Stocks create | `/create/stocks` | Signed-in; one private Stocks draft per account (`stock_launch_drafts`), independent of the Agent draft. Three autosaving sections (token details, stock and auction terms, subject revenue and administrator), the fixed-terms list, then the wallet step. The "Create" menu in the rail links here when the site is not read-only. |
| Wallet step | `/create/stocks` | `Autolaunch.Stocks.LaunchActions` reviews the draft against the fork and writes one `launch(LaunchParams)` envelope (`stock_launch_operations`, one open per account). Review shows the derived start block and estimated close, the exact executable floor (largest multiple of 100 not above the entered price, at least 2^32+1), the required raise in the stock's base units, and the subject lane (zero address when off). Verification decodes `StockLaunchCreated`, checks it against `launches(id)` and `launchIdOfAuction`, stores `new_token`, `auction`, `launch_id` and projects the `Auction` row (`kind: :stocks`). |
| Auction list and detail | `/auctions`, `/auctions/:address`, `/api/v1/auctions` | Shared with Agent. `Auction.kind` is `:agent` or `:stocks`; the quote token fields carry the real currency (address, symbol, decimals) and the detail page states them. |
| Bid | auction page | Two forms side by side, never auto-switched: "Bid with STOCK" (allowance to Permit2, Permit2 allowance to the auction, `submitBid`) and, on Stocks auctions with the Stocks lab running, "Bid with USDC" (exact USDC allowance to the adapter, then `bidWithUsdc` with `minStockOut` = route estimate less 1% and a 15-minute deadline). Amounts and prices use the auction's own currency decimals. |
| Market feed | background | `Autolaunch.Stocks.LabMarketFeed` polls the fork every second, projects every `launches(id)` whose launcher is a wallet a site account holds into an `Auction` row, and refreshes state and clearing price of Stocks auctions from the auction contract and the launchpad lifecycle. |
| Test funds | `/create/stocks`, auction pages | Lab sites only; see below. |

The site prepares against the local lab only. Without `AUTOLAUNCH_STOCKS_LAB_CONFIG` the draft
page saves and validates, and the wallet step refuses with "Stock launches are not open on this
site." The stock decimals shown on the draft page come from the lab configuration; the review
uses the decimals the launchpad's `stockAdmission` records.

## Lab configuration

The Stocks lab extends a running Agent lab (`platform/docs/local-base-lab.md`). Run
`contracts/stocks/bin/local-stocks-lab.py deploy` from `contracts/stocks`; it reads the Agent
run record, installs the fixture stock tokens at the catalog addresses, deploys the Stocks
graph, admits the fixture routes, and writes
`contracts/v1/reports/generated/local-base-lab/stocks-site-config.json`:

```json
{
  "rpc_url": "http://127.0.0.1:PORT",
  "chain_id": 31337,
  "agent_lab_config": "/abs/path/site-config.json",
  "addresses": {
    "launchpad": "0x…", "hook": "0x…", "bid_adapter": "0x…",
    "usdc": "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913",
    "regent": "0x6f89bca4ea5931edfcb09786267b251dee752b07",
    "permit2": "0x000000000022d473030f116ddee9f6b43ac78ba3",
    "cca_factory": "0x000000001f26a0044baa66024e7b6599c61963f8",
    "pool_manager": "0x498581ff718922c3f8e6a244956af099b2652b2b",
    "position_manager": "0x7c5f5a4bbd8fd63184577525326123b519429bdc",
    "live_staking": "0xb027dc261636e30cbc0fe25b2f8e1ed273354ab5",
    "governance_safe": "0x9fa152b0eadbfe9a7c5c0a8e1d11784f22669a3e",
    "agent_factory": "0x…", "agent_strategy": "0x…"
  },
  "faucet": {
    "regent_holder": "0x9fa152b0eadbfe9a7c5c0a8e1d11784f22669a3e",
    "regent_amount": "1000000000000000000000",
    "stock_amount_units": "100",
    "usdc_holder": "0x…",
    "usdc_amount": "1000000000"
  },
  "stocks": [
    {"symbol": "AAPLc", "address": "0xb200000000000000000000c2e324d24d7eecd1fb", "decimals": 8,
     "route": "0x…", "fixture": true, "launch_admission": "fixture_admitted"}
  ],
  "abis": {"launchpad": [...], "hook": [...], "bid_adapter": [...], "route": [...], "auction": [...], "erc20": [...], "permit2": [...]}
}
```

Addresses are lowercase. The website refuses a file whose `rpc_url` is not a loopback URL answering
as chain 31337, whose `agent_lab_config` differs from the Agent lab it runs with, whose repeated
Agent addresses (`agent_factory`, `agent_strategy`, `regent`, `permit2`, `governance_safe`,
`cca_factory`, `pool_manager`, `position_manager`) differ from the Agent lab's, whose `stocks`
entries are not in `Autolaunch.Stocks.Assets`, or whose ABI set lacks a function or event the site
prepares against (`Autolaunch.Stocks.LabAbi.requirements/0`). The interface ABIs the site was
written against are pinned at `platform/contracts/abi/stocks-*.json` and registered in
`platform/contracts/chain-contracts.yaml` under `stocks_local_lab`.

Environment: `AUTOLAUNCH_STOCKS_LAB_CONFIG=/abs/path/stocks-site-config.json` alongside the
Agent lab variables. Development and test only; production refuses it.

## Faucet

Lab sites only, rendered as a "Test funds" panel on `/create/stocks` and on auction pages for a
signed-in account whose selected wallet the account holds. `Autolaunch.Stocks.Faucet` performs
one fork transaction per press using `anvil_impersonateAccount` on the RPC URL of a validated lab
configuration (loopback only) and refuses on a read-only site or without a lab:

- "Get 1,000 test REGENT": needs only the Agent lab; `transfer(wallet, 1000e18)` from the
  governance Safe's forked REGENT balance.
- "Get test STOCK" (one button per admitted stock): `mint(wallet, stock_amount_units × 10^decimals)`
  on the fixture token, sent from the governance Safe.
- "Get 1,000 test USDC": `transfer(wallet, usdc_amount)` from `faucet.usdc_holder`.

The holder's ETH is topped up on the fork when it cannot pay gas. Every press sends; the RPC's
own error text is reported on failure, the receipt is awaited, and the wallet's new balance is
shown. Nothing here signs with the user's wallet or touches mainnet. The `erc20` ABI in the
configuration must declare `approve`, `transfer`, `balanceOf`, `allowance`, `decimals` and the
`Approval` event; `mint` calldata is built from its fixed signature.

## Evidence index

Levels: `reported-existing`, `implemented-unverified`, `unit-proven`, `integrated-local`
(the local Base-fork lab with fixture stock tokens), `stock-integration-proven` (real Base-native
stock execution; not reachable on Anvil), `release-admitted`. Nothing below is
`stock-integration-proven` or `release-admitted`; every PROVISIONAL preset value in
`contracts/stocks/README.md` blocks admission until the founder confirms it.

The `integrated-local` rows were exercised on 9 September 2026 against the recovered Agent lab
fork (`http://127.0.0.1:58737`, chain 31337) with the Stocks graph deployed by
`contracts/stocks/bin/local-stocks-lab.py deploy` (launchpad `0xd0e57e59…3067`, hook
`0x4eb57aaf…e0cc`, adapter `0x97534a85…a38d`) and the site running from this worktree on port
4060 with the test verifier (account wallet `0x1111…1111`). The browser's part was played by
sending each prepared step's exact calldata from the impersonated signer on the fork, then
binding the hash and verifying through the same server code the wallet card calls.

| Reference | Level | Evidence |
| --- | --- | --- |
| P01 separate mode, Agent unchanged | integrated-local | Agent resources, actions and pages untouched except the shared `Auction.kind`, currency-neutral bid copy and the additive `kind`/`quote_token` API fields; Agent tests unchanged (`mix test`: 39 tests, the 2 `PrivySessionControllerTest` failures are pre-existing on `origin/main` and unrelated). |
| P02 exact STOCK identity | unit-proven | `Autolaunch.Stocks.Assets.fetch/2` resolves by chain and address; launchpad `admitStock`/`stockAdmission` (`contracts/stocks/test/StocksLaunchpadLaunch.t.sol`). |
| P03 pinned CCA, ~24 h schedule | unit-proven | `StocksPreset.t.sol`: 13 steps sum to 43,200 blocks and exactly 1e7 mps; fork lifecycle uses the real CCA factory. Block count PROVISIONAL. |
| P04 exact 80/20 | integrated-local | Launch #2 on the fork: `auction_inventory` 800,000,000e18, `migration_reserve` 200,000,000e18 read back from `StockLaunchCreated` by the site's verifier. |
| P05 no creator allocation, vesting, treasury | unit-proven | `LaunchParams` has no such fields; the review rejects injected ones (`launch_actions_test.exs`). |
| P07 direct STOCK bid and USDC→STOCK bid | integrated-local | Direct: token approval → Permit2 → `submitBid` confirmed (`onchain_bid_id` 1, 2.5 AAPLc; then 20 AAPLc). USDC: `approve(adapter)` → `bidWithUsdc` confirmed (`StockBidPlaced`, owner = signer, 50 USDC → 0.2173913 AAPLc). Both visible on `/portfolio`. |
| P08/P09/P10/P11 hook lanes and attribution | unit-proven + fork | `StocksFeeHook.t.sol` (17 tests: four swap forms × both orderings × subject on/off, conservation, bucket attribution by configuration version); fork lifecycle settles the REGENT bucket into the real `LIVE_STAKING` and a subject bucket into a real Agent splitter. Hook permission set differs from the brief's afterSwap-only wording, see "Open decisions". |
| P12 conversion outside swaps | unit-proven | `settle` is executor-only and the only path out; a failing settle reverts only itself. |
| P13 all-net-STOCK liquidity, retirement, locked LP | unit-proven + fork | `StocksLaunchpadMigrate.t.sol` (12 tests incl. fuzz over clearing prices, both orderings): full-range position plus one-sided STOCK position, both NFTs at `0x…dEaD`, dust 0 observed and bounded, unsold NEW retired; no principal path for either NFT. Fork: see "Migration" row. |
| P15 UI and CLI parity | integrated-local | `/api/v1/auctions` and the CLI now carry `kind` and `quote_token`; `cli`: `npm run check` (6 pass), `test:parity` (1 pass), `check:contract` (copy matches). The public CLI remains read-only by design; it does not sign. |
| STK-00 decision record | blocked | No Stocks decision record exists in this repository or the workspace; PROVISIONAL values are listed in `contracts/stocks/README.md`. |
| STK-01..09 contracts | unit-proven + fork | `forge test --fuzz-runs 64`: 68 passed; `FOUNDRY_PROFILE=fork forge test --fork-url http://127.0.0.1:58737`: 3 passed; Slither: no medium/high. `contracts/stocks/SECURITY.md` maps invariants to tests. |
| STK-10 Stocks draft (AT11) | unit-proven | `core_tests/elixir/autolaunch/stocks/launch_draft_test.exs`: another account can neither read nor update a draft. |
| STK-11 review envelope (AT09) | integrated-local | `launch_actions_test.exs` for the exact tuple; on the fork the prepared 772-byte calldata created launch #2 (`StockLaunchCreated` decoded, `launches(2)` and `launchIdOfAuction` cross-checked, `chain_verified`). |
| STK-11 subject lane off (AT06, §5.1) | unit-proven | Disabling the lane leaves the zero address in the params and no splitter bytes in the calldata. |
| STK-12 `/create/stocks` | integrated-local | `stocks_create_live_test.exs` (autosave; stock change clears amounts) plus a headless-browser pass over `/create/stocks`, `/auctions`, `/auctions/:id`, `/portfolio` on the lab site. |
| STK-13 market feed and listing | integrated-local | The feed projected launch #2 into an `Auction` row (`kind: stocks`, AAPLc, 8 decimals) within seconds and moved it `created → active` at the start block; `/api/v1/auctions` lists it with `quote_token`. |
| STK-14 faucet | integrated-local | REGENT (+1,000 from the Safe's forked balance), AAPLc (+100 fixture mint) and USDC (+1,000 from the Morpho holder) each landed in one press with the new balance read back. |
| Migration (STK-05 on the fork, observed by the site) | integrated-local | Launch #1 on the redeployed graph: 22.71739129 AAPLc raised across the three site bids; `advance --to migration` then `migrate --launch 1` → `Graduated`. `lpStockUsed` 2,271,739,129 = the whole raise (all net STOCK locked; <25% sold so the full-range position took it all and no one-sided position was needed), `lpNewUsed` ≈ 2.27M NEW, LP NFT 3017409 owned by `0x…dEaD`, 995,456,521.74 unsold NEW retired to `0x…dEaD`, launchpad holds 0 NEW and 0 STOCK. The site's feed moved the auction to `graduated` and `/api/v1/auctions` reports it. Bid claims after graduation are not yet exposed in the portfolio (see remaining work). |
| AT04, AT48 real stock assets | blocked | Base-native stock tokens carry `0xef` code Anvil cannot execute; the lab uses fixture ERC-20s at the exact catalog addresses. Issuer transfer policy, Permit2 behaviour and the real acquisition route are unproven. |
| AT47 manual review | pending | Founder review in a real browser with Privy sign-in; see the handoff for the run command. |

### Open decisions for the founder

1. Every PROVISIONAL preset value (supply, decimals, 43,200-block duration, start-lead bounds, LP fee 0.30% / spacing 60, one-sided STOCK position width, rounding-residue destination).
2. Hook permission set: the hook uses `beforeSwap` + `afterSwap` with return deltas so the STOCK-side fee is charged on all four swap forms; STOCK-specified swaps that a price limit cuts short revert (`PartialFillNotSupported`) rather than under-charging. The brief's afterSwap-only wording cannot charge STOCK on two of the four forms.
3. Whether the Agent one-auction-per-account limit should also apply to Stocks launches (not applied today).
4. Whether public listing of Stocks auctions launched outside this site (CLI or another front end) should be ingested with truthful provenance (AT43); today only launches this site verified are listed.

### Remaining work

- Bidder settlement after the auction (claim NEW, exit and refund STOCK) is not exposed on the
  portfolio for Stocks auctions; the CCA path exists and is proven in the fork suite, the site
  surface is Agent's existing gap too.
- Pool, fee-administration and revenue pages (STK-14 pool/fee UI): `configureSubject`, administrator
  transfer and `settle` are contract-proven and lab-scriptable (`local-stocks-lab.py settle`), not yet
  in the website.
- Shared CLI commands that sign are out of scope for the public read-only CLI; the CLI now exposes
  kind and quote token on every auction.
- Real-browser manual review with Privy sign-in (AT47) and all founder decisions above.

## Running the lab site from this worktree

```sh
# contracts: hydrate, build, deploy onto the running Agent lab fork
cd contracts/stocks
python3 bootstrap-deps.py /Users/sean/Documents/regent/repos/autolaunch
forge build
python3 bin/local-stocks-lab.py --agent-lab-dir /Users/sean/Documents/regent/repos/autolaunch/contracts/v1/reports/generated/local-base-lab deploy --force

# website: own partition, both lab configs, read-only off via the serve script
cd ../../platform
env -u DATABASE_URL -u DATABASE_DIRECT_URL MIX_ENV=test REGENT_DEPS_ROOT=/Users/sean/Documents/regent/repos \
  MIX_TEST_PARTITION=_stocks_lab2 AUTOLAUNCH_BROWSER_TEST=1 AUTOLAUNCH_DB_POOL_SIZE=3 \
  AUTOLAUNCH_LAB_CONFIG=/Users/sean/Documents/regent/repos/autolaunch/contracts/v1/reports/generated/local-base-lab/site-config.json \
  AUTOLAUNCH_STOCKS_LAB_CONFIG=/Users/sean/Documents/regent/repos/autolaunch/contracts/v1/reports/generated/local-base-lab/stocks-site-config.json \
  AUTOLAUNCH_ACCEPTANCE_RUN_ID=stocks-2026-09-09 PORT=4060 PRIVY_APP_ID=browser-test-public-id \
  sh -c 'mix ash.setup && mix run --no-start --no-halt /Users/sean/Documents/regent/artifacts/autolaunch-stocks-lab/serve.exs'
```

Add `AUTOLAUNCH_LAB_AUTH=privy`, the real `PRIVY_APP_ID` and `PRIVY_VERIFICATION_KEY` (public PEM)
for real sign-in, on the port the Privy application allows. The serve script only flips
`prelaunch_read_only` after checking the database and fork bindings, exactly as the Agent lab's
does. `anvil_mine`, `local-stocks-lab.py advance --to start|end|claim|migration` and
`migrate --launch N` move an auction through its life; Anvil mines only when asked.
