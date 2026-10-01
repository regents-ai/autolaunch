# Base mainnet

**Prepared, not approved, nothing sent.** `mainnet-no-go-packet.json` was prepared on
29 September 2026 against live Base at block 51936156 for deployer
`0x9b2C414614aEE294202c1219520955EF3B596031` at nonce 28 (founder decision 1a, 29 September 2026)
and rehearsed on a Base node after block 51936163. Its digest is
`0x78e5e04928efd068eec73d58aa11cb605fcf755d0c140c8b00ea483b596f79a2`. Nothing may be sent until the
founder names that digest.

Two files live in this directory, and keeping them apart is the point.

- `mainnet-no-go-packet.json` is a **proposal**: the selection (deployer, starting nonce, mined
  hook salt, the eight predicted addresses), the observed external state and the creation
  topology. `render` re-derives it offline and compares it byte for byte.
- `deployed-manifest.json` is a **record**, empty until `record` fills it from confirmed Base
  receipts. No simulated fact reaches it.

The tool is the shared one in `contracts/stocks-v2/bin/ceremony.py`, run from this package
directory (`python3 ../stocks-v2/bin/ceremony.py <mode>`). It refuses to run beside any signing,
keystore, sender or hardware-wallet variable, or beside a dotenv file.

## The whole ceremony

Five plain zero-value contract creations from the deployer, in nonce order. The factory's
constructor then creates the strategy (factory nonce 1), whose constructor creates the LP locker
(strategy nonce 1), and the fee hook (`CREATE2` over the pinned salt
`0x…1989`, address bits `0x2044`).

| Nonce | Contract | Predicted address | Gas used in rehearsal |
| --- | --- | --- | --- |
| 28 | UERC20Factory | `0x4c003500c6a28826d15A6E4cF023C1f1ecd41E08` | 2,793,709 |
| 29 | ConditionalVestingEscrowV2 | `0x8F511153393429468C3861E7cC5341Abb3310871` | 831,431 |
| 30 | SubjectSplitterV1 | `0x0886e34742B5E5ab8e07B0A6C3fC66A7912DE942` | 1,438,247 |
| 31 | PaymentReceiverV1 | `0xb58f2AF6A588414C6ad44280143db9aE7927d5fc` | 900,720 |
| 32 | RegentsAutolaunchFactoryV2 | `0xf4F591E63f4B6d8240a150081C1CA7Edfaeb768E` | 8,099,110 |
| (factory) | RegentLBPStrategyV2 | `0x4dEEd15f650F45900F2e55a44eADe7bD5Fd556d9` | |
| (strategy) | RevstakeLPLocker | `0x5483EfCc207F6233b393AC3Ab3ECE91D19a7C120` | |
| (factory) | RegentFeeHook | `0x57681398fB72027E719F3E558a0E188dd0c96044` | |

14,063,217 gas in all. The factory is born paused. The Governance and Regent Safe is its only
authority; the deployer holds none after the last creation.

The Base Memestake launchpad binds the token factory created at nonce 28 (founder decision 2a), so
Memestake is prepared only after this ceremony lands. On 29 September 2026 all five creations and
then Memestake's twelve (v1's ten Base stocks, nonces 33 to 44) were simulated back to back on a
Base node after block 51936147: every creation landed at its predicted address and all 47 wiring
readbacks matched, 30,158,802 gas in all.

## Before the first send

Run the rehearsal again just before sending. It proves the deployer is still at nonce 28 with no
transaction of its own waiting (the latest and pending reads must both be 28), that every committed
external fact still holds, and writes the exact transactions to
`reports/generated/deployment/rehearsed-transactions.json`:

```bash
REGENT_BASE_RPC_URL=https://mainnet.base.org python3 ../stocks-v2/bin/ceremony.py rehearse
```

## Sending by hand

Send each creation from the deployer with a signer of your own, confirm its receipt (status,
sender, nonce, created address) and only then send the next. If any creation lands elsewhere, the
packet is terminal and is prepared again, never resumed. The signer flags are yours and are never
written down here. Every flag comes before `--create`.

