# Robinhood Chain: the Memestake v2 ceremony

`mainnet-no-go-packet.json` was prepared on 7 October 2026 against live Robinhood Chain at block
82653102 and live Base at block 52302598, for deployer
`0x9b2C414614aEE294202c1219520955EF3B596031` at nonce 31 on Robinhood Chain and nonce 49 on Base,
and rehearsed against both chains with no signer. It admits the same 25 stocks, pools and feeds as
the v1 ceremony, in the same order. Its digest is
`0x50fae25da62216dd4131e5d3e5983317cd7f563b7f12704ea43216c2303075b2`. Nothing may be sent until the
founder names that digest.

The tool is `../stocks-v2/bin/ceremony.py`, run from this package directory (`contracts/robinhood-v2`).
`deployed-manifest.json` is the record, empty until `record` fills it from confirmed receipts.

The deployer is also the founder's everyday wallet. Any other transaction it sends on Base before
the receiver below, or on Robinhood Chain before the last route, moves its nonce and makes this
packet stale; the practice run then has to be repeated for a new digest.

## The whole ceremony

Thirty-two plain zero-value contract creations from the deployer, in nonce order: six fixed
creations and twenty-five routes on Robinhood Chain (chain id 4663), then the revenue receiver on
Base (chain id 8453). The launchpad's constructor asks the hook factory for the fee hook
(`CREATE2` over the mined salt `0x000000000000000000000000000000000000000000000000000000000000068a`), then creates the
splitter implementation and the LP locker.

