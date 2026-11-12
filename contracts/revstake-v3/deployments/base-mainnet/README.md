# Base mainnet

**Not deployed.** `mainnet-no-go-packet.json` carries the selection `prepare` derived on 12 November
2026 at Base block 56,518,999 (digest
`0x0ef9d1209779378e80a4982f72c1e176bd04cf38a8a3982e95cfac59c5cb6f28`): the deployer
`0x9b2C414614aEE294202c1219520955EF3B596031` at nonce 68, before Base Memestake version 3's two
creations at 69 and 70. Sending is the founder's decision alone, and nothing in this directory
authorizes it. `deployed-manifest.json` is the empty record; it is written once, by `record`, from
confirmed Base receipts.

The selection holds only while the deployer's nonce is 68. Anything else the deployer sends first
moves it, the deploy script then stops before sending anything, and both packets are prepared again
at the new nonces.

| Nonce | Creates | Predicted address |
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
python3 ../stocks-v3/bin/ceremony.py record --receipts receipts.json --approved-digest 0x…
```

`rehearse` reads the latest Base block's gas limit off the node at that run and offers the
creation all of it. Base's block gas limit changes with Denim on 5 November 2026, so it is never
assumed; a creation that needs more than one block holds fails the rehearsal.
