# Base mainnet

**Deployed and open, 12 November 2026.** The founder sent both creations of the packet
`mainnet-no-go-packet.json` (digest
`0xdba99ae57caae5c06185cded85bf5495140626c93b38edd6da529dd0dee40818`, selection derived at Base
block 56,519,000) from the deployer `0x9b2C414614aEE294202c1219520955EF3B596031`, right after Base
Revstake version 3's creation at nonce 68:

| Nonce | Transaction | Block |
| --- | --- | --- |
| 69 | `0xb8abcf9d70499a9edbcaa6b7be5c88f24657c7d507dc8b9a1da72ab8d3951764` | 56,661,100 (22:29 UTC) |
| 70 | `0xe95a0fd337fde8b68104a8faee4205611646c1af90cf78dafe0d0669bc81442f` | 56,661,111 (22:29 UTC) |

`deployed-manifest.json` is the record `record` wrote from the confirmed receipts: every created
contract landed at its prediction, its code matches the frozen build, and the five wiring
readbacks matched at the last creation's block, the launchpad still paused.

The Governance and Regent Safe switched version 3 on in transaction
`0x3ee0a4044b7641aae1fd7bb492f749fc03820fc74fa1f350d3070b07240c116f` at block 56,661,365 (22:30
UTC): `safe-switch-on.json`'s thirteen calls exactly, the ten admissions, the hook's executor and
`unpauseLaunches()` on this launchpad and on Base Revstake version 3's factory. Both read
`launchesPaused() == false` since. An earlier identical batch, transaction `0x3719a6a6…e253a`, ran
before the creations against addresses that held no code yet and changed nothing.

Version 2's launchpad `0x1d4bc582a9193061d53c4BFA429D366Ed38eEd0B` and version 1's
`0x1d36a95112835f81b1B499A808e556020C64Cac2` stay paused; their launches keep their bids, claims,
vesting, staking and trading on their own contracts, USDC bids included through their own bid
adapters.

| Nonce | Creates | Address | Transaction data |
| --- | --- | --- | --- |
| 69 | StocksLaunchpadV3 | `0x1db36b3BD9eC61c54B06a753FeC0b425237D7E7C` | `transaction-data-launchpad.txt` |
| 69, inside | MemestockSplitterV1 | `0x892E2EdE6cFF49C24DDd4A1a85F5bE4696836cae` | |
| 69, inside | MemestockLPLocker | `0xb3FD1ceBF07Bc47c39b42Da054552Bd041B125b6` | |
| 69, inside | StocksFeeHookV1 (salt `0x…3171`) | `0x48B5F05910b3c548e97d9C9E7F85CdE076B260cc` | |
| 70 | StockBidAdapterV1 | `0xa28334dEbaeea58Cd0b12D6814219498293EE1fA` | `transaction-data-bid-adapter.txt` |

Each transaction-data file is the creation's data byte for byte: the init code hashes to the
packet's `creation_keccak256`, the rest is the packet's constructor arguments, and the deploy script
sent exactly these bytes in the rehearsal below.

The tool is `bin/ceremony.py`, shared with Base Revstake version 3 and run from this package
directory (`contracts/stocks-v3`). Version 3 builds on version 2's deployment: `prepare` reads the
UERC20 factory and the ten admitted stocks with their routes from
`../stocks-v2/deployments/base-mainnet/deployed-manifest.json`, and observes each of them on Base.

## The whole ceremony

Two plain zero-value contract creations from the deployer, in nonce order.

| Nonce | Contract | Constructor arguments |
| --- | --- | --- |
| starting nonce | StocksLaunchpadV3 | the UERC20 factory version 2's launchpad binds, `0x4c003500c6a28826d15A6E4cF023C1f1ecd41E08`; the mined hook salt |
| starting nonce + 1 | StockBidAdapterV1 | the launchpad |

The launchpad's constructor creates the splitter implementation (launchpad nonce 1), the LP locker
(launchpad nonce 2) and StocksFeeHookV1 (`CREATE2` over the mined salt). The launchpad is born
paused with no stock admitted, and the deployer holds no role anywhere afterwards.

## After the ceremony: the Safe's admissions

Version 3 creates no stock route. The ten `AerodromeStockRouteV2` routes version 2 deployed are
unchanged, and the Governance and Regent Safe `0x9fa152B0EAdbFe9A7c5C0a8e1D11784f22669a3e` admits
each to the new launchpad with `admitStock(stock, route)`. `rehearse` simulates the ten calls from
the Safe right after the simulated ceremony, reads each admission back through
`stockAdmission(stock)`, and writes the unsigned batch to
`reports/generated/deployment/safe-batch.json` for the Safe's owners. It is signed only after both
creations have landed.

