# Autolaunch Litepaper

Draft as of April 22, 2026

This document is a working litepaper for Autolaunch. It is based on the current Regent founder file, the Autolaunch `layer2.md` and `layer3.md` files, the Autolaunch README, the Autolaunch contracts overview, and the broader Regent system paper. When this document goes beyond those sources, it labels the point as a thesis or draft claim.

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [The Problem Autolaunch Is Trying to Solve](#2-the-problem-autolaunch-is-trying-to-solve)
3. [The Central Thesis](#3-the-central-thesis)
4. [What Autolaunch Is](#4-what-autolaunch-is)
5. [Launch Structure](#5-launch-structure)
6. [Continuous Clearing Auction Mechanics](#6-continuous-clearing-auction-mechanics)
7. [Price Discovery and Fairness Claims](#7-price-discovery-and-fairness-claims)
8. [Liquidity and Treasury Split](#8-liquidity-and-treasury-split)
9. [Subject Revenue and Revsplit Mechanics](#9-subject-revenue-and-revsplit-mechanics)
10. [Relation to `$REGENT`](#10-relation-to-regent)
11. [Launch Flow and Operator Flow](#11-launch-flow-and-operator-flow)
12. [What the Contracts Try to Enforce](#12-what-the-contracts-try-to-enforce)
13. [Incentives by Actor](#13-incentives-by-actor)
14. [Failure Modes and Attack Surfaces](#14-failure-modes-and-attack-surfaces)
15. [Tradeoffs](#15-tradeoffs)
16. [Product and Market Risks](#16-product-and-market-risks)
17. [Open Questions](#17-open-questions)
18. [Why This Design Can Beat Common Launch Patterns](#18-why-this-design-can-beat-common-launch-patterns)
19. [Conclusion](#19-conclusion)

## 1. Executive Summary

Autolaunch is Regent’s launch and market system for agent businesses. It is built for a narrow problem: an agent with a real edge often needs capital before revenue, liquidity after launch, and a holder relationship that lasts longer than launch day. Most token launch systems solve only one piece of that problem. They help distribute supply, then leave the business to figure out treasury, revenue, and post-launch alignment later.

Autolaunch tries to connect the whole path. It gives an operator a way to prepare a launch, check readiness, deploy a contract stack, run a continuous clearing auction, form liquidity, route treasury funds, create a per-subject revenue-rights lane, and keep holders engaged after the sale through staking, claims, and recognized revenue. The product includes public auction pages, a guided launch surface, subject pages, position views, trust follow-up, and an operator-facing contract console. The repo also includes the full Foundry workspace for the launch contracts.

The strongest claim in Autolaunch is economic, not visual. The launch is not meant to be the end of the story. It is meant to finance the next phase of work. The deeper thesis in this paper is that onchain stablecoin revenue is the fact that makes that model coherent. If the token only points to future attention, the market still rests on narrative. If stablecoin revenue reaches a contract-defined revsplit and becomes visible onchain, the token becomes a claim on measured inflow and the launch becomes a capital formation tool for a real business.

The current product docs already define concrete launch economics. Ten percent of a 100 billion supply sells in the auction. Five percent is reserved for the Uniswap v4 LP position. Half of auction USDC goes to that LP position. The other half goes to the agent Safe for business operations. The remaining 85 percent of the token supply vests to the agent treasury over one year. The launch pool fee is fixed at 2 percent on swaps in the official pool, split 1 percent to Regent and 1 percent to the subject revenue lane. Recognized subject revenue sends a fixed 1 percent skim to Regent and keeps the remaining 99 percent in the subject lane, where stakers earn their formula share and the remainder accrues to the agent treasury.

Those numbers matter because they show what Autolaunch is trying to do. It is not only selling inventory. It is shaping capital, liquidity, and downstream revenue into one system. If that thesis holds, Autolaunch can be better than the usual launch pattern because it gives buyers a clearer market, gives the agent a treasury, and gives post-launch holders a reason to stay.

## 2. The Problem Autolaunch Is Trying to Solve

An agent business faces a structural mismatch. Costs arrive before proof compounds. Compute, model calls, storage, infrastructure, and distribution can become expensive well before revenue stabilizes. A good agent may show strong edge but still fail because it runs out of time and cash before the edge becomes a business.

Most token launches do not solve that problem. They solve distribution. They create a pool, run a sale, or let a community chase a chart. That may create a temporary price. It does not guarantee aligned capital, healthy liquidity, or any connection between holders and future revenue. In the worst case, launch day becomes a specialist game for speed, private flow, and extraction.

Autolaunch starts from a different premise. An agent with a real edge should be able to raise capital without turning launch day into a pure race, and the people who support that agent should have a reason to stay after the auction ends. The README says this plainly: raise before compute and API costs set the pace, keep a treasury that can fund more models and retries, and give backers a reason to stay after launch through claims, staking, and recognized revenue.

The product is therefore solving two linked problems at once.

The first problem is initial capital formation. How does an agent business raise working capital for compute, distribution, and operations without relying only on private deals, grants, or short-lived speculation?

The second problem is post-launch alignment. Once the token exists, why should anyone hold, stake, or support the business beyond simple price momentum? A token that ends at distribution is weak. A token that connects to liquidity, treasury, and recognized revenue can become stronger.

Autolaunch also solves a third problem that is easy to miss. Operators need a clean operational path, not only a smart contract. Launches require planning, metadata, identity follow-up, deploy checks, tracking, and post-launch monitoring. The product owns that workflow state in the backend and gives the operator clear entrypoints through the browser surface, the contract console, and the CLI-first launch path.

## 3. The Central Thesis

The central Autolaunch thesis has two layers.

The first layer is a product claim grounded in the repo docs. Continuous clearing auctions are a better launch model for quality teams than common timing-game launch patterns. Buyers state a total budget and a maximum price. Orders run across remaining blocks like a TWAP. Tokens are received only when the block clearing price stays below the buyer’s maximum price. This model is meant to reduce speed advantages and make price discovery more legible.

The second layer is a broader economic thesis. Onchain stablecoin revenue is the necessary fact that turns a token launch into both initial capital funding and a continuing holder revenue stream. This second layer is interpretation, but it follows directly from the contract and product shape.

Why does stablecoin revenue matter so much? Because agent businesses pay bills in stable units. Treasury planning, hosted runtime costs, API spend, and operator overhead all become more legible when measured in stablecoin. A business can survive volatility in its own token better than it can survive the absence of actual spendable revenue.

This means the launch alone is not enough. A launch can create treasury. It can also create distraction. The missing bridge is recognized revenue that reaches a contract-defined lane. In Autolaunch, only Base USDC that reaches the revsplit counts as recognized revenue. That rule is important because it turns a vague “the business is doing well” story into a measurable onchain event.

Once that event exists, the system can define holder economics with precision. A fixed skim can go to Regent. The subject lane can continue to pay stakers and treasury. The token becomes part of an operating business rather than a free-floating badge of support. That is the heart of the thesis.

This does not remove risk. It does change the category of the risk. The main question stops being “will there be enough hype” and becomes “will the business produce real stablecoin inflow that reaches the revsplit lane.” That is a harder question, but it is the right question.

## 4. What Autolaunch Is

Autolaunch is both a product surface and a contract system.

On the product side, it includes:

- public landing and auction explainer pages
- a guided launch flow
- public auction browsing
- bid quoting and bid lifecycle actions
- agent inventory and launch readiness checks
- subject pages for stake, unstake, claim, and ingress actions
- trust follow-up through ENS, AgentBook, and related flows
- launch job persistence and onchain tracking
- an operator-facing contract console
- a separate `$REGENT` staking rail surface

On the contract side, it includes:

- the deployment controller for assembling a launch
- the vesting wallet for retained supply
- the strategy and factory for the auction and liquidity path
- the fee registry, fee hook, and fee vault
- the subject registry
- the revenue share factory and per-subject splitter
- the revenue ingress factory and per-subject ingress account
- the separate `RegentRevenueStaking` contract for the existing `$REGENT` token

The distinction matters. The browser app is not itself the launch engine. The app reads deployment output, stores workflow state, computes quotes, tracks the auction, and gives people and operators a way to act on the system. The contracts enforce the money path and the launch-side rules. The backend bridges between them.

Autolaunch also sits in the middle of the wider Regent system. It consumes shared SIWA identity for signed agent requests. It shares room-record patterns with Techtree. It exposes surfaces in the CLI. It links trust follow-up back into the broader identity and company stack. It is not an isolated launch microsite.

## 5. Launch Structure

The launch structure in the current docs is concrete enough to describe in one sequence.

1. An operator prepares a prelaunch plan.
2. The plan is validated and paired with hosted metadata.
3. The deploy flow creates the launch stack and returns the contract addresses.
4. The auction begins and sells 10 percent of the token supply.
5. The strategy reserves 5 percent for the LP position.
6. Half of raised USDC goes into the LP migration.
7. The other half goes to the agent Safe for operations.
8. The remaining 85 percent of token supply vests to the agent treasury over one year.
9. The subject registry and revenue stack remain in place after launch for ongoing revenue and staking behavior.

This structure matters because the launch is not only a sale. It is the creation of a business scaffold.

The token exists, but so do the vesting rules. Liquidity exists, but so does the treasury split. A subject exists, but so does the revenue lane and default ingress path. The docs also show that the launch response carries a `reputation_prompt` so the operator can complete trust follow-up through linked ENS and AgentBook flows. That means identity follow-up is treated as part of the launch lifecycle, not as unrelated aftercare.

The structure also separates public and operator actions. Public auction and subject pages handle direct wallet flows like bid, stake, unstake, claim, and ingress sweep. The contract console handles prepare-only flows for advanced actions, multisig submission, or operator review. The backend tracks only the flows it is supposed to track after a real transaction hash exists.

That split reduces confusion. The app can expose useful prepared payloads without pretending it should send every transaction directly from the browser. The contracts remain the place where actual money movement and position state are finalized.

## 6. Continuous Clearing Auction Mechanics

Autolaunch uses a continuous clearing auction instead of a more common instant distribution or blast-open pool launch.

The buyer mental model in the current docs is simple:

1. choose a total budget
2. choose the highest token price you are willing to pay
3. let the order run across the remaining blocks like a TWAP
4. receive tokens only in blocks where the clearing price stays below your maximum price
5. stop when the clearing price moves above the cap

This mechanism matters because it changes how participation works.

In many launch models, the main skill is speed. Buyers need low latency, good automation, and specialized tactics. Those tactics can dominate retail buyers and distort price discovery. In the Autolaunch model, the buyer does not need to out-click every other buyer on the first second. The buyer needs to state a budget and a maximum price that matches their honest view of value.

The docs also make a game-theory claim. Waiting only shortens your participation window and often worsens your average price. Early truthful bidding is meant to be the better move. That is a meaningful design choice because it tries to reward honest demand rather than tactical delay.

The phrase “continuous clearing” matters too. The market is not meant to clear once and only once. It clears block by block against the remaining order set. That lets the market update as demand interacts with supply rather than forcing everything through a single instant where speed dominates.

This design does not eliminate all manipulation. Large buyers can still influence demand. External order flow can still shape secondary expectations. Operators still have to choose sane auction timing and parameters. But the mechanism changes the dominant tactics. That is the point.

## 7. Price Discovery and Fairness Claims

Autolaunch makes a strong fairness claim, but it makes a specific one rather than a magical one.

The claim is not that all buyers become equal in every respect. The claim is that the auction structure reduces the edge that comes purely from launch-day timing games. The docs point to sniping, bundling, sandwiching, and other timing-based strategies as the problems the design is trying to weaken.

The fairness story has four parts.

First, every buyer faces the same clearing process. The system does not reserve a better price path for the fastest clicker or the fastest bot in the opening second.

Second, the buyer has a built-in self-protection rule. The maximum price prevents paying above what the buyer has already said is fair.

Third, the order runs through time rather than demanding one perfect moment of entry. That reduces the reward to pure speed.

Fourth, the auction still produces a price, not only a whitelist outcome. That means it keeps price discovery inside the mechanism instead of outsourcing it to pure secondary-market chaos.

Those claims should be read carefully. Fairness in markets is always conditional. If parameters are poor, if a single large buyer dominates, or if external expectations overwhelm the launch, the outcome can still look bad. Autolaunch is better understood as a market structure that tries to improve the initial conditions for price discovery. It is not a guarantee that every launch price is correct.

The design does, however, improve one important thing if the operator and market cooperate: legibility. Buyers know their budget, their cap, and the fact that their order stops when price rises above that cap. That is cleaner than many launch patterns where participants only discover the true price after the fastest actors have already moved first.

## 8. Liquidity and Treasury Split

One of Autolaunch’s most important design decisions is how it splits the raised USDC and the token supply.

The current docs define the structure exactly:

- 10 percent of supply sells in the auction
- 5 percent of supply is reserved for the LP position
- half of auction USDC goes to that LP position
- half of auction USDC goes to the agent Safe
- 85 percent of supply vests to the agent treasury over one year

This split does three jobs at once.

The LP allocation gives the launched token a structured path into secondary liquidity. The intention is not to leave the market without a meaningful pool after the auction ends.

The treasury allocation gives the agent business operating capital in USDC, which is the unit it can use for compute, tooling, distribution, and payroll-like costs. This is a crucial point. The business does not only receive more of its own token. It receives stable units it can spend.

The vesting allocation keeps the long-term supply aligned with the agent treasury rather than distributing everything at once. That preserves future flexibility and reduces the pressure to treat launch day as the only meaningful capital event.

The docs also show why this split connects to the larger thesis. If the treasury only received more volatile token inventory, the business would still face a mismatch between operating needs and treasury assets. By routing half of raised USDC directly to the Safe, Autolaunch gives the agent business immediate stablecoin runway.

That split comes with tradeoffs. More treasury means less USDC goes into the initial LP. More LP means less treasury runway. The current structure chooses balance: enough liquidity support to seed the market, enough stablecoin treasury to keep the business alive.

## 9. Subject Revenue and Revsplit Mechanics

Autolaunch’s post-launch design revolves around the subject revenue lane and the revsplit.

The key rule in the docs is exact: only Base USDC that reaches the revsplit counts as recognized revenue. This is one of the most important lines in the whole system.

Why is it so important? Because it creates a hard threshold for what counts. Not every mention of business success counts. Not every offchain invoice counts. Not every vague revenue statement counts. Revenue becomes recognized when it lands in the contract-defined lane.

The contract overview shows the pieces:

- `SubjectRegistry` records the launched subject and links its token, splitter, treasury Safe, and identity references.
- `RevenueShareFactory` creates the per-subject revsplit.
- `RevenueIngressFactory` creates the canonical receiving addresses for raw USDC.
- `RevenueIngressAccount` accepts that raw USDC and sweeps it into splitter accounting.
- `RevenueShareSplitter` becomes the canonical contract for revenue rights and staking on the launched token.

The fee rules then sit on top of this path. The launch-pool fee charges 2 percent on swaps in the official pool. One percent goes to Regent. One percent goes to the subject revenue lane. Recognized subject revenue sends a fixed 1 percent skim to Regent. The remaining 99 percent stays in the subject lane, where stakers earn their formula share and the remainder accrues to the agent treasury.

This means the post-launch token relationship is not only “hold and hope.” It is “stake if you want to participate in recognized revenue once it reaches the lane.” That is a stronger holder story than many launch systems offer.

This is also where the stablecoin thesis becomes most concrete. Once revenue reaches the revsplit, the system can distribute a staker share and preserve treasury remainder in the same unit in which operating costs are paid. The token is no longer only a symbol of support. It is attached to a cash-flow lane.

## 10. Relation to `$REGENT`

Autolaunch has its own per-subject economics, but it also sits inside the larger Regent token system. The docs are clear that the separate `$REGENT` staking rail is not the same thing as a launched subject’s revenue splitter.

The subject splitter is per agent. It is part of the launch stack on the active Base launch network. It routes recognized revenue tied to that launched subject.

`$REGENT` staking is a singleton company-token rail. It is configured separately, has its own contract, and is meant for the existing Regent token rather than the launched subject token. The contract overview says `RegentRevenueStaking` is the singleton Base-mainnet staking and Base USDC rewards rail for `$REGENT`, fed manually after Treasury A bridges non-Base income into Base USDC.

This distinction matters because it prevents category collapse.

A subject token is a claim on the economics of one launched agent business.

`$REGENT` is a claim on the wider Regent platform rails.

The current product sources say Platform and Autolaunch open the same `$REGENT` staking rail and the same reward claims. That creates coherence for the company token. At the same time, the per-subject splitters remain distinct so subject-level economics are not flattened into the platform token.

This separation is one of the better architectural decisions in the Regent system. It lets Autolaunch serve both a subject-level market and a company-level platform without confusing the two.

## 11. Launch Flow and Operator Flow

Autolaunch is built around an operator flow that is now explicitly CLI-first.

The preferred path is:

1. save a prelaunch plan
2. validate and publish hosted metadata
3. run the launch from the saved plan
4. monitor the auction lifecycle
5. finalize post-auction actions
6. release vested tokens later

The CLI commands named in the README reflect this:

- `regents autolaunch prelaunch wizard`
- `regents autolaunch launch run`
- `regents autolaunch launch monitor`
- `regents autolaunch launch finalize`
- `regents autolaunch vesting status`

This matters because launches are not single-click events. They require stored plans, deploy binaries, workdirs, contract outputs, chain reads, identity proof, and post-launch verification. The CLI is a better place for that operational path than a purely browser-first flow.

The browser still matters. It exposes public landing pages, the guided launch page, auction pages, position pages, subject pages, trust follow-up, and the contract console. But the README is clear that the browser launch flow is still available, not primary. The CLI is meant to be the first stop for serious operators.

The release and validation commands also show how Autolaunch treats operational health:

- `mix autolaunch.doctor`
- `mix autolaunch.smoke`
- `mix autolaunch.verify_deploy --job <job-id>`

`doctor` checks the environment and launch dependencies. `smoke` runs a synthetic in-repo launch-to-subject flow. `verify_deploy` checks the actual deployed stack against chain state. This is important. The product does not stop at “the contracts compiled.” It also tries to prove that the deployment and workflow layers align with the contract outputs.

## 12. What the Contracts Try to Enforce

The contracts do not try to solve every product problem. They do try to enforce the money path and the stack shape.

On the launch side, the deployment controller assembles the launch stack in one call. The strategy owns the launch-side token supply, creates the auction, migrates the LP slice, and records pool and position state. The vesting wallet holds retained supply on a schedule. The fee registry, fee vault, and fee hook define and capture the official fee lane.

On the revenue side, the contracts try to enforce three important boundaries.

First, they enforce canonical subject linkage. The subject registry is the source of truth for the subject’s token, splitter, treasury Safe, and linked identities.

Second, they enforce recognized revenue routing. The ingress factory and ingress accounts create a defined path for raw USDC to reach the splitter, and the splitter is the place where recognized revenue is counted and then shared.

Third, they enforce separation between per-subject economics and platform-level `$REGENT` staking. The `RegentRevenueStaking` contract is separate on purpose.

The contracts also try to enforce another valuable property: prepared actions and recorded outputs. The contract console can show launch deployment provenance, stack addresses, and prepared payloads for advanced actions. That means the contracts are not only write targets. They are also part of the operator’s inspection surface.

The best way to describe the contract intent is this: they try to reduce the number of trust assumptions around supply creation, liquidity formation, fee capture, subject registration, revenue routing, and reward claims. They do not eliminate the need for good product logic. They narrow the set of things that product logic can lie about.

## 13. Incentives by Actor

Autolaunch works only if each actor has a reason to participate.

### Agent founder or operator

The operator wants stable runway, a credible launch path, and continued upside after launch. Autolaunch offers immediate treasury USDC from half of the auction proceeds, retained supply through vesting, ongoing subject revenue participation through the revsplit structure, and better market conditions than a pure speed race may provide.

### Auction buyer

The buyer wants fairer entry, price protection, and a reason to stay after launch. The CCA model gives budget-plus-max-price entry rather than forcing one perfect timing move. The post-launch system gives a route into staking and recognized revenue rather than leaving the buyer with only chart exposure.

### Long-term staker

The staker wants a measurable economic relationship to the subject. The revsplit gives that relationship if stablecoin revenue reaches the lane. The value proposition becomes stronger if the business is real and weaker if the business never produces recognized inflow.

### Regent platform

Regent wants protocol participation without flattening the subject’s economics. The fixed skim from launch-pool fees and recognized subject revenue creates a platform take while still leaving the bulk of the subject lane inside the launched business and its holders.

### Wider market

The wider market wants a launch format that is easier to reason about. The CCA structure, public pages, contract console, and onchain revenue lanes all contribute to legibility. The system is strongest when observers can explain how money enters, where it goes, and who can claim it.

These incentives do not guarantee success. They do show that the mechanism is not random. Each actor is supposed to benefit from a different part of the design.

## 14. Failure Modes and Attack Surfaces

Autolaunch has both technical and market failure modes.

### Market failure modes

The first market failure is simple: the business never produces meaningful recognized revenue. In that case, the launch may still have created capital, but the stronger post-launch thesis weakens. Holders are left with a thinner reason to stay.

The second market failure is poor initial pricing. Even with a better auction structure, bad expectations, low demand quality, or concentrated buying can still create a weak market.

The third market failure is a treasury mismatch. If the treasury burns quickly or deploys funds poorly, launch capital still disappears.

### Product failure modes

The README names several operational dependencies. Database failure breaks launch jobs, bids, sessions, and subject action registrations. Privy failure breaks authenticated browser and CLI session exchange. SIWA failure blocks launch creation because wallet signatures cannot be verified. Deploy binary or workdir failure means launches cannot execute on that node. Launch-chain RPC failure makes reads, quotes, and verification unreliable.

These dependencies matter because Autolaunch is not only a contract package. It is a live product with workflow state.

### Contract and mechanism attack surfaces

The current docs and contract overview point to several attack surfaces worth naming, even if they are not all fully modeled in the product copy.

- auction parameter abuse if launch timing or settings are poor
- liquidity migration mistakes
- incorrect fee configuration or recipient configuration
- faulty subject registration or identity linkage
- ingress misuse or mistakes in routing raw USDC to the splitter
- errors in contract-to-backend reconciliation after deployment
- reliance on external systems like the CCA factory, Uniswap v4 infrastructure, USDC, and ERC-8004 identity registries

### Trust and proof failures

The product also depends on correct identity and trust follow-up. ENS, AgentBook, World ID, and related surfaces do not directly create revenue, but they shape whether buyers trust the subject enough to participate. Weak trust linkage may not break contracts, but it can still weaken the market.

## 15. Tradeoffs

Autolaunch makes several deliberate tradeoffs.

It chooses a more structured launch over a simpler instant pool. That raises operator complexity but aims to improve price discovery and post-launch economics.

It routes half of raised USDC to liquidity and half to treasury. That sacrifices maximum immediate liquidity depth in exchange for giving the business spendable runway.

It preserves a large vested treasury allocation. That creates long-term alignment, but it also means a lot of supply remains outside immediate circulation.

It keeps a platform skim for Regent while leaving most subject revenue in the subject lane. That supports the wider ecosystem, but it means subject holders do not capture every dollar that enters the lane.

It relies on Base USDC as the recognized revenue unit. That creates a clean rule and supports the stablecoin thesis, but it narrows what counts.

It separates `$REGENT` staking from subject splitters. That keeps category clarity, but it also means users must understand two layers of token economics rather than one.

These tradeoffs are not bugs. They are the substance of the design. The right question is whether they improve the full capital-and-revenue path enough to justify the added structure.

## 16. Product and Market Risks

The biggest risk is that the thesis is right in theory but weak in practice. A launch can be well designed and still fail if the business does not produce stablecoin revenue or if buyers do not care about that path.

Another risk is that fairness gains are real but modest. The CCA may reduce timing games without removing them. Large buyers may still dominate. Secondary-market psychology may still overwhelm the careful structure of the primary auction.

There is also a user-comprehension risk. The system is more honest than many launch patterns, but it is also more complex. Buyers need to understand budgets, max prices, claims, staking, recognized revenue, and the split between subject tokens and `$REGENT`.

There is a deployment risk too. The contract stack is not tiny. The product depends on correct deploy outputs, reliable chain reads, correct external addresses, and accurate backend state tracking. Complexity raises the need for strong operator discipline.

Finally, there is the broader legal and market risk that follows any system connecting auctions, revenue rights, token claims, and treasury behavior. This paper does not make legal claims. It only notes that these risks exist and are central.

## 17. Open Questions

Several important questions remain open after reading the current product and contract sources.

1. How much recognized subject revenue will real launched agents generate, and how soon?
2. What parameters make the continuous clearing auction work best across different demand profiles?
3. How concentrated can buyer participation become before the fairness gains weaken?
4. How should operators communicate the difference between subject-token economics and `$REGENT` economics to users?
5. What is the best path for integrating more trust evidence without making launch prep too heavy?
6. How much of the current Base Sepolia rehearsal path translates cleanly into Base mainnet production?
7. What parts of the current flow should remain CLI-first forever, and what parts should return to a stronger browser-first path?

These questions do not invalidate the design. They define the work still needed to prove it.

## 18. Why This Design Can Beat Common Launch Patterns

If the thesis holds, Autolaunch can beat common launch patterns for three reasons.

First, it gives the business capital in the unit the business needs. The treasury receives stablecoin, not only token inventory. That makes the launch useful for operations.

Second, it gives the market a cleaner structure. Buyers bid with budgets and maximum prices instead of fighting over the opening millisecond. That can improve both fairness and legibility.

Third, it gives holders a post-launch reason to stay. Once stablecoin revenue reaches the revsplit, the token participates in a measurable economic lane. That is stronger than pure narrative support.

Common launch patterns often fail on one of those fronts. They may create price without runway. They may create liquidity without business funding. They may create community without revenue linkage. They may reward speed more than conviction. Autolaunch tries to do better by treating launch, liquidity, treasury, and revenue as one system.

That does not mean it always will. The design is conditional on real businesses, real revenue, and good operator execution. But if those conditions are present, the structure is stronger than the usual pattern of “launch first, figure out the business later.”

## 19. Conclusion

Autolaunch is not only a launch app. It is a market design for agent businesses.

Its launch structure gives the business an immediate treasury, a defined liquidity path, a vesting schedule, and a continuing subject revenue lane. Its auction structure tries to reward truthful demand more than timing tricks. Its contract stack tries to make launch, fee capture, subject registration, and recognized revenue legible. Its post-launch economics try to turn token holding from a pure price bet into a relationship with measured stablecoin inflow.

The strongest claim in the system is still a thesis. Onchain stablecoin revenue is the fact that can turn an agent token into both an initial capital mechanism and a continuing holder revenue stream. If that thesis proves out, Autolaunch can be more than a better launch page. It can be a better way to finance an agent business.

If the thesis fails, the launch still may raise capital and form liquidity, but the deeper holder story weakens. That is why the right way to judge Autolaunch is not only by whether launches happen. It is by whether launched agents later produce real stablecoin revenue that reaches the lane the contracts define.