| Chain | Nonce | Contract | Predicted address |
| --- | --- | --- | --- |
| Robinhood | 31 | UERC20Factory | `0xb58f2AF6A588414C6ad44280143db9aE7927d5fc` |
| Robinhood | 32 | RobinhoodProtocolRevenueInboxV1 | `0xf4F591E63f4B6d8240a150081C1CA7Edfaeb768E` |
| Robinhood | 33 | RobinhoodPositionsLib | `0x1d4bc582a9193061d53c4BFA429D366Ed38eEd0B` |
| Robinhood | 34 | RobinhoodFeeHookFactory | `0x528fF2ef4EAf382461269aE4290b15b065080Dae` |
| Robinhood | 35 | RobinhoodStocksLaunchpadV2 | `0xc0e910234d2a057Eb5E78B69C5149567617c0563` |
| Robinhood | 36 | RobinhoodStockBidAdapterV1 | `0x7755bB35d838602748a44A66f671f96f2b42eFa2` |
| Robinhood | 37 | UniswapV3StockRouteV1 (AAPL) | `0x4dC2b96F07271b82e0F97DfF7A1555153fe3EF6d` |
| Robinhood | 38 | UniswapV3StockRouteV1 (AMD) | `0x71280E11Da1B4ed47E168B364fb52e2918975417` |
| Robinhood | 39 | UniswapV3StockRouteV1 (AMZN) | `0xC090F75b7C664a60CA56aE4b8590De34e46FBDe1` |
| Robinhood | 40 | UniswapV3StockRouteV1 (BABA) | `0x8e901a2b5775d3FF8d93E8c83D0622df08D74868` |
| Robinhood | 41 | UniswapV3StockRouteV1 (CRCL) | `0x390Bc80fCf71dBcd3782fF9DB3954a7211fed999` |
| Robinhood | 42 | UniswapV3StockRouteV1 (DELL) | `0x75d0B57bC539F72DD16fB248855873126bd08916` |
| Robinhood | 43 | UniswapV3StockRouteV1 (GME) | `0xC9Ae2AeBa42fC2408Ac664Ef278dF1D996E27B19` |
| Robinhood | 44 | UniswapV3StockRouteV1 (GOOGL) | `0x55009863EaFf428C4dc52520f6468B423C99B38a` |
| Robinhood | 45 | UniswapV3StockRouteV1 (INTC) | `0xF9E8F9AA8847C5eE0fCa0306fD863E18BE864CC8` |
| Robinhood | 46 | UniswapV3StockRouteV1 (META) | `0x5D3CD2588e3C288e77693C72D5a54deB3916383f` |
| Robinhood | 47 | UniswapV3StockRouteV1 (MSFT) | `0x5070a3A2F20E7dEDf8a3E8eb3142cA5e1cc2E89e` |
| Robinhood | 48 | UniswapV3StockRouteV1 (MSTR) | `0xA209312b751Fb621Af63d3dFB80F7284Ac7Ae594` |
| Robinhood | 49 | UniswapV3StockRouteV1 (MU) | `0xc5B0FFC447796CB8F44E35fE844bC9Ac81472f1e` |
| Robinhood | 50 | UniswapV3StockRouteV1 (NVDA) | `0x15741dA3EAb718565C1fFA0Ccbbc1b9FaA984FB6` |
| Robinhood | 51 | UniswapV3StockRouteV1 (PLTR) | `0x2d856296C8398e82F1746A262AE60Cc273916bA8` |
| Robinhood | 52 | UniswapV3StockRouteV1 (QQQ) | `0x6329C349fEaCA53c3646c205F3e7311f4139026C` |
| Robinhood | 53 | UniswapV3StockRouteV1 (SGOV) | `0x9DB034B53d69F9D768e711D990bAB26b09C4bCcE` |
| Robinhood | 54 | UniswapV3StockRouteV1 (SLV) | `0x82F62aE092DcF99fFa7fF15a9ac63488D5b4F5C7` |
| Robinhood | 55 | UniswapV3StockRouteV1 (SNDK) | `0x6e80e0b65F50666E230276FD5bEf61059aC65f98` |
| Robinhood | 56 | UniswapV3StockRouteV1 (SPCX) | `0xAECE72c94CaC843f9Ecd54aC6Ca833bF4CFED048` |
| Robinhood | 57 | UniswapV3StockRouteV1 (SPY) | `0x2773F49DC59bB82E19e0317822FfC37E13b71131` |
| Robinhood | 58 | UniswapV3StockRouteV1 (TSLA) | `0x64b8404E979EC2791E68f55d959d011EA4EEA88a` |
| Robinhood | 59 | UniswapV3StockRouteV1 (TSM) | `0x01CB7E396954583aA7A62105549B3E76777e5fEE` |
| Robinhood | 60 | UniswapV3StockRouteV1 (USAR) | `0x9E3faE9111c426577f0627e5795bA622D9B44f57` |
| Robinhood | 61 | UniswapV3StockRouteV1 (USO) | `0xeb3e597A13410cc6f57A5A40bdE239Ff05507617` |
| Robinhood | (launchpad) | RobinhoodFeeHookV1 | `0x073AF13E3Cb4be2f5200e2f0e97ffc7e5fe5A0CC` |
| Robinhood | (launchpad) | RobinhoodMemestockSplitterV1 | `0x8F47B5D2B55D5472830337E2FfaB5364Ba8A56Fe` |
| Robinhood | (launchpad) | MemestockLPLocker | `0x23c951E9006Ede99c61AeF1D0f12a2b5a6459fe3` |
| Base | 49 | RobinhoodBaseRevenueReceiverV1 | `0xc5B0FFC447796CB8F44E35fE844bC9Ac81472f1e` |

Some addresses repeat ones the same deployer already holds on Base (the inbox here and the Base
Revstake v2 factory share `0xf4F591E63f4B6d8240a150081C1CA7Edfaeb768E`, for example). Each pair is the same nonce on two
different chains, so the contracts are unrelated.

The launchpad is born paused and holds no owner: the admin Safe `0x9fa152B0EAdbFe9A7c5C0a8e1D11784f22669a3e`
(2 of 3 owners on Robinhood Chain) is its only authority. The deployer holds no role anywhere after
the last creation.