| Stock | Address | Version 2 route |
| --- | --- | --- |
| AAPLc | `0xb200000000000000000000C2e324d24d7eEcd1fb` | `0xc0e910234d2a057Eb5E78B69C5149567617c0563` |
| AMZNc | `0xb200000000000000000000d9192b6B456483C2E8` | `0x7755bB35d838602748a44A66f671f96f2b42eFa2` |
| GOOGLc | `0xb2000000000000000000002D0BA3164cc74f58B7` | `0x4dC2b96F07271b82e0F97DfF7A1555153fe3EF6d` |
| METAc | `0xb2000000000000000000008bC8786B856E61707C` | `0x71280E11Da1B4ed47E168B364fb52e2918975417` |
| MSFTc | `0xB200000000000000000000Ab99cFa739E253872B` | `0xC090F75b7C664a60CA56aE4b8590De34e46FBDe1` |
| MSTRc | `0xb2000000000000000000004884b426556b92883d` | `0x8e901a2b5775d3FF8d93E8c83D0622df08D74868` |
| NVDAc | `0xb20000000000000000000078ee7ce2fE4908108C` | `0x390Bc80fCf71dBcd3782fF9DB3954a7211fed999` |
| SNDKc | `0xb200000000000000000000397293Cb8cda9a10c5` | `0x75d0B57bC539F72DD16fB248855873126bd08916` |
| SPCXc | `0xb2000000000000000000007b9fcbd005511aCBd5` | `0xC9Ae2AeBa42fC2408Ac664Ef278dF1D996E27B19` |
| TSLAc | `0xb2000000000000000000001e800a7f5189430cD0` | `0x55009863EaFf428C4dc52520f6468B423C99B38a` |

`safe-switch-on.json` is the one Safe batch that switches version 3 on, for the Safe's Transaction
Builder: the ten admissions above, `setExecutor(0x72E2FB09147d3E6E5c9F44A4E127E6321e022045)` on
the hook (the executor version 2's hook names on Base), `unpauseLaunches()` on the launchpad, and
`unpauseLaunches()` on Base Revstake version 3's factory `0xA738aa7c82324EE8fa17FbAaa34a227e90f67D48`.
Thirteen calls, each to a predicted address, so it is signed only after all three creations have
landed and the site reads version 3. Version 2's launchers stay paused; their existing launches keep
their claims and withdrawals.

## Rehearsal

On 12 November 2026, on an anvil copy of Base mainnet at block 56,519,000, nothing sent to Base: `prepare` against the
copy, then the founder's exact sends with the deployer impersonated (`--unlocked`), Revstake first,
then the Safe batch from the Safe.

| Send | Gas used | Gas limit forge asked for |
| --- | --- | --- |
| Revstake factory, nonce 68 | 7,829,467 | 10,178,307 |
| StocksLaunchpadV3, nonce 69 | 8,895,862 | 11,564,620 |
| StockBidAdapterV1, nonce 70 | 747,404 | 971,625 |
| The Safe batch's thirteen calls, each sent from the impersonated Safe | 650,690 in all | |

Every creation landed at its prediction, each fits Base's 16,777,216-gas limit for one transaction
and the copy's 40,000,000-gas block, and after the Safe batch both launchers read
`launchesPaused() == false`, the hook names the executor, and all ten stocks are admitted with
their routes. At Base's fees on 12 November (a base fee of 0.005 gwei) the three creations cost
about 0.0001 ETH plus under 0.00001 ETH of L1 data fee; the deployer holds 0.0049 ETH.

## Sending it

`/Users/sean/Documents/regent/handoffs/autolaunch-sean-steps/Deploy Base auctions V3.command` sends
the three creations from the `autolaunch-deployer` keystore, from a copy of both packages at the
commit that holds these packets. For each creation it runs the deploy script once without sending,
requires the data it would send to equal the transaction-data file byte for byte, then sends it
(`--broadcast --slow`, never `--resume`). The scripts themselves require Base, the packet's nonce
and every predicted address before anything is signed.

## Steps

```sh
cd contracts/stocks-v3
python3 bin/ceremony.py render                      # offline
python3 bin/ceremony.py prepare --deployer 0x…      # read-only, REGENT_BASE_RPC_URL
# review reports/generated/deployment/mainnet-no-go-packet.json, install it here, commit it
python3 bin/ceremony.py rehearse                    # read-only
python3 bin/ceremony.py preflight 0                 # right before each creation
python3 bin/ceremony.py record --receipts receipts.json --approved-digest 0x…   # Foundry 1.5.1
```

`record` runs under Foundry 1.5.1, whose `cast --json` answers are the plain receipt and
transaction; 1.8.6 wraps them in an envelope the tool does not read. It reads the readbacks at the
last creation's block, so the Safe's later switch-on does not count against the ceremony.

`rehearse` reads the latest Base block's gas limit off the node at that run and offers each
creation all of it, one creation per simulated block. Base's block gas limit changes with Denim on
5 November 2026, so it is never assumed; a creation that needs more than one block holds fails the
rehearsal.
