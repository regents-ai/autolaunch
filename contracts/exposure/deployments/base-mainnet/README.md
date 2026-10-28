# After-hours Exposure on Base

Deployed 28 October 2026 by `autolaunch-deployer` (`0x9b2C414614aEE294202c1219520955EF3B596031`) with
`script/DeployAfterHours.s.sol` on Sean's go; receipts in `../../broadcast/DeployAfterHours.s.sol/8453/`.

| Contract | Address | Block | Checked |
| --- | --- | --- | --- |
| `ChainlinkPrintOracleV1` (Coinbase AMZN feed `0x06A8E4b3aBB3B7543d8396FB2B763d22820cB295`) | `0x6e80e0b65F50666E230276FD5bEf61059aC65f98` | 53,219,732 | Runtime equals the build with its three constructor values masked; `feed()` is the AMZN feed; `feedId()` is `0xf8b06b9f6b7e9541a46f9372cc945f222da74536c8715cd00f1c18bbd0b6a306` |
| `ExposureFactoryV1` | `0xAECE72c94CaC843f9Ecd54aC6Ca833bF4CFED048` | 53,219,733 | Runtime equals the build byte for byte; `owner()` is the Governance and Regent Safe `0x9fa152B0EAdbFe9A7c5C0a8e1D11784f22669a3e` |

## First series (Safe step)

[`safe-create-first-series.json`](safe-create-first-series.json) is the Safe Transaction Builder batch:
one `createSeries` call to the factory with the terms `firstSeriesCall` prints for the oracle above
and the approved terms hash `0x5fb35de4a9b0a0b9fcf37641d6777e413680c016e690df395283ca421ef23e7a`
(`platform/docs/after-hours-terms-amznc-2026-11-06.md`). Decoded: AMZNc, this oracle and feed id,
a seven-day recording window, a 0.4 AMZNc cap, the 11 closes and opens from Fri 30 Oct 20:00 UTC to
Fri 6 Nov 21:00 UTC, legs "AMZNc After-hours to 6 Nov 2026" (AMZNc-AH-1106) and "AMZNc Market-hours
to 6 Nov 2026" (AMZNc-MH-1106). Simulated from the Safe against Base on 28 Oct: succeeds, about
2.4M gas, creating the series at `0x77b82face369db560677a903b13e747891096cb7`. It must execute before
Fri 30 Oct 16:00 New York time.
