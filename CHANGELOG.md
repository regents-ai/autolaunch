# Changelog

What changed on autolaunch.sh for people and agents, newest first.

## 29 October 2026: the last amounts in the one Regents way
- A stock's liquidity and past week's trading volume, on the stock pages and when you pick a stock to launch, are written in full like every other amount ("$1,234,567.89" instead of "$1.2M").
- A share picture or video draws every figure whole, smaller if it has to, instead of cutting it off with "…", and the video's figures now match the picture's to the cent.
- "Still to go" before an auction reaches its minimum is rounded up at its last digit, so it never shows less than is missing.
- A bid's budget typed in an unusual way, such as "1e6144", no longer breaks the bid page, and a dollar figure below zero reads "-$6.00".

## 29 October 2026: every amount shown the one Regents way
- Every amount the site shows you to read now looks the same as on every Regents site: prices, bids, balances, rewards, refunds, raises, revenue, supply and dollar values, on the pages, in the ticker and in the share pictures. Amounts of 1 and above show two decimals with thousands separated ("26,590,000,000.00"), smaller amounts show their first three digits ("0.0000000123"), and digits are cut, never rounded up.
- Large figures are written out in full instead of shortened to K, M or B, and tiny prices write their zeros out instead of counting them with a small number.
- Amounts you type, what a review asks your wallet to send, and the exact figures on a token's facts are unchanged.
- For agents: wallet positions now give each held, staked and claimable amount exactly, to its last digit, as every other amount there already was.

## 29 October 2026: your USDC shown the one Regents way
- The USDC balance in the Credits window now reads as on every Regents site: amounts of 1 and above show two decimals with thousands separated ("1,234.56"), smaller amounts show their first three digits ("0.000999"), and digits are cut, never rounded up.

## 29 October 2026: a full-size balance on phones
- On a phone, the Credits balance in the top bar is a full-size press again, even when it shows a single digit.

## 29 October 2026: your account in a menu
- The side panel is gone. Press your picture and name at the top right of any page and a menu opens under it with your name and wallet, your three most recently active agents, Pair New Agent, Manage Account and Sign out. Press Escape, or anywhere else, and it closes.
- Pair New Agent now takes you to the pairing section of your Account page, which is the one place to pair an agent, as on every Regents site. The Account page starts with Autolaunch's own sections (Credits and Points activity, and your connected accounts), then your account, your agents, pairing, your Credits and Points, and the name people see for you.
- On a phone, your Credits balance now stays in the top bar, without the word Credits. On the narrowest phones (320 pixels wide) it moves into the account menu, and pressing it there opens Buy Credits as before.
- While the phone's navigation menu is open, the page and the bar along the bottom can't be pressed until it closes.
- For agents: the guides now say your person pairs you from Pair New Agent on their Account page.

## 29 October 2026: browser agents can use the site's tools in Chrome
- Nothing changes on the pages. Every page of autolaunch.sh now takes part in Chrome's WebMCP trial, so an agent in Chrome can find and use the tools the pages offer (auction lists, token details and the rest) without a special browser setting. The trial runs until 29 March 2027.

## 29 October 2026: every Memestock launch on Base is listed
- A Memestock token launched on Base without the create page, for example by an agent from its own wallet, now has its own auction and token pages and a place in the lists. Its creator is shown as the wallet that launched it.
- Such a launch shows only what passes the site's usual checks: its name, ticker and description as plain text with hidden characters taken out, its website only when it is a full https:// link, and its picture only when the picture is stored on Autolaunch. Otherwise the token shows its first letter. A launch whose ticker is not capital letters and numbers, up to ten, is not listed, as the create page would refuse it.
- Launches made on the create page still show their person's account, as before. Robinhood Chain listings are unchanged.
- For agents: the signed agent guide (/agents.md) has the steps to launch a Memestock token on Base from your own wallet. The wallet that sends the launch owns it for good, with its creator allocation and its share of trading fees.

## 29 October 2026: the covered calls contract is on Base
- Nothing changes on the pages yet. The contract behind covered calls on Amazon (AMZNc) is now on Base at 0x0B2FE2810F9219bDd5e5e304DC8A1A4c84eA553E, and anyone can read its source on Basescan and Sourcify. Covered calls open on the site in a later update.

## 29 October 2026: a clearer picture when autolaunch.sh is shared
- The picture that shows when someone shares autolaunch.sh now leads with "onchain stocks for agents" as its headline, with "DeFi for agents" above it, and the line under the headline is gone. Revstake and Memestock are larger, and the two coloured corner lines have swapped places: Powder Blue at the top left, Tangerine at the bottom right.
- The shared link's title is now "Autolaunch · Back AI agents at a fair price", so it adds to the picture instead of repeating it, and its description reads "Bid in token auctions where everyone pays the same price, then stake to earn stablecoins or onchain stocks."

## 28 October 2026: covered calls in the works
- Nothing changes on the pages yet. Autolaunch is building covered calls on Base: someone who holds a stock token can sell calls on it, and anyone can buy them for a premium paid in USDC. The first stock is Amazon (AMZNc). They open once they are finished and checked.
- Until then the pages, the site's scripts, the API description (/openapi.json) and the agent guides are exactly as before and never mention covered calls. For agents: a covered-call price request gets the same answer as any other request the site does not take before it opens, and the other covered-call addresses are not found.
- Once they open, the covered calls page says, under its title, that they are available to eligible people outside the US. Any wallet can sell, buy and exercise them; nothing on the site checks who you are beyond the wallet you sign in with.

## 28 October 2026: the agent guides name Regents CLI 1.10.20
- The agent guides and agents.md now name Regents CLI 1.10.20, the newest release, with its source commit and the fingerprint of its published package, so an agent installs the same version every Regents site uses.
- The install line in every guide now asks for Python 3.14, so an agent gets the same setup every time.

## 28 October 2026: each agent keeps its pairing code
- When you pair an agent, each agent you choose keeps its own code until it expires. Choosing another agent and coming back shows the same message and code again, instead of a new one each time. The refresh icon still makes a new code for the agent you have chosen.

## 28 October 2026: a calmer home page
- The Autolaunch name now sits at the left of the top bar, beside search, in the site's pixel lettering, next to its mark. It no longer sits above the links in the left column. On a phone the top bar shows the mark alone, as before.
- When no auction is taking bids, "Coming next" now says so in one framed line: "No auction is taking bids. New auctions show here as soon as bidding opens." The row of stock buttons and the three finished-auction cards that sat there are gone; finished auctions stay in the list further down.
- The line under the title now always sits under it, on wide screens too, and reads "Back long-term agents early, through an auction where everyone pays the same price."
- The list of launches now starts right under its tabs. A search shows "Results for …" and Clear search beside Filter (on a phone, on their own line under the tabs) instead of keeping an empty line open above the list. After Clear search, the keyboard is on Filter.

## 28 October 2026: a security update to the web server
- The site's web server takes its latest security fix. Nothing changes in how the site looks or works.

## 28 October 2026: Withdraw and Claim work from the first moment
- Pressing Withdraw, Return or Claim on your bid the moment its card appears now opens your wallet with the right step. Before, a press in the instant before the card had read your bid sent nothing.

## 28 October 2026: the side panel closes on a test copy of the site
- On a test copy of Autolaunch, the "Local Base fork · test assets · no mainnet value" line now stays at the top of the screen, with the header just under it, and the side panel and phone menu open under the header. Before, the panel opened behind the header there, hiding its close button. The live site has no such line and looks the same as before.

## 28 October 2026: flat cards and windows
- Token cards on the home page no longer lift or cast a shadow when you point at them; the picture still drifts closer. The Buy Credits window and the swap review sit flat on the page, with their thin outline, as everything else on Regents sites does.

## 28 October 2026: the agent skill's check-back heading
- For agents: the section of the agent skill (/skill.md) on how often to look again is now headed "Check-back intervals". Its advice is unchanged.

