# After-hours Exposure on Base

Deployed by `autolaunch-deployer` (`0x9b2C414614aEE294202c1219520955EF3B596031`) on Sean's go;
receipts in `../../broadcast/DeployAfterHours.s.sol/8453/`.

| Contract | Address | Block | State |
| --- | --- | --- | --- |
| `ExposureFactoryV1` | `0xAECE72c94CaC843f9Ecd54aC6Ca833bF4CFED048` | 53,219,733 | Live. Runtime equals the build byte for byte; `owner()` is the Governance and Regent Safe `0x9fa152B0EAdbFe9A7c5C0a8e1D11784f22669a3e`. |
| `ChainlinkPrintOracleV1` | `0x6e80e0b65F50666E230276FD5bEf61059aC65f98` | 53,219,732 | Superseded on 29 Oct before any series used it: it followed the live proxy, so a print could depend on when it was recorded relative to an aggregator switch. Not used by anything. |
| `ChainlinkPrintOracleV2` | to be deployed with `script/DeployAfterHours.s.sol` | — | Pinned to phase 2 of the Coinbase AMZN feed `0x06A8E4b3aBB3B7543d8396FB2B763d22820cB295`. |

The Safe's `createSeries` batch for the first series is written once V2 is deployed and the revised
terms are approved, because it commits to both.
