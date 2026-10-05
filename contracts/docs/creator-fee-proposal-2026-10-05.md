# Creator fees: proposal (5 Oct 2026)

**Decided 5 Oct (HQ 80 a, 81 a, 82, 83 a):** Revstake adds a 0.3% creator lane on top, paid to the
treasury (3.3% in all). Memestake keeps its 0.3% creator lane, takes no share of the raise, and its
supply becomes 49.75% auction, 49.75% pool and 0.5% to the launcher, vesting over 30 days. Item 3
below is withdrawn.

Sean's priority for the week: "Contract update for auction/token fees benefiting the creators of both
the memestock tokens and the revenue share tokens." Nothing below is deployed. Every change needs a new
rehearsal, a new digest and Sean's signed go.

## What the creator gets today (1 Oct terms)

| | Revstake (Base) | Memestake (Base and Robinhood) |
| --- | --- | --- |
| Supply | 70% vests to the creator's treasury over 365 days | 1% vests to the launching wallet over about 30 days (0.5% from 5 Oct) |
| Auction raise | At least half, paid in REGENT to the treasury; the rest goes into the locked pool | None; all of it goes into the locked pool |
| Auction fee | None | None |
| Trading fee | 3%: 1% Regent, 2% to the launch's stakers. No creator lane | 4.3%: **0.3% creator**, 1% Regent, 3% stakers. Paid in the stock token; anyone can trigger the payout |
| Pool fee (0.3%) and staker lane | 2% to Regent; stakers get their staked share of the total supply; **the unstaked rest goes to the treasury** | 2% to Regent, 98% to stakers; all of it to Regent when nothing is staked. Nothing to the creator |

Who "the creator" is: in Memestake, the wallet that pressed Launch. In Revstake, the treasury
address chosen at launch; the launching wallet gets nothing.

## Proposal

1. **Revstake trading fee: add a 0.3% creator lane, paid to the treasury.** This matches Memestake.
   The total becomes 3.3%: 0.3% creator, 1% Regent, 2% stakers. It is paid each swap in REGENT or the
   token, as the other two lanes are.
2. **Revstake auction: no change.** The creator already receives at least half the raise.
3. ~~Memestake auction: the creator receives a share of the raise at graduation.~~ Withdrawn 5 Oct:
   the whole raise goes to the pool, and the launcher's vesting share becomes 0.5%.
4. **Memestake trading fee: keep the 0.3% creator lane.**
5. While the contracts are open, fix the Revstake fee comments, which still say 2%.

## What changes on chain

- **Revstake:** only the fee hook changes. The factory creates the hook, so send 5 (nonce 32) changes,
  and a new hook address must be mined. Sends 1–4 stay as they are, but the packet is rehearsed again
  and gets a new digest in place of
  0xea59e17dfba46987fd75b3d9f8d937783a4324234e03bbbabf01bc47d124cfba.
- **Memestake Base and Robinhood:** the shared settings change (the supply split and the minimum raise). Both packets are
  still trial packets, so nothing is lost.

## Decisions (answered 5 Oct)

- Revstake creator lane: 0.3% on top, 3.3% total (80 a).
- Revstake creator: the treasury address (81 a).
- Memestake creator share of the raise: none; the launcher's vesting share is 0.5% (82).
- Memestake creator trading lane: keep 0.3% (83 a).
- The Revstake send stays held until the new hook is rehearsed and Sean gives a signed go (HQ 56).