## Opening it is a separate act

After the record, the admin Safe on Robinhood Chain, in one transaction batch:

1. `setBaseDestination(address)` on the inbox, naming the Base receiver `0xc5B0FFC447796CB8F44E35fE844bC9Ac81472f1e`.
2. `setBridgeAdapter(address)` on the inbox, naming the bridge adapter the founder selects.
3. `admitStock(address stock, address route)` on the launchpad, once per stock, with its route above.
4. `setExecutor(address)` on the fee hook `0x073AF13E3Cb4be2f5200e2f0e97ffc7e5fe5A0CC`.
5. `unpauseLaunches()` on the v2 launchpad `0xc0e910234d2a057Eb5E78B69C5149567617c0563`.
6. `pauseLaunches()` on the v1 launchpad `0x635615cCEF2Ef24D0655fC2eBC47a14e005FEF6e`, so new
   launches only open on v2. Existing v1 launches keep their bids, claims and withdrawals.

## Sending the ceremony by hand

The founder sends each creation from a signer of his own, confirms its receipt (chain, sender,
nonce, created address, status) against the table above, and only then sends the next. If any
creation lands elsewhere, the packet is terminal and is never resumed. `robinhood` and `base` are
the `[rpc_endpoints]` aliases in `foundry.toml`. The signer flags are the founder's own and are
never written down here.

Nonce 31:

```bash
forge create ../stocks-v2/lib/uerc20-factory/src/factories/UERC20Factory.sol:UERC20Factory --rpc-url robinhood --broadcast
```

Nonce 32:

```bash
forge create src/RobinhoodProtocolRevenueInboxV1.sol:RobinhoodProtocolRevenueInboxV1 --rpc-url robinhood --broadcast --constructor-args 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168 0x9fa152B0EAdbFe9A7c5C0a8e1D11784f22669a3e
```

Nonce 33:

```bash
forge create src/libraries/RobinhoodPositionsLib.sol:RobinhoodPositionsLib --rpc-url robinhood --broadcast
```

Nonce 34:

```bash
forge create src/RobinhoodFeeHookFactory.sol:RobinhoodFeeHookFactory --rpc-url robinhood --broadcast --constructor-args 0x8366a39CC670B4001A1121B8F6A443A643e40951
```

Nonce 35:

```bash
forge create src/RobinhoodStocksLaunchpadV2.sol:RobinhoodStocksLaunchpadV2 --rpc-url robinhood --broadcast --libraries src/libraries/RobinhoodPositionsLib.sol:RobinhoodPositionsLib:0x1d4bc582a9193061d53c4BFA429D366Ed38eEd0B --constructor-args "(0xb58f2AF6A588414C6ad44280143db9aE7927d5fc,0x000000001F26a0044BaA66024e7b6599c61963F8,0x8366a39CC670B4001A1121B8F6A443A643e40951,0x58daec3116aae6D93017bAAea7749052E8a04fA7,0x528fF2ef4EAf382461269aE4290b15b065080Dae,0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168,0xf4F591E63f4B6d8240a150081C1CA7Edfaeb768E,0x9fa152B0EAdbFe9A7c5C0a8e1D11784f22669a3e)" 0x000000000000000000000000000000000000000000000000000000000000068a
```

Nonce 36:

```bash
forge create src/RobinhoodStockBidAdapterV1.sol:RobinhoodStockBidAdapterV1 --rpc-url robinhood --broadcast --constructor-args 0xc0e910234d2a057Eb5E78B69C5149567617c0563 0x000000000022D473030F116dDEE9F6B43aC78BA3
```

Nonce 37, AAPL:

```bash
forge create src/routes/UniswapV3StockRouteV1.sol:UniswapV3StockRouteV1 --rpc-url robinhood --broadcast --constructor-args 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9 0xAae0d815EE56e4092a5E5C2911E676Fea50B2d6D 0x6B22A786bAa607d76728168703a39Ea9C99f2cD0
```