## 28 October 2026: the pairing steps are where the message says
- For agents: the message your person pastes to pair you sends you to the "Pair with a person's account" steps in Autolaunch's short agent guide (/llms.txt). Those steps are there now: install the Regents command line, sign in, check your status, pair with the code, check in.
- For agents: the API description (/openapi.json and the contract the Regents command line carries) now says what pairing and check-in are refused with: an unpaired check-in with agent_not_paired, and a pairing with pairing_failed, harness_unknown or invalid_name, or agent_limit at 100 agents.
- For agents: the pairing steps say your person can pair you from any page's side panel, and that a pairing made on any Regents site works here, since their account is one account on every site.
- On a phone, Balance beside a bid's budget, which fills in your whole balance, is now a full-size press instead of a thin line of text.
- When your agent fills in your launch, the list of what it filled in shows an address it chose (a Revstake treasury, or a Memestock token's stock on Base) the way every address on the site is shown: you can copy it whole and open it on Basescan to check it before you launch.

## 28 October 2026: the agent guides name Regents CLI 1.10.19
- The agent guides and agents.md now name Regents CLI 1.10.19, the newest release, with its source commit and the fingerprint of its published package, so an agent installs the same version every Regents site uses.

## 27 October 2026: no surprise sign-outs, and agents can ask their status
- If your sign-in can't be read for a moment, the page says "Something didn't load." and offers Try again, which loads the same page. You stay signed in, and nothing is saved or paired until it can be read. A sign-in that has ended still shows Sign in.
- Wallet buttons say "That did not go through. Nothing was sent. Try again in a moment." when your account can't be read, instead of asking you to sign in. Connect ENS says "That did not go through. Try again in a moment." instead of asking you to check the name.
- Connect ENS now says when a name is already connected to another account, instead of asking you to check it.
- A token picture that can't be saved for a moment says "That did not go through. Try again in a moment." instead of calling the file broken, and a sign-in that has ended signs the page out.
- Agents can ask their status here first: not paired or paired, what they may do here and what to do next. Since a recent update that question had answered with an error.
- An agent whose pairing doesn't lead to a Regent account is told it isn't paired and to ask its person to pair it with Pair New Agent. When its person's account can't be read for a moment, it is told to try again.

## 27 October 2026: the motion lab's panels stay under the skip link
- On the motion lab page, an open drawer, sheet, note or Share menu now covers the header but no longer covers the "Skip to content" link, and they lie flat without a shadow, as menus do elsewhere on the site.

## 27 October 2026: menus and panels in one order
- On a phone, the open side panel now runs to the foot of the screen, over the ticker of recent bids and trades, instead of leaving the ticker showing and pressable beneath it.
- Menus, filters, hover names and the notice after a trade now lie flat on the page, without a soft shadow. The header, menus, side panel and notices stack in the same order as on the other Regents sites.

## 27 October 2026: Buy Credits never opens a wallet that can't pay
- Pressing Buy on Credits the moment the page changed wallet or amount could open your wallet for a purchase it was certain to refuse, such as one with too little USDC or before the approval. Now the button shows why it can't go through, as it already did once the page caught up. Bids are unchanged.

## 27 October 2026: clearer agent list
- On your Account page, each paired agent now shows its whole name, with its address and its copy and explorer buttons on the line beneath, as on every Regents site.

## 27 October 2026: steadier during updates, quieter records
- Nothing changes on the pages. Autolaunch now keeps a smaller, fixed number of links open to the database it shares with the other Regents sites, so an update to several sites at once no longer leaves every site briefly unable to load or save.
- Updates to Autolaunch now wait their turn behind any other Regents site's update, so two sites never swap over at the same moment.
- An address the site refuses outright no longer adds a line to the site's records for every try, so the records show what visitors did.

## 27 October 2026: one address for each page
- An address ending in a slash, such as autolaunch.sh/contact/, now shows the site's "page not found" page, as the template does. Some of these showed an error page and others opened a second copy of the page. The same address without the slash opens the page as before; the home page is unchanged.

## 26 October 2026: following a visit step by step
- Nothing changes on the pages. The site's records now note each page opened, each button pressed and how it ended, under one code per visit, so a problem someone hits can be followed step by step. The records never hold your name, wallet, what you typed or which item you opened, only the kind of page.

## 26 October 2026: a newer database library
- Nothing changes on the pages. The site moves to a newer release of the library it saves records with, which closes two published weaknesses and keeps every record in Autolaunch's own part of the shared database.
- When a required detail is missing, the site again says which one, instead of failing with an unclear database error.

## 26 October 2026: a Safe your agent chose needs your tick too
- When your paired agent sets your launch's treasury to a Safe, the create page now asks you to tick it before the launch review, as it already did for any other smart contract account. The tick reads "This smart contract will receive all treasury funds".

## 26 October 2026: safer web server
- Nothing changes on the pages. The site moves to newer releases of its web server and its data library. The web server release closes eleven published weaknesses in how it handles connections.
- The library that checks sign-in tokens moves to its newest release, which closes eight weaknesses published today.

## 26 October 2026: your account page opens again
- If you had bought Credits, your account page kept reloading and never finished opening. It opens normally again, and each line of your Credits activity says what happened and by how much, such as "Bought Credits" and "+5".

## 26 October 2026: releases fetch their parts directly
- Nothing changes on the pages. Building a release now downloads its ready-made parts straight from where their makers publish them, with no extra steps.

## 26 October 2026: a calmer hand-over between releases
- Nothing changes on the pages. When a new release replaces the site's server, open pages and work already under way now finish first instead of being cut off.

## 24 October 2026: auction prices are read once for every page
- Nothing changes on the pages. Every auction, on Base and on Robinhood, is now read from its own contract in one place, and every open page shows that one reading.

## 24 October 2026: you confirm a treasury your agent chose
- When your paired agent sets your launch's treasury to a smart contract account, the create page shows the address and asks you to tick that it is where your launch's money should go. The launch review opens only after you tick. If your agent changes the treasury again, you tick again.
- On a phone, the button to launch without X, GitHub or ENS now reads "Skip connections", which fits; before, its words were cut off.

## 24 October 2026: a browser check of the side panel
- Nothing changes on the pages. Every full check of the site now opens it in a browser at desktop and phone widths and confirms the side panel opens right under the top bar.

## 24 October 2026: the side panel opens right under the top bar
- On wider screens the top bar runs across the whole page, above the menu on the left, and the side panel opens directly beneath it, lined up with its edges, in every browser.
- The top bar keeps one height on every page and screen size.

## 24 October 2026: agent guides name Regents command-line tool 1.10.17
- Every agent guide names the newest Regents command-line tool, 1.10.17.
- Nothing changes on the pages. The site now builds with the newest shared design library, which no longer warns during the build.

## 23 October 2026: a quieter start
- Nothing changes on the pages. The site no longer writes a needless warning each time it starts.

## 23 October 2026: releases build on any computer
- Nothing changes on the pages. A release of the site now builds the same way on an Apple computer as on the release servers.

## 23 October 2026: ChatGPT agents show their picture
- An agent from ChatGPT shows with its own picture on the Account page, which before could not open with one listed.

## 23 October 2026: bids and trades keep coming in through a restart
- The reading of each auction's bids, each token's trades and the chain's record now carries on from another server when one stops or restarts, so the figures on the pages keep up. Nothing else changes on the pages.

## 23 October 2026: Pair New Agent stays open when nothing is chosen
- The side panel no longer closes with an error when the page reconnects, or when you press to make a code before choosing an agent. The box stays as it was.

## 23 October 2026: only your account's wallets act for it
- When you sign in, a wallet app you had connected before signing in no longer acts for your account unless it is one of your account's wallets.

## 23 October 2026: see your agent's work as it happens
- With a create page open, what your paired agent fills in shows straight away, in the form and in the list of what your agent filled in. You no longer need to reload. Anything you typed that could not be saved stays in its box.
- A picture your agent sends is saved only while its pairing still holds.

## 23 October 2026: the phone menu sits right in every browser
- On a phone, the menu and the account panel open right under the top bar in every browser, and the bar keeps its top line as you scroll.
- On the Account page, the agents link says it opens regents.sh, and the note says a paired agent can fill in your launch drafts for you to check.

## 23 October 2026: quicker to notice a slow moment
- autolaunch.sh now keeps a record of how long each page and each look-up takes, so the team sees a slow moment as it happens. Nothing changes on the pages.

## 23 October 2026: new releases build again
- Nothing changes on the pages. A new release of the site fetches four prebuilt parts from their makers' download addresses directly, so it no longer stops when GitHub's downloads refuse the build.

## 23 October 2026: your own wallet comes first, and IronClaw in the side panel
- When you sign in with a wallet of your own, that wallet is your main wallet, with its ENS name. The Regents wallet made for you at sign-in no longer takes its place.
- Pair New Agent in the side panel offers IronClaw where NemoClaw was. NemoClaw agents still pair as any agent.
- The Hermes pairing message tells your agent to keep the key it pairs with, made with the SIWA client or its own wallet.

## 23 October 2026: the chain is read when it matters
- Auctions, tokens, trades and the REGENT page are brought up to date from Base every five minutes instead of every few seconds.
- When you bid, launch, claim or make any other on-chain move, the site reads the chain again within ten seconds, so your own change shows straight away.
- A new launch still appears on Explore within a minute of its creator's press.

## 23 October 2026: pay a Revstake token from its page
- A Revstake token's page can take a payment into its revenue split once launches are open: choose USDC, REGENT or the token, check the review, and confirm in your wallet. The payment address comes from the launch's own record on Base, and the card refuses any address whose money would not go to the launch's treasury, or a site on another network.

## 23 October 2026: the payment card checks its network
- The Revstake payment card only prepares a payment when the site is on the token's own Base network, and otherwise says payments are not open here. The card still takes no payments until it is switched on.

## 23 October 2026: your agent can fill in your whole launch
- A paired agent can now fill in everything the launch form takes: the token's name, ticker, description, links and picture, and its launch settings: where a Revstake token's treasury goes, or which chain and stock a Memestock token pairs with.
- When you open the launch page, a box above the wallet steps names every field your agent filled in, with its value, and the launch review names them again as it stands when you press Review, with every community link shown. Change any field and it becomes yours. You still check everything and sign the launch yourself.
- An agent can never give your acknowledgement for a treasury held by a private key, and changing the treasury takes back an acknowledgement you gave before.
- If anything in a launch changes while its review is open, the review is brought up to date and says so beside the button, so you check it again before you press.

## 23 October 2026: the price chart draws itself in
- A token's price chart now grows from its opening price to today when it first appears. If your device is set to reduce motion, it appears whole straight away.

## 23 October 2026: revenue history for Revstake tokens
- A Revstake token's page shows its revenue history: each payment that reached its revenue splitter, with the amount, the day and a link to the transaction. Agents get the same list when they read the token.

## 23 October 2026: a clearer home page
- The home page now says in one line what Autolaunch is for, and offers two ways in: Back a launch, or Launch yours.
- A new "Coming next" area shows the auctions taking bids or opening soon. When none are open, it shows stocks you can launch with and the latest results.
- The Agent Tools button has moved from the top of every page to the footer and the developer guide.

## 23 October 2026: a light stock listing, with a page for each stock
- The stock listing is now a short list that opens quickly. Each stock has its own page with its addresses, company links and pool research, at an address you can share, such as /stock-listing/AAPLc.

## 23 October 2026: one figure a row on a phone
- On a phone, each auction in the lists shows one figure: how much bidders have put in while it can still take bids, and its price once it has finished.

## 23 October 2026: token pages open on the price
- A token's page now opens on its price in dollars, its market cap, how far it has moved since its pool opened and who made it, then its chart, then Swap and Stake. On a phone the picture sits small beside them, so they are all on the first screen.
- Where the outside chart site has no chart for a token yet, View Chart opens the token's own price chart on the page instead of saying the chart is unavailable.

## 23 October 2026: creators named the same way everywhere
- Every list, auction page, token page and share picture names a launch's creator the same way: their checked X, ENS or GitHub name when they have one, otherwise their wallet, shortened. Before, lists showed only the wallet.

## 23 October 2026: a short agent guide, one CLI version everywhere
- /llms.txt is now a short index: what Autolaunch is, first steps for an agent and where to read on. The whole guide is at /llms-full.txt, and /sitemap.md lists every page with what it is for.
- Every agent guide names the same regents-cli release, 1.10.12.
- The signed agent guide says whether saving drafts is open right now, instead of a fixed line.

## 23 October 2026: other websites can show Autolaunch auctions and tokens
- A page on any website can read Autolaunch's public auction, token, count and treasury figures straight from its visitors' browsers. Anything tied to a person's sign-in or an agent's pairing still answers only autolaunch.sh.

## 23 October 2026: every auction and token page points to its own record
- An agent on an auction or token page finds a link to that page's record in the agent API, and the page describes that auction or token to search engines, not only the site.

## 23 October 2026: token prices in dollars, short prices and auction counts for agents
- Agents reading tokens now get each token's price and market cap in its own currency and in dollars, and what its auction raised, the same figures the token lists show.
- Prices in the agent API are 18 digits long instead of about 90, rounded up, so a bid at a stated clearing price still reaches it.
- Agents can ask how many auctions are live and how many have graduated, for Revstake on Base and Memestock on Base and Robinhood, without paging through the list.

## 23 October 2026: tips that open as you point
- An "i" anywhere on Autolaunch opens as soon as you rest the mouse on it, and closes when you move away. Click it to keep it open. On a phone, tap it as before.
- On auction and token cards, bid volume and market cap have a dotted underline: point at or tap the figure to read what it means.

## 23 October 2026: a clearer pairing message, on newer foundations
- The message you copy to pair an agent names your Regents Labs account and the site, and sends the agent to the pairing steps in the agent guide.
- autolaunch.sh runs on newer versions of the software it is built with. Nothing else changes for people or agents.

## 23 October 2026: buttons, agents and tips as on every Regent site
- Main buttons rest as plain colour and show their corner marks when you point at them or reach them with the keyboard, as on the other Regent sites.
- On Account, each paired agent shows its wallet address beside its name, with a copy button. Pressing the address shows it in full.
- The pairing box shows the agent you chose to pair.
- A tip opens under the mouse pointer when you hover its icon.

## 23 October 2026: the side panel opens under the header
- The side panel opens below the header's bottom line instead of beside it, with its right edge in line with the header's. While it is open the header stays at the top of the screen as you scroll.
- On a phone, the menu, the dimmed page behind it and the side panel start exactly at the header's bottom line, with no sliver of overlap.

## 23 October 2026: Manage links stay on autolaunch.sh
- In the side panel, Manage Account opens your Account page here, and Manage Agents opens the agents on it, both in the same tab. They used to open regents.sh in a new tab. Manage Credits on regents.sh on the Account page stays as it was.

## 23 October 2026: two fixed libraries
- The documentation helper agents use when they build Autolaunch's moving pictures runs on a corrected release of its tool library, which closes three known security problems. The pages themselves do not change.
- The library that protects your sign-in and the site's signed links runs on a corrected release, which closes a known security problem. Nothing changes on the pages.

## 22 October 2026: safer connections to other services
- autolaunch.sh now trusts only the current list of certificate issuers when it talks to other services such as Base, Robinhood Chain and Privy. Certificates from eMudhra, whose certificates were misused on 20 October, are no longer accepted.

## 21 October 2026: share pictures that show in full on X, and tidier searches
- The home and How it works share pictures are new: the headline and autolaunch.sh sit on the left, where X shows them on a phone, with Revstake and Memestock beside them.
- An auction's or token's share picture puts autolaunch.sh along the top and the token's name, figures and price line on the left, so X's phone view shows all of them and X's own label no longer covers the site's name.
- A search ignores stray and invisible spaces, so a pasted name with an extra space finds the same launches, and a shared link to a searched list opens that same list.

## 19 October 2026: filters you can tap, and plainer answers when something can't load
- On a phone, each filter on Auctions and Tokens is a full-size tap, and the Verified menu stays on screen. On a computer they keep their normal size.
- When a token or auction page can't be read for a moment, it says so plainly. "Try again" appears only when the site can't reach its records.
- If the list of stocks can't be read, the stock launch page says so with a Try again button.
- The Buy Credits panel no longer stops working when a network can't be reached.

## 19 October 2026: lighter pages that hold still, and plainer words
- The home page and token pages load each stock picture at the size it is shown, so they open much faster on a phone.
- A token page no longer jumps when its pool is read: the address, Uniswap and chart buttons, Claim Rewards and the price chart keep their places from the start.
- A bid with a very high limit shows it short in the auction's activity, such as 26.59B SNDK, with the exact amount on hover and for screen readers.
- Token and auction pages name the token in the browser tab, such as "SANDY token", and show the name once when the ticker only repeats it.
- Every page agrees that a creator's tokens vest over 30 days from graduation. The auction page's pool card shows the same lock answer as the facts above it.
- The Revstake minimum raise reads "about 0.000000001 REGENT, so any real bid reaches it".
- The developer guide says the command-line tool is published, with the versions to use, and that every error, profile ones included, carries a code, a message and a hint.
- Internal wording on public pages is rewritten in plain words, and the header button reads "17 Agent Tools".
- Signed out, Points says "Sign in to see your points.", Portfolio says "Sign in to see your portfolio", and a bid page that has no bid says "We can't find that bid".
- Screen readers find one main area and one site header on every page, every page has a heading, orange text on light pages is dark enough to read, and the developer guide's tables can be scrolled from the keyboard.

## 19 October 2026: slimmer buttons
- Buttons are slimmer, with the label on one line, and filter pills close with Escape or a tap outside.

## 19 October 2026: your share video is saved, and a new look for share videos and pictures
- Your share video for a launch is saved. Opening the share window again shows the same video straight away; after three hours you can make a new one. Saved videos are deleted after a day. If the space for saved videos is ever full, your video is still made; it just isn't saved for next time.
- The daily limit of three videos each is gone. Autolaunch makes up to 1000 videos a day across the site; on a day it reaches that, the share window says "Error making video, try tomorrow"
- Share videos and share pictures have a tangerine frame, no dates, and autolaunch.sh along the bottom. During an auction they show the time left instead of "Graduated", and large earnings are never cut off.
- On a computer the share window's video button reads "Download video". A video you made stays ready if you close the window and open it again.

## 18 October 2026: three share videos a day, even from several tabs at once, and easier taps
- Asking for share videos from several tabs or windows at the same moment still counts toward your three a day. Before, asks that arrived together could make a fourth.
- A share video that several people ask for at the same moment is made once, and everyone waits for that one.
- On token and auction pages, every link and control you tap on its own is easy to hit on a phone.
- The auction chart's replay slider and price-limit slider work again.
- If a share video can't be made, the share window says why in one line, such as a daily limit or a figure that couldn't be read, with a button to try again.

## 18 October 2026: share-video requests kept in order, and the old account copy removed
- Your place in line for a share video and your three-a-day count stay right however many people ask at once.
- Autolaunch's old, unused copy of your account is deleted. Your account now lives only in your one Regent account.

## 18 October 2026: one Regent account, no Autolaunch copy
- Autolaunch no longer keeps its own copy of your account. It reads and writes your one Regent account, the same one every Regent site uses, so your drafts, X and social links, ENS name and sign-ins here belong to that account.
- An agent paired with you can read and save your drafts and check in here even if you have never signed in on Autolaunch. Agents are never told that you need to sign in on this site first.
- An agent that isn't paired is told: "Ask your person to sign in on this site and pair you with Pair New Agent in the side panel, then send the request again."
- An agent's check-in shows your Regent profile name and ENS name, when you have them.
- If your Regent account has no wallet yet, an agent asking for your bids and tokens is told so (`wallet_required`) and asked to have you sign in with your wallet.
- The pairing box offers only the agents the pairing step accepts.
- If you have only ever signed in on Autolaunch, you now have your Regent account, holding the same sign-in and wallets Autolaunch has for you, as your first sign-in on any other Regent site would have given you.
- The site paused for about a minute while everything moved over to your Regent account.

## 18 October 2026: share videos wait their turn, three of your own a day
- Share videos are made one at a time. While yours is being made, the share window says "Preparing your video…" and how many are ahead of it.
- Each person can make three videos of their own in any 24 hours. After that the share window offers the launch's video everyone sees.

## 18 October 2026: share a video any time, from any launch
- Token and auction pages, on Base and Robinhood, have a Share button by the title, and each row in Portfolio has one too.
- A launch still in its auction has its own share video, and a signed-in bidder can share a video of their own bids. Only you can open your own video.
- Once an auction graduates, its video link leads to the token's video.

## 18 October 2026: share a token as a short video
- A graduated token's share card has a short video version anyone can open, and its ticker reads "$TOKEN / STOCK".
- After you stake, the share window offers Share video: a video of your own bids, trades, stake and earnings in that token. Only you can open your own video.
- A new stake, unstake, buy or sell shows in your video straight away.

## 17 October 2026: a mistyped token or auction address is not found again
- An address that can't belong to any auction or token, such as a mistyped link, shows the not-found page again. For a short while it said the page didn't open.

## 17 October 2026: empty pages that point the way, and plain field messages
- Empty lists, searches with no matches, a bid page with no bid and a draft that won't open each say why in one line and offer a button to move on.
- An auction or token that is no longer listed says so, instead of showing a long internal number.
- If an auction or token page can't be read for a moment, it says the page didn't open and offers Try again, instead of claiming the page doesn't exist.
- Creator connections that couldn't be read say so, instead of looking unconnected.
- Draft fields explain their limits in plain words, and hidden characters are pointed out instead of failing the save.
- A launch's website must be a full https link before the launch can go ahead, for people and agents alike.
- Searches with hidden characters in them no longer fail.

## 17 October 2026: a phone layout built like the rest of Regents
- On a phone the top bar matches the other Regents sites: the Autolaunch mark and Menu on the left; search, Regents Products and Sign in (or your picture) on the right. It stays on one line even on the smallest phones.
- Menu now slides in from the left, under the bar. Escape, a tap beside it, Back, a link or another page closes it, and the page behind it stays still.
- Every button and link you press on its own is at least 44 pixels, and no page scrolls sideways on any phone, tablet or laptop.
- On a phone, Place bid and the Launch button stay at the bottom of the screen while you fill in their form.
- Cards, tags and the Base and Robinhood labels look the same everywhere, on phone and desktop.
- Pages that take a moment to load their figures show the shape of what's coming instead of a blank line.
- A very long ticker no longer pushes an auction card off the screen.

## 17 October 2026: a phone layout that gets out of the way
- On a phone the top of every page is one slim bar: Autolaunch on the left, then Menu and Sign in (or your picture). Pages start right under it, and the bar stays at the top as you scroll.
- Menu opens a panel from the right with Explore, Auctions, Tokens, Stocks, Portfolio and Docs as plain rows, and Launch as the one big button. Search is there too once the site opens. Tap beside it, press Close navigation or go to another page to close it.
- Your picture opens the side panel, which now also shows your Credits balance on a phone.
- The WebMCP tools button and the light and dark switch are at the top of the footer on a phone.
- Pages reach the edges of the screen and keep clear of the notch and the home bar.
- Tablets and laptops look as they did.

## 17 October 2026: buttons with cut corners and a footer at the bottom
- Main buttons cut two corners again, with Powder Blue and Tangerine marks in Autolaunch's own colours in light and dark. Their arrow nudges when you point at them and they give a little when pressed.
- The footer reads About, Developer docs, Agent guide, Contact, Privacy policy and Terms of use. Agent guide opens the two plain-text guides to give your agent.
- On a short page the footer sits at the bottom of the screen.
- Opening the side panel on a laptop screen no longer pushes the page down: the header stays on one line.
- Agents are told which agent kinds they can name when they pair, and that their person may need to sign in on Autolaunch once. The agent guides point to the latest Regents command-line tool.

## 16 October 2026: claim everything in one press
- Claim rewards also moves the trading fees still waiting in the pool, so one press claims everything. A wallet that can send several steps together does it in one go; others confirm each step in turn.
- After a claim, a green light swirls into the Stake button, with a line saying staking is the only way to receive the stock (or REGENT) from fees.
- A refresh button in the trade widget reads your balances again, and it happens on its own after any claim, settle, release, stake or unstake.
- The Base or Robinhood badge sits at the bottom right of the token card.
- On Create, the stock list stays open when you switch chain.
- A claim with nothing owed says so plainly.

## 16 October 2026: pair an agent from the side panel
- The side panel holds the box to pair an agent, the same one the Account page shows: choose your agent, copy the message with its code, make a new code, and see your agent's name as soon as it pairs, from any Regent site. On the Account page the box shows once, in the Agents section.
- "Manage Agents" opens your Regents account at its agents, from the side panel and from the Account page.
- Help leaves the side panel; Docs and Contact stay at the bottom of every page.
- On a wide screen the side panel slides in beside the page, which narrows to make room. On a narrower screen it slides in over the page's edge, and only when you open it on that page. If you asked for less motion, it opens and closes at once.
- Opening the side panel moves you into it, and Escape closes it and takes you back to its button. Its Account and Sign out buttons no longer break mid-word.
- An agent that isn't paired yet is told it can get a code from the side panel or Account page here, or on regents.sh, and the agent guide has the steps.

## 16 October 2026: the token card fits every width
- The token card stacks its picture above the ticker when space is short, so the ticker no longer breaks one letter per line and nothing is cut off at laptop widths.
- On a phone the trade widget comes first, under the token's name.
- Copied token details show prices to 18 decimal places.
- The Account page opens again for people with a paired agent.

## 16 October 2026: a token page you can use at a glance
- One trade widget: Swap or Stake, plus Unstake once you have a stake. Stake is one button that stakes your whole balance; Unstake keeps 25, 50, 75 and Max.
- Claim Rewards sits under the widget with what you will receive, beside Settle contract, which moves every trading fee waiting in the pool into the staking contract.
- "Copy Full Token Details to Agent" holds the long explanations, the supply breakdown and the Uniswap Liquidity Pool details; the page keeps a short details list.
- The token card shows a large Base or Robinhood badge. Auction pages show the ticker with its pair and no "$", with larger links and the ENS mark.
- Onchain Stocks is now Stocks, at /stock-listing.
- "Agents see 17 WebMCP Tools" opens the tool list with a prompt to copy, as on every Regent site, and the apps menu reads Regents Products.
- The price impact box, the rewards chart and the reward walkthrough are gone.

## 16 October 2026: every sign-in has its end recorded
- The few sign-ins made in the minutes the 30-day rule arrived now end too, 30 days after their last refresh, the same as every other sign-in.

## 16 October 2026: a sign-in ends 30 days after it was made
- A sign-in now ends 30 days after you signed in, however often you come back in between. Before, each visit that refreshed the sign-in started the 30 days again, so an account used every week stayed signed in indefinitely. Every Regent site follows this rule.
- Sign-ins that were already open count from their most recent refresh.

## 16 October 2026: a simpler header and clearer lists
- The sidebar's Auctions and Tokens open their own pages, each with its own heading.
- The WebMCP badge opens the site's tools for agents, with one line on what WebMCP is and a prompt to copy for your agent.
- agents.md moves into the $REGENT menu, and the header gains the Regents Labs apps menu.
- The side panel and its button appear only while you are signed in, so nothing covers Sign in after you sign out.
- A request that is too large or unreadable gets a clear answer instead of an error page.
- Agent guides point to a newer Regents command-line tool, which has `token <id>` and reads the current account answers. Tool names read in plain words.

## 15 October 2026: Escape closes swap settings; Autolaunch's own agent skill
- On a token page, Escape closes the swap settings and returns to the settings button.
- Revstake wallet payments read a typed amount exactly, digit for digit, the same way bids do.
- `/skill.md` is now Autolaunch's own guide for agents: what to read, which tool or command fits, and how often to check back. `/agents.md` is unchanged, and `/llms.txt` links both.

## 15 October 2026: sign out stays signed out
- After Sign out, a sign-in the wallet still remembers no longer signs you back in by itself. Signing out in one tab signs out the others.
- Every wallet transaction names its chain.
- Request limits work as on every Regent site, with the same allowances.
- Pages and the X connection window follow the same security rules as every Regent site.

## 15 October 2026: swaps start at 6% slippage, and room for more visitors
- The token page's swap widget starts with a 6% maximum slippage, up from 1%. Swappers can still pick anywhere from 1% to 10%.
- The site handles more people at once, and no visitor is turned away when it is busy.

## 15 October 2026: stock bids let you set slippage
- Base USDC and Robinhood USDG stock auction bids have an editable slippage, 5% by default, from 0% to 99.99% with up to two decimals. The bid shows the exact minimum stock received, and that minimum goes into the transaction. Direct stock bids are unchanged.

## 15 October 2026: agent account answers match every Regent site
- Signed agent reads of Points, Credits balances and Credits history answer in the same shape as every Regent site: Points as two-decimal amounts with daily allowances, Credits history paged by `pagination.next_cursor`, and a short note when Points earning or agent spending is off. An invalid history cursor is refused by name.
- Agents can read one listed token by its id at `/api/v1/tokens/{id}`, on Base and Robinhood, with its page and auction links, stored price, quote token and supply. Token lists include each token's page link.
- An agent's check-in includes the account's stored wallets. They give the agent no wallet authority.

## 15 October 2026: behind-the-scenes updates
- Behind-the-scenes updates only.

## 14 October 2026: a security fix
- A security fix. Nothing changes on the pages.

## 14 October 2026: pages answer data requests with a clear refusal
- Asking one of the site's pages, such as Onchain Stocks, for data instead of a page now gets a clear refusal instead of an error. Browsing, signing in and linking accounts work as before.

## 14 October 2026: Credits stays easy to tap
- The header's Credits button is at least 44 pixels wide and tall, including when its balance is unavailable. It lines up with the account control, as on every Regent site.

## 14 October 2026: mobile auction names and pool charts stay readable
- Phone auction rows put the token name and ticker above actions and status, so wallet buttons no longer squeeze names out.
- Loaded token pool charts fit the page and wrap long price-range labels.
- Opening the side panel moves focus inside at every screen size; Escape closes it and returns to its button.

## 14 October 2026: launch and agent tools are easier to find
- Available to Pair links Memestock to the create page and shows Dual Stock Token greyed out with a Coming soon hint.
- The sidebar ends with an orange Launch button. The header links to agents.md, and a badge below it shows how many tools agents can use.

## 14 October 2026: stock details and clearer Explore navigation
- Onchain Stocks moves to `/upcoming-stocks`; `/upcoming` redirects there. Clicking a stock opens its token and Chainlink addresses, company and stock links, and dated pool details. Escape closes the dialog.
- Available to Pair preserves its 35 established stocks. New research appears in Soon Available (14 stocks) and Chainlink Feed Required (78 stocks). Soon Available says "pending Autolaunch smart contract enablement." Liquidity uses compact dollar amounts.
- The sidebar says Docs and adds smaller Auctions and Tokens links beneath Explore. Both lists share the Explore page.

## 14 October 2026: token pages quote prices again
- The price impact box on a token page gives buy and sell figures again, on Base and Robinhood, where it had said "The quote did not come back" for every size.
- Checking a bid on an auction that has ended now speaks in the past, against the final price: for example "Above the final price: bought every block". A withdrawn bid says its unspent money was already returned when it was withdrawn.
- A Base Memestock auction now shows its token's address under Additional Details and in the site's token list for agents, as Robinhood ones already did. AIFROG, BITE, JollyBoi and two earlier auctions now show theirs too.
- The "Uniswap Pool" button at the top of a Base token page opens the token's pool on Uniswap, as it already did on Robinhood.

## 14 October 2026: steadier stock checks behind the scenes
- Behind-the-scenes updates only.

## 14 October 2026: finished auctions lead on to their token
- An auction that ended below its minimum says "Minimum not met" on the lists, in place of an empty bar.
- On the Auctions list, a graduated auction's row shows a "Buy" button on hover that opens its token page. A signed-in wallet with something to collect sees its "Claim" or "Refund" button in the same place, and a Claim button now names the token, for example "Claim AIFROG".
- A graduated auction's page, on Base or Robinhood, opens with "Auction is Finished" and a button on to its token page, beside the token's picture, its creator and their links, the total bid volume, the starting market cap (the auction's final price times the whole supply) and the market cap now.
- An auction page lists the 100 prices nearest the price now, so it opens faster.
- An auction page reads a signed-in visitor's own bids from the chain when it opens and when one of them changes, not on every block.
- The lists send an open page only what changed on screen.
- Every stock Chainlink prices on Base or Robinhood now has a logo: CleanSpark, the iShares South Korea fund, IonQ and Rigetti join the rest, so no stock on the Onchain Stocks page shows letters in place of a logo.

## 14 October 2026: a closer watch on token trades behind the scenes
- Behind-the-scenes updates only.

## 14 October 2026: ENS pictures are tried again, and Points share one daily limit
- When a wallet's ENS picture can't be read because the picture service is slow or busy, it is tried again instead of leaving the wallet with no picture.
- Refunds and their history read the same way on every Regent site, and Points share one daily limit.
- An agent's refused signed request gets the same answer on every Regent site.

## 14 October 2026: ENS lookup problems noted behind the scenes
- Behind-the-scenes updates only.

## 14 October 2026: your Claim or Refund button on the Auctions list, and outcome pictures in search
- On the Auctions list, a signed-in wallet with something to collect from a finished Base auction sees its own button on that row: "Claim", "Withdraw", or "Refund" with the amount. It opens the same card as on the home page. Signed out, or with nothing to collect, the list looks as before.
- In search results, a finished auction shows the same picture as the lists: a full bar with a tick and "Graduated", or a part-filled bar with how much of its minimum it raised. On a phone, search leaves it out to save room.

## 14 October 2026: auction figures are read once for everyone
- An auction's price, price chart, schedule and stage are read from the chain once and shown to every visitor alike. An open page changes when one of those figures changes, not every time a block goes by.
- The line under the price names the block those figures were read at, and keeps it until a figure changes.
- An auction with a long price chart is read over a few rounds and then costs nothing until the next bid. If an auction's page could not be read on a round, it keeps what was last read.
- When the chain replaces a block the figures were read at, they are read again.

## 14 October 2026: the menu says "Onchain Stocks"
- The left menu's link to the stocks page reads "Onchain Stocks". Where the two words do not fit on one line they take two, inside a button the same size as the others.

## 14 October 2026: finished auctions show a picture, and your own Claim or Refund button
- On the home page's list, a finished auction shows a bar in place of the text about its dates: a full bar with a tick and "Graduated", or a part-filled bar with how much of its minimum it raised.
- A signed-in wallet with something to collect from a finished Base auction sees its own button on that row: "Claim", "Withdraw", or "Refund" with the amount. It opens the same card Portfolio does, in place. Nobody else sees a button there, and signed out there are none.
- Robinhood auctions show the picture; their claims stay on Portfolio.

## 14 October 2026: the create page's link says "Onchain Stocks"
- On the create page, the link under the stock picker to the stocks page reads "Onchain Stocks".

## 14 October 2026: the stocks page is called "Onchain Stocks"
- The stocks page opens with "Onchain Stocks" and one line: launch a pair with a meme ticker and earn from trading fees, with Covered Call Options coming soon. The browser tab says "Onchain Stocks" too.
- The list of stocks next in line is headed "Soon Available".

## 14 October 2026: logos for NBIS, CRWV and RKLB
- On the Upcoming stocks page, NBIS, CRWV and RKLB show a logo in place of their first two letters. Every stock the page lists today has one.

## 13 October 2026: logos for GLD, ORCL and ASML
- On the Upcoming stocks page, GLD, ORCL and ASML show a logo in place of their first two letters. GLD carries State Street's mark, as SPY does.

## 13 October 2026: a page of upcoming stocks
- New page, autolaunch.sh/upcoming. "Eligible to add" lists, for Base and for Robinhood, the stocks not yet available that have a live Chainlink price and more than $10,000 in a dollar pool, with the size of that pool. "Available to Pair" lists every stock a Memestock token can be paired with today.
- The eligible list is the site's hourly reading of outside services. It is not a promise: a stock is added only when the Safe admits it. The page shows a ticker and a pool size, and no token address or link.
- The left menu has a fourth link, "New Stocks", to that page, and the create page shows "Upcoming stocks" under the stock picker.

## 13 October 2026: the stock list comes from the chain, and the create and bid pages show more
- The stocks a Memestock token can be paired with are now read from each chain's launchpad
  every five minutes. A stock the Safe admits shows in the picker within about six minutes,
  with its dollar price, and a stock it revokes leaves the picker. Before, either waited for
  a site update.
- The picker shows a company's short name: "Apple", "Microsoft", "Meta Platforms".
- Both create pages show the gallery card for the token beside the form as it is filled in.
- A bid window shows the auction's picture and the wallet's balances.
- "Buy at" on a stock names its trading venues with more than $10,000, the two deepest.
- An auction names its minimum only when it is about to miss it, and an auctions list with
  nothing in a status says so instead of reporting a failed search.
- For about ten minutes on 13 October (21:41 to 21:50 UTC) the create page showed an error,
  stock prices were not read and the stock picker was empty.

## 13 October 2026: lighter open pages behind the scenes
- Behind-the-scenes updates only.

## 13 October 2026: open pages are told only when something they show changed
- An open page updates only when something it shows has changed, instead of many times a
  minute whether or not anything had moved.
- Claims on finished auctions show on the lists within ten minutes.

## 13 October 2026: an auction page shows its price before bidding opens
- An auction's page shows its price and schedule from the moment it is launched. Before,
  between the launch and the first block of bidding, the page said the auction could not be
  read from the chain.

## 13 October 2026: open pages keep working when the site is busy
- When the site is very busy, new visitors wait a moment to get in and pages already open
  keep working.

## 13 October 2026: pages stay quick, and commands say who may run them
- Pages and clicks no longer slow down about 40 minutes after each site update.
- Every agent command now says who may run it: any signed-in agent, or an agent paired
  with a person.

## 13 October 2026: faster pages, and clearer answers to refused agents
- Pages and clicks answer faster.
- An agent whose signed request is refused is told why, such as a body that changed after
  signing or a request that was already sent, as on every Regent site.

## 13 October 2026: agent sign-in checks the request body
- A signed agent request is now refused if its body was changed after signing, as on every
  Regent site from today. Nothing changes on the pages, and agents keep signing the same way.

## 13 October 2026: a page for each bid
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

## 13 October 2026: the home page as the front door
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

## 13 October 2026: bid estimates on Robinhood auctions
- Asking for a bid estimate on a Robinhood auction now says estimates cover Base auctions only
  and where to read that auction's figures, instead of saying the auction was not found.

## 12 October 2026: bid estimates on finished auctions
- A bid estimate on an auction that has finished or failed no longer says the bid would be
  active. It says no bid can be placed there and estimates no tokens.

## 12 October 2026: agent reads and a steadier volume schedule
- The Regents command-line tool can read Autolaunch's auctions, one auction, a bid estimate,
  launched tokens and a treasury's security report without signing in, once the tool's next
  version picks them up. None of them places a bid or changes anything.
- Stock trading volumes keep updating when one of them is slow to read.

## 12 October 2026: stock trading volumes
- Trading volumes for Robinhood stocks update again. Since early on 12 October, 16 of them
  had stopped updating after a new exchange's pools began to be listed.

## 12 October 2026: side panel, Points and Credits
- The account dropdown in the header is gone. A side panel button sits beside your name,
  and either one opens the side panel: your name with Account and Sign out at the top,
  then Help. It stays open or closed as you left it. On the narrowest phones only the
  panel button shows.
- A Points page at /account/points: your balance, your NFT bonus, recent
  activity and what earns points. Earning hasn't opened on Autolaunch, so it says so.
  The Account page links to it.
- A Credits button in the header on every page shows your Regents Credits balance and
  opens Buy Credits: pay USDC on Base from your wallet and the Credits count across every
  Regent site. The Account page's Credits card links to regents.sh to manage them.

## 12 October 2026: Portfolio refresh, create page layout, shared dropdowns
- On Portfolio, the time the figures were read sits under Refresh. While a refresh runs the
  button reads "Refreshing…" and can't be pressed again until it finishes.
- On the Memestock create page, Paired stock comes right after Name and Ticker, and
  Description moves down to where Paired stock was.
- "More links" is now "Community Links" and "Socials (optional)" is now "Connect Socials",
  each in a bordered box. Community Links changes on the Revstake create page too.
- The token image hint reads "400x400 optimal".
- The list dropdowns use the rounded style every Regent site now shares.

## 12 October 2026
- Wallet balance reads count against an allowance of 30 a minute: the account's when signed
  in, the visitor's address when signed out. Past it, figures already shown stay.
- Signed out, the Revstake token panel shows the open wallet's balances, the same figures
  as signed in, with a Sign in to pay button.
- Sign in always opens the sign-in window, and any earlier sign-in the browser still
  remembers is ended first, so you sign in with the wallet your wallet app is on now.
- Sign out finishes on the page where you pressed it. One that can't finish in time is
  finished by the next page, never dropped.
- Whether you're signed in is always checked fresh, never remembered from an earlier page.
- The Tokens list shows each ticker with the currency it trades against, such as RDOG / SPCX.
- A token's picture always fits its circle in the lists, however tall or wide the picture is.
- An auction that ended below its minimum reads "Minimum unmet" instead of "Failed".
- The list dropdowns are rounded, with the arrow set in from the edge.

## 12 October 2026
- Lists of cards settle in once, the first time they scroll into view; one already in view
  when the page opens is simply there.
- An open page checks you are still signed in before each update it shows, not only on a
  click or a page change. When the sign-in has ended, the page says so.
- Wallet panels check it again before each press, and act with the wallets the account
  links at that moment.
- The Revstake token panel and the Robinhood launch card keep showing the account's own
  wallet when the open wallet isn't linked to the account, instead of going empty.
- Agents are offered only the signed tools as signed operations, each with its own inputs.

## 12 October 2026
- Behind-the-scenes updates only.

## 12 October 2026
- Behind-the-scenes updates only.

## 12 October 2026
- Behind-the-scenes updates only.

## 12 October 2026
- Memestake is now called Memestock everywhere on the site, including its links and earlier launches.
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

## 11 October 2026
- The header shows the signed-in wallet's ENS name and picture when the wallet has a primary
  ENS name that points back to it. Each sign-in reads it again from Ethereum mainnet.
- A security fix.

## 10 October 2026
- Nine Learn pages keep the same navigation and content position, with the current page marked.
  Docs, About, Blog, Contact, Fees, Privacy and Terms also select Learn in the main menu.
- Learn links work with keyboard navigation, direct links, refresh and browser Back/Forward.
- REGENT's Stake and Redeem links are marked as external and open separately.

## 9 October 2026
- Explore defaults to Live auctions. All still shows historical auctions.
- Create Memestock sits in its own container above Explore and opens the Memestake form.
- The homepage introduction, Revstake and Memestake panels, divider and auction counts are removed.

## 9 October 2026
- Site copy, creator reviews, token and pool explanations, public agent guidance and
  contract docs match the final v2 allocations, fees and destinations, liquidity positions,
  fixed auction minimums, vesting from graduation and token retirement.
- The four existing v1 auctions keep their original terms.
- The Robinhood-to-Base bridge remains unbuilt; protocol USDG stays in its inbox.

## 9 October 2026
- Token pages show View Chart only when DexScreener lists their exact pool.
  Otherwise they show Chart unavailable, including when the listing cannot be checked.
  This applies on Base and Robinhood; listing results are kept for one minute.

## 9 October 2026
- Ended auction pages load correctly again. The Finish card receives its network's
  latest block reading on Base and Robinhood, fixing AGI's stuck Loading screen.

## 9 October 2026
- A launch shows its full transaction hash while waiting for confirmation, with Copy and
  an explorer link. Pending and confirmed hashes wrap on mobile.
- A confirmed launch keeps finding its auction page as new listings arrive. Its draft
  clears only if it still describes that launch, preserving edits in another tab.
- Finish refreshes on a new block from the auction's own network.
- Hidden Robinhood auctions keep withdrawal and claim controls without public token links.
  Failed auctions show full refunds, and receipts handle bids exactly at the clearing price.
- New launches use the 5 October fee terms; the four existing v1 auctions keep working.

## 9 October 2026
- The public auction list (`GET /api/v1/auctions`) answers each address 6 times a
  minute; past that it says how many seconds to wait. One address that read it every
  2.3 seconds is refused. The developer guide and API description say so, and the
  browser tools pass the wait on to agents.

## 9 October 2026
- Auctions finish automatically once their finish block has passed.

## 9 October 2026
- The public auction list (`GET /api/v1/auctions`) is kept for five seconds, so callers
  asking for the same list again share one answer.

## 9 October 2026
- On the Revstake Create page, a Safe treasury address is now read on Base as it is
  pasted, and a line under the box says what is there: "2-of-3 Safe found", "This is a
  wallet, not a Safe", "No Safe at this address", "Safe, but not 2 of 3" or "Base could
  not be read just now". The treasury step only counts as done for a 2-of-3 Safe.

## 9 October 2026
- An auction whose bidding has ended now has a Finish button on its page. Anyone signed
  in can press it once the auction's finish block has passed: it opens the pool, or opens
  refunds if the minimum wasn't met, for the network fee. Before that block the button
  says when finishing opens.

## 9 October 2026
- Autolaunch can now take an auction off the site: it leaves every list, its page and its
  links, while anyone who bid on it still sees it in their own portfolio. The two test
  auctions, which had no bids, are off the site.

## 8 October 2026
- After a launch goes through, its card says "Your token … is launched." with the full
  transaction, a Copy button, a link to the explorer and, once it is listed, a button to open
  the auction.
- The Create form starts over blank as soon as the launch goes through, so the same launch
  isn't sent twice by mistake.

## 8 October 2026
- You can start more than one Revstake auction from the same account.
- New launches on Base and Robinhood are open on the new contracts; the old contracts take no
  new launches, and earlier auctions and tokens keep working as before.

## 8 October 2026
- Robinhood auction pages read their pool again, and Robinhood token pages open again.

## 8 October 2026
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

## 7 October 2026
- Share pictures are drawn less often and kept, so they load faster.
- A sign-in now lasts 30 days from the last time you signed in.

## 7 October 2026
- The site now always opens over a secure connection, and browsers remember to use one.
- Security reports now go to build@regents.sh.

## 6 October 2026
- A security fix. Nothing changes on the pages.
- When you open your profile without signing in, the message now says what went wrong and what to do next.

## 5 October 2026
- The browser tab, search results and the guide for AI agents now say "where agents launch" too.

## 5 October 2026
- New tagline: "where agents launch". Links to the site now show it on their preview picture.

## 30 September 2026
- The REGENT page explains staking the way the contract pays it: by share of all 100 billion
  REGENT, with the unstaked share going to Regent's treasury.
- Portfolio and auction pages show only the wallet you signed in with.
- New theme button in the header, as on the other Regent sites. Until you choose a theme, the
  site follows your device's light or dark setting.

## 30 September 2026
- New About page: the team behind Autolaunch, how it works and key facts come first, and
  the key facts also appear in llms.txt.

## 29 September 2026
- Behind-the-scenes updates only.

## 28 September 2026
- New Terms page, with the Autolaunch and blockchain-risk sections from the Regents Labs
  terms. The footer links it, and the privacy page points to it.
- The developer guide moves to /docs (the old /developers address forwards there) and
  explains errors, versions and request limits.
- The public API allows 120 requests a minute from each visitor.
- Files that help agents find the site: security contact, API catalog and tool list.
- A security fix.

## 27 September 2026
- Buttons and menus move the same way as on the other Regent sites, from their shared
  motion. With reduced motion turned on, in system settings or on the page, nothing moves.

## 27 September 2026
- The light and dark switch is in the header on every page, not only the blog, and every
  page opens in the chosen look straight away, with no flash of the other one.
- On narrower screens the header search takes its own row, so the switch and buttons fit.

## 27 September 2026
- Robinhood token and auction pages say when they could not be loaded, with a Retry
  button, instead of failing, and keep what they showed when a later read fails.
- Auction pages say when the bids could not be read, with Try again.
- The auction counts keep the last numbers when a refresh fails, marked as the last read.
- A dollar estimate never carries over from one auction to the next.

## 27 September 2026
- Behind-the-scenes updates only.

## 27 September 2026
- Every page's browser tab title and link preview name the page, then "Autolaunch", from
  one list, so shared links describe the page they point to.

## 27 September 2026
- The $REGENT address copy in the header says "Copied" on every page, like the site's
  other copy buttons.

## 27 September 2026
- A visit to www.autolaunch.sh moves to the same page on autolaunch.sh.
- A missing page says "We can’t find that page"; any other error says "Something went
  wrong".

## 27 September 2026
- Copying a token's address or the agent guide says "Copied", or "Couldn't copy" when the
  browser refuses, and screen readers hear the same.

## 27 September 2026
- Addresses show the same short way on every page (0x1234..abcd), and times read as
  "3 minutes ago" or "in 2 hours" everywhere, from the shared Regent formatting.

## 27 September 2026
- Signing in with one of several linked wallets keeps that wallet as the signed-in one.

## 27 September 2026
- Create now starts with a clear choice between a Memestake and a Revstake token, and each
  page is named for the one it makes.
- Every page that states Memestake trading fees shows the same three: the 0.30% pool fee
  and the two 1.00% fees for REGENT stakers and the token's stakers. The trade review now
  lists the fees already included in the quote.
- Portfolio says while it is refreshing, when it last read everything, and which part could
  not be read, keeping that part's last figures with their time. Signing out elsewhere
  clears the page.
- Auction figures show in the auction's own currency when there is no dollar price, and a
  figure that isn't known yet says so instead of showing a dash.
- An auction counts as ended from the auction itself, not from the clock.
- Wording about failed auctions now says each bidder can withdraw their bid, since nothing
  is sent back without a withdrawal.
- The bid estimate address now answers each kind of problem with its own code and says
  whether trying again will help.

## 27 September 2026
- AI assistants built into web browsers can now bid, finish a bid after its auction, buy,
  sell, stake, unstake and claim staking rewards for a signed-in person, using the same
  cards the person would. Every one opens the person's own wallet to confirm; nothing is
  sent without it. Launching a token still happens on the Create page.
- A signed-in person's assistant can read their bids and tokens, and the same list is
  available at autolaunch.sh/api/v1/me/positions.
- Each of these calls now says plainly what happened: sent, not sent and why (including the
  wallet being on the wrong account or refusing to switch networks), or unknown.
- A fix to signing in with an agent wallet and to looking up ENS names.
- A security fix.
- The leftover opening countdown is gone.

## 26 September 2026
- The tools Autolaunch offers to AI assistants built into web browsers are now described in
  one place, and the developer guide and agent guide list all eight of them, including the
  three that manage a signed-in person's profile (they previously named only five).
- Pages now tell browsers that only Autolaunch's own pages may offer these tools.

## 26 September 2026
- New Developers, About, Contact and Privacy pages, linked from every page's footer.
- AI agents can read the homepage and these pages as plain text at the same address, and a
  missing page tells them where to go instead of showing a dead end.
- Problems reading the public data now come with a short hint on what to try next.
- The data description moved to autolaunch.sh/openapi.json, with a sentence on what each
  request does, and a site map lists every page, auction and token for search engines.
- The homepage arrives with its coins already listed instead of filling them in a moment later.

## 26 September 2026
- Behind-the-scenes updates only.

## 26 September 2026
- Pressing a button, opening a menu or copying the address again while its animation is still
  playing no longer leaves it stuck half-faded or half-sized; every animation finishes cleanly.

## 26 September 2026
- Behind-the-scenes updates only.

## 26 September 2026
- Buttons give a small squish when pressed, and a short shake when the action isn't available.
- Menus, pop-ups and the "copied" message pop open; pop-ups also fade their dark background in
  and out.
- Nothing moves for keyboard presses or for visitors who have asked their device for less
  motion, and wallet buttons respond at once as before.

## 26 September 2026
- Search puts the best match first and forgives typos ("artficial" finds AGI). It looks at the
  name, ticker, the stock being raised, the creator's connected accounts and the description;
  pasting an address finds that auction, token or creator.
- Auction pages on Base and Robinhood show bold figures, orange tickers and coloured state
  labels, like the portfolio and token pages; a bid's standing is a coloured label too.
- Each launch step on the Create pages shows its state as a coloured label.
- Signed out, both Create pages say X, GitHub and ENS can be connected after signing in.
- Information labels take their colour from the shared design, matching the other sites.

## 25 September 2026
- Both launch pages open without signing in. Visitors can fill in the whole form, pick a stock
  and chain, and see the terms, raise and starting price update, with nothing saved.
- Signing in from either page saves what was typed into the account's draft; fields left blank
  keep what the draft already had. A refresh before signing in keeps the typed values too.
- Adding an image, connecting socials and launching ask the visitor to sign in first.

## 25 September 2026
- Figures stand out on your portfolio, token pages and every pop-up: numbers are bold, tickers
  are orange, and states such as Ready, Completed or Outbid show as coloured labels.
- The staking panel and the Pool section show short, readable amounts (94,450,000 BITE rather
  than every digit); the exact amount shows when you hover over it.
- Wallet steps in the claim, bid, swap and payment pop-ups show their state as a coloured label.

## 25 September 2026
- Your bids: clicking the name opens the page, so the Token button is gone. The Action column
  shows Withdraw, then Claim once the tokens can be claimed, then Completed.
- "Launched" reads "Graduated" again everywhere, including the Status column.
- The bid settlement card follows the current design: a status label, ruled rows of figures and
  one clear button.
- Token pages show staking right under the token info: a meter of how much of the supply is
  staked, and the pool's trading fees for the last 24 hours and all time.

## 25 September 2026
- A Robinhood token's Uniswap Pool button opens its pool on Uniswap.

## 25 September 2026
- A token page's heading reads like "First Bite BITE / AAPLc", with the shortened token address,
  a copy button, a Uniswap Pool button and a View Chart button to DEX Screener, on every Base and
  Robinhood token.
- When the wallet app is on a different account from the signed-in one, the settlement, bid and
  launch panels say so beside the button and ask to switch, instead of doing nothing on a press.

## 25 September 2026
- A bid that was spent in full on a launched auction offers "Claim BITE to wallet" and reads
  "Tokens ready to claim" in the portfolio, instead of offering to return unspent money that
  does not exist.

## 25 September 2026
- A shared How it works link shows its own picture, "how autolaunch works" with Revstake and
  Memestake supply and auction length, and its own title and description.
- Every page's link preview carries the X title and description as well.

## 25 September 2026
- Withdrawing and claiming after an auction ends works on Base and Robinhood. Before, every press
  showed "That did not go through. Try again in a moment.", and a bid priced out by the final
  price could not get its unspent money back.
- An ended auction says how long ago it ended, such as "Ended 24m ago", instead of how long ago
  it was listed.

## 25 September 2026
- The API, the command-line tool and the browser tools for AI agents call the two launch types
  `revstake` and `memestake`, in what they return as well as in the filter. The old names
  `agent` and `stocks` are gone.

## 25 September 2026

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
- The bottom ticker shows Robinhood trades from the start of each auction.

### For agents
- The API, the command-line tool and the browser tools list auctions and tokens with the
  website's own search, filters and sort, and each auction carries its page address, time
  left, amounts raised and how much of its minimum is met.

## 25 September 2026
- After you launch a memestock, "Launch memestock" starts from an empty form instead of showing
  the token you just launched.
- While your Memestake auction is live, the form is grayed out under "Only one Memestake auction
  can be live per account". It opens again once that auction ends.

## 25 September 2026
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

## 25 September 2026
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

## 25 September 2026
- Gallery cards no longer show the description. The space under the links is a quarter of its old
  height, so every card is shorter. Hovering a card shows the bid volume, with how much of the
  launch threshold is met, over the launch threshold, beside the FDV.
- The count under the gallery reads "1 auction" or "1 token" when there is one.
- Once you're signed in, every bid, payment, launch and staking box uses the wallet you signed in
  with straight away, after moving between pages and after a reload. None of them asks you to
  connect or choose a wallet first. If your browser wallet is on a different address, a note
  beside the button names both. Pressing a button when your signed-in wallet isn't connected
  opens the connect step; press again once it is.

## 25 September 2026
- The profile page shows only your connected accounts: the name, wallet and X box above them is
  gone.
- A connected GitHub account can be changed or disconnected, like X.
- Account names in the connections list are no longer underlined.
- The connections on the profile page respond again: before, their buttons could stop working
  once the page finished loading.

## 24 September 2026
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

## 24 September 2026
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

## 24 September 2026
- A launch threshold met many times over reads "100% met" instead of a huge percentage.

## 24 September 2026

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

## 24 September 2026
- Each auction page lists its bids with wallets, a price-over-time chart, and bids placed against
  sold so far.
- Amount fields accept values like ".01".

## 24 September 2026
- Auctions record the wallet that launched them. Pages show a "Created by" block with X, ENS and
  GitHub.
- Base and Robinhood chips on cards and pages; the bid form sits right under the auction card.

## 24 September 2026
- Fixed a crash, about once a second after the opening, in the updates for the Robinhood
  auction's bid activity.

## 24 September 2026
- Launches opened at 15:00 UTC on Base and Robinhood.
