# Autolaunch user-journey candidate — 24 September 2026

Branch: `astra/user-journeys-2026-09-24`, based on `97f46b3021acdfc3123ef582942ff1d0bf8ae7e4`.
Implementation checkout: `/Users/sean/Documents/regent/worktrees/autolaunch/astra-user-journeys`.

## Done and boundaries

The local candidate should keep browsing simple, query the full database rather
than a capped in-memory list, show verified creator connections, and make the
next claim/refund/staking step explicit. Changed behavior must pass focused checks
and representative browser review. Real wallet execution, production OAuth,
the Linux release image, migration and deployment remain separate release evidence.
No contract source was changed, no wallet was used and nothing was pushed or deployed.

## User journeys

“Browser” means the isolated local preview with synthetic records. “Representative”
means component/action or mocked-chain checks with the real application code. Neither
means a real network transaction succeeded.

| # | Journey | Candidate behavior and evidence |
|---|---|---|
| 1 | New visitor understands the site | Browse without connecting a wallet; sign-in required only for personal actions. Browser. |
| 2 | Returning user finds holdings | Portfolio links to the matching network/token staking page and preserves holdings during refresh. Code and existing checks. |
| 3 | Find an auction in a large archive | Database search, network/type/state filters and cursor pagination; 10,000 records traversed without duplication. Browser and database checks. |
| 4 | Compare auctions quickly | Card/list views, newest/closing/volume ordering; closing and volume use persisted chain-derived data. Browser and database checks. |
| 5 | Read auction terms and provenance | Detail pages retain terms and contracts and show X, ENS and GitHub links. Browser. |
| 6 | Create Base Revstake | Correct creation route plus optional verified creator connections. Browser entry and representative forms; real submission remains. |
| 7 | Create Base Memestake | Correct creation route plus the same connections. Browser entry and existing form checks; real submission remains. |
| 8 | Create Robinhood Memestake | Correct route; unsupported Robinhood Revstake remains unavailable. Browser entry; real submission remains. |
| 9 | Creator returns and shares | Connections appear on the auction and graduated token. Database mapping and browser checks. |
| 10 | Place a bid | Existing reviewed wallet path retained; every distinct press reaches the wallet. Existing JS checks; real transaction remains. |
| 11 | Return and add another bid | Refreshes retain account scope; existing wallet press behavior retained. Code and JS checks. |
| 12 | Auction reaches its end | Bid wording changes from buying/future refunds to outcome/settlement; existing finish action retained. Representative checks; real finish remains. |
| 13 | Winner claims then stakes | Claim to wallet or choose staking next; confirmed claim opens token staking with exact amount. Representative verified receipt and parent navigation check. |
| 14 | Partially filled bidder returns | Refund and token claim remain separate, with current outcome wording. Code/representative checks; real partial settlement remains. |
| 15 | Failed auction refunds | States the failed minimum, returned amount/currency and full receiving wallet. Representative UI; real failed-auction refund remains. |
| 16 | Browse graduated tokens | Same social filters and links on token gallery/details; preserved filters across tabs. Browser and database checks. |
| 17 | Buy then stake | A verified purchase offers staking with the received amount. Code/representative checks; real swap remains. |
| 18 | Stake a wallet holding | Stake-all uses wallet balance; form survives market refresh; shows full wallet and no lock period. Representative state checks and responsive UI. |
| 19 | Collect rewards or exit | Rewards disclosure, unstake-all from staked balance, and sell route retained. Representative UI; real rewards/unstake/sell remain. |
| 20 | Recover from rejection or account change | Separate wallet presses remain available; stale account inputs and pending staking intent clear when identity changes. Existing checks and representative state review. |

## Added social discovery and footer

- X uses the existing profile/company OAuth flow. GitHub uses Privy account linking
  and server-verified session refresh. ENS uses the shared `AgentEns` package;
  control and forward resolution must both match the signed-in wallet.
- X/ENS/GitHub filters combine with AND in SQL before counts and pagination,
  for auctions and tokens. All eight toggle combinations were checked.
