# Changelog

What changed on autolaunch.sh, newest first. Each entry names the live version on Fly
(`autolaunch-sh`) and the commit it was built from.

## v125, 14 October 2026: launch and agent tools are easier to find
- Available to Pair links Memestock to the create page and shows Dual Stock Token greyed out with a Coming soon hint.
- The sidebar ends with an orange Launch button. The header links to agents.md, and a glossy vgpu badge below it shows the tool count from the site's manifest.

## v124, 14 October 2026: stock details and clearer Explore navigation
- Onchain Stocks moves to `/upcoming-stocks`; `/upcoming` redirects there. Clicking a stock opens its token and Chainlink addresses, company and stock links, and dated pool details. Escape closes the dialog.
- Available to Pair preserves its 35 established stocks. New research appears in Soon Available (14 stocks) and Chainlink Feed Required (78 stocks). Soon Available says "pending Autolaunch smart contract enablement." Liquidity uses compact dollar amounts.
- The sidebar says Docs and adds smaller Auctions and Tokens links beneath Explore. Both lists share the Explore page.

## v123, 14 October 2026 (d787d04): token pages quote prices again
- The price impact box on a token page gives buy and sell figures again, on Base and Robinhood, where it had said "The quote did not come back" for every size.
- Checking a bid on an auction that has ended now speaks in the past, against the final price: for example "Above the final price: bought every block". A withdrawn bid says its unspent money was already returned when it was withdrawn.
- A Base Memestock auction now shows its token's address under Additional Details and in the site's token list for agents, as Robinhood ones already did. AIFROG, BITE, JollyBoi and two earlier auctions now show theirs too.
- The "Uniswap Pool" button at the top of a Base token page opens the token's pool on Uniswap, as it already did on Robinhood.

## v122, 14 October 2026 (d8e3135): the stock watcher always moves on to the next stocks
- The site's ten-minute check of stocks waiting to be added now marks each stock's turn before it starts. A check that runs out of time sends that stock to the back of the line, so a few slow stocks can no longer hold up the rest. Visitors see no change.

