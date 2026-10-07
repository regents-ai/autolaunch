# Revstake v2: handoff, and launching from another contract

Status on 6 October 2026, branch `feat/contracts-v2`. Base Revstake v2 is deployed (the addresses
below are live on Base mainnet); the factory is born paused until the switch-on batch.

## Where the v2 deploy stands

| Step | State |
| --- | --- |
| Base Revstake (five creations, deployer `0x9b2C…6031`, nonces 28–32) | Deployed 6 October 2026 at Base blocks 52267808 to 52268160 from packet digest `0xf6c2bcac6100455da994e5822ec6f40777b26f3885a1e9c1cd525cc9ba5ec862`, sent by the founder; recorded in `deployments/base-mainnet/deployed-manifest.json`. |
| Base Memestake v2 | Packet digest `0x94fac84efc322f6ed6fe2a32d61acf51f4215cc78cae51ed01dfa3cea3db2e65` (twelve creations, nonces 33–44, binding the token factory `0x4c003500c6a28826d15A6E4cF023C1f1ecd41E08`) awaits the founder's go; see `contracts/stocks-v2/deployments/base-mainnet/README.md`. |
| Robinhood Memestake v2 | Waits for Base Memestake: its revenue receiver points at Base. A trial prepare and rehearse succeeded. |
| Switch-on | The Governance Safe `0x9fa1…9a3e` sends one batch that unpauses the v2 factory and the v2 Memestake launchpad and pauses both v1 entry points (see `deployments/base-mainnet/README.md`). |
| Website | `feat/v2-site` is built on these ABIs and held for release. |

The predicted addresses below come from `deployments/base-mainnet/README.md`. They hold only if the
packet is sent exactly as approved, from deployer nonce 28.

| Contract | Predicted address |
| --- | --- |
| `RegentsAutolaunchFactoryV2` | `0xf4F591E63f4B6d8240a150081C1CA7Edfaeb768E` |
| `RegentLBPStrategyV2` | `0x4dEEd15f650F45900F2e55a44eADe7bD5Fd556d9` |
| `RegentFeeHook` | `0x72bE4F7FAE670e42048697e010699316318A2044` |
| `RevstakeLPLocker` | `0x5483EfCc207F6233b393AC3Ab3ECE91D19a7C120` |
| `UERC20Factory` | `0x4c003500c6a28826d15A6E4cF023C1f1ecd41E08` |

Read the live factory after the send rather than trusting this table:
`strategy()`, `hook()` and `launchesPaused()`.

## Any contract can be the launcher

`RegentsAutolaunchFactoryV2.launch` is open to every caller. There is no allowlist, no fee, no
REGENT payment, no approval and no ETH. The one condition is that the Governance Safe has opened
launches (`launchesPaused()` is `false`). A contract calls it exactly like a wallet does:

```solidity
interface IRevstakeFactoryV2 {
    struct LaunchParams {
        string name;        // 1–64 bytes
        string symbol;      // 1–16 bytes
        string description; // 1–512 bytes
        string website;     // 1–256 bytes
        string image;       // 1–256 bytes
        address treasury;
    }

    function launch(LaunchParams calldata params)
        external
        returns (uint256 launchId, address subject, address auction, address escrow);
}

contract MyLauncher {
    IRevstakeFactoryV2 constant FACTORY = IRevstakeFactoryV2(0xf4F591E63f4B6d8240a150081C1CA7Edfaeb768E);

    function start() external returns (uint256 launchId, address token, address auction, address escrow) {
        (launchId, token, auction, escrow) = FACTORY.launch(
            IRevstakeFactoryV2.LaunchParams({
                name: "Example Agent",
                symbol: "EXA",
                description: "What the agent does",
                website: "https://example.com",
                image: "https://example.com/logo.png",
                treasury: address(this) // or any other address you control
            })
        );
    }
}
```

Every field must be non-empty and within its byte limit. Nothing else is checked: no character
rules and no URL checks. Everything else is fixed by the factory and the shared strategy, and the
caller cannot choose any of it: supply, split, floor price, minimum raise, schedule, pool, hook
and fees.

The call creates, in one transaction:

- the token: 100B, 18 decimals;
- its escrow, holding the 70%;
- its auction, holding the 20%.

The strategy keeps the 10% reserve. The factory emits:

```
LaunchCreated(launchId, launcher, subject, auction, escrow, treasury, startBlock, endBlock)
```

