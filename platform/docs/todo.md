# Autolaunch to-do

## Auction counts by launch type

Noted by the founder on 22 September 2026:

> There's a public auction list, but no ready-made count for the three categories. The public
> API provides the data: base + agent means Revstake; base + stocks means Memestake; robinhood +
> stocks means Robinhood Memestake. A tracker would need to follow its pages and tally them.
>
> I checked the public API read-only. It currently returns zero listed auctions, both overall and
> open for bidding. That describes what the site exposes today, not a verified count of every
> auction on either chain. I made no changes.

The website now shows these counts in a thin band on the home, auctions and create pages:
Revstake Auctions (live and graduated) and Memestake Auctions (live and graduated, Base and
Robinhood together). Live means open for bidding, the same as the auctions list's live filter.

Still open: the public API has no counts of its own, so an outside tracker must still page
through the auction list and tally it.

## Creator X accounts before activation

Checked 22 September 2026 by secret name only: the live app `autolaunch-sh` holds no
`X_OAUTH_CLIENT_ID` (nor `PRIVY_APP_ID`; the site is still the read-only prelaunch). Until an
X app is registered with the callback `https://autolaunch.sh/auth/x/callback` and its client id
is set, creators cannot add X accounts and no auction or token shows a creator link.

Robinhood launches name their creator by the launching wallet: the account whose signed-in
wallet it still is, when exactly one account's is. The launch itself required that wallet.