## v121, 14 October 2026 (c51d0a9): finished auctions lead on to their token
- An auction that ended below its minimum says "Minimum not met" on the lists, in place of an empty bar.
- On the Auctions list, a graduated auction's row shows a "Buy" button on hover that opens its token page. A signed-in wallet with something to collect sees its "Claim" or "Refund" button in the same place, and a Claim button now names the token, for example "Claim AIFROG".
- A graduated auction's page, on Base or Robinhood, opens with "Auction is Finished" and a button on to its token page, beside the token's picture, its creator and their links, the total bid volume, the starting market cap (the auction's final price times the whole supply) and the market cap now.
- An auction page lists the 100 prices nearest the price now, so it opens faster.
- An auction page reads a signed-in visitor's own bids from the chain when it opens and when one of them changes, not on every block.
- The lists send an open page only what changed on screen.
- Every stock Chainlink prices on Base or Robinhood now has a logo: CleanSpark, the iShares South Korea fund, IonQ and Rigetti join the rest, so no stock on the Onchain Stocks page shows letters in place of a logo.

## v120, 14 October 2026 (28d2cb6): the trades health reading follows the token furthest behind
- The site's health reading for token trades now shows, for each chain, the token whose trades are furthest behind, so one token that is up to date no longer hides another that is catching up. Visitors see no change.

## v119, 14 October 2026 (06bfa91): shared library update
- Brings in the latest shared fixes: a slow or busy ENS picture service counts as a failed read and is tried again, rather than leaving a wallet with no picture; Credits holds keep their cause; refund decisions and history read the same way on every site; Points share one daily limit; and a refused signed request gets one answer everywhere.
- A release now stops, naming what is missing, if the shared database hasn't yet been given a change the Credits or Points code needs.

## v118, 14 October 2026 (f3e0524): a failed ENS lookup keeps its reason
- When the site can't read a wallet's ENS name or picture, the reason is now kept with the site's saved errors, so the team can see why. Visitors see no change; the site tries again later as before.

## v117, 14 October 2026 (80523b6): your Claim or Refund button on the Auctions list, and outcome pictures in search
- On the Auctions list, a signed-in wallet with something to collect from a finished Base auction sees its own button on that row: "Claim", "Withdraw", or "Refund" with the amount. It opens the same card as on the home page. Signed out, or with nothing to collect, the list looks as before.
- In search results, a finished auction shows the same picture as the lists: a full bar with a tick and "Graduated", or a part-filled bar with how much of its minimum it raised. On a phone, search leaves it out to save room.

## v116, 14 October 2026 (d379c58): auction figures are read once for everyone
- An auction's price, price chart, schedule and stage are read from the chain once and shown to every visitor alike. An open page changes when one of those figures changes, not every time a block goes by.
- The line under the price names the block those figures were read at, and keeps it until a figure changes.
- An auction with a long price chart is read over a few rounds and then costs nothing until the next bid. If an auction's page could not be read on a round, it keeps what was last read.
- When the chain replaces a block the figures were read at, they are read again.

## v115, 14 October 2026 (9fbf1d8): the menu says "Onchain Stocks"
- The left menu's link to the stocks page reads "Onchain Stocks". Where the two words do not fit on one line they take two, inside a button the same size as the others.

## v114, 14 October 2026 (28d4f1a): finished auctions show a picture, and your own Claim or Refund button
- On the home page's list, a finished auction shows a bar in place of the text about its dates: a full bar with a tick and "Graduated", or a part-filled bar with how much of its minimum it raised.
- A signed-in wallet with something to collect from a finished Base auction sees its own button on that row: "Claim", "Withdraw", or "Refund" with the amount. It opens the same card Portfolio does, in place. Nobody else sees a button there, and signed out there are none.
- Robinhood auctions show the picture; their claims stay on Portfolio.

## v113, 14 October 2026 (1a656e0): the create page's link says "Onchain Stocks"
- On the create page, the link under the stock picker to the stocks page reads "Onchain Stocks".

## v112, 14 October 2026 (6b8ad5f): the stocks page is called "Onchain Stocks"
- The stocks page opens with "Onchain Stocks" and one line: launch a pair with a meme ticker and earn from trading fees, with Covered Call Options coming soon. The browser tab says "Onchain Stocks" too.
- The list of stocks next in line is headed "Soon Available".

## v111, 14 October 2026 (037127d): logos for NBIS, CRWV and RKLB
- On the Upcoming stocks page, NBIS, CRWV and RKLB show a logo in place of their first two letters. Every stock the page lists today has one.

## v110, 13 October 2026 (c54c0e4): logos for GLD, ORCL and ASML
- On the Upcoming stocks page, GLD, ORCL and ASML show a logo in place of their first two letters. GLD carries State Street's mark, as SPY does.

## v109, 13 October 2026 (28a45d8): a page of upcoming stocks
- New page, autolaunch.sh/upcoming. "Eligible to add" lists, for Base and for Robinhood, the stocks not yet available that have a live Chainlink price and more than $10,000 in a dollar pool, with the size of that pool. "Available to Pair" lists every stock a Memestock token can be paired with today.
- The eligible list is the site's hourly reading of outside services. It is not a promise: a stock is added only when the Safe admits it. The page shows a ticker and a pool size, and no token address or link.
- The left menu has a fourth link, "New Stocks", to that page, and the create page shows "Upcoming stocks" under the stock picker.

## v108, 13 October 2026 (38c4edf): the stock list comes from the chain, and the create and bid pages show more
- The stocks a Memestock token can be paired with are now read from each chain's launchpad
  every five minutes. A stock the Safe admits shows in the picker within about six minutes,
  with its dollar price, and a stock it revokes leaves the picker. Before, either needed a
  site release.
- The picker shows a company's short name: "Apple", "Microsoft", "Meta Platforms".
- Once an hour the site notes which stocks not yet admitted have a Chainlink price and more
  than $10,000 in a dollar pool. This is a record only: it changes no page, launch or bid.
- Both create pages show the gallery card for the token beside the form as it is filled in.
- A bid window shows the auction's picture and the wallet's balances.
- "Buy at" on a stock names its trading venues with more than $10,000, the two deepest.
- An auction names its minimum only when it is about to miss it, and an auctions list with
  nothing in a status says so instead of reporting a failed search.
- For about five minutes after this release (21:41Z to 21:46Z) the create page answered an
  error and stock prices were not read, and the stock picker was empty until 21:50Z: the
  release went out before its two database changes were applied. They were applied at
  21:46Z.

## v107, 13 October 2026 (27c5135): an open page's connection holds less memory
- The connection behind each open page now gives back the memory it used to send the
  page. Before, it kept it for as long as the tab stayed open. With 50 pages open on a
  practice copy of the site, a connection held about 0.09 MB, down from about 1.67 MB.
  The limit of 150 connections at Fly's door is unchanged.

## v106, 13 October 2026 (ca358ae): open pages are told only when something they show changed
- An open page is sent an update only when something it shows changed. Before, every open
  page was told on each pass of the site's readers, whether or not anything had moved. On
  the live site an open page now receives about 24 updates a minute, down from about 70.
- An auction's page reads its auction again when a reading names that auction, and the
  price strip sends its list only when the list differs from the last one.
- Claims on finished auctions reach the lists on the ten-minute pass.

## v105, 13 October 2026 (3bd5639): an auction page shows its price before bidding opens
- An auction's page shows its price and schedule from the moment it is launched. Before,
  between the launch and the first block of bidding, the page said the auction could not be
  read from the chain.

## v104, 13 October 2026 (13094a2): a limit on connections at Fly's door
- Fly now hands the site at most 150 connections at once; newcomers beyond that wait at
  Fly's door and open pages keep their connection. This does not by itself make open pages
  faster.

## v103, 13 October 2026 (19db73f): a dedicated processor, and commands say who may run them
- The site runs on a dedicated processor. On the shared one it was held back once its
  allowance ran out, which made pages and clicks slow about 40 minutes after each release.
- Every agent command now says who may run it: any signed-in agent, or an agent paired
  with a person.

## v102, 13 October 2026 (9b85b31): faster pages, and clearer answers to refused agents
- Pages and clicks answer faster. The site reads the description of its contracts once
  and keeps it, where before it read the files again for every request, and it hashes with
  a faster routine. Its steady background work is about half what it was.
- An agent whose signed request is refused is told why in the sign-in service's own words,
  such as a body that changed after signing or a request that was already sent, as on every
  Regent site.

## v101, 13 October 2026 (38bb67b): agent sign-in checks the request body
- When an agent signs a request, the site now sends a digest of the request's body along
  with the proof it checks, as every Regent site does from today. Nothing changes on the
  pages, and agents keep signing the same way.

## v100, 13 October 2026 (370a738): a page for each bid
- Every bid has its own page, opened from Details on the portfolio. It shows what is yours,
  what may happen next with its one button, and each transaction the bid made.
- While bidding is open, a bid that is outbid or sharing the price can take its unspent
  money back early from its page, the same as from the portfolio.
- A failed auction's return is called "Refund <amount> <currency>" on the bid page, the
  portfolio and both dialogs.
- The portfolio no longer fails to load for a wallet with a Base bid ready to withdraw or
  claim.
- Bid estimates read the auction's whole price. Before, a long price read as 0, so a bid
  below the price could be estimated as buying.
- Typed bid amounts are read exactly, digit for digit.
- Agents' positions answer carries each bid's page, to hand to their person.

## v99, 13 October 2026 (5874c18): the home page as the front door
- The home page opens with the title "Autolaunch Auctions" and one "Launch a token"
  button. Before launches open, the button stays in place, switched off, with "Opens soon"
  beside it.
- A "Bid volume" row shows up to six launches with the most put in by bidders, as large
  square pictures with their rank, amount raised and state.
- The list below has four tabs: New (every launch, newest first, so the page is never
  empty while any launch exists), Live, Finished and Tokens. Each row shows the token,
  who made it and when, its price, amount raised, market cap and state, with a Bid or Buy
  button where one applies. The rows are in the page as it first loads. A grid view stays
  one press away.
- An empty tab says so in words. With nothing live it offers finished auctions and tokens;
  the other tabs offer a way back to every launch. With no launches at all the page says
  "No launches yet. Be the first." with the launch button.
- The extra Create buttons, "Buy $REGENT" and "Follow on X" left the top bar and side rail.
  "Buy $REGENT" is now in the footer beside the other links; the crown menu still offers
  Buy on Uniswap.
- The side rail no longer slides in when a page opens, and the token pictures on the home
  page move faster when pointed at.

## v98, 13 October 2026 (230462d): bid estimates on Robinhood auctions
- Asking for a bid estimate on a Robinhood auction now says estimates cover Base auctions only
  and where to read that auction's figures, instead of saying the auction was not found.

## v97, 12 October 2026 (1833c5b): bid estimates on finished auctions
- A bid estimate on an auction that has finished or failed no longer says the bid would be
  active. It says no bid can be placed there and estimates no tokens.

## v96, 12 October 2026 (1db2f96): agent reads and a steadier volume schedule
- The Regents command-line tool can read Autolaunch's auctions, one auction, a bid estimate,
  launched tokens and a treasury's security report without signing in, once the tool's next
  version picks them up. None of them places a bid or changes anything.
- Choosing which stocks' volumes to read next no longer waits behind a slow read.

## v95, 12 October 2026 (372881a): stock trading volumes
- Trading volumes for Robinhood stocks update again. Since early on 12 October, 16 of them
  had stopped updating after a new exchange's pools began to be listed.

## v94, 12 October 2026 (5a93551): errors kept on the site, side panel, Points, Credits
- Errors the site meets are saved in Autolaunch's own database and cleared a week after
  they were last seen, the way the template does it; Sentry is no longer used. Credits
  admins (named in REGENT_CREDITS_ADMINS) read them at /admin/errors; anyone else gets
  the ordinary not-found page.
- The motion lab at /animations shows every version of each movement the site uses, side
  by side, the same page as the template's. AUTOLAUNCH_SHOWCASE="public" opens it; on the
  live site it stays off until that is set.
- The account dropdown in the header is gone. A side panel button sits beside your name,
  and either one opens the side panel: your name with Account and Sign out at the top,
  then Help. It stays open or closed as you left it. On the narrowest phones only the
  panel button shows.
- A Points page at /account/points, the template's: your balance, your NFT bonus, recent
  activity and what earns points. Earning hasn't opened on Autolaunch, so it says so.
  The Account page links to it.
- A Credits button in the header on every page shows your Regents Credits balance and
  opens Buy Credits: pay USDC on Base from your wallet and the Credits count across every
  Regent site. The Account page's Credits card links to regents.sh to manage them.

## v93, 12 October 2026 (a82c114): Portfolio refresh, create page layout, shared dropdowns
- On Portfolio, the time the figures were read sits under Refresh. While a refresh runs the
  button reads "Refreshing…" and can't be pressed again until it finishes.
- On the Memestock create page, Paired stock comes right after Name and Ticker, and
  Description moves down to where Paired stock was.
- "More links" is now "Community Links" and "Socials (optional)" is now "Connect Socials",
  each in a bordered box. Community Links changes on the Revstake create page too.
- The token image hint reads "400x400 optimal".
- The list dropdowns use the rounded style every Regent site now shares (Sean, 89 a).

## v92, 12 October 2026 (5649093)
- The Account page relies on the sign-in check every Regent site shares (Sean, 66 a).
- Wallet balance reads count against an allowance of 30 a minute: the account's when signed
  in, the visitor's address when signed out. Past it, figures already shown stay
  (Sean, 70 a).
- Signed out, the Revstake token panel shows the open wallet's balances, the same figures
  as signed in, with a Sign in to pay button (Sean, 67 a).
- Sign in always opens Privy's window, and any Privy session the browser still remembers
  is logged out first, so you sign in with the wallet your wallet app is on now (Sean, 71 a).
- Sign out finishes Privy's logout on the page where you pressed it. One that can't finish
  in time is finished by the next page, never dropped (Sean, 71 a).
- Whether you're signed in is never kept by your browser or a network cache, so a page
  always asks fresh.
- The Tokens list shows each ticker with the currency it trades against, such as RDOG / SPCX.
- A token's picture always fits its circle in the lists, however tall or wide the picture is.
- An auction that ended below its minimum reads "Minimum unmet" instead of "Failed".
- The list dropdowns are rounded, with the arrow set in from the edge.

## v91, 12 October 2026 (df4a9e7)
- Lists of cards settle in once, the first time they scroll into view; one already in view
  when the page opens is simply there (Sean, 45 a).
- An error report sent to Sentry leaves without the values the failing code was handling
  and without a crashed process's saved state or last message.
- An open page re-checks the sign-in before every update it receives and every background
  result, not only on a click or a page change. When the sign-in has ended, the update is
  dropped and the page shows that the sign-in ended.
- Wallet panels re-check it before each press and each result of their own, and act with
  the wallets the account links at that moment.
- The Revstake token panel and the Robinhood launch card keep showing the account's own
  wallet when the open wallet isn't linked to the account, instead of going empty.
- Agents are offered only the signed tools as signed operations, each with its own inputs.

## v90, 12 October 2026 (9cabd3a)
- Site errors can be reported to Sentry. Nothing is sent until a Sentry project is set.

## v89, 12 October 2026 (0cad4ad)
- The site connects to its database only through the direct connection, which its live
  updates and database upgrades need.
- New versions start beside the running one and take over once healthy.

## v88, 12 October 2026 (60a0dd9)
- Each page carries one security policy, the site's own.
- Shared design-system and library pins match ash-template 7e8f73e.

## v87, 12 October 2026 (fa57c44)
- Memestake is now called Memestock everywhere on the site, in its links and in stored launches.
- Create Memestock picks the paired stock from a searchable gallery, sorted Alphabetical,
  by Trading Volume or Recently Added. Each stock shows its past week of trading volume;
  a figure ending in "+" is at least that much. A picked stock carries over to the other
  chain when that chain lists the same company's stock.
- Explore has a Finished tab for graduated and failed launches.
- The account page lives at /account. It shows paired agents, Credits and Points, links
  out to regents.sh, and says when a session has ended.
- When the open wallet isn't linked to the account, a note beside the button names both
  wallets and asks for a switch.
- Agents pair and act over signed requests only. The in-page wallet tools for bidding,
  trading, staking and launching are removed; the page's read tools stay.
- Shared motion, design-system and library pins match the other Regent sites.

## v86, 11 October 2026 (2ec5eb4)
- The header shows the signed-in wallet's ENS name and picture when the wallet has a primary
  ENS name that points back to it. Each sign-in reads it again from Ethereum mainnet.
- decimal 3.1.2 (security fix EEF-CVE-2026-97853).

## v85, 10 October 2026 (39383ca)
- Nine Learn pages keep the same navigation and content position, with the current page marked.
  Docs, About, Blog, Contact, Fees, Privacy and Terms also select Learn in the main menu.
- Learn links work with keyboard navigation, direct links, refresh and browser Back/Forward.
- REGENT's Stake and Redeem links are marked as external and open separately.

## v84, 9 October 2026 (08dd63e)
- Explore defaults to Live auctions. All still shows historical auctions.
- Create Memestock sits in its own container above Explore and opens the Memestake form.
- The homepage introduction, Revstake and Memestake panels, divider and auction counts are removed.

## v83, 9 October 2026 (1d355d4)
- Site copy, creator reviews, token and pool explanations, public agent guidance and
  contract docs match the final v2 allocations, fees and destinations, liquidity positions,
  fixed auction minimums, vesting from graduation and token retirement.
- Deployment guides identify completed v2 deployments. Historical v1 terms and lab records
  are labelled clearly; the four existing v1 auctions keep their original terms.
- The Robinhood-to-Base bridge remains unbuilt; protocol USDG stays in its inbox.

## v82, 9 October 2026 (a09044f)
- Token pages show View Chart only when DexScreener lists their exact pool.
  Otherwise they show Chart unavailable, including when the listing cannot be checked.
  This applies on Base and Robinhood; listing results are kept for one minute.

## v81, 9 October 2026 (409523b)
- Ended auction pages load correctly again. The Finish card receives its network's
  latest block reading on Base and Robinhood, fixing AGI's stuck Loading screen.

## v80, 9 October 2026 (b75c693)
- A launch shows its full transaction hash while waiting for confirmation, with Copy and
  an explorer link. Pending and confirmed hashes wrap on mobile.
- A confirmed launch keeps finding its auction page as new listings arrive. Its draft
  clears only if it still describes that launch, preserving edits in another tab.
- Finish refreshes on a new block from the auction's own network.
- Hidden Robinhood auctions keep withdrawal and claim controls without public token links.
  Failed auctions show full refunds, and receipts handle bids exactly at the clearing price.
- Release source includes the final deployed v2 contracts, deployment records and
  5 October fee terms. New launches use v2; the four existing v1 auctions keep working.
- Ash is updated to the patched 3.34.6 version.

## v79, 9 October 2026 (29af631)
- The public auction list (`GET /api/v1/auctions`) answers each address 6 times a
  minute; past that it says how many seconds to wait. One address that read it every
  2.3 seconds is refused. The developer guide and API description say so, and the
  browser tools pass the wait on to agents.
- The site's engine measurements (memory, run queues, process counts) now reach the
  monitoring dashboard.

## v78, 9 October 2026 (98c7f73, same build as v77)
- Auctions finish automatically once their finish block has passed.

## v77, 9 October 2026 (98c7f73)
- The public auction list (`GET /api/v1/auctions`) is kept for five seconds, so callers
  asking for the same list again share one answer. The site now runs on a shared
  2 CPU / 2 GB machine.

## v76, 9 October 2026 (6d93209)
- On the Revstake Create page, a Safe treasury address is now read on Base as it is
  pasted, and a line under the box says what is there: "2-of-3 Safe found", "This is a
  wallet, not a Safe", "No Safe at this address", "Safe, but not 2 of 3" or "Base could
  not be read just now". The treasury step only counts as done for a 2-of-3 Safe.

## v75, 9 October 2026 (7371b81)
- An auction whose bidding has ended now has a Finish button on its page. Anyone signed
  in can press it once the auction's finish block has passed: it opens the pool, or opens
  refunds if the minimum wasn't met, for the network fee. Before that block the button
  says when finishing opens.

## v74, 9 October 2026 (cd69683)
- Autolaunch can now take an auction off the site: it leaves every list, its page and its
  links, while anyone who bid on it still sees it in their own portfolio. The two test
  auctions, which had no bids, are off the site.

## v73, 8 October 2026 (92f9dff)
- After a launch goes through, its card says "Your token … is launched." with the full
  transaction, a Copy button, a link to the explorer and, once it is listed, a button to open
  the auction.
- The Create form starts over blank as soon as the launch goes through, so the same launch
  isn't sent twice by mistake.

## v72, 8 October 2026 (3ac7d8d)
- You can start more than one Revstake auction from the same account.
- New launches on Base and Robinhood are open on the new contracts; the old contracts take no
  new launches, and earlier auctions and tokens keep working as before.

## v71, 8 October 2026 (17f12c3)
- Robinhood auction pages read their pool again, and Robinhood token pages open again.

## v70, 8 October 2026 (4c598a3)
- The new site: fresh Explore, auction, token, Create and profile pages, with a launch timeline
  on both Create pages and one shared look for Memestake and Revstake.
- New launches use the new contracts. A Memestake token's supply splits 49.75% sold at auction,
  49.75% locked in the pool and 0.5% to its creator over 30 days.
- Robinhood launches use the new contracts too; earlier auctions keep working on their own.
- Every account has one profile page; the separate Settings page is gone.
- You can start a second Memestake auction while another is still live.
- Agents can read, fill and launch from both Create pages.
- A wallet step the chain would refuse now says it can't be sent as it stands, instead of
  saying your wallet declined it.

## v69, 7 October 2026 (52806ed)
- Share pictures are drawn less often and kept, so they load faster.
- A sign-in now lasts 30 days from the last time you signed in.

## v68, 7 October 2026 (1a509b0)
- The site now always opens over a secure connection, and browsers remember to use one.
- A new browser safety rule watches what each page loads. For now it only reports; pages work as before.
- Security reports now go to build@regents.sh.

## v67, 6 October 2026 (7968f74)
- A security update to the site's underlying software. Nothing changes on the pages.
- When you open your profile without signing in, the message now says what went wrong and what to do next.

## v66, 5 October 2026 (2303ff9)
- The browser tab, search results and the guide for AI agents now say "where agents launch" too.

## v65, 5 October 2026 (9e69bad)
- New tagline: "where agents launch". Links to the site now show it on their preview picture.

## v64, 30 September 2026 (1ba5740)
- The REGENT page explains staking the way the contract pays it: by share of all 100 billion
  REGENT, with the unstaked share going to Regent's treasury.
- Portfolio and auction pages show only the wallet you signed in with.
- New theme button in the header, as on the other Regent sites. Until you choose a theme, the
  site follows your device's light or dark setting.

## v63, 30 September 2026 (68a060b)
- New About page: the team behind Autolaunch, how it works and key facts come first, and
  the key facts also appear in llms.txt.
- The automated GitHub checks are switched off; the same checks run before every release.

## v62, 29 September 2026 (067a3c4)
- The site monitor now notices if the site stops reading new launches, bids or trades.
- Shared Regent libraries updated, including how ENS names are read.

## v61, 28 September 2026 (abb4c66)
- New Terms page, with the Autolaunch and blockchain-risk sections from the Regents Labs
  terms. The footer links it, and the privacy page points to it.
- The developer guide moves to /docs (the old /developers address forwards there) and
  explains errors, versions and request limits.
- The public API and health check allow 120 requests a minute from each visitor.
- Files that help agents find the site: security contact, API catalog and tool list.
- Security update to a web library the site uses.

## v60, 27 September 2026 (d48be63)
- Buttons and menus move the same way as on the other Regent sites, from their shared
  motion. With reduced motion turned on, in system settings or on the page, nothing moves.

## v59, 27 September 2026 (c345559)
- The light and dark switch is in the header on every page, not only the blog, and every
  page opens in the chosen look straight away, with no flash of the other one.
- On narrower screens the header search takes its own row, so the switch and buttons fit.

## v58, 27 September 2026 (2e596c1)
- Robinhood token and auction pages say when they could not be loaded, with a Retry
  button, instead of failing, and keep what they showed when a later read fails.
- Auction pages say when the bids could not be read, with Try again.
- The auction counts keep the last numbers when a refresh fails, marked as the last read.
- A dollar estimate never carries over from one auction to the next.

## v57, 27 September 2026 (503b4f3)
- Behind-the-scenes tidying only: unused styles removed and the site's checks moved to
  the standard places. Nothing changes for visitors.

## v56, 27 September 2026 (91ec923)
- Every page's browser tab title and link preview name the page, then "Autolaunch", from
  one list, so shared links describe the page they point to.

## v55, 27 September 2026 (865890b)
- The $REGENT address copy in the header says "Copied" on every page, like the site's
  other copy buttons.

## v54, 27 September 2026 (67847e4)
- A visit to www.autolaunch.sh moves to the same page on autolaunch.sh.
- A missing page says "We can’t find that page"; any other error says "Something went
  wrong".

## v53, 27 September 2026 (fadd996)
- Copying a token's address or the agent guide says "Copied", or "Couldn't copy" when the
  browser refuses, and screen readers hear the same.

## v52, 27 September 2026 (af7caea)
- Addresses show the same short way on every page (0x1234..abcd), and times read as
  "3 minutes ago" or "in 2 hours" everywhere, from the shared Regent formatting.

## v51, 27 September 2026 (9061676)
- The site now uses Regent's shared sign-in, design and blog code at fixed published
  versions, the same ones every Regent site checks against, so the release no longer
  depends on copies kept next to it.
- Signing in with one of several linked wallets keeps that wallet as the signed-in one.
- Sign-in checks against Privy's one current key.

## v50, 27 September 2026 (03b5a7f)
- Create now starts with a clear choice between a Memestake and a Revstake token, and each
  page is named for the one it makes.
- Every page that states Memestake trading fees shows the same three: the 0.30% pool fee
  and the two 1.00% fees for REGENT stakers and the token's stakers. The trade review now
  lists the fees already included in the quote.
- Portfolio says while it is refreshing, when it last read everything, and which part could
  not be read, keeping that part's last figures with their time. A burst of updates now
  causes one extra read instead of one each. Signing out elsewhere clears the page.
- Auction figures show in the auction's own currency when there is no dollar price, and a
  figure that isn't known yet says so instead of showing a dash.
- An auction counts as ended from the auction itself, not from the clock.
- Wording about failed auctions now says each bidder can withdraw their bid, since nothing
  is sent back without a withdrawal.
- The bid estimate address now answers each kind of problem with its own code and says
  whether trying again will help.

## v49, 27 September 2026 (a6711fc)
- AI assistants built into web browsers can now bid, finish a bid after its auction, buy,
  sell, stake, unstake and claim staking rewards for a signed-in person, using the same
  cards the person would. Every one opens the person's own wallet to confirm; nothing is
  sent without it. Launching a token still happens on the Create page.
- A signed-in person's assistant can read their bids and tokens, and the same list is
  available at autolaunch.sh/api/v1/me/positions.
- Each of these calls now says plainly what happened: sent, not sent and why (including the
  wallet being on the wrong account or refusing to switch networks), or unknown.
- Signing in with an agent wallet and looking up ENS names use corrected address hashing.
- A security update to the data layer the site is built on.
- The leftover opening countdown is gone.

## v48, 26 September 2026 (8d96f71)
- The tools Autolaunch offers to AI assistants built into web browsers are now described in
  one place, and the developer guide and agent guide list all eight of them, including the
  three that manage a signed-in person's profile (they previously named only five).
- Pages now tell browsers that only Autolaunch's own pages may offer these tools.
- Setup notes no longer mention browser tests and commands that were retired earlier.

## v47, 26 September 2026 (fe8b172)
- New Developers, About, Contact and Privacy pages, linked from every page's footer.
- AI agents can read the homepage and these pages as plain text at the same address, and a
  missing page tells them where to go instead of showing a dead end.
- Problems reading the public data now come with a short hint on what to try next.
- The data description moved to autolaunch.sh/openapi.json, with a sentence on what each
  request does, and a site map lists every page, auction and token for search engines.
- The homepage arrives with its coins already listed instead of filling them in a moment later.

## v46, 26 September 2026 (6046ba5)
- Reading from the blockchain no longer prints an outdated-setting notice on every request
  (about 9 a second before), and the server log is quiet again. Connection behaviour is
  unchanged.

## v45, 26 September 2026 (fedde03)
- Pressing a button, opening a menu or copying the address again while its animation is still
  playing no longer leaves it stuck half-faded or half-sized; every animation finishes cleanly.

## v44, 26 September 2026 (a6b7b59)
- The chain reader and the auction activity refresh no longer fill the server log with
  missed-notification warnings (about 300 every two minutes before; none after).

## v43, 26 September 2026 (1007375)
- Buttons give a small squish when pressed, and a short shake when the action isn't available.
- Menus, pop-ups and the "copied" message pop open; pop-ups also fade their dark background in
  and out.
- Nothing moves for keyboard presses or for visitors who have asked their device for less
  motion, and wallet buttons respond at once as before.

## v42, 26 September 2026 (f041e5f)
- Search puts the best match first and forgives typos ("artficial" finds AGI). It looks at the
  name, ticker, the stock being raised, the creator's connected accounts and the description;
  pasting an address finds that auction, token or creator.
- Auction pages on Base and Robinhood show bold figures, orange tickers and coloured state
  labels, like the portfolio and token pages; a bid's standing is a coloured label too.
- Each launch step on the Create pages shows its state as a coloured label.
- Signed out, both Create pages say X, GitHub and ENS can be connected after signing in.
- Information labels take their colour from the shared design, matching the other sites.
- Refreshing token trades no longer fills the server log with missed-notification warnings.

## v41, 25 September 2026 (03ecc10)
- Both launch pages open without signing in. Visitors can fill in the whole form, pick a stock
  and chain, and see the terms, raise and starting price update, with nothing saved.
- Signing in from either page saves what was typed into the account's draft; fields left blank
  keep what the draft already had. A refresh before signing in keeps the typed values too.
- Adding an image, connecting socials and launching ask the visitor to sign in first.

## v40, 25 September 2026 (58d09fc)
- Figures stand out on your portfolio, token pages and every pop-up: numbers are bold, tickers
  are orange, and states such as Ready, Completed or Outbid show as coloured labels.
- The staking panel and the Pool section show short, readable amounts (94,450,000 BITE rather
  than every digit); the exact amount shows when you hover over it.
- Wallet steps in the claim, bid, swap and payment pop-ups show their state as a coloured label.

## v39, 25 September 2026 (b63a7e4)
- Your bids: clicking the name opens the page, so the Token button is gone. The Action column
  shows Withdraw, then Claim once the tokens can be claimed, then Completed.
- "Launched" reads "Graduated" again everywhere, including the Status column.
- The bid settlement card follows the current design: a status label, ruled rows of figures and
  one clear button.
- Token pages show staking right under the token info: a meter of how much of the supply is
  staked, and the pool's trading fees for the last 24 hours and all time.

## v38, 25 September 2026 (0a06f51)
- A Robinhood token's Uniswap Pool button opens its pool on Uniswap.

## v37, 25 September 2026 (209fa5a)
- A token page's heading reads like "First Bite BITE / AAPLc", with the shortened token address,
  a copy button, a Uniswap Pool button and a View Chart button to DEX Screener, on every Base and
  Robinhood token.
- When the wallet app is on a different account from the signed-in one, the settlement, bid and
  launch panels say so beside the button and ask to switch, instead of doing nothing on a press.

## v36, 25 September 2026 (4425219)
- A bid that was spent in full on a launched auction offers "Claim BITE to wallet" and reads
  "Tokens ready to claim" in the portfolio, instead of offering to return unspent money that
  does not exist.

## v35, 25 September 2026 (025f9a6)
- A shared How it works link shows its own picture, "how autolaunch works" with Revstake and
  Memestake supply and auction length, and its own title and description.
- Every page's link preview carries the X title and description as well.

## v34, 25 September 2026 (4fc881a)
- Withdrawing and claiming after an auction ends works on Base and Robinhood. Before, every press
  showed "That did not go through. Try again in a moment.", and a bid priced out by the final
  price could not get its unspent money back.
- An ended auction says how long ago it ended, such as "Ended 24m ago", instead of how long ago
  it was listed.
- The site reports its health (indexer lag, job age, wallet send failures, database wait) to
  Fly Sentinel on a private port.

## v33, 25 September 2026 (45c99c5)
- The API, the command-line tool and the browser tools for AI agents call the two launch types
  `revstake` and `memestake`, in what they return as well as in the filter. The old names
  `agent` and `stocks` are gone.
- Two database indexes the auction list no longer uses were removed (run 11:29 UTC).

## v32, 25 September 2026 (8eb7841)

### Sharing
- Auction and token pages have readable addresses, such as `/auctions/BITE/80be8`: the ticker,
  then the last five characters of the auction's address. Old links, including ones already
  posted on X, go to the new address.
- Each auction and token has its own share picture: its image, name, ticker, chain, a price line,
  and the FDV with the time left (or the price, once trading). X shows it large under the post.
- "Share on X" after a bid or a stake opens a window with the post to edit, the picture X will
  show, and "Open X to share". Nothing is posted until you post it on X.

### Portfolio
- The portfolio takes the create page's look: no diamond headings or dotted lines.
- Your bids and your tokens are rows like the auctions list, each with a small picture, the name
  in white and the ticker with its pair in orange, such as `BITE / AAPLc`.
- Under each bid: Auction (or Token once it has launched), Withdraw or Claim tokens when the
  auction allows it, and Bid more while bidding is open. Under each token: Token, Buy, Sell and
  Stake. Each opens the same window the auction and token pages use.
- A withdraw note now shows only under a bid that is outbid, not under every open bid.
- Past bids are folded under "Past bids".

### Fixes
- Bid, withdraw and Buy/Sell windows stay open while prices update behind them; before, an
  update could close them.
- Finishing a Buy or Sell from a home page card no longer breaks the home page.
- The bottom ticker's Robinhood trades are read from where each auction starts, and one shared
  reader feeds every open page.

### For agents
- The API, CLI and browser tools list auctions and tokens with the website's own search,
  filters and sort, and each auction carries its page address, time left, amounts raised and
  how much of its minimum is met.

## v31, 25 September 2026 (972b492)
- After you launch a memestock, "Launch memestock" starts from an empty form instead of showing
  the token you just launched.
- While your Memestake auction is live, the form is grayed out under "Only one Memestake auction
  can be live per account". It opens again once that auction ends.
- Every change to the site is now checked and test-built on GitHub before release.

## v30, 25 September 2026 (fe84aea)
- Search works as you type. Every word you type must appear somewhere in the auction: its name,
  ticker, paired stock, description, addresses, or the creator's X, GitHub or ENS name. A $ in
  front of a ticker and extra spaces are ignored. Typing in the search box on any other page
  opens the results on the home page.
- Agentic Revenue Launch: "Minimum REGENT Raised to Launch" is optional, with an info icon
  explaining why a minimum helps backers. Left blank, the launch uses 0.00001 REGENT.
- The token image on the Agentic Revenue Launch page is a file you upload, like the memestock
  page; pasting an image link is gone.
- X and GitHub show Connect, or Disconnect once connected; ENS keeps Change.
- The connections section starts with "Start Here" and a line on gaining credibility, and the
  preview reads "This auction and the resulting token will show these identities".

## v29, 25 September 2026 (6fbff12)
- The Create page is now "Launch memestock": one short form beside a summary card of the token
  it makes. There's no longer a first step asking which kind of launch you want.
- A Base / Robinhood switch picks where the token trades, with a blue or green wash across the
  form as it changes. The paired stock is a dropdown of that chain's stocks, each with its logo.
- The token image is a file you upload; pasting an image link is gone.
- A Telegram community link and a website are optional in the main form. X, GitHub and ENS sit
  under a folded "Socials" section. A Telegram link shows on the auction and token pages.
- Required raise (0.00001) and starting price (0.00000001) are filled in and sit under
  "Advanced".
- The summary card shows the chain, paired stock, trading fees (1% to stakers, 1% to Regent),
  when bidding opens, auction length, required raise, starting price, liquidity locked forever
  and no launch fee.
- The agent revenue launch has its own page, "Agentic Revenue Launch", linked from the top right
  of the memestock page.
- Each account keeps one memestock draft, which carries across the Base / Robinhood switch.

## v28, 25 September 2026 (59cd771)
- Gallery cards no longer show the description. The space under the links is a quarter of its old
  height, so every card is shorter. Hovering a card shows the bid volume, with how much of the
  launch threshold is met, over the launch threshold, beside the FDV.
- The count under the gallery reads "1 auction" or "1 token" when there is one.
- Once you're signed in, every bid, payment, launch and staking box uses the wallet you signed in
  with straight away, after moving between pages and after a reload. None of them asks you to
  connect or choose a wallet first. If your browser wallet is on a different address, a note
  beside the button names both. Pressing a button when your signed-in wallet isn't connected
  opens the connect step; press again once it is.

## v27, 25 September 2026 (d5f4bff)
- The profile page shows only your connected accounts: the name, wallet and X box above them is
  gone.
- A connected GitHub account can be changed or disconnected, like X.
- Account names in the connections list are no longer underlined.
- The connections on the profile page respond again: before, their buttons could stop working
  once the page finished loading.

## v26, 24 September 2026 (40327e4)
- The bid box is laid out like a swap: a Max budget box with the currency beside the figure, a
  Max FDV box with a slider, and a Receive box showing about how many tokens the budget buys.
  The slider starts a quarter above the price to start buying, and its tip shows the price per
  token. On Base stock auctions, a USDC or stock switch sits above the currency.
- "Place a bid" has a ? beside it with a short note on how bidding works. The wallet line, the
  balance list, the price mode choice and the Advanced section are gone.
- The bid help under the auction book uses the new wording on budget, max price, per-block
  buying, withdrawals and returned bids.
- Clicking an auction no longer sends up fire.
- Treasury security shows only on Revstake auctions and tokens, not on Memestake.
- Auction figures explain themselves: in the table, FDV, Bid volume and Launch threshold each
  have an info icon that opens a short note on hover; in the gallery, hovering one of those
  three numbers opens the same note.
- On the create page, X, GitHub and ENS each sit in one row of the same shape: logo, name or
  "not connected", and a Connect or Change button.
- The token image is one box: upload a file on one side, paste an image link on the other,
  split by OR.
- Text boxes on the create page have a cut top-right corner. Website and Required raise line
  up, and the dollar value of the typed REGENT shows under Required raise.
- Revstake: creator connections come first. Memestake: they come after the token details,
  folded away as optional.
- Launching a Revstake token with no X, GitHub or ENS connected first asks the creator to type
  a sentence accepting that the auction may not appear in the gallery or list.
- Explore, Portfolio, Create and Learn are header-style buttons with larger text and no icons:
  the corner marks close into a full outline on hover and stay closed on the page you are on.
  On phones the four sit two by two, always visible, and settle in one after another.
- Switching blockchain or token type on the create page no longer moves the page: the space
  for the description and the Robinhood note stays the same height for every choice.
- On phones, the header is the $REGENT crown beside Sign in. Tapping the crown opens Buy on
  Uniswap, View Chart and Follow on X, and the header Buy, Follow and Create buttons are gone.
  Wider screens keep the full header, in this order: + Create, Buy $REGENT, Follow on X, the
  crown, GitHub, Sign in.
- The treasury section no longer shows a technical note under a verified recipient.
- Portfolio shows every Base bid made from your wallet, including bids placed outside this
  site or whose confirmation the site missed: the site now records each bid the auction
  announces. A bid saved on an auction launched without a creator account no longer breaks the
  portfolio page.

## v25, 24 September 2026 (864624e)
- The time bar on auction cards fills again: the site now records when each auction opened, so
  the bar shows how much of its time has passed.
- Card links show a small logo for what each is (X, ENS, GitHub, website, wallet) and no
  underline. The creator's wallet shows as its logo alone, with the full address on hover.
- Changing a gallery setting (sort, chain, type, Auctions or Tokens) no longer blanks the
  gallery for a moment: the cards shown stay until the new ones replace them.
- A stock price that could not be read is tried again after one second, then two, four and so
  on, instead of staying missing for ten minutes.
- The Robinhood feather is always Robinhood green.
- Table view: each row reads the name, then the ticker in gray on the same line, with no check
  mark. A live auction's status is a time bar in its chain's colour with the time left under it,
  such as "5d 21h 48m". Times left no longer show seconds anywhere.
- Sorting is a three-way switch: Recent, Closing and Highest. "Oldest first" is gone.
- Grid and Table are shown as icons.
- The Filter menu is only as wide as its choices, with a tick beside each chosen one and one
  choice per group: status, network (All, Base, Robinhood), type, and which account the creator
  has verified. "Reset filters" is gone. The menu closes when you click outside it or press Escape.

## v24, 24 September 2026 (b97e278)
- A launch threshold met many times over reads "100% met" instead of a huge percentage.

## v23, 24 September 2026 (f3fef43)

### Explore, Portfolio, Create, Learn
- The menu has four places: Explore, Portfolio, Create and Learn. Explore holds the auctions and
  tokens lists, with links to search all of either.
- "Token details" is now "How Autolaunch works" at `/how-it-works`, since the old name sounded
  like one token's page. The old address is gone.
- Plainer wording: "auction" instead of "CCA auction", and "trading fee" instead of "Uniswap
  hook fee".

### Portfolio shows what you can do now
- Money available to withdraw, tokens ready to claim, tokens available to stake and rewards
  available come first, each with its button, and appear only when there is something in them.
  Other bids follow below.

### Who's behind a launch, and the launch itself
- Auction and token pages on both chains show two separate parts. "Who's behind it" lists the
  launch wallet and the creator's X, ENS and GitHub, each marked as ownership checked, and says
  plainly that a checked account is not an endorsement. "The launch itself" lists the launch
  type, the token, auction, treasury and locker contracts, how the supply is split, and the
  liquidity status.
- Liquidity reads "Reserved for liquidity, not yet deposited" until the auction launches, and
  "Deposited and locked", with the amounts, once the pool has been read from the chain. A note
  explains why Uniswap's numbers can differ.

### Auction and token cards
- Cards show the ticker as `BITE / AAPLc`, the FDV at the floor price, and the bid volume and
  launch threshold on hover.
- A time bar shows how far the auction has run. Until the launch threshold is met, a second bar
  above it shows how much of the threshold is met.
- The Tokens tab uses the same card. Every card is the same height and shows at most six links;
  the rest are on the token's own page.
- A card lifts slightly when you point at it.
- On phones, links sit in two columns and the description stops at four lines, so cards are
  shorter.

### Bidding
- A bid shows as outbid once the auction's price has passed its maximum, and the banner links to
  "See my outbid bid".
- Each outbid bid says in one line when its unspent money can come back: now; after the minimum
  is reached (with the amount still to go and the end time); after one extra wallet
  confirmation that records the new price; or, when its limit equals the price, that it is still
  buying until the end.
- While bidding is still open, the withdraw button records the auction's new price first when
  that is needed, then sends the unspent money back. Anyone can record the price, and it moves
  no money.
- Every press of a bid, settlement or launch button reaches the wallet. A new review no longer
  cancels an earlier one.
- Auction pages open on the price chart, with a window for the full details, and fit a 375px
  phone.

### Live trades
- The bottom ticker shows token buys and sells from each launched token's pool next to the bids.

### Database changes
Five, all applied before the switch-over:
- `20260924171619_auction_market_figures`: amount raised, floor price and token supply for each
  auction.
- `20260924183803_token_trades`: the trades table behind the ticker.
- `20260924183957_allow_many_open_bid_reviews` and
  `20260924191532_allow_many_open_settlement_and_launch_reviews`: remove the one-open-review
  limits.
- `20260924193836_record_the_auction_price`: lets a settlement include the step that records
  the price.

## v22, 24 September 2026 (e517da2)
- Each auction page lists its bids with wallets, a price-over-time chart, and bids placed against
  sold so far.
- Amount fields accept values like ".01".

## v21, 24 September 2026 (ae5f53b)
- Auctions record the wallet that launched them. Pages show a "Created by" block with X, ENS and
  GitHub.
- Base and Robinhood chips on cards and pages; the bid form sits right under the auction card.

## v20, 24 September 2026 (008d3fd)
- Fixed a crash, about once a second after the opening, in the updates for the Robinhood
  auction's bid activity.

## v19, 24 September 2026 (136f579)
- Launches opened at 15:00 UTC on Base and Robinhood.