`launcher` is `msg.sender`, so for a contract it is the contract's address. That record is for
provenance only. **The launcher gains no rights and no money.** Everything of value goes to the
treasury.

## The treasury is what matters

The treasury is fixed when you launch and can never change. Choose it carefully: a contract
treasury that cannot move ERC-20s out locks the launch's money in it forever.

What the treasury receives, all as plain ERC-20 transfers (no callbacks, no NFTs):

| When | What | Who triggers it |
| --- | --- | --- |
| Graduation (`strategy.migrate(auction)`) | At least half of the REGENT raised; the other half funds the locked pool position | Anyone; the Regent bot sends it |
| Over 365 days after graduation | The 70% plus any unpaired reserve and leftovers, via `escrow.release()` | Anyone; it always pays the treasury |
| Every revenue deposit to the launch's splitter | The share not earned by stakers: net revenue × (unstaked supply ÷ 100B), after a 2% skim | Whoever deposits revenue or calls `recognizeSurplusRevenue` |
| Recovery calls on the splitter and receivers | Unsupported tokens and forced ETH | Anyone |

At graduation the treasury also becomes the beneficiary and note editor of the launch's canonical
payment receiver. A contract treasury that wants to set the receiver's note needs a way to call
`setReceiverNote(bytes32)`. Nothing else needs the treasury to sign.

These addresses are refused as the treasury, and the launch reverts:

- zero, or the escrow itself;
- the factory, strategy, hook or LP locker;
- Uniswap's PoolManager or PositionManager;
- live REGENT staking.

## After the launch

1. **Bidding**
   - The auction opens 300 blocks after creation and runs 86,401 blocks (about two days on Base).
   - Bids are in REGENT through the pinned Uniswap CCA:
     `submitBid(maxPriceQ96, amount, owner, hookData)` on the `auction` address.
   - The auction pulls REGENT through Permit2. A contract bidder approves Permit2 for REGENT, then
     approves the auction inside Permit2 (`Permit2.approve(REGENT, auction, amount, expiration)`).
   - Any contract may bid, including the launcher.
2. **The minimum**
   - A launch needs `1,084,202,174` REGENT base units raised (about 1.08e-9 REGENT), and the
     launch fails without it.
   - Bid the minimum plus one base unit: a raise of exactly the minimum counts only in the
     auction's first block.
3. **Graduation**
   - `migrate(auction)` on the strategy can be called by anyone from 128 blocks after the end.
   - It opens the official token/REGENT Uniswap v4 pool at the auction's final clearing price.
   - It locks the pool position forever and pays the treasury.
   - It creates the launch's splitter and canonical payment receiver, and starts vesting.
   - Events: `LaunchGraduated` and `LaunchSettled`.
4. **Failure**
   - If the minimum was not reached, `migrate` retires the launch.
   - Bidders take their REGENT back from the auction, and the whole token supply goes to the dead
     address.
5. **Claims**
   - Bidders exit their bids and call `claimTokens` from 64 blocks after the end.
   - Anyone may claim for any bid; the tokens always go to the bid's owner.
6. **Fees**
   - Every swap in the official pool pays the LP fee of 0.30% plus the hook's 3%: 1% to Regent and
     2% to the launch's splitter.
   - The locked position's fees can be sent to the splitter by anyone through
     `RevstakeLPLocker.collect(tokenId)`.
7. **Extra payment receivers**
   - After graduation, anyone may create more receivers for the launch with
     `factory.createPaymentReceiver(launchId, beneficiary, referralBps)`.
   - The caller becomes that receiver's note editor.

## How autolaunch.sh treats a launch made by a contract

The site records every factory `LaunchCreated` it sees, from any caller. It **lists** a launch only
when it can match it to a review made on the site. The review's signer, target and calldata must
equal the transaction that created the launch. A launch sent from another contract has the calling
contract as its target, so it is recorded as **unlisted** and does not appear on the site's
auction pages.

The launch itself works fully on chain either way: bidding, graduation, pool, fees and vesting.
Whether the site should list launches made by contracts is a product decision that has not been
taken.

## Revstake is Base only

Revstake launches exist only on Base. Robinhood Chain allows memestock (Memestake) auctions only,
through `RobinhoodStocksLaunchpadV2`. Those take a stock pairing and follow the Memestake terms,
not the ones above.
