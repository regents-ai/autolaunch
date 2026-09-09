# Autolaunch Stocks: website, lab and evidence

Stocks is a separate launch mode next to Agent: a new token (NEW) auctioned for one admitted Base
stock token (STOCK) through the pinned CCA, then migrated into the official NEW/STOCK pool.
Product terms are in the September 8 brief (local planning) and the contract preset in
`contracts/stocks/README.md`. This page records what the website does, how the local Base-fork
lab runs it, and the evidence index.

## Routes and surfaces

| Surface | Path | Notes |
| --- | --- | --- |
| Stocks create | `/create/stocks` | Signed-in; one private Stocks draft per account (`stock_launch_drafts`), independent of the Agent draft. Three autosaving sections (token details, stock and auction terms, subject revenue and administrator), the fixed-terms list (which states the 100,000 REGENT launch fee, paid to REGENT staking as rewards and not refunded), then the wallet step. One stock launch in progress per account: while the account has a Stocks `Auction` in state `created` or `active`, the page shows "You already have a stock launch in progress. One at a time for now." and hides the review button; `Autolaunch.Stocks.LaunchOperation.Validations.ActiveLaunchLimit` refuses `prepare` with code `active_stocks_launch_exists` (site rule, not a contract rule; the Agent limit is separate and untouched). The "Create" menu in the rail links here when the site is not read-only. |
| Wallet step | `/create/stocks` | `Autolaunch.Stocks.LaunchActions` reviews the draft against the fork and writes one immutable envelope of at most two steps (`stock_launch_operations`, one open per account): an `approval` step `approve(launchpad, fee)` on REGENT whenever the signer's allowance to the launchpad is not exactly `launchFee()` (higher included; the launchpad requires exact equality), then the `launch(LaunchParams)` step with `expectedLaunchFee = fee` as the twelfth tuple word. The snapshot reads `launchFee()`, the signer's REGENT balance and allowance; a balance below the fee refuses review with "This wallet holds less REGENT than the launch fee." Review shows the fee ("100,000 REGENT, paid to REGENT staking as rewards, not refunded if the minimum is not raised"), the derived start block and estimated close, the exact executable floor (largest multiple of 100 not above the entered price, at least 2^32+1), the required raise in the stock's base units, and the subject lane (zero address when off). The approval is verified by the `Approval` log and the allowance read back equal to the fee, then the row advances to the launch step. Launch verification decodes `StockLaunchCreated` and `StockLaunchFeeCollected` (payer = signer, amount = reviewed fee; absent only when the fee is zero), checks against `launches(id)` and `launchIdOfAuction`, stores `new_token`, `auction`, `launch_id`, `launch_fee` and projects the `Auction` row (`kind: :stocks`). |
| Auction list and detail | `/auctions`, `/auctions/:address`, `/api/v1/auctions` | Shared with Agent. `Auction.kind` is `:agent` or `:stocks`; the quote token fields carry the real currency (address, symbol, decimals) and the detail page states them. |
| Bid | auction page | Two forms side by side, never auto-switched: "Bid with STOCK" (allowance to Permit2, Permit2 allowance to the auction, `submitBid`) and, on Stocks auctions with the Stocks lab running, "Bid with USDC" (exact USDC allowance to the adapter, then `bidWithUsdc` with `minStockOut` = route estimate less 1% and a 15-minute deadline). Amounts and prices use the auction's own currency decimals. |
| Market feed | background | `Autolaunch.Stocks.LabMarketFeed` polls the fork every second, projects every `launches(id)` whose launcher is a wallet a site account holds into an `Auction` row, and refreshes state and clearing price of Stocks auctions from the auction contract and the launchpad lifecycle. When either feed (Agent or Stocks) sees an auction reach `graduated`, it projects the public `Token` row in the same transaction (`LabProjection.project_graduated_token/1`; Stocks tokens carry no Agent subject), so the token page and its pool section exist as soon as the auction row says so. |
| Pool and fee administration | `/tokens/:id` (section `#pool`); linked from a graduated auction page ("View the pool and fee lanes") | Lab sites only, both launch kinds. `Autolaunch.Pool.read/1` reads one latest fork block: the pair (launch token / currency with symbols and exact addresses), pool id, liquidity fee 0.30% and tick spacing 60, the price at graduation (`finalSqrtPriceX96` → currency per whole token through `Autolaunch.PoolPrice`, exact when the value is a finite decimal, otherwise truncated and marked "…"), the current price, tick and liquidity read from the PoolManager's own storage (`extsload` of `Pool.State`; the Base `StateView` has no code on the fork), the locked positions with their NFT ids, amounts and `ownerOf` (Agent: one full-range position from `distribution(auction)`; Stocks: the full-range position and, when nonzero, the one-sided currency position from `launches(id)`), the unsold tokens (Stocks: retired at `0x…dEaD`; Agent: held by the vesting escrow) and the public Uniswap app link, labelled as Base mainnet. Fee lanes: Agent pools show the fixed 1% REGENT + 1% subject lanes, the splitter, a link to the subject page and the per-lane totals from the frozen hook's `SwapFeeSettled` logs since the migration block (one bounded `eth_getLogs`); Stocks pools show the REGENT lane, the subject lane's state from `subjectConfig`, the number of trades charged (`HookFeeAccrued`), revenue per destination (`accrued`/`settled` for `REGENT_DESTINATION()` and every splitter that ever held the lane, found from the hook's `PoolRegistered`/`SubjectLaneSet` logs since migration), the conversion history (`BucketSettled`) and the operator account (`executor()`). Fee administration (Stocks only, `AutolaunchWeb.StocksFeeAdminComponent`): everyone sees the administrator, any proposed administrator and the configuration version; the signed-in account whose selected wallet is the administrator can turn the subject lane on or onto another authentic Agent splitter (`configureSubject(launchId, splitter, currentVersion)`, splitter checked exactly as the create page checks it), turn it off (`configureSubject(launchId, 0x0, currentVersion)`) or propose a successor (`proposeFeeAdministrator`); the proposed wallet accepts (`acceptFeeAdministrator`). One durable lane, `Autolaunch.Stocks.FeeAdminOperation` (`stock_fee_admin_operations`, one open per account and auction) driven by `Stocks.FeeAdminActions` (prepare → claim_dispatch → bind_hash → verify) on the shared wallet-press plumbing (`WalletAttempt` kind `:stocks_fee_admin`, step `action`). Each is verified by its own event (`SubjectConfigured` with version = reviewed + 1, `FeeAdministratorTransferStarted`, `FeeAdministratorTransferred`) and by reading `subjectConfig` back at the receipt block. Nothing gates a press on page state: a stale version is refused by the contract and shown as the revert. Agent pools state "Fee lanes are fixed for this pool". Revenue conversion (`settle`) is executor-only; on the lab the executor is the impersonated deployer `0x5700…0001`, never a site wallet, so the page carries no conversion button, only the note "Revenue is converted to USDC and deposited by the operator outside trading" and the operator address. |
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
    "regent_launch_fee_amount": "500000000000000000000000",
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
prepares against (`Autolaunch.Stocks.LabAbi.requirements/0`; for the launchpad that now includes
`launchFee()`, `setLaunchFee(uint256)`, `StockLaunchFeeCollected`, `LaunchFeeUpdated`,
`configureSubject`, `proposeFeeAdministrator`, `acceptFeeAdministrator`, `StockLaunchGraduated`,
`SubjectConfigured`, `FeeAdministratorTransferStarted` and `FeeAdministratorTransferred`; for the
hook `REGENT_DESTINATION()`, `accrued`, `settled`, `HookFeeAccrued` and `BucketSettled`). The Agent
lab's `hook` ABI has to declare `SwapFeeSettled` (`Autolaunch.LabAbi.requirements/0`). Reads the
pinned interfaces do not carry (`executor()`, `PoolRegistered`, `SubjectLaneSet`, the PoolManager's
`extsload`, the PositionManager's `ownerOf`) use fixed selectors and topics.
`faucet.regent_launch_fee_amount` is optional: when present it must be a decimal string of REGENT
base units, and the faucet then offers it as the launch-fee grant. The interface ABIs the site was
written against are pinned at `platform/contracts/abi/stocks-*.json` (regenerated from
`contracts/stocks/src/interfaces` with solc 0.8.26) and registered in
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
- "Get 500,000 test REGENT (launch fee)": rendered only when the Stocks lab configuration carries
  `faucet.regent_launch_fee_amount`; `transfer(wallet, regent_launch_fee_amount)` from the same
  governance Safe balance. The button's number is the configured amount in whole REGENT, so it
  follows the configuration rather than this page.
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
| STK fee: 100,000 REGENT launch fee, exact allowance, funded into staking | unit-proven | `launch_actions_test.exs`: the twelfth tuple word is `expectedLaunchFee`; allowance 0 → approval then launch; allowance equal to the fee → launch only; allowance above the fee → approval (corrected down to exactly the fee) then launch; a balance below the fee is refused (`insufficient_regent`). Verification of `StockLaunchFeeCollected` and the `advance` transition are implemented against the interface and await the redeployed lab (`implemented-unverified` on the fork). |
| STK one-active rule (site) | unit-proven | `launch_draft_test.exs`: a `created` Stocks auction of the account refuses `prepare` with `active_stocks_launch_exists`, never counts for another account, and a graduated auction frees the slot. |
| P07 direct STOCK bid and USDC→STOCK bid | integrated-local | Direct: token approval → Permit2 → `submitBid` confirmed (`onchain_bid_id` 1, 2.5 AAPLc; then 20 AAPLc). USDC: `approve(adapter)` → `bidWithUsdc` confirmed (`StockBidPlaced`, owner = signer, 50 USDC → 0.2173913 AAPLc). Both visible on `/portfolio`. |
| P08/P09/P10/P11 hook lanes and attribution | unit-proven + fork | `StocksFeeHook.t.sol` (17 tests: four swap forms × both orderings × subject on/off, conservation, bucket attribution by configuration version); fork lifecycle settles the REGENT bucket into the real `LIVE_STAKING` and a subject bucket into a real Agent splitter. Hook permission set differs from the brief's afterSwap-only wording, see "Open decisions". |
| P12 conversion outside swaps | unit-proven | `settle` is executor-only and the only path out; a failing settle reverts only itself. |
| P13 all-net-STOCK liquidity, retirement, locked LP | unit-proven + fork | `StocksLaunchpadMigrate.t.sol` (12 tests incl. fuzz over clearing prices, both orderings): full-range position plus one-sided STOCK position, both NFTs at `0x…dEaD`, dust 0 observed and bounded, unsold NEW retired; no principal path for either NFT. Fork: see "Migration" row. |
| P15 UI and CLI parity | integrated-local | `/api/v1/auctions` and the CLI now carry `kind` and `quote_token`; `cli`: `npm run check` (6 pass), `test:parity` (1 pass), `check:contract` (copy matches). The public CLI remains read-only by design; it does not sign. |
| STK-00 decision record | blocked | No Stocks decision record exists in this repository or the workspace; PROVISIONAL values are listed in `contracts/stocks/README.md`. |
| STK-01..09 contracts | unit-proven + fork | `forge test --fuzz-runs 64`: 68 passed; `FOUNDRY_PROFILE=fork forge test --fork-url http://127.0.0.1:58737`: 3 passed; Slither: no medium/high. `contracts/stocks/SECURITY.md` maps invariants to tests. |
| STK-10 Stocks draft (AT11) | unit-proven | `core_tests/elixir/autolaunch/stocks/launch_draft_test.exs`: another account can neither read nor update a draft. |
| STK-11 review envelope (AT09) | integrated-local (11-field tuple) / unit-proven (12-field tuple) | `launch_actions_test.exs` for the exact tuple; on the fork the prepared 772-byte calldata of the earlier 11-field tuple created launch #2 (`StockLaunchCreated` decoded, `launches(2)` and `launchIdOfAuction` cross-checked, `chain_verified`). The 12-field tuple with `expectedLaunchFee` and the approval step have not yet been sent on the fork; that needs the redeployed launchpad and a migrated lab partition. |
| STK-11 subject lane off (AT06, §5.1) | unit-proven | Disabling the lane leaves the zero address in the params and no splitter bytes in the calldata. |
| STK-12 `/create/stocks` | integrated-local | `stocks_create_live_test.exs` (autosave; stock change clears amounts) plus a headless-browser pass over `/create/stocks`, `/auctions`, `/auctions/:id`, `/portfolio` on the lab site. |
| STK-13 market feed and listing | integrated-local | The feed projected launch #2 into an `Auction` row (`kind: stocks`, AAPLc, 8 decimals) within seconds and moved it `created → active` at the start block; `/api/v1/auctions` lists it with `quote_token`. |
| Launch fee (STK-05, decision 5) | integrated-local | Launch #1 on the third deployment: two steps (REGENT `approve(launchpad, 100,000)` then `launch` with `expectedLaunchFee`), both sent from the signer and verified by the site; `launch_fee` decoded from `StockLaunchFeeCollected`; the real staking contract's `totalFundedRegent` rose by exactly 100,000 REGENT and the launchpad holds 0 REGENT. A second review by the same account was refused with `active_stocks_launch_exists`. |
| STK-14 faucet | integrated-local | REGENT (+1,000 from the Safe's forked balance), AAPLc (+100 fixture mint) and USDC (+1,000 from the Morpho holder) each landed in one press with the new balance read back. |
| Migration (STK-05 on the fork, observed by the site) | integrated-local | Launch #1 on the redeployed graph: 22.71739129 AAPLc raised across the three site bids; `advance --to migration` then `migrate --launch 1` → `Graduated`. `lpStockUsed` 2,271,739,129 = the whole raise (all net STOCK locked; <25% sold so the full-range position took it all and no one-sided position was needed), `lpNewUsed` ≈ 2.27M NEW, LP NFT 3017409 owned by `0x…dEaD`, 995,456,521.74 unsold NEW retired to `0x…dEaD`, launchpad holds 0 NEW and 0 STOCK. The site's feed moved the auction to `graduated` and `/api/v1/auctions` reports it. Bid claims after graduation are not yet exposed in the portfolio (see remaining work). |
| Pool page, both kinds (STK-14 pool UI) | integrated-local (10 September 2026, partition `_pool_lab`, port 4080, fork head ≈ 51,238,483) | Agent launch "Pool Agent" (PAGT) created through `Autolaunch.LaunchActions` (500,000 REGENT fee approval + launch), 150 REGENT bid, mined to its migration block and graduated by `strategy.migrate(auction)` (`0x07d40f86…c70a`): REGENT/PAGT pool `0xf2bfe8f4…1203`, LP NFT 3017414 at `0x…dEaD` with 149.999… REGENT and 150,000 PAGT, splitter `0xca960bec…6578`. Stocks launch #4 "Pool Apple Pair" (PAPL, fee administrator `0x1111…1111`, lane off) created through `Stocks.LaunchActions` (approval `0x8a4c6ea7…9117`, launch `0x9d2201a3…6f40`), 12 AAPLc bid, `migrate --launch 4` (`0x4aac0761…8b3e`): AAPLc/PAPL pool `0x0df62e2b…941e`, LP NFT 3017413 at `0x…dEaD` with 11.99999999 AAPLc and 1,199,999.999 PAPL, no one-sided position, 997,600,000.000995… PAPL retired. Both feeds projected the `Token` rows at graduation; `/tokens` lists both and `/tokens/:id#pool` renders every field above (price at graduation 0.00000999… AAPLc per PAPL and 0.000999… REGENT per PAGT from `finalSqrtPriceX96`; current price, tick and liquidity from `extsload`; owners read back as `0x…dEaD`). Four swaps per pool through a `PoolSwapTest` router (`0x96F2AE08…347D`, deployed with `forge create --unlocked` from the lab deployer): the Agent page counts 4 trades and 0.262234837456109564 REGENT + 332.798595160161002643 PAGT per lane from `SwapFeeSettled`; the Stocks page counts 4 trades, REGENT bucket accrued/settled and the subject bucket 0.09233961 AAPLc. Screenshots: `artifacts/autolaunch-pool-lab/shots/`. |
| STK-14 fee administration | integrated-local | On launch #4, from `0x1111…1111` (the administrator): subject lane on → `0xca960bec…6578` through the wallet-press plumbing (`dispatch_wallet_press` → hash `0xcc68b299…e7de` → `verify_wallet_press`, `SubjectConfigured` version 2), off (`0x15c56411…bf13`, version 3), on again (`0x7938d74a…8ef9`, version 4), propose `0x2222…2222` (`0xbee90bfb…ea1e`); then, signed in with the `changed-wallet` fixture (wallet `0x2222…2222`), accept (`0xe609c26b…7984`, `FeeAdministratorTransferred`; `subjectConfig` read back: administrator `0x2222…2222`, proposed none, version 4). The page re-read every change. In a headless browser signed in as the administrator, the card showed the three forms and a reviewed "turn off" action with its "Confirm in wallet" press (`shots/fee_admin_review.png`); as a non-administrator it says the wallet is neither administrator nor proposed. Unit: `fee_admin_actions_test.exs` (non-administrator refused with `not_fee_administrator`, non-proposed refused with `not_proposed_administrator`, exact `configureSubject(7, splitter, 3)` calldata, zero address when the lane is turned off, unauthentic splitter refused); `pool_price_test.exs` (both currency orders, 18/18 and 8/18, exact; non-terminating value truncated and marked). |
| STK-14 revenue settlement | integrated-local (read-only surface) | `local-stocks-lab.py settle` converted 0.1 AAPLc of the REGENT bucket into 23 USDC (`0x5e0c051a…a471`); the page lists it under "Conversions so far" and shows the bucket's awaiting/converted/deposited figures. No conversion button exists on the site: `settle` is executor-only and the executor is the lab deployer, never a site wallet. |
| AT04, AT48 real stock assets | blocked | Base-native stock tokens carry `0xef` code Anvil cannot execute; the lab uses fixture ERC-20s at the exact catalog addresses. Issuer transfer policy, Permit2 behaviour and the real acquisition route are unproven. |
| AT47 manual review | pending | Founder review in a real browser with Privy sign-in; see the handoff for the run command. |

### Founder decisions (9 September 2026)

1. The PROVISIONAL preset values are accepted, on the basis that the step schedule keeps ~30% of the
   auction supply in the final block as Agent's does (verified: 29.88%, `StocksPreset.t.sol`).
2. Hook permission set accepted (`beforeSwap` + `afterSwap` with return deltas).
3. One Stocks launch in progress per account, as a site rule (`ActiveLaunchLimit`); the contracts admit
   any launcher. Agent's own limit now counts only Agent auctions, so the two modes do not block each
   other.
4. Only launches this website verified are listed, for now.
5. Launch fees: a Stocks launch costs 100,000 REGENT, pulled at creation and funded into REGENT
   staking as staker rewards, never refunded. The Agent factory's fee is set to 500,000 REGENT by
   governance (`setLaunchFee`) rather than by editing the frozen V1 source; the lab applies the same
   call. Recorded in `contracts/README.md`.

### Remaining work

- Bidder settlement after the auction (claim NEW, exit and refund STOCK) is not exposed on the
  portfolio for Stocks auctions; the CCA path exists and is proven in the fork suite, the site
  surface is Agent's existing gap too.
- The pool page reads the local lab only; a production site has no pool section yet (no
  mainnet reader for the strategy, launchpad and hooks exists on the website).
- The Agent subject page still shows its splitter only once a position readback projects it; the
  pool page reads the splitter from the strategy directly.
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

The pool-page proof ran the same way on partition `_pool_lab` and port 4080 (scripts and
screenshots in `artifacts/autolaunch-pool-lab/`: `serve.exs`, `e2e_launch.exs`, `e2e_bids.exs`,
`mine_to.py`, `swaps.sh`, `e2e_fee_admin.exs`, `browse.mjs`, `browse_admin.mjs`). An Agent launch
graduates only after `START_DELAY_BLOCKS + AUCTION_DURATION_BLOCKS + MIGRATION_DELAY_BLOCKS`
(≈ 88,300 blocks), then anyone may call `strategy.migrate(auction)`; the swaps that make the fee
lanes nonzero go through a v4 `PoolSwapTest` router deployed on the fork with
`forge create --unlocked --from 0x5700…0001` from `contracts/stocks`.
