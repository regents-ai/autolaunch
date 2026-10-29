# After-hours Exposure on Base

Deployed by `autolaunch-deployer` (`0x9b2C414614aEE294202c1219520955EF3B596031`) on Sean's go;
receipts in `../../broadcast/DeployAfterHours.s.sol/8453/`.

| Contract | Address | Block | State |
| --- | --- | --- | --- |
| `ExposureFactoryV1` | `0xAECE72c94CaC843f9Ecd54aC6Ca833bF4CFED048` | 53,219,733 | Live. Runtime equals the build byte for byte; `owner()` is the Governance and Regent Safe `0x9fa152B0EAdbFe9A7c5C0a8e1D11784f22669a3e`. |
| `ChainlinkPrintOracleV1` | `0x6e80e0b65F50666E230276FD5bEf61059aC65f98` | 53,219,732 | Superseded on 29 Oct before any series used it: it followed the live proxy, so a print could depend on when it was recorded relative to an aggregator switch. Not used by anything. |
| `ChainlinkPrintOracleV2` | `0x64b8404E979EC2791E68f55d959d011EA4EEA88a` | 53,231,023 | Live (29 Oct, Sean's go). Runtime equals the build with its four constructor values masked; `feed()` is the Coinbase AMZN feed `0x06A8E4b3aBB3B7543d8396FB2B763d22820cB295`, `phase()` 2 (the proxy's current phase), `feedId()` `0xa4e7373e87b082c0fbf44cb5781e59e77a4636c518486646da1f6c1b3a1aab3c`, `MAX_STALENESS` 84 hours. A simulated `record` of Wed 28 Oct's close accepts round 482 (the round in force) and refuses rounds 480 and 481. |

The Safe's `createSeries` batch for the first series is written once the revised terms are approved,
because it commits to their hash.
