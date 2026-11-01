# Base mainnet

**Not deployed.** `mainnet-no-go-packet.json` carries no selection: the deployer, its starting
nonce and the time to send are the founder's decision, and nothing in this directory authorizes a
deployment. `deployed-manifest.json` is the empty record; it is written once, by `record`, from
confirmed Base receipts.

The tool is `../stocks-v2/bin/ceremony.py`, shared with version 2 and run from this package
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

Setting the hook's executor (`setExecutor`) and opening launches (`unpauseLaunches`) are further
Safe calls, each made by its own decision once Base runs 0.2-second blocks; neither is in this
batch.

## Steps

```sh
cd contracts/stocks-v3
python3 ../stocks-v2/bin/ceremony.py render                      # offline
python3 ../stocks-v2/bin/ceremony.py prepare --deployer 0x…      # read-only, REGENT_BASE_RPC_URL
# review reports/generated/deployment/mainnet-no-go-packet.json, install it here, commit it
python3 ../stocks-v2/bin/ceremony.py rehearse                    # read-only
python3 ../stocks-v2/bin/ceremony.py preflight 0                 # right before each creation
python3 ../stocks-v2/bin/ceremony.py record --receipts receipts.json --approved-digest 0x…
```

`rehearse` reads the latest Base block's gas limit off the node at that run and offers each
creation all of it, one creation per simulated block. Base's block gas limit changes with Denim on
5 November 2026, so it is never assumed; a creation that needs more than one block holds fails the
rehearsal.
