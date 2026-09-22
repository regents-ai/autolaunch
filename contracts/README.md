# Autolaunch contracts

Four Foundry projects, one per directory. Each is built and verified from its own directory, and
nothing in any of them is deployed on a public chain.

| Project | What it is | Chain | Status | Verify |
| --- | --- | --- | --- | --- |
| [v1/](v1/README.md) | Base Revstake: agent tokens auctioned for REGENT, with a permanent fee-only LP locker, a shared fee hook, per-launch staking, payment receivers and a vesting escrow | Base (8453) | Complete against the frozen [SPEC.md](v1/SPEC.md); offline gate, Base fork evidence, deployment packet prepared and rehearsed; not yet deployed | `cd v1 && bin/gate.sh`, offline, after the one-time setup in its README |
| [stocks/](stocks/README.md) | Base Memestake: a new token auctioned for one admitted tokenised stock, then locked into its stock pool with two stock-side fee lanes and per-launch staking | Base (8453) | Implemented with its own gate; packet carries the code identity, no deployer selected yet | `cd stocks && bin/gate.sh`, after `python3 bootstrap-deps.py <hydrated checkout>` has filled `lib/` |
| [robinhood/](robinhood/README.md) | Robinhood Memestake: the Memestake launchpad rebuilt for Robinhood Chain with USDG as the dollar, plus a Base-side receiver for bridged revenue | Robinhood Chain (4663), one contract on Base | Implemented with its own gate; packet carries the code identity, no deployer selected; no production stock route contract yet | `cd robinhood && bin/gate.sh`, with `../stocks/lib` in place |
| [revenue-mesh/](revenue-mesh/README.md) | Immutable USDC payment routes over Circle CCTP from other chains into a Base `PaymentReceiverV1` | Source chains (Arbitrum One wrapper first) into Base | Offline foundation; every route is an unverified, inactive candidate | `cd revenue-mesh && forge fmt --check && forge build && forge test -vvv` |

The website's runtime copies of the ABIs and the chain manifest live in
[`platform/contracts/`](../platform/contracts/). They are consumers of this directory, not sources.

## Which contracts each launch type uses

**Base Revstake** (`v1/src`). `RegentsAutolaunchFactoryV1.launch` mints a 100 billion token
through the pinned `UERC20Factory` and creates a continuous clearing auction through the pinned CCA
factory. The shared `RegentLBPStrategy` holds the 10% auction inventory and 5% reserve, and anyone
may call `migrate` once the auction ends. On graduation it opens the REGENT/token pool at the final
price, mints one full-range position into `RevstakeLPLocker` (created once by the strategy, no
withdrawal path), clones a `SubjectSplitterV1` (the launch's staking contract) and a canonical
`PaymentReceiverV1`, and starts the 85% `ConditionalVestingEscrowV1` vesting to the treasury over
365 days. `RegentFeeHook` charges two 1% lanes on every swap: one to the Regent Safe, one into the
splitter. Anyone may call `RevstakeLPLocker.collect` to deposit the position's fees into the
splitter. A failed auction retires the whole supply to the dead address; bidders refund from the
auction.

**Base Memestake** (`stocks/src`). `StocksLaunchpadV1.launch` mints a 1 billion token through a
`UERC20Factory` and auctions 80% of it for one admitted stock. On graduation the launchpad locks the
20% reserve, paired at the clearing price, and every remaining unit of the stock raised into two
positions owned by `MemestockLPLocker`, clones a `MemestockSplitterV1` for staking, and registers
the pool with `StocksFeeHookV1`. The hook accrues two 1% lanes of the stock side of every swap:
`settleRegentLane` (executor only) converts the REGENT lane to USDC through the stock's
`AerodromeStockRouteV1` and deposits it into live REGENT staking; `settleStakerLane` (anyone)
deposits the staker lane as stock into the splitter. `StockBidAdapterV1` lets a bidder pay USDC and
bid the stock in one transaction.

**Robinhood Memestake** (`robinhood/src`). `RobinhoodStocksLaunchpadV1` (over
`RobinhoodLaunchpadBase`) plays the same Memestake shape on Robinhood Chain: `RobinhoodFeeHookV1`
(created through `RobinhoodFeeHookFactory`), the same `MemestockLPLocker`, and
`RobinhoodMemestockSplitterV1` clones. `RobinhoodStockBidAdapterV1` turns USDG into a stock bid.
Protocol dollars stop in `RobinhoodProtocolRevenueInboxV1` as USDG; the Robinhood Safe may bridge
them through an adapter it names to `RobinhoodBaseRevenueReceiverV1` on Base, where they are
deposited into live REGENT staking. `RobinhoodPositionsLib` is a linked library that keeps the
launchpad under the contract size limit.

### What is shared

- **Dependencies.** `v1/` pins its whole dependency closure as Git submodules, declared in the
  repository's top-level `.gitmodules` at `contracts/v1/lib/...` (the CCA, the liquidity launcher,
  the UERC20 factory and forge-std, each with its nested tree). `stocks/` exports the same pinned
  revisions into its own ignored `lib/` with `bootstrap-deps.py` and never edits `v1/`;
  `robinhood/` resolves its libraries from `../stocks/lib` and installs nothing of its own;
  `revenue-mesh/` has no external dependencies.
- **Base bindings.** `stocks/src/StocksBindings.sol` copies the frozen Base addresses from `v1`
  (REGENT, USDC, CCA factory, PoolManager, PositionManager, live staking, the Governance and
  Regent Safe) and adds Permit2. Robinhood takes every binding as a constructor argument instead.
