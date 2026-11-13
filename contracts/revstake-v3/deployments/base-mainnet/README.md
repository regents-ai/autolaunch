# Base mainnet

**Deployed and open, 12 November 2026.** The founder sent the creation of the packet
`mainnet-no-go-packet.json` (digest
`0x0ef9d1209779378e80a4982f72c1e176bd04cf38a8a3982e95cfac59c5cb6f28`, selection derived at Base
block 56,518,999) from the deployer `0x9b2C414614aEE294202c1219520955EF3B596031` at nonce 68, in
transaction `0x7aaf058f354f53b0992c6a550eb67a83da74ad87fbf90854cbd95a08e9e1d8ea` at Base block
56,660,037 (22:26 UTC). `deployed-manifest.json` is the record `record` wrote from the confirmed
receipt: every created contract landed at its prediction, its code matches the frozen build, and
the twelve wiring readbacks matched at the creation's block, the factory still paused.

The Governance and Regent Safe opened launches in transaction
`0x3ee0a4044b7641aae1fd7bb492f749fc03820fc74fa1f350d3070b07240c116f` at block 56,661,365 (22:30
UTC), the thirteen calls of `../../stocks-v3/deployments/base-mainnet/safe-switch-on.json`, whose
last is this factory's `unpauseLaunches()`. The factory reads `launchesPaused() == false` since. An
earlier identical batch, transaction `0x3719a6a6…e253a`, ran before the creations against
addresses that held no code yet and changed nothing.

Version 2's factory `0xf4F591E63f4B6d8240a150081C1CA7Edfaeb768E` stays paused; its launches keep
their bids, claims, vesting, staking and trading on version 2's own contracts.

| Nonce | Creates | Address |
| --- | --- | --- |
| 68 | RegentsAutolaunchFactoryV3 | `0xA738aa7c82324EE8fa17FbAaa34a227e90f67D48` |
| 68, inside | RegentLBPStrategyV3 | `0x9253413b8eD663548b15a596481E495698FA4a67` |
| 68, inside | RevstakeLPLocker | `0x30fDDFFDa111F52AcfACf8bc71F019B9dCC93925` |
| 68, inside | RegentFeeHook (salt `0x…f7cc`) | `0xcCc1F9f049AADF419Ae15CB976AE61c38c28e044` |

`transaction-data.txt` is the creation's data byte for byte: the init code hashes to the packet's
`creation_keccak256`, the rest is the packet's constructor arguments, and the deploy script sent
exactly these bytes on an anvil copy of Base at block 56,519,000, where the creation used 7,829,467
gas (forge asked for a limit of 10,178,307) and landed at its prediction. The rehearsal of all three
creations and the Safe batch, and how they are sent, are in
`../../stocks-v3/deployments/base-mainnet/README.md`.

The tool is `../stocks-v3/bin/ceremony.py`, shared with Base Memestake version 3 and run from this
package directory (`contracts/revstake-v3`). Version 3 builds on version 2's deployment: `prepare`
reads the four contracts it reuses from `../revstake-v2/deployments/base-mainnet/deployed-manifest.json`
and proves on Base that each carries the frozen runtime code hash.

## The whole ceremony

One plain zero-value contract creation from the deployer, `RegentsAutolaunchFactoryV3`, at the
starting nonce, with these constructor arguments:

| Argument | Version 2 contract | Address |
| --- | --- | --- |
| `uerc20Factory_` | UERC20Factory | `0x4c003500c6a28826d15A6E4cF023C1f1ecd41E08` |
| `escrowImplementation_` | ConditionalVestingEscrowV2 | `0x8F511153393429468C3861E7cC5341Abb3310871` |
| `splitterImplementation_` | SubjectSplitterV1 | `0x0886e34742B5E5ab8e07B0A6C3fC66A7912DE942` |
| `receiverImplementation_` | PaymentReceiverV1 | `0xb58f2AF6A588414C6ad44280143db9aE7927d5fc` |
| `hookSalt` | | the mined salt |

The factory's constructor refuses any of the four whose runtime code hash is not version 2's. It
creates `RegentLBPStrategyV3` (factory nonce 1), whose own constructor creates the
`RevstakeLPLocker`, and then `RegentFeeHook` (`CREATE2` over the mined salt). The factory is born
paused, and the deployer holds no role anywhere afterwards. Opening launches is the Governance and
Regent Safe's `unpauseLaunches()`, the last call of the Safe batch
`../../stocks-v3/deployments/base-mainnet/safe-switch-on.json`. Version 2's factory stays paused.

## Steps

```sh
cd contracts/revstake-v3                                         # with ../stocks-v3/lib in place
python3 ../stocks-v3/bin/ceremony.py render                      # offline
python3 ../stocks-v3/bin/ceremony.py prepare --deployer 0x…      # read-only, REGENT_BASE_RPC_URL
# review reports/generated/deployment/mainnet-no-go-packet.json, install it here, commit it
python3 ../stocks-v3/bin/ceremony.py rehearse                    # read-only
python3 ../stocks-v3/bin/ceremony.py preflight 0                 # right before the creation
python3 ../stocks-v3/bin/ceremony.py record --receipts receipts.json --approved-digest 0x…   # Foundry 1.5.1
```

`record` runs under Foundry 1.5.1, whose `cast --json` answers are the plain receipt and
transaction; 1.8.6 wraps them in an envelope the tool does not read. It reads the readbacks at the
last creation's block, so the Safe's later switch-on does not count against the ceremony.

`rehearse` reads the latest Base block's gas limit off the node at that run and offers the
creation all of it. Base's block gas limit changes with Denim on 5 November 2026, so it is never
assumed; a creation that needs more than one block holds fails the rehearsal.