Nonce 38, AMD:

```bash
forge create src/routes/UniswapV3StockRouteV1.sol:UniswapV3StockRouteV1 --rpc-url robinhood --broadcast --constructor-args 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168 0x86923f96303D656E4aa86D9d42D1e57ad2023fdC 0x48D284A2A4d3DC1b3Da08231Fe44317e7e7Aa51f 0x943A29E7ae51A4798823ca9eEd2ed533B2A22C72
```

Nonce 39, AMZN:

```bash
forge create src/routes/UniswapV3StockRouteV1.sol:UniswapV3StockRouteV1 --rpc-url robinhood --broadcast --constructor-args 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168 0x12f190a9F9d7D37a250758b26824B97CE941bF54 0x8AC92DA74AB5F3b1d024Dc1943Ad7e15Dc4179Ef 0xD5a1508ceD74c084eBf3cBe853e2C968fB2a651C
```

Nonce 40, BABA:

```bash
forge create src/routes/UniswapV3StockRouteV1.sol:UniswapV3StockRouteV1 --rpc-url robinhood --broadcast --constructor-args 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168 0xad25Ac6C84D497db898fa1E8387bf6Af3532a1c4 0xa57ab582b310dd6f9e934EA1EEEa152741545E6A 0x62Cc8F9b5f56a33c9C8A60c8B92779f523c4E984
```

Nonce 41, CRCL:

```bash
forge create src/routes/UniswapV3StockRouteV1.sol:UniswapV3StockRouteV1 --rpc-url robinhood --broadcast --constructor-args 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168 0xdF0992E440dD0be65BD8439b609d6D4366bf1CB5 0x654E4143e82a5824445Ade0824351C2A9ACD95a8 0x6652eDf64bA3731C4F2D3ce821A0Fb1f1f6b482a
```

Nonce 42, DELL:

```bash
forge create src/routes/UniswapV3StockRouteV1.sol:UniswapV3StockRouteV1 --rpc-url robinhood --broadcast --constructor-args 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168 0x941AE714EC6D8130c7B75d67160Ca08f1e7d11Dd 0xc30c89cB7815A1488b7998D15eEC73961707Fc5a 0x1C6c8cADBe02E19129c39dDB92281cE4c0bf206b
```

Nonce 43, GME:

```bash
forge create src/routes/UniswapV3StockRouteV1.sol:UniswapV3StockRouteV1 --rpc-url robinhood --broadcast --constructor-args 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168 0x1b0E319c6A659F002271B69dB8A7df2F911c153E 0xE2b46c905E12Ab8E2f864e4821a4325884C1B126 0x27C71df6A64fB476468EdF256CF72c038baB5B67
```

Nonce 44, GOOGL:

```bash
forge create src/routes/UniswapV3StockRouteV1.sol:UniswapV3StockRouteV1 --rpc-url robinhood --broadcast --constructor-args 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168 0x2e0847E8910a9732eB3fb1bb4b70a580ADAD4FE3 0x34D0dC122CF9A8Eb296fC5e0D3A233625D7d19b7 0xF6f373a037c30F0e5010d854385cA89185AE638b
```

Nonce 45, INTC:

```bash
forge create src/routes/UniswapV3StockRouteV1.sol:UniswapV3StockRouteV1 --rpc-url robinhood --broadcast --constructor-args 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168 0xc72b96e0E48ecd4DC75E1e45396e26300BC39681 0x2e5a92f5013a64661A49312111be2e8aBd33F56a 0x3f390C5C24628Ac7C489515402235FeAD71D1913
```

Nonce 46, META:

```bash
forge create src/routes/UniswapV3StockRouteV1.sol:UniswapV3StockRouteV1 --rpc-url robinhood --broadcast --constructor-args 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168 0xc0D6457C16Cc70d6790Dd43521C899C87ce02f35 0x107a7Cb40d8665360ba10E59471Af06150A50922 0x7C38C00C30BEe9378381E7B6135d7283356D71b1
```