- Gallery badges are compact; detail links expose the connected names.
- Newest, closing soon and highest bid volume are database sorts. Volume is an
  explicit USD estimate of total committed bids, not net proceeds.
- The footer reads confirmed persisted events, shows up to 20 from the last hour,
  links each to its auction, rounds USDC/USDG to dollars and REGENT millions to
  one decimal, and supports pause, keyboard focus and reduced motion.
- The background reader limits each pass to one auction and 2,000 blocks, narrows
  dense ranges, retries failures, separates live/history work and persists its
  cursor with events and totals. Repeated ranges do not duplicate bids; changed
  chain history invalidates and rebuilds the affected derived data.

## Local verification

- Existing Elixir suite: 92 passing tests; JavaScript suite: 12 passing tests;
  TypeScript check and asset build passed.
- Owned databases only: `autolaunch_astra_journeys_0924_test` (preview/manual)
  and `autolaunch_astra_journeys_checks_0924_test` (clean suite).
- The additive migration ran successfully on both. No production database access.
- A 10,000-auction archive was traversed without duplicates; cursor scope changes
  are rejected. Social combinations, counts and ordered pages were checked.
- Public identity reads cannot retrieve provider subjects or metadata; owner
  reads can. A local RPC fixture exercised the actual ENS library and rejected
  a name merely pointing to the wallet, an anonymous caller and a stale lease.
- Confirmed bid fixture checks covered persistence, USD totals, post-commit live
  notifications, retry deduplication and changed-history replay. Base Memestake
  adapter events were matched by auction, transaction and bid and rendered as
  `304 USDC`. Both live and historical database claim queries were exercised.
- Browser review covered list/grid, pagination, search, network/type/social
  filters, graduated token details, signed-out entry points and responsive
  staking layout. Ticker pause and its auction link worked.
- The real gallery was exercised in a 390-pixel frame: all social controls
  remained reachable and document width equaled viewport width after fixing
  the inherited filter offset. The local release-context assembler passed and
  included ENS/SIWA plus the exact input revisions. A Linux image was not built.
- Shared inputs at verification: `elixir-utils`
  `2a7c853e7973697e960b5ef9807e0d13b5ad777e`, `regents`
  `d5921ac4f762f490a0869b2d17024095f5b58e91`, `design-system`
  `5dd0d0a0a41faea131c18a44cb60388c662d3337`.
- Temporary verification scripts/logs are under `/tmp/astra-user-journeys/`;
  these are local evidence, not new permanent test suites.

## Contract limits and release follow-up

Existing contracts send claims and refunds to the original bid owner and credit
staking to the caller. This candidate therefore shows the full receiving wallet
but does not offer a misleading alternate-address or ENS recipient field. Claim
then transfer or stake-for-another requires a separately supported transaction
path. Claim-and-stake is a guided sequence with the wallet approvals the contracts
actually require, not a new atomic contract operation.

The staking copy says there is no lock period and tokens may be withdrawn, with
the next-block exception the contracts enforce. Share to X appears after a
verified stake and opens prefilled content; it never publishes automatically.

Before release, exercise real X/GitHub OAuth configuration, ENS against the
selected production RPC, and all three auction flows on this exact candidate.
In particular, retain the failed-minimum refund and buy/sell checks from the demo
agent. Its results from `97f46b3` are useful baseline evidence, not verification of
this changed candidate. The new Robinhood activity reader still needs its actual
chain/configuration canary, including its separate rollup clock and deployment
height search. Unknown prices or incomplete backfills sort last rather than
publishing a made-up volume. WorldID remains deferred.

Build the Linux image with the exact shared package revisions recorded in
`BUILD-INPUTS.txt`, including the newly required ENS and SIWA source inputs.
Apply migration `20260924134726_auction_activity` to `autolaunch_app` through the
normal authorized release procedure before serving this candidate. The migration
adds six nullable auction fields, their indexes, and the confirmed bid table.
It does not change balances or existing auction records.
