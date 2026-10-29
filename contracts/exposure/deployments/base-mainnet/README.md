# Afterhours Exposed Tokens on Base

Deployed by `autolaunch-deployer` (`0x9b2C414614aEE294202c1219520955EF3B596031`) on Sean's go;
receipts in `../../broadcast/DeployAfterHours.s.sol/8453/`.

| Contract | Address | Block | State |
| --- | --- | --- | --- |
| `ExposureFactoryV1` | `0xAECE72c94CaC843f9Ecd54aC6Ca833bF4CFED048` | 53,219,733 | Live. Runtime equals the build byte for byte; `owner()` is the Governance and Regent Safe `0x9fa152B0EAdbFe9A7c5C0a8e1D11784f22669a3e`. |
| `ChainlinkPrintOracleV1` | `0x6e80e0b65F50666E230276FD5bEf61059aC65f98` | 53,219,732 | Superseded on 29 Oct before any series used it: it followed the live proxy, so a print could depend on when it was recorded relative to an aggregator switch. Not used by anything. |
| `ChainlinkPrintOracleV2` | `0x64b8404E979EC2791E68f55d959d011EA4EEA88a` | 53,231,023 | Live (29 Oct, Sean's go). Runtime equals the build with its four constructor values masked; `feed()` is the Coinbase AMZN feed `0x06A8E4b3aBB3B7543d8396FB2B763d22820cB295`, `phase()` 2 (the proxy's current phase), `feedId()` `0xa4e7373e87b082c0fbf44cb5781e59e77a4636c518486646da1f6c1b3a1aab3c`, `MAX_STALENESS` 84 hours. A simulated `record` of Wed 28 Oct's close accepts round 482 (the round in force) and refuses rounds 480 and 481. |

## First series (Safe step)

[`safe-relaunch-first-series.json`](safe-relaunch-first-series.json) is the Safe Transaction Builder batch:
one `createSeries` call to the factory, as `firstSeriesCall` prints it for the V2 oracle and the terms
Sean approved on 29 Oct (`platform/priv/exposure_terms/0x5f67343b39277939aea7613c578fa3931b8b89da7a65eb36dd7217c81a5a2e8f.md`, keccak256
`0x5f67343b39277939aea7613c578fa3931b8b89da7a65eb36dd7217c81a5a2e8f`). Decoded: AMZNc, the V2 oracle
and its feed id, a seven-day recording window, a 0.4 AMZNc cap, the 11 closes and opens from Fri 30
Oct 20:00 UTC to Fri 6 Nov 21:00 UTC, legs "AMZNc After-hours to 6 Nov 2026" (AMZNc-AH-1106) and
"AMZNc Market-hours to 6 Nov 2026" (AMZNc-MH-1106). Simulated from the Safe against Base on 29 Oct:
succeeds, about 2.4M gas. It
must execute before Fri 30 Oct 16:00 New York time.

## First series as created

The Safe executed `createSeries` on 29 Oct 2026 at Base block 53,251,697 (transaction
`0xd71bee1785f5fd7ee404cec953168e6f66df28baa884cffdd570b1930ace3708`, Safe nonce 72) from the earlier
batch, not the file above. Read from Base: series `0x77b82face369db560677a903b13e747891096cb7` uses
`ChainlinkPrintOracleV1` `0x6e80e0b65F50666E230276FD5bEf61059aC65f98` and `termsHash`
`0x5fb35de4a9b0a0b9fcf37641d6777e413680c016e690df395283ca421ef23e7a` (the terms as first approved,
commit dd83312a), cap 0.4 AMZNc, seven-day recording window, the 11 prices of 30 Oct to 6 Nov. Legs:
After-hours `0x8112D5DEfb35474Fd3Bc7Db9b7b24d86492BbA2F` (AMZNc-AH-1106), Market-hours
`0xA8F0bE850BE09Efa971eb04653340E3F421AbD91` (AMZNc-MH-1106). The V2 batch above was not executed.

## Relaunch (Sean's 1b, 29 Oct)

Sean chose to relaunch the first series correctly. The batch, renamed `safe-relaunch-first-series.json`
so it can't be mixed up with the earlier one, carries the same `createSeries` call: the V2 recorder, the
approved terms and a 0.4 AMZNc cap. Simulated from the Safe at 17:5x UTC on 29 Oct, with Safe nonce 73:
it succeeds, uses about 2.4M gas and creates `0xcae5aad4cc21700b32931404c366efd4fc1ddfa0`. The series at
`0x77b8…6cb7` stays unused and the site doesn't list it.

## Monday series (Sean's 2a, 29 Oct; terms awaiting approval)

[`safe-create-monday-series.json`](safe-create-monday-series.json): one `createSeries` call, as
`mondaySeriesCall` prints it for the V2 recorder and the draft terms
(`platform/priv/exposure_terms/0x0b0a03fb91ecdb27960ecbef9331d61b58f6b5587de9e28311e1a4aca7d434fb.md`). Decoded: AMZNc, the V2 recorder and its feed id,
a seven-day recording window, a 40 AMZNc cap, the 9 closes and opens from Mon 2 Nov 21:00 UTC to Fri
6 Nov 21:00 UTC, legs "AMZNc After-hours 2 to 6 Nov 2026" (AMZNc-AH-1102) and "AMZNc Market-hours 2 to
6 Nov 2026" (AMZNc-MH-1102). Simulated from the Safe on 29 Oct: it succeeds. Signed after the relaunch,
it creates `0x1df53a86c8260c20Ab79b5f620544209Bd454266`. It must execute before Mon 2 Nov 16:00 New York.