Nonce 47, MSFT:

```bash
forge create src/routes/UniswapV3StockRouteV1.sol:UniswapV3StockRouteV1 --rpc-url robinhood --broadcast --constructor-args 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168 0xe93237C50D904957Cf27E7B1133b510C669c2e74 0xeb60bCD1D920ad6E102690CCFC6fB488899E1510 0x45C3C877C15E6BA2EBB19eA114Ea508d14C1Af2E
```

Nonce 48, MSTR:

```bash
forge create src/routes/UniswapV3StockRouteV1.sol:UniswapV3StockRouteV1 --rpc-url robinhood --broadcast --constructor-args 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168 0xec262a75e413fAfD0dF80480274532C79D42da09 0x17578C0e0D15da44f31677263114F71aE76653EA 0x396118bdFB181e6240E74D243F266B061c0edc3D
```

Nonce 49, MU:

```bash
forge create src/routes/UniswapV3StockRouteV1.sol:UniswapV3StockRouteV1 --rpc-url robinhood --broadcast --constructor-args 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168 0xfF080c8ce2E5feadaCa0Da81314Ae59D232d4afD 0xd057B1Bc54917855BBee58eAd58647f47caB35E5 0x425EEFdCf05ed6526C3cE61Af99429A228a6d596
```

Nonce 50, NVDA:

```bash
forge create src/routes/UniswapV3StockRouteV1.sol:UniswapV3StockRouteV1 --rpc-url robinhood --broadcast --constructor-args 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC 0xd4EB21209C4D6093f80B5b84f5C45cc093EA14a3 0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15
```

Nonce 51, PLTR:

```bash
forge create src/routes/UniswapV3StockRouteV1.sol:UniswapV3StockRouteV1 --rpc-url robinhood --broadcast --constructor-args 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168 0x894E1EC2D74FFE5AEF8Dc8A9e84686acCB964F2A 0x851680416A4f4E1c463d45171d61ACDdBc8554c0 0x820ABedFF239034956B7A9d2F0a331f9F075eB4c
```

Nonce 52, QQQ:

```bash
forge create src/routes/UniswapV3StockRouteV1.sol:UniswapV3StockRouteV1 --rpc-url robinhood --broadcast --constructor-args 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168 0xD5f3879160bc7c32ebb4dC785F8a4F505888de68 0xD60A5d14dB690B7Afad71F76B108071D7175597d 0x80901d846d5D7B030F26B480776EE3b29374C2ae
```

Nonce 53, SGOV:

```bash
forge create src/routes/UniswapV3StockRouteV1.sol:UniswapV3StockRouteV1 --rpc-url robinhood --broadcast --constructor-args 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168 0x92FD66527192E3e61d4DDd13322Aa222DE86F9B5 0x6Ba50150B17Ffd0972915Aaf04fFd5E8f4Fa49b4 0xa0DF4ee0fFf975306345875E3548Fcc519577A11
```

Nonce 54, SLV:

```bash
forge create src/routes/UniswapV3StockRouteV1.sol:UniswapV3StockRouteV1 --rpc-url robinhood --broadcast --constructor-args 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168 0x411eFb0E7f985935DAec3D4C3ebaEa0d0AD7D89f 0x8cB787e6c315D464775289BaD00FDD67d53Ecb3D 0x209b73908e92Ae021826eD79609845451Ecba2ce
```

Nonce 55, SNDK:

```bash
forge create src/routes/UniswapV3StockRouteV1.sol:UniswapV3StockRouteV1 --rpc-url robinhood --broadcast --constructor-args 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168 0xB90A19fF0Af67f7779afF50A882A9CfF42446400 0xA1e1C9519cD5ae47e9A935645E1A7b935b944559 0xfb133Fa4B7b385802B693a293606682Df47109A3
```

