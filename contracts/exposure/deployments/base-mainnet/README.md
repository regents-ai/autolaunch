# Isolated Exposure to After-hours Stocks on Base

Deployed by `autolaunch-deployer` (`0x9b2C414614aEE294202c1219520955EF3B596031`) on Sean's go;
receipts in `../../broadcast/DeployAfterHours.s.sol/8453/`.

| Contract | Address | Block | State |
| --- | --- | --- | --- |
| `ExposureFactoryV1` | `0xAECE72c94CaC843f9Ecd54aC6Ca833bF4CFED048` | 53,219,733 | Live. Runtime equals the build byte for byte; `owner()` is the Governance and Regent Safe `0x9fa152B0EAdbFe9A7c5C0a8e1D11784f22669a3e`. |
| `ChainlinkPrintOracleV1` | `0x6e80e0b65F50666E230276FD5bEf61059aC65f98` | 53,219,732 | Superseded on 29 Oct before any series used it: it followed the live proxy, so a print could depend on when it was recorded relative to an aggregator switch. Not used by anything. |
| `ChainlinkPrintOracleV2` | `0x64b8404E979EC2791E68f55d959d011EA4EEA88a` | 53,231,023 | Live (29 Oct, Sean's go). Runtime equals the build with its four constructor values masked; `feed()` is the Coinbase AMZN feed `0x06A8E4b3aBB3B7543d8396FB2B763d22820cB295`, `phase()` 2 (the proxy's current phase), `feedId()` `0xa4e7373e87b082c0fbf44cb5781e59e77a4636c518486646da1f6c1b3a1aab3c`, `MAX_STALENESS` 84 hours. A simulated `record` of Wed 28 Oct's close accepts round 482 (the round in force) and refuses rounds 480 and 481. |

## Source verification

`ExposureFactoryV1` and `ChainlinkPrintOracleV2` are verified on Sourcify (creation and runtime
match, 29 Oct 2026, `forge verify-contract --verifier sourcify`) and on Basescan (Source Code
Verified, run by Sean with `forge verify-contract --verifier etherscan`, 29 Oct 2026). `ChainlinkPrintOracleV1` and the unused series `0x77b8…6cb7`
are not verified. The first series as relaunched (`0xcae5…dfa0`) and its two tokens are verified on
Sourcify (match, 30 Oct 2026) and on Basescan (Sean, 30 Oct: the series and After-hours token exact
match; the Market-hours token matched to it, the same code); their constructor values are in
[`verify/`](verify/).

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

## First series as relaunched (live)

The Safe executed the relaunch batch on 30 Oct 2026 at Base block 53,292,267 (transaction
`0x5dddb8490ffe7575063292707695bdadfbb337a81c6dff7fd8342be92e4704dd`, Safe nonce 73). Read from Base:
series `0xcae5aad4cc21700b32931404c366efd4fc1ddfa0` uses `ChainlinkPrintOracleV2`
`0x64b8404E979EC2791E68f55d959d011EA4EEA88a`, `termsHash` `0x5f67343b…2e8f` (the approved terms),
cap 0.4 AMZNc, seven-day recording window, 11 prices. Legs: After-hours
`0x07e4aAbF673b556892Ac3f9a254941b222993603`, Market-hours
`0x668a22Ab136Ad30e88cB76859c151CBBb20eFffd`. [`site-series.json`](site-series.json) lists it for the
site.

## Monday series (Sean's 2a, 29 Oct; terms under the title Sean set, 29 Oct 20:53Z)

[`safe-create-monday-series.json`](safe-create-monday-series.json): one `createSeries` call, as
`mondaySeriesCall` prints it for the V2 recorder and the draft terms
(`platform/priv/exposure_terms/0xa1cf3a36b50d547ac64d9877391da6edfbe2fdb0b594345280db6f05b4a5db23.md`). Decoded: AMZNc, the V2 recorder and its feed id,
a seven-day recording window, a 40 AMZNc cap, the 9 closes and opens from Mon 2 Nov 21:00 UTC to Fri
6 Nov 21:00 UTC, legs "AMZNc After-hours 2 to 6 Nov 2026" (AMZNc-AH-1102) and "AMZNc Market-hours 2 to
6 Nov 2026" (AMZNc-MH-1102). Simulated from the Safe on 29 Oct: it succeeds. The draft terms were retitled twice on 29 Oct on Sean's word, last to Isolated Exposure to After-hours Stocks (nothing else in them changed), so their fingerprint and this batch were rebuilt with `mondaySeriesCall`; the rebuilt call simulates from the Safe at Base block 53258971 (about 2.47M gas). Signed after the relaunch,
it creates `0x1df53a86c8260c20Ab79b5f620544209Bd454266`. It must execute before Mon 2 Nov 16:00 New York.

Created by the Safe on 30 Oct 2026 at Base block 53,293,530 (transaction
`0x0484c78e73ba8ca16416f23ecd697ab29987ff15e2742a3e7212f9cf593233f3`). Read from Base: series
`0x1df53a86c8260c20Ab79b5f620544209Bd454266`, `ChainlinkPrintOracleV2`, `termsHash` `0xa1cf3a36…db23`,
cap 40 AMZNc, seven-day recording window, 9 prices from Mon 2 Nov 21:00 UTC. Legs: After-hours
`0xb1303E0Eb033e6DfCDdA568a54C73A6BAFbb7E42`, Market-hours
`0x0fD3995511a1D35f77d0855fD5c112Eb61084AAA`. Listed in [`site-series.json`](site-series.json).
