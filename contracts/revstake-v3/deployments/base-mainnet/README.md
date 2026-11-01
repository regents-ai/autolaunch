# Base mainnet

**Not deployed.** `mainnet-no-go-packet.json` carries no selection: the deployer, its starting
nonce and the time to send are the founder's decision, and nothing in this directory authorizes a
deployment. `deployed-manifest.json` is the empty record; it is written once, by `record`, from
confirmed Base receipts.

The tool is `../stocks-v2/bin/ceremony.py`, shared with version 2 and run from this package
directory (`contracts/revstake-v3`). Version 3 builds on version 2's deployment: `prepare` reads
the four contracts it reuses from `../revstake-v2/deployments/base-mainnet/deployed-manifest.json`
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
Regent Safe's `unpauseLaunches()`, by its own decision once Base runs 0.2-second blocks.

## Steps

```sh
cd contracts/revstake-v3                                         # with ../stocks-v3/lib in place
python3 ../stocks-v2/bin/ceremony.py render                      # offline
python3 ../stocks-v2/bin/ceremony.py prepare --deployer 0x…      # read-only, REGENT_BASE_RPC_URL
# review reports/generated/deployment/mainnet-no-go-packet.json, install it here, commit it
python3 ../stocks-v2/bin/ceremony.py rehearse                    # read-only
python3 ../stocks-v2/bin/ceremony.py preflight 0                 # right before the creation
python3 ../stocks-v2/bin/ceremony.py record --receipts receipts.json --approved-digest 0x…
```

`rehearse` reads the latest Base block's gas limit off the node at that run and offers the
creation all of it. Base's block gas limit changes with Denim on 5 November 2026, so it is never
assumed; a creation that needs more than one block holds fails the rehearsal.