- **The token factory.** `StocksLaunchpadV1` is constructed with a `UERC20Factory` address and
  requires its runtime code hash to equal the constant the `v1` factory demands. The Revstake
  ceremony creates that factory on Base, so the Base Memestake ceremony follows it, and the
  Memestake website file is rendered with the Revstake factory address as well. Robinhood Chain
  carries no such deployment, so its ceremony creates its own `UERC20Factory`.
- **Memestake accounting.** `stocks/src/StocksPreset.sol` (the fixed launch terms),
  `MemestockSplitterCore.sol` (staking and revenue accounting) and `MemestockLPLocker.sol` are
  compiled into both the Base and the Robinhood launchpads.
- **Gates.** `stocks/bin/gate.sh` and `robinhood/bin/gate.sh` share one body,
  `stocks/bin/memestake-gate.sh`, and one ceremony tool, `stocks/bin/ceremony.py`.

## Deployment state and order

Every project keeps two files apart: a **packet** (`mainnet-no-go-packet.json`), the proposal that
describes what a ceremony would do and the only committed ceremony authority, and a **deployed
manifest** (`deployed-manifest.json`), the record of what was actually created, populated only from
confirmed receipts. All three manifests are the empty record; every packet's authorization state
is `not authorized`. The founder signs and sends every creation by hand; no key,
endpoint or credential appears in this repository.

1. **Base Revstake first** ([v1/deployments/base-mainnet/](v1/deployments/base-mainnet/README.md)).
   Five zero-value creations from one dedicated deployer, in order: `UERC20Factory`,
   `ConditionalVestingEscrowV1`, `SubjectSplitterV1`, `PaymentReceiverV1` and
   `RegentsAutolaunchFactoryV1`, whose constructor creates `RegentLBPStrategy`, which creates
   `RevstakeLPLocker`, and mines `RegentFeeHook` with the pinned salt: eight contracts in all. The
   packet names the deployer, its starting nonce (0), the hook salt and the eight predicted
   addresses, and records the external state observed at Base block 51657720; it was rendered
   offline, prepared and rehearsed against a read-only Base fork with nothing broadcast. Its digest
   is `0x5ba245ed0af9de1c1749f0b50cd54919a8084faf580d92282ef0592144f35327`, and only a founder
   instruction naming that digest authorizes a signature. After the receipts confirm,
   `bin/ceremony.py record` proves them against the packet and writes the deployed manifest, and
   `bin/ceremony.py site-config` renders the website's deployment file from it. The factory is born
   paused: opening it is a later `unpauseLaunches()` from the Governance and Regent Safe.
2. **Base Memestake next** ([stocks/deployments/base-mainnet/](stocks/deployments/base-mainnet/README.md)).
   `bin/ceremony.py prepare` takes the deployer, the UERC20 factory from step 1 and one
   `--admission STOCK:POOL:FEED` per stock, and a human installs its candidate. The ceremony is then
   `StocksLaunchpadV1` (creating its splitter implementation, `MemestockLPLocker` and
   `StocksFeeHookV1`), `StockBidAdapterV1`, and one `AerodromeStockRouteV1` per admitted stock.
   Afterwards the Safe admits each stock, names the hook executor and unpauses the launchpad.
3. **Robinhood as its own track** ([robinhood/deployments/robinhood-mainnet/](robinhood/deployments/robinhood-mainnet/README.md)).
   Six creations on Robinhood Chain (`UERC20Factory`, the revenue inbox, the positions library,
   the hook factory, the launchpad and the bid adapter) and one on Base (the revenue receiver),
   after the founder supplies the chain bindings, the USDG address, the Safes, a reviewed bridge
   adapter and the stock admissions. No production `IRobinhoodStockRoute` implementation exists
   yet, so the launchpad would open with no admitted stock until one is written.

The revenue mesh has no deployment script and no production address.

## Decisions in force

- **No launch fee**, on any launch type (founder decision, 21–22 September 2026). A launch costs
  only gas. The Revstake factory moves no REGENT and takes no allowance; the Base Memestake
  launchpad pulls no REGENT and never holds it; the Robinhood launchpad pulls no USDG.
- **The launcher chooses the required raise.** Every launchpad admits any raise above zero that the
  fixed inventory can reach at the highest bid price, and there is no governance minimum.
- **Every auction opens on a fixed clock**: 300 blocks after the launch on Base, 6,000 blocks on
  Robinhood Chain (the Base schedule times twenty for 0.1-second blocks). The launcher does not
  choose it.
- **Memestake preset accepted** (9 September 2026): the fixed terms in `StocksPreset.sol` stand, on
  the basis that their 13-step schedule leaves about 30% of the auction inventory for the final
  block, as the Revstake schedule does (29.88% on Base). The values are still labelled
  PROVISIONAL inside `stocks/README.md`.
- **Hook permissions.** The Memestake hooks declare `beforeInitialize`, `beforeSwap`, `afterSwap`
  and both swap return deltas, so the stock is charged on every swap form. Both lanes are always
  on; the staker lane and the locker's `collect` need no authority, the REGENT (Base) or protocol
  (Robinhood) lane is settled only by the executor the Safe names, with a minimum out.
- **Listing.** The website lists Base launches it verified itself from its accounts' wallets;
  anything else on a launchpad is not listed. Robinhood launches are read from the launchpad
  directly, so every launch there is listed.
- **One Memestake launch in progress per account** is a website rule
  (`Autolaunch.Stocks.LaunchOperation.Validations.ActiveLaunchLimit`); the contracts admit any
  launcher.
- **Revstake is Base-only; Robinhood is Memestake-only** (founder decision, 18 September 2026).
- **Robinhood's staking exit rule reads the Ethereum block** the rollup last observed, so a staker
  waits about twelve seconds after staking before claiming or unstaking (kept as is, 21 September
  2026).