Right before each send, run the preflight for that creation (0 before nonce 28, 1 before nonce 29,
and so on up to 4). It must print `PREFLIGHT PASS`: the deployer's confirmed and pending nonces both
equal that creation's nonce and its address holds no code yet. If it stops, do not send; never move
the remaining creations to other nonces.

```bash
REGENT_BASE_RPC_URL=https://mainnet.base.org python3 ../stocks-v2/bin/ceremony.py preflight 0
```

```bash
cast send --rpc-url base <your signer flags> --nonce 28 --gas-limit 3400000 --create $(jq -r '.transactions[0].data' reports/generated/deployment/rehearsed-transactions.json)
```

```bash
cast send --rpc-url base <your signer flags> --nonce 29 --gas-limit 1000000 --create $(jq -r '.transactions[1].data' reports/generated/deployment/rehearsed-transactions.json)
```

```bash
cast send --rpc-url base <your signer flags> --nonce 30 --gas-limit 1750000 --create $(jq -r '.transactions[2].data' reports/generated/deployment/rehearsed-transactions.json)
```

```bash
cast send --rpc-url base <your signer flags> --nonce 31 --gas-limit 1100000 --create $(jq -r '.transactions[3].data' reports/generated/deployment/rehearsed-transactions.json)
```

```bash
cast send --rpc-url base <your signer flags> --nonce 32 --gas-limit 9800000 --create $(jq -r '.transactions[4].data' reports/generated/deployment/rehearsed-transactions.json)
```

`base` is the `[rpc_endpoints]` alias in `foundry.toml`, resolved from `REGENT_BASE_RPC_URL`.

After the last receipt, the public reads that prove the graph:

```bash
cast call 0xf4F591E63f4B6d8240a150081C1CA7Edfaeb768E "strategy()(address)" --rpc-url base
```

```bash
cast call 0xf4F591E63f4B6d8240a150081C1CA7Edfaeb768E "hook()(address)" --rpc-url base
```

```bash
cast call 0xf4F591E63f4B6d8240a150081C1CA7Edfaeb768E "launchesPaused()(bool)" --rpc-url base
```

## Recording

Put the five transaction hashes, in nonce order, in a file `{"transactions": ["0x…", …]}` and run:

```bash
REGENT_BASE_RPC_URL=https://mainnet.base.org python3 ../stocks-v2/bin/ceremony.py record --receipts receipts.json --approved-digest 0x78e5e04928efd068eec73d58aa11cb605fcf755d0c140c8b00ea483b596f79a2
```

It checks every receipt against the packet, proves all eight contracts' code against the frozen
build and reads back the twelve wiring facts, then writes the deployed-manifest candidate to
`reports/generated/deployment/` for a human to install here.

## Opening

Deploying and opening are separate acts. After the website's version 2 switch is ready, the
Governance Safe `0x9fa152B0EAdbFe9A7c5C0a8e1D11784f22669a3e` sends one batch on Base that opens
version 2 and closes version 1 (founder decision 16a, 30 September 2026):

| Call | Target |
| --- | --- |
| `unpauseLaunches()` | this package's `RegentsAutolaunchFactoryV2` |
| `unpauseLaunches()` | the Base Memestake version 2 launchpad |
| `pauseLaunches()` | Revstake version 1 factory `0x635615cCEF2Ef24D0655fC2eBC47a14e005FEF6e` |
| `pauseLaunches()` | Memestake version 1 launchpad `0x1d36a95112835f81b1B499A808e556020C64Cac2` |

Pausing stops new launches only. Existing auctions, claims, refunds, staking and fee collection on
version 1 are untouched. Both version 1 launchers were open (`launchesPaused()` false) on
30 September 2026. Robinhood's version 1 launchpad is closed by its own Safe transaction on
Robinhood Chain; see `contracts/robinhood-v2/README.md`.

AGI (version 1 Memestake launch 3, auction `0xd4cecfbf6d1e4afb46b054d1b7a284f450551140`) ended
without being migrated. Read on Base on 1 October 2026: `nextBidId()` 0, `currencyRaised()` 0,
`totalCleared()` 0, no `BidSubmitted` event. Nobody bid, so it stays ended and unmigrated
(founder decision 18: migrate only if it had bids). Pausing the launchpad does not change it.