Nonce 56, SPCX:

```bash
forge create src/routes/UniswapV3StockRouteV1.sol:UniswapV3StockRouteV1 --rpc-url robinhood --broadcast --constructor-args 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168 0x4a0E65A3EcceC6dBe60AE065F2e7bb85Fae35eEa 0xc61284332117c3FB23A2A56cceFFD07F7aF60029 0xB265810950ba6c5C0Ff821c9963014a56fD8Bffb
```

Nonce 57, SPY:

```bash
forge create src/routes/UniswapV3StockRouteV1.sol:UniswapV3StockRouteV1 --rpc-url robinhood --broadcast --constructor-args 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168 0x117cc2133c37B721F49dE2A7a74833232B3B4C0C 0xa7Bb1AC63BBaB0C44316E6c8C455213441689167 0x319724394D3A0e3669269846abE664Cd621f9f6A
```

Nonce 58, TSLA:

```bash
forge create src/routes/UniswapV3StockRouteV1.sol:UniswapV3StockRouteV1 --rpc-url robinhood --broadcast --constructor-args 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168 0x322F0929c4625eD5bAd873c95208D54E1c003b2d 0xf4ACdAEEB7022862A763C9B1B885e11191c889E3 0x4A1166a659A55625345e9515b32adECea5547C38
```

Nonce 59, TSM:

```bash
forge create src/routes/UniswapV3StockRouteV1.sol:UniswapV3StockRouteV1 --rpc-url robinhood --broadcast --constructor-args 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168 0x58FfE4a942d3885bAa22D7520691F611EF09e7AA 0x07e8Ea83D4C1340774c8965125e26e12bf943bf1 0x874cF94aa8eC88Fd9560094dD065f2fB3E41Fc2F
```

Nonce 60, USAR:

```bash
forge create src/routes/UniswapV3StockRouteV1.sol:UniswapV3StockRouteV1 --rpc-url robinhood --broadcast --constructor-args 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168 0xd917B029C761D264c6A312BBbcDA868658eF86a6 0x04391780F519B7d3ba59c9590459D76e23d225C4 0xA994d3684e8400A6c8078226925779FdeE682DD9
```

Nonce 61, USO:

```bash
forge create src/routes/UniswapV3StockRouteV1.sol:UniswapV3StockRouteV1 --rpc-url robinhood --broadcast --constructor-args 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168 0xa30FA36Db767ad9eD3f7a60fC79526fB4d56D344 0x02175608F1b5E6b5ed221cCFdC7Be197D111D915 0x75a9c76Ef439e2C7c2E5a34Ab105EcFe3766431c
```

Base, nonce 49:

```bash
forge create src/RobinhoodBaseRevenueReceiverV1.sol:RobinhoodBaseRevenueReceiverV1 --rpc-url base --broadcast --constructor-args 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913 0xb027Dc261636E30Cbc0fE25b2F8e1ed273354AB5 0x9fa152B0EAdbFe9A7c5C0a8e1D11784f22669a3e
```

## Recording

With every receipt confirmed, list the 32 transaction hashes in ceremony order (the six fixed
creations, the routes, the Base receiver last) in a JSON file and run:

```bash
python3 ../stocks-v2/bin/ceremony.py record --receipts receipts.json --approved-digest 0x50fae25da62216dd4131e5d3e5983317cd7f563b7f12704ea43216c2303075b2
```

`record` proves each transaction's chain, sender, nonce, order, created address and status against
the packet, proves every created contract's code against the frozen build, reads back the bindings,
and writes the deployed-manifest candidate to `reports/generated/deployment/`. A human installs it
here.

## The website's file

```bash
python3 ../stocks-v2/bin/ceremony.py site-config --rpc-url URL --public-rpc-url URL --run-id LABEL
```

writes `reports/generated/deployment/site-config.json` in the shape the website loads. It carries
the endpoints passed on the command line and is never committed.
