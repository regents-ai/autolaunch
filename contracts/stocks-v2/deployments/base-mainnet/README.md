# Base mainnet

Deployment is complete. V2 launches are open, as checked on 9 October 2026. The preparation
and ceremony instructions below record the original deployment; they do not authorize another one.

`mainnet-no-go-packet.json` was prepared on 6 October 2026 for the 5 October Memestake terms
(49.75% sold, 49.75% pooled, 0.5% vesting to the launcher), against live Base at block 52273288
for deployer `0x9b2C414614aEE294202c1219520955EF3B596031` at nonce 33, and rehearsed on a Base
node after block 52273327. It binds the token factory Base Revstake v2 created at nonce 28,
`0x4c003500c6a28826d15A6E4cF023C1f1ecd41E08`. Its digest is
`0x94fac84efc322f6ed6fe2a32d61acf51f4215cc78cae51ed01dfa3cea3db2e65`. The founder approved and sent this packet; confirmed receipts are recorded below.

The tool is `bin/ceremony.py`, run from this package directory. `deployed-manifest.json` is the
record, populated from confirmed Base receipts.

## The whole ceremony

Twelve plain zero-value contract creations from the deployer, in nonce order. The launchpad's
constructor creates the splitter implementation, the LP locker and the fee hook (`CREATE2` over
the pinned salt `0x…1e5f`).

| Nonce | Contract | Predicted address | Gas used in rehearsal |
| --- | --- | --- | --- |
| 33 | StocksLaunchpadV2 | `0x1d4bc582a9193061d53c4BFA429D366Ed38eEd0B` | 8,895,226 |
| 34 | StockBidAdapterV1 | `0x528fF2ef4EAf382461269aE4290b15b065080Dae` | 747,404 |
| 35 | AerodromeStockRouteV2 (AAPLc) | `0xc0e910234d2a057Eb5E78B69C5149567617c0563` | 677,877 |
| 36 | AerodromeStockRouteV2 (AMZNc) | `0x7755bB35d838602748a44A66f671f96f2b42eFa2` | 677,877 |
| 37 | AerodromeStockRouteV2 (GOOGLc) | `0x4dC2b96F07271b82e0F97DfF7A1555153fe3EF6d` | 677,877 |
| 38 | AerodromeStockRouteV2 (METAc) | `0x71280E11Da1B4ed47E168B364fb52e2918975417` | 677,877 |
| 39 | AerodromeStockRouteV2 (MSFTc) | `0xC090F75b7C664a60CA56aE4b8590De34e46FBDe1` | 677,877 |
| 40 | AerodromeStockRouteV2 (MSTRc) | `0x8e901a2b5775d3FF8d93E8c83D0622df08D74868` | 677,865 |
| 41 | AerodromeStockRouteV2 (NVDAc) | `0x390Bc80fCf71dBcd3782fF9DB3954a7211fed999` | 677,877 |
| 42 | AerodromeStockRouteV2 (SNDKc) | `0x75d0B57bC539F72DD16fB248855873126bd08916` | 677,877 |
| 43 | AerodromeStockRouteV2 (SPCXc) | `0xC9Ae2AeBa42fC2408Ac664Ef278dF1D996E27B19` | 677,877 |
| 44 | AerodromeStockRouteV2 (TSLAc) | `0x55009863EaFf428C4dc52520f6468B423C99B38a` | 677,877 |
| (launchpad) | MemestockSplitterV1 | `0xF0265AbC72496eD84305e7f0B77eBFeFd3525f1B` | |
| (launchpad) | MemestockLPLocker | `0x6bcf22BF056dc84542b2cB37C64Bd5a91cc38323` | |
| (launchpad) | StocksFeeHookV1 | `0x385E40e1c07c215Ad1a7f5D8c2B878507dc520cc` | |

16,421,388 gas in all; every created code matched the frozen build and all 35 readbacks matched.
The launchpad is born paused. After the record, the Governance and Regent Safe
`0x9fa152B0EAdbFe9A7c5C0a8e1D11784f22669a3e` admits the ten stocks with their routes, sets the
executor and opens launches in the switch-on batch.
