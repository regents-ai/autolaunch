# Releases

Which Fly release of `autolaunch-sh` carried which commit. This is the operator record; the public
[CHANGELOG.md](CHANGELOG.md) says what changed for people and agents, under the same dates and titles.

| Fly release | Date | Commit | Changelog entry |
| --- | --- | --- | --- |
| v162 | 23 October 2026 | `b93e918` | the side panel opens under the header. The side panel, and on a phone the menu and the dimmed page behind it, start at the header's bottom line instead of covering it. No migration. Approved: Sean "3a", 23 Oct; deploys by the production-fixes chief (AL-LANE-OWNER). Rollback: v161 `acfde4e` |
| v161 | 23 October 2026 | `acfde4e` | Manage links stay on autolaunch.sh. In the side panel, Manage Account opens /account and Manage Agents opens /account#account-agents, in the same tab. No migration. Approved: Sean "2a", 23 Oct; deploys by the production-fixes chief (AL-LANE-OWNER). Rollback: v160 `c0c551c` |
| v160 | 23 October 2026 | `c0c551c` | two fixed libraries. plug_crypto 2.2.1 closes EEF-CVE-2026-105963 (a page join with a non-text session could write the secret key base to the log); vgpu's MCP library is pinned to 2.3.1, as the template does. Also carried de46f14f, already on main: new lines in a list only fade in, as in ash-template (no live page uses these entrances yet). No migration. Approved: Sean "1a", 23 Oct (the plug_crypto bump rides with it as the same security fix); deploys by the production-fixes chief, Sean "1. a" 22 Oct 21:55Z (AL-LANE-OWNER). Rollback: v159 `b0e11a1` |
| v159 | 22 October 2026 | `b0e11a1` | safer connections to other services. castore 1.0.22 is the only certificate list outbound connections trust, so the eMudhra roots dropped on 20 Oct are refused. No migration (the release command found none). Approved: Sean "1. a" to question 40, 21 Oct 08:12:23Z; deploys by the production-fixes chief, Sean "1. a" 22 Oct 21:55Z (AL-LANE-OWNER). Rollback: v158 `835573c` |
| v158 | 21 October 2026 | `835573c` | share pictures that show in full on X, and tidier searches. First deploy with scripts/deploy.sh: migrations run as the release command on autolaunch-sh (none pending). Approved: Sean "1. a" 20 Oct 00:14Z, "see it through" 21 Oct 08:56Z, migration login staged by Sean, "1. done" 10:11:58Z. Rollback: v157 `667774e` |
| v157 | 19 October 2026 | `667774e` | filters you can tap, and plainer answers when something can't load. Shipped under "teams check and ship their own releases" (13:51:27Z) with operations/CHECKLIST.md |
| v156 | 19 October 2026 | `fa3597f` | lighter pages that hold still, and plainer words. Approved: Sean "Build them" 18 Oct 23:21Z; shipped under "teams check and ship their own releases" 13:51:27Z with operations/CHECKLIST.md |
| v155 | 19 October 2026 | `5faffa2` | slimmer buttons. Approved: Sean "ok deploy when you can" 03:41Z, "Normal desktop size" 04:30Z; shipped under "teams check and ship their own releases" 13:51:27Z with operations/CHECKLIST.md |
| v154 | 19 October 2026 | `883e19a` | your share video is saved, and a new look for share videos and pictures. Approved: Sean "Ship Autolaunch v154 from commit 883e19a6, backup first, rollback v153, tests after" 11:15:08Z; database go 02:38:34Z; backup_1792408662_5001d53d030e1277 |
| v153 | 19 October 2026 | `24e59e3` | three share videos a day, even from several tabs at once, and easier taps. Approved: Sean "go v153" 02:32:20Z; duplicate check "a" 00:10:06Z; Sentinel GO 01:55Z |
| v152 | 18 October 2026 | `9916452` | share-video requests kept in order, and the old account copy removed |
| v151 | 18 October 2026 | `960fcd7` | one Regent account, no Autolaunch copy |
| v150 | 18 October 2026 | `955b9f9` | share videos wait their turn, three of your own a day |
| v149 | 18 October 2026 | `4d05325` | share a video any time, from any launch |
| v148 | 18 October 2026 | `e690353` | share a token as a short video |
| v147 | 17 October 2026 | `f38d9f5` | a mistyped token or auction address is not found again |
| v146 | 17 October 2026 | `0eda7c0` | empty pages that point the way, and plain field messages |
| v145 | 17 October 2026 | `d4db42f` | a phone layout built like the rest of Regents |
| v144 | 17 October 2026 | `87b4ef7` | a phone layout that gets out of the way |
| v143 | 17 October 2026 | `1c4e5d5` | buttons with cut corners and a footer at the bottom |
| v142 | 16 October 2026 | `811a5b9` | claim everything in one press |
| v141 | 16 October 2026 | `901ca8e` | pair an agent from the side panel |
| v140 | 16 October 2026 | `78de400` | the token card fits every width |
| v139 | 16 October 2026 | `ce7aa07` | a token page you can use at a glance |
| v138 | 16 October 2026 | `0ad2a7f` | every sign-in has its end recorded |
| v137 | 16 October 2026 | `06c075f` | a sign-in ends 30 days after it was made. Approved: Sean, 15 Oct, decision 2a (every site follows this rule) |
| v136 | 16 October 2026 | `227b1ff` | a simpler header and clearer lists |
| v135 | 15 October 2026 | `b830b18` | Escape closes swap settings; Autolaunch's own agent skill |
| v134 | 15 October 2026 | `39c0cc9` | sign out stays signed out |
| v133 | 15 October 2026 | `5f0209f` | swaps start at 6% slippage, and room for more visitors |
| v132 | 15 October 2026 | `0db69a6` | stock bids let you set slippage |
| v131 | 15 October 2026 | `e055673` | agent account answers match every Regent site |
| v130 | 15 October 2026 | not recorded | behind-the-scenes updates |
| v129 | 14 October 2026 | not recorded | a security fix |
| v128 | 14 October 2026 | not recorded | pages answer data requests with a clear refusal |
| v127 | 14 October 2026 | not recorded | Credits stays easy to tap |
| v126 | 14 October 2026 | not recorded | mobile auction names and pool charts stay readable |
| v125 | 14 October 2026 | not recorded | launch and agent tools are easier to find |
| v124 | 14 October 2026 | not recorded | stock details and clearer Explore navigation |
| v123 | 14 October 2026 | `d787d04` | token pages quote prices again |
| v122 | 14 October 2026 | `d8e3135` | steadier stock checks behind the scenes |
| v121 | 14 October 2026 | `c51d0a9` | finished auctions lead on to their token |
| v120 | 14 October 2026 | `28d2cb6` | a closer watch on token trades behind the scenes |
| v119 | 14 October 2026 | `06bfa91` | ENS pictures are tried again, and Points share one daily limit |
| v118 | 14 October 2026 | `f3e0524` | ENS lookup problems noted behind the scenes |
| v117 | 14 October 2026 | `80523b6` | your Claim or Refund button on the Auctions list, and outcome pictures in search |
| v116 | 14 October 2026 | `d379c58` | auction figures are read once for everyone |
| v115 | 14 October 2026 | `9fbf1d8` | the menu says "Onchain Stocks" |
| v114 | 14 October 2026 | `28d4f1a` | finished auctions show a picture, and your own Claim or Refund button |
| v113 | 14 October 2026 | `1a656e0` | the create page's link says "Onchain Stocks" |
| v112 | 14 October 2026 | `6b8ad5f` | the stocks page is called "Onchain Stocks" |
| v111 | 14 October 2026 | `037127d` | logos for NBIS, CRWV and RKLB |
| v110 | 13 October 2026 | `c54c0e4` | logos for GLD, ORCL and ASML |
| v109 | 13 October 2026 | `28a45d8` | a page of upcoming stocks |
| v108 | 13 October 2026 | `38c4edf` | the stock list comes from the chain, and the create and bid pages show more |
| v107 | 13 October 2026 | `27c5135` | lighter open pages behind the scenes |
| v106 | 13 October 2026 | `ca358ae` | open pages are told only when something they show changed |
| v105 | 13 October 2026 | `3bd5639` | an auction page shows its price before bidding opens |
| v104 | 13 October 2026 | `13094a2` | open pages keep working when the site is busy |
| v103 | 13 October 2026 | `19db73f` | pages stay quick, and commands say who may run them |
| v102 | 13 October 2026 | `9b85b31` | faster pages, and clearer answers to refused agents |
| v101 | 13 October 2026 | `38bb67b` | agent sign-in checks the request body |
| v100 | 13 October 2026 | `370a738` | a page for each bid |
| v99 | 13 October 2026 | `5874c18` | the home page as the front door |
| v98 | 13 October 2026 | `230462d` | bid estimates on Robinhood auctions |
| v97 | 12 October 2026 | `1833c5b` | bid estimates on finished auctions |
| v96 | 12 October 2026 | `1db2f96` | agent reads and a steadier volume schedule |
| v95 | 12 October 2026 | `372881a` | stock trading volumes |
| v94 | 12 October 2026 | `5a93551` | side panel, Points and Credits |
| v93 | 12 October 2026 | `a82c114` | Portfolio refresh, create page layout, shared dropdowns. Approved: Sean, 89 a (shared rounded dropdowns) |
| v92 | 12 October 2026 | `5649093` | (entry under this date). Approved: Sean, 66 a (shared sign-in check on the Account page), 70 a (wallet balance allowance), 67 a (signed-out Revstake panel), 71 a (sign in and sign out) |
| v91 | 12 October 2026 | `df4a9e7` | (entry under this date). Approved: Sean, 45 a (card lists settle in once) |
| v90 | 12 October 2026 | `9cabd3a` | (entry under this date) |
| v89 | 12 October 2026 | `0cad4ad` | (entry under this date) |
| v88 | 12 October 2026 | `60a0dd9` | (entry under this date) |
| v87 | 12 October 2026 | `fa57c44` | (entry under this date) |
| v86 | 11 October 2026 | `2ec5eb4` | (entry under this date) |
| v85 | 10 October 2026 | `39383ca` | (entry under this date) |
| v84 | 9 October 2026 | `08dd63e` | (entry under this date) |
| v83 | 9 October 2026 | `1d355d4` | (entry under this date) |
| v82 | 9 October 2026 | `a09044f` | (entry under this date) |
| v81 | 9 October 2026 | `409523b` | (entry under this date) |
| v80 | 9 October 2026 | `b75c693` | (entry under this date) |
| v79 | 9 October 2026 | `29af631` | (entry under this date) |
| v78 | 9 October 2026 | `98c7f73` (same build as v77) | (entry under this date) |
| v77 | 9 October 2026 | `98c7f73` | (entry under this date) |
| v76 | 9 October 2026 | `6d93209` | (entry under this date) |
| v75 | 9 October 2026 | `7371b81` | (entry under this date) |
| v74 | 9 October 2026 | `cd69683` | (entry under this date) |
| v73 | 8 October 2026 | `92f9dff` | (entry under this date) |
| v72 | 8 October 2026 | `3ac7d8d` | (entry under this date) |
| v71 | 8 October 2026 | `17f12c3` | (entry under this date) |
| v70 | 8 October 2026 | `4c598a3` | (entry under this date) |
| v69 | 7 October 2026 | `52806ed` | (entry under this date) |
| v68 | 7 October 2026 | `1a509b0` | (entry under this date) |
| v67 | 6 October 2026 | `7968f74` | (entry under this date) |
| v66 | 5 October 2026 | `2303ff9` | (entry under this date) |
| v65 | 5 October 2026 | `9e69bad` | (entry under this date) |
| v64 | 30 September 2026 | `1ba5740` | (entry under this date) |
| v63 | 30 September 2026 | `68a060b` | (entry under this date) |
| v62 | 29 September 2026 | `067a3c4` | (entry under this date) |
| v61 | 28 September 2026 | `abb4c66` | (entry under this date) |
| v60 | 27 September 2026 | `d48be63` | (entry under this date) |
| v59 | 27 September 2026 | `c345559` | (entry under this date) |
| v58 | 27 September 2026 | `2e596c1` | (entry under this date) |
| v57 | 27 September 2026 | `503b4f3` | (entry under this date) |
| v56 | 27 September 2026 | `91ec923` | (entry under this date) |
| v55 | 27 September 2026 | `865890b` | (entry under this date) |
| v54 | 27 September 2026 | `67847e4` | (entry under this date) |
| v53 | 27 September 2026 | `fadd996` | (entry under this date) |
| v52 | 27 September 2026 | `af7caea` | (entry under this date) |
| v51 | 27 September 2026 | `9061676` | (entry under this date) |
| v50 | 27 September 2026 | `03b5a7f` | (entry under this date) |
| v49 | 27 September 2026 | `a6711fc` | (entry under this date) |
| v48 | 26 September 2026 | `8d96f71` | (entry under this date) |
| v47 | 26 September 2026 | `fe8b172` | (entry under this date) |
| v46 | 26 September 2026 | `6046ba5` | (entry under this date) |
| v45 | 26 September 2026 | `fedde03` | (entry under this date) |
| v44 | 26 September 2026 | `a6b7b59` | (entry under this date) |
| v43 | 26 September 2026 | `1007375` | (entry under this date) |
| v42 | 26 September 2026 | `f041e5f` | (entry under this date) |
| v41 | 25 September 2026 | `03ecc10` | (entry under this date) |
| v40 | 25 September 2026 | `58d09fc` | (entry under this date) |
| v39 | 25 September 2026 | `b63a7e4` | (entry under this date) |
| v38 | 25 September 2026 | `0a06f51` | (entry under this date) |
| v37 | 25 September 2026 | `209fa5a` | (entry under this date) |
| v36 | 25 September 2026 | `4425219` | (entry under this date) |
| v35 | 25 September 2026 | `025f9a6` | (entry under this date) |
| v34 | 25 September 2026 | `4fc881a` | (entry under this date) |
| v33 | 25 September 2026 | `45c99c5` | (entry under this date) |
| v32 | 25 September 2026 | `8eb7841` | (entry under this date) |
| v31 | 25 September 2026 | `972b492` | (entry under this date) |
| v30 | 25 September 2026 | `fe84aea` | (entry under this date) |
| v29 | 25 September 2026 | `6fbff12` | (entry under this date) |
| v28 | 25 September 2026 | `59cd771` | (entry under this date) |
| v27 | 25 September 2026 | `d5f4bff` | (entry under this date) |
| v26 | 24 September 2026 | `40327e4` | (entry under this date) |
| v25 | 24 September 2026 | `864624e` | (entry under this date) |
| v24 | 24 September 2026 | `b97e278` | (entry under this date) |
| v23 | 24 September 2026 | `f3fef43` | (entry under this date) |
| v22 | 24 September 2026 | `e517da2` | (entry under this date) |
| v21 | 24 September 2026 | `ae5f53b` | (entry under this date) |
| v20 | 24 September 2026 | `008d3fd` | (entry under this date) |
| v19 | 24 September 2026 | `136f579` | (entry under this date) |
