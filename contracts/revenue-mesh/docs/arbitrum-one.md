# Arbitrum One Wrapper Facts

`ArbitrumOneRevenueInboxFactoryV1` is an offline candidate wrapper. It does not establish that any
factory or inbox is deployed, admitted, compatible, or active, and it does not authorize publishing
a payment address.

## Fixed facts and owners

| Owner | Fixed fact | Value | Official source |
| --- | --- | --- | --- |
| Arbitrum | Arbitrum One chain ID | `42161` | [Arbitrum chain information](https://docs.arbitrum.io/for-devs/dev-tools-and-resources/chain-info) |
| Circle | Arbitrum CCTP domain | `3` | [CCTP supported chains and domains](https://developers.circle.com/cctp/concepts/supported-chains-and-domains) |
| Circle | Native Arbitrum USDC | `0xaf88d065e77c8cC2239327C5EDb3A432268e5831` | [USDC contract addresses](https://developers.circle.com/stablecoins/usdc-contract-addresses) |
| Circle | Arbitrum TokenMessenger V2 | `0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d` | [CCTP contract addresses](https://developers.circle.com/cctp/references/contract-addresses) |
| Circle | Per-transaction CCTP burn limit | `10_000_000e6` USDC base units | [CCTP contract interfaces](https://developers.circle.com/cctp/references/contract-interfaces) |
| RevenueMesh | Source namespace | `bytes32("eip155")` = `0x6569703135350000000000000000000000000000000000000000000000000000` | This repository's route identity policy |

Sources were retrieved on 2026-08-30. The Arbitrum chain-information page reported that it was last
updated on 2026-08-18 at retrieval time. Official documentation is attribution evidence for this
offline candidate, not proof of live bytecode, deployment provenance, or current configuration.

## Fixed route-ID vector

For Base receiver `0x1111111111111111111111111111111111111111` and Base splitter
`0x2222222222222222222222222222222222222222`, the route ID is:

`0x816118fa8cee7c00584d3965730ec11d752e7c97525586e160dbc03e88d734ab`

The expected value was computed independently from the route preimage using `cast abi-encode` and
`cast keccak`; the test stores this fixed result rather than obtaining its expected value from the
factory function under test.

## Later admission gates

Later activation must separately admit the wrapper runtime identity and provenance, verify every
fixed configuration fact against the approved release and live chain state, and verify the local
CCTP source domain against the admitted Circle messenger deployment or exact message evidence.
Circle's pinned caller interface is not extended with an assumed generic domain getter. The Base
compatibility and canary requirements in [Security](../SECURITY.md) also remain unsatisfied.
