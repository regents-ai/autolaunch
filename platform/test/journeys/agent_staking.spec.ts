import {randomBytes} from "node:crypto"
import {mkdirSync, writeFileSync} from "node:fs"
import type {Page} from "@playwright/test"
import {decodeEventLog, decodeFunctionResult, encodeFunctionData, formatUnits, parseAbi, parseUnits, type Abi, type Hex} from "viem"
import {Agent} from "./support/agent"
import {
  clockStep, evidenceText, given, launchRecord, listedAuction, listedToken, record, refusedBoth, sendSteps, type Landed, type Venue,
} from "./support/agent_steps"
import {balanceOf, call, memestock, mineTo, mintStock, receipt, revstake, sendAs} from "./support/chain"
import {AAPLC, draftFor, launch} from "./support/launch"
import {pairWith, unpair} from "./support/pairing"
import {expect, fitsAndPresses, people, ready, signIn, test, type Sent} from "./support/person"
import {
  balanceOf as rhBalanceOf, call as rhCall, clock, deployment, lab, mint,
} from "./support/robinhood"

// Agent staking, with the site switched on for it (scripts/agent-journeys.sh). Person A pairs an
// agent, which fills in a launch A signs; A's bid, which the agent prepares, carries the auction
// past its minimum, and A's wallet sends the agent's finish. With the launched token in A's wallet,
// the agent prepares A's stake, through its signed route and through the hosted MCP tool (regents
// mcp) alike, and A's wallet sends exactly those steps. The next answer's facts and the token's
// page show the whole balance staked. A wallet that holds none of the token is refused the stake,
// an unstake above the stake is refused, and so is a wallet that is not A's. Then the agent
// prepares an unstake of part of the stake, and a claim; after each, the next answer's facts and
// the page show what moved. On Base Memestock a trade made while A is staked leaves stakers' fees
// in the pool, so the claim settles the staker lane first and pays A its share. The agent never
// holds A's key: every step leaves from A's wallet, the injected test wallet the page uses.
// Feature map: operations/FEATURES.md, Agents.
test.use({wallet: people.a.wallet})

const wallet = people.a.wallet
const stakePath = (id: string) => `/api/agent/v1/tokens/${id}/stake/steps`
const staking = (agent: Agent, id: string, body: object) =>
  given(agent, stakePath(id), body, "prepare_stake", {token_id: id, ...body})
const refused = (agent: Agent, id: string, body: object, status: number, code: string) =>
  refusedBoth(agent, stakePath(id), body, "prepare_stake", {token_id: id, ...body}, status, code)

const splitterAbi = parseAbi([
  "function stakedOf(address) view returns (uint256)",
  "function claimable(address token, address account) view returns (uint256)",
])

async function shot(page: Page, name: string) {
  mkdirSync(`${process.env.AGENT_JOURNEYS_OUT}/shots`, {recursive: true})
  await page.screenshot({path: `${process.env.AGENT_JOURNEYS_OUT}/shots/${name}.png`, fullPage: true})
}

/** A whole number of the token's smallest units, from an answer's figure. */
const atomic = (figure: {amount: string}, decimals = 18) => parseUnits(figure.amount, decimals)

/**
 * One venue's chain reads: the token balance and stake of a wallet on the launch's splitter, and
 * the chain the launch is on.
 */
function chainOf(venue: Venue) {
  const robinhood = venue === "robinhood"
  return {
    balance: (token: string, owner: string) => (robinhood ? rhBalanceOf(token, owner) : balanceOf(token, owner)),
    async staked(splitter: string, owner: string) {
      const data = encodeFunctionData({abi: splitterAbi, functionName: "stakedOf", args: [owner as Hex]})
      return BigInt(robinhood ? await rhCall(splitter, data) : await call(splitter, data))
    },
  }
}

/**
 * A graduated launch as the journey reads it: the site's listing of its token, and its own record
 * on its chain once it has migrated, with the token and the staking contract that record names.
 */
type Launched = {listing: any; record: any; token: string; splitter: string}

async function graduated(venue: Venue, auction: string, listing: any): Promise<Launched> {
  const record = await launchRecord(venue, auction)
  const token = venue === "revstake" ? record.subject : record.newToken
  return {listing, record, token: String(token).toLowerCase(), splitter: String(record.splitter).toLowerCase()}
}

/**
 * A buys the token on its page with `amount` of `currency`, as anyone trades it on the copy of
 * Base: the review's button shows each wallet step the swap needs, approvals first, and each press
 * lands before the button moves on to the next. Keeps each press's transaction.
 */
async function buyOnPage(page: Page, sent: Sent[], launched: Launched, currency: string, amount: string, label: string, transactions: Landed[]) {
  const held = await balanceOf(launched.token, wallet)
  await page.goto(new URL(launched.listing.url).pathname)
  await ready(page)
  await page.getByRole("textbox", {name: `Amount of ${currency} to sell`}).fill(amount)
  await page.getByRole("button", {name: "Review"}).click()
  const next = page.locator(".token-swap__wallet-step[data-onchain-step]:visible")
  for (let step = await next.getAttribute("data-onchain-step"); ; step = await next.getAttribute("data-onchain-step")) {
    const before = sent.length
    await next.click()
    await expect.poll(() => sent.length, {timeout: 30_000}).toBeGreaterThan(before)
    const hash = sent[sent.length - 1].hash
    const landed = await receipt(hash)
    transactions.push({label, step: step!, chain_id: 31_337, hash, status: landed.status, block: Number(BigInt(landed.blockNumber))})
    expect(landed.status, `${label}: ${step} lands`).toBe("0x1")
    if (step === "swap") break
    await expect(next, "the button moves on once the step has landed").not.toHaveAttribute("data-onchain-step", step!, {timeout: 60_000})
  }
  expect(await balanceOf(launched.token, wallet), `${label}: A holds more of the token`).toBeGreaterThan(held)
}

/** The token's page on the trade widget's `tab`, read afresh. */
async function onTab(page: Page, path: string, tab: "Swap" | "Stake" | "Unstake") {
  await page.goto(path)
  await ready(page)
  const chosen = page.getByRole("tab", {name: tab, exact: true})
  await chosen.click()
  await expect(chosen).toHaveAttribute("aria-selected", "true")
  return page.locator("[data-stake-panel]")
}

/**
 * The staking journey on one graduated launch, of whose token A holds some; `trade` has a trade
 * made in its pool while A is staked.
 */
async function stakeUnstakeClaim(
  page: Page, agent: Agent, venue: Venue, launched: Launched, touch: boolean, project: string,
  evidence: Record<string, any>, transactions: Landed[], trade?: () => Promise<void>,
) {
  const chain = chainOf(venue)
  const {listing: token, splitter} = launched
  const path = new URL(token.url).pathname
  const symbol = token.symbol
  const held = await chain.balance(launched.token, wallet)
  expect(held, "A holds the launched token").toBeGreaterThan(0n)
  const stakedBefore = await chain.staked(splitter, wallet)

  await test.step("stake: the agent prepares A's whole balance, and A's wallet sends it", async () => {
    const stake = await staking(agent, token.id, {kind: "stake"})
    expect(stake).toMatchObject({kind: "stake", signer: wallet, token: {id: token.id, address: launched.token}})
    expect(atomic(stake.facts.balance)).toBe(held)
    expect(atomic(stake.facts.staked)).toBe(stakedBefore)
    expect(stake.steps.map((step: any) => step.step)).toEqual(["token_approval", "stake"])
    expect(stake.steps.map((step: any) => step.to)).toEqual([launched.token, splitter])
    await sendSteps(page, wallet, stake, "stake", transactions)
    expect(await chain.balance(launched.token, wallet)).toBe(0n)
    expect(await chain.staked(splitter, wallet)).toBe(stakedBefore + held)
    evidence.stake = stake
  })

  await test.step("refusals: nothing to stake, an unstake above the stake, a wallet not A's", async () => {
    const staked = stakedBefore + held
    evidence.refusals = {
      nothing_to_stake: await refused(agent, token.id, {kind: "stake"}, 409, "nothing_to_stake"),
      amount_above_stake: await refused(agent, token.id, {kind: "unstake", amount: formatUnits(staked + 1n, 18)}, 409, "amount_above_stake"),
      wrong_signer: await refused(agent, token.id, {kind: "stake", signer: people.b.wallet}, 403, "wrong_signer"),
    }
  })

  const part = (stakedBefore + held) / 3n
  await test.step("after the stake: the next answer's facts and the page show it all staked", async () => {
    const unstake = await staking(agent, token.id, {kind: "unstake", amount: formatUnits(part, 18)})
    expect(atomic(unstake.facts.balance)).toBe(0n)
    expect(atomic(unstake.facts.staked)).toBe(stakedBefore + held)
    expect(unstake.steps.map((step: any) => step.step)).toEqual(["unstake"])
    evidence.after_stake = unstake.facts
    const stakePanel = await onTab(page, path, "Stake")
    await expect(stakePanel).toContainText(`No ${symbol} in this wallet`)
    await fitsAndPresses(page, touch)
    const unstakePanel = await onTab(page, path, "Unstake")
    await expect(unstakePanel.locator(".token-swap__leg-foot")).toContainText(`${unstake.facts.staked.amount} ${symbol}`)
    await expect(unstakePanel.locator(".token-swap__leg-foot")).toContainText("staked")
    await fitsAndPresses(page, touch)
    await shot(page, `staking-${venue}-${project}-staked`)
  })

  if (trade) await test.step("a trade in the pool while A is staked", trade)

  await test.step("unstake: the agent prepares a third of the stake, and A's wallet sends it", async () => {
    const before = await chain.balance(launched.token, wallet)
    const unstake = await staking(agent, token.id, {kind: "unstake", amount: formatUnits(part, 18)})
    await sendSteps(page, wallet, unstake, "unstake", transactions)
    expect(await chain.staked(splitter, wallet)).toBe(stakedBefore + held - part)
    expect((await chain.balance(launched.token, wallet)) - before).toBe(part)
    evidence.unstake = unstake
  })

  let claim: any
  await test.step("after the unstake: the next answer's facts and the page show the stake less that part", async () => {
    claim = await staking(agent, token.id, {kind: "claim"})
    expect(atomic(claim.facts.staked)).toBe(stakedBefore + held - part)
    expect(atomic(claim.facts.balance)).toBe(await chain.balance(launched.token, wallet))
    evidence.after_unstake = claim.facts
    const unstakePanel = await onTab(page, path, "Unstake")
    await expect(unstakePanel.locator(".token-swap__leg-foot")).toContainText(`${claim.facts.staked.amount} ${symbol}`)
    const stakePanel = await onTab(page, path, "Stake")
    await expect(stakePanel.locator("output.token-trade__figure")).toHaveAttribute("title", `${claim.facts.balance.amount} ${symbol}`)
    await fitsAndPresses(page, touch)
    await shot(page, `staking-${venue}-${project}-unstaked`)
  })

  return claim
}

test("agent staking on Base Memestock: the agent prepares its person's stake, unstake and claim, and the person's wallet sends them", async ({page, sent}, info) => {
  test.setTimeout(25 * 60_000)
  const touch = info.project.name === "phone"
  const transactions: Landed[] = []
  const evidence: Record<string, any> = {project: info.project.name, venue: "Base Memestock", transactions}
  const out = `${process.env.AGENT_JOURNEYS_OUT}/agent-staking-memestock-${info.project.name}.json`
  const {addresses, abis} = memestock()
  const read = async (auction: string, name: string) =>
    Number(BigInt(await call(auction, encodeFunctionData({abi: abis.auction, functionName: name as any, args: []}) as Hex)))

  try {
    await signIn(page, people.a)
    const agent = new Agent(`staking-${info.project.name}`)
    await pairWith(page, agent, `Staking ${info.project.name}`)
    const tag = agent.address.slice(2, 6).toUpperCase()

    let launched!: Launched
    await test.step("a launch A bids past its minimum and the agent's finish graduates", async () => {
      const made = await launch(page, sent, agent, tag, {...draftFor(tag), name: `Agent Stake ${tag}`, symbol: `SM${tag}`})
      const auction = await listedAuction(agent, made.draft.symbol)
      await mineTo(await read(auction.address, "startBlock"))
      await expect.poll(async () => (await record(auction.id)).state, {timeout: 120_000}).toBe("active")
      await mintStock(AAPLC, wallet, 10n ** 8n)
      const bid = agent.signed("POST", "/api/agent/v1/bids/steps", {auction_id: auction.id, amount: "0.5", max_price: "0.00001"})
      expect(bid.status, JSON.stringify(bid.json)).toBe(200)
      await sendSteps(page, wallet, bid.json.data, "bid 0.5 AAPLc", transactions)
      await mineTo(await read(auction.address, "endBlock"))
      await expect.poll(async () => (await record(auction.id)).state, {timeout: 120_000}).toBe("ended")
      await mineTo(Number((await launchRecord("memestock", auction.address)).migrationBlock) - 1)
      const finish = await given(agent, `/api/agent/v1/auctions/${auction.id}/finish/steps`, {}, "prepare_finish", {auction_id: auction.id})
      await sendSteps(page, wallet, finish, "finish", transactions)
      await expect.poll(async () => (await record(auction.id)).state, {timeout: 120_000}).toBe("graduated")
      launched = await graduated("memestock", auction.address, await listedToken(agent, made.draft.symbol))
      evidence.launch = {auction, token: launched.listing, chain_token: launched.token, splitter: launched.splitter, launch: made.hash}
    })

    const buy = (label: string) => buyOnPage(page, sent, launched, "AAPLc", "0.1", label, transactions)
    await test.step("A buys the token on its page", () => buy("A buys the token"))

    // The hook's staker lane: the third of the lanes `accrued` answers.
    const stakerLane = async () =>
      (decodeFunctionResult({
        abi: abis.hook,
        functionName: "accrued",
        data: await call(addresses.hook, encodeFunctionData({abi: abis.hook, functionName: "accrued", args: [launched.record.poolId]} as any) as Hex),
      } as any) as bigint[])[2]

    const token = launched.listing
    const claim = await stakeUnstakeClaim(page, agent, "memestock", launched, touch, info.project.name, evidence, transactions, async () => {
      const lane = await stakerLane()
      await buy("A trades while staked")
      evidence.staker_lane = {before: lane, after: await stakerLane()}
      expect(evidence.staker_lane.after, "the trade leaves stakers' fees in the pool").toBeGreaterThan(lane)
    })

    await test.step("claim: the agent prepares the staker lane's settle, each position's collect and the claim, and A's wallet sends them", async () => {
      const names = claim.steps.map((step: any) => step.step)
      expect(names[0], "the staker lane is settled first").toBe("settle")
      expect(names.at(-1)).toBe("claim")
      expect(names.slice(1, -1).every((name: string) => name.startsWith("collect_"))).toBe(true)
      const stock = await balanceOf(AAPLC, wallet)
      await sendSteps(page, wallet, claim, "claim", transactions)
      expect(await stakerLane(), "the settle empties the staker lane").toBe(0n)
      const paid = (await balanceOf(AAPLC, wallet)) - stock
      expect(paid, "A, the only staker, is paid stakers' fees in AAPLc").toBeGreaterThan(0n)
      evidence.claim = {prepared: claim, paid_aapl_c: paid}
    })

    await test.step("after the claim: the next answer's facts and the page show nothing left to claim", async () => {
      const after = await staking(agent, token.id, {kind: "claim"})
      evidence.after_claim = after.facts
      expect(after.facts.claimable.map((figure: any) => Number(figure.amount))).toEqual([0, 0, 0])
      expect(atomic(after.facts.staked)).toBe(atomic(claim.facts.staked))
      await page.goto(new URL(token.url).pathname)
      await ready(page)
      await expect(page.locator(".token-claim__rows")).toContainText("Trading fees")
      await fitsAndPresses(page, touch)
      await shot(page, `staking-memestock-${info.project.name}-claimed`)
    })

    unpair("did:privy:journey-a", agent.address)
  } finally {
    writeFileSync(out, evidenceText(evidence))
  }
})

// The governance Safe holds REGENT on the copy of Base, which a Revstake auction is bid in.
const SAFE = "0x9fa152b0eadbfe9a7c5c0a8e1d11784f22669a3e"
const transferAbi = parseAbi(["function transfer(address to, uint256 amount) returns (bool)"])

test("agent staking on Base Revstake: the agent prepares its person's stake, unstake and claim, and the person's wallet sends them", async ({page, sent}, info) => {
  test.setTimeout(25 * 60_000)
  const touch = info.project.name === "phone"
  const transactions: Landed[] = []
  const evidence: Record<string, any> = {project: info.project.name, venue: "Base Revstake", transactions}
  const out = `${process.env.AGENT_JOURNEYS_OUT}/agent-staking-revstake-${info.project.name}.json`
  const {addresses, abis} = revstake()
  const regent = addresses.regent.toLowerCase()
  const read = async (auction: string, name: string) =>
    Number(BigInt(await call(auction, encodeFunctionData({abi: abis.auction, functionName: name as any, args: []}) as Hex)))

  try {
    await signIn(page, people.a)
    const agent = new Agent(`rs-staking-${info.project.name}`)
    await pairWith(page, agent, `Revstake staking ${info.project.name}`)
    const tag = agent.address.slice(2, 6).toUpperCase()

    let launched!: Launched
    await test.step("a Revstake A launches on /agent-business, bids on, and the agent's finish graduates", async () => {
      // The agent fills in the whole draft with a contract treasury, which A confirms on the page;
      // A has no X, GitHub or ENS account, so A types the page's warning before launching.
      const draft = {
        name: `Agent Revstake Stake ${tag}`,
        symbol: `SR${tag}`,
        description: "A Revstake its agent filled in and its person launched and staked.",
        website: "https://example.com",
        treasury: `0x${randomBytes(20).toString("hex")}`,
        treasury_path: "contract",
      }
      const saved = agent.autolaunch(["drafts", "revstake", "save"], {...draft, image: draftFor(tag).image})
      expect(saved.status, saved.stdout).toBe(0)
      await page.goto("/agent-business")
      await ready(page)
      const confirm = page.locator("#launch-agent-treasury")
      await expect(confirm).toContainText(new RegExp(draft.treasury, "i"))
      await confirm.getByText("This smart contract will receive all treasury funds").click()
      await expect(confirm).toBeHidden()
      await page.getByRole("button", {name: "Skip connections"}).click()
      const dialog = page.locator("#launch-no-connections-dialog")
      await expect(dialog).toBeVisible()
      await dialog.locator("#launch-no-connections-typed").fill((await dialog.locator("#launch-no-connections-warning").textContent())!.trim())
      await dialog.getByRole("button", {name: "Continue"}).click()
      await page.getByRole("button", {name: "Review launch"}).click()
      const before = sent.length
      await page.getByRole("button", {name: /Create the launch/i}).click()
      await expect.poll(() => sent.length).toBe(before + 1)
      const placed = page.locator(".launch-placed")
      await expect(placed).toContainText(`Your token ${draft.symbol} is launched.`, {timeout: 60_000})
      const launchedAt = await receipt(sent[before].hash)
      transactions.push({label: "launch", step: "launch", chain_id: 31_337, hash: sent[before].hash, status: launchedAt.status, block: Number(BigInt(launchedAt.blockNumber))})

      const auction = await listedAuction(agent, draft.symbol)
      await mineTo(await read(auction.address, "startBlock"))
      await expect.poll(async () => (await record(auction.id)).state, {timeout: 120_000}).toBe("active")
      await sendAs(SAFE, regent, encodeFunctionData({abi: transferAbi, functionName: "transfer", args: [wallet as Hex, 100n * 10n ** 18n]}))
      // Any bid passes a Revstake auction's minimum.
      const bid = agent.signed("POST", "/api/agent/v1/bids/steps", {auction_id: auction.id, amount: "10", max_price: "0.001"})
      expect(bid.status, JSON.stringify(bid.json)).toBe(200)
      await sendSteps(page, wallet, bid.json.data, "bid 10 REGENT", transactions)
      await mineTo(await read(auction.address, "endBlock"))
      await expect.poll(async () => (await record(auction.id)).state, {timeout: 120_000}).toBe("ended")
      const ended = await launchRecord("revstake", auction.address)
      await mineTo(Number(ended.migrationBlock) - 1)
      const finish = await given(agent, `/api/agent/v1/auctions/${auction.id}/finish/steps`, {}, "prepare_finish", {auction_id: auction.id})
      expect(finish.steps[0].to, "a Revstake finishes on its strategy").toBe(ended.finisher)
      await sendSteps(page, wallet, finish, "finish", transactions)
      await expect.poll(async () => (await record(auction.id)).state, {timeout: 120_000}).toBe("graduated")
      launched = await graduated("revstake", auction.address, await listedToken(agent, draft.symbol))
      evidence.launch = {auction, token: launched.listing, chain_token: launched.token, splitter: launched.splitter}
    })

    const buy = (label: string) => buyOnPage(page, sent, launched, "REGENT", "1", label, transactions)
    await test.step("A buys the token on its page", () => buy("A buys the token"))

    const token = launched.listing
    const claim = await stakeUnstakeClaim(page, agent, "revstake", launched, touch, info.project.name, evidence, transactions,
      () => buy("A trades while staked"))

    await test.step("claim: each locked position's collect and the claim, with no staker lane, and A's wallet sends them", async () => {
      const names = claim.steps.map((step: any) => step.step)
      expect(names.at(-1)).toBe("claim")
      expect(names.slice(0, -1).length).toBeGreaterThan(0)
      expect(names.slice(0, -1).every((name: string) => name.startsWith("collect_")), "a Revstake has no staker lane to settle").toBe(true)
      const before = {regent: await balanceOf(regent, wallet), token: await balanceOf(launched.token, wallet)}
      await sendSteps(page, wallet, claim, "claim", transactions)
      const after = {regent: await balanceOf(regent, wallet), token: await balanceOf(launched.token, wallet)}
      evidence.claim = {prepared: claim, before, after}
      expect(after.regent - before.regent + (after.token - before.token), "the claim pays A, the only staker").toBeGreaterThan(0n)
    })

    await test.step("after the claim: the next answer's facts and the page show nothing left to claim", async () => {
      const after = await staking(agent, token.id, {kind: "claim"})
      evidence.after_claim = after.facts
      expect(after.facts.claimable.map((figure: any) => Number(figure.amount))).toEqual([0, 0, 0])
      expect(atomic(after.facts.staked)).toBe(atomic(claim.facts.staked))
      await page.goto(new URL(token.url).pathname)
      await ready(page)
      await expect(page.locator(".token-claim__rows")).toContainText("Token rewards")
      await fitsAndPresses(page, touch)
      await shot(page, `staking-revstake-${info.project.name}-claimed`)
    })

    unpair("did:privy:journey-a", agent.address)
  } finally {
    writeFileSync(out, evidenceText(evidence))
  }
})

test("agent staking on Robinhood Chain: the agent prepares its person's stake, unstake and claim, and the person's wallet sends them", async ({page, sent}, info) => {
  test.setTimeout(20 * 60_000)
  const touch = info.project.name === "phone"
  const transactions: Landed[] = []
  const evidence: Record<string, any> = {project: info.project.name, venue: "Robinhood Chain", transactions}
  const out = `${process.env.AGENT_JOURNEYS_OUT}/agent-staking-robinhood-${info.project.name}.json`
  const {addresses, abis} = deployment()
  const read = async (auction: string, name: string) =>
    Number(BigInt(await rhCall(auction, encodeFunctionData({abi: abis.auction as Abi, functionName: name, args: []}) as Hex)))

  try {
    await signIn(page, people.a)
    const agent = new Agent(`rh-staking-${info.project.name}`)
    await pairWith(page, agent, `Robinhood staking ${info.project.name}`)
    const tag = agent.address.slice(2, 6).toUpperCase()
    const stock = lab().stocks[0]

    let launched!: Launched
    await test.step("a lab launch A bids on, the agent's finish graduates, and A claims the tokens bought", async () => {
      const made = await launch(page, sent, agent, tag, {
        ...draftFor(tag), name: `Agent Robin Stake ${tag}`, symbol: `RS${tag}`, chain: "robinhood", stock_address: stock.address,
      })
      const auction = await listedAuction(agent, made.draft.symbol)
      await clockStep(await read(auction.address, "startBlock"))
      await expect.poll(async () => (await record(auction.id)).state, {timeout: 60_000}).toBe("active")
      await mint(addresses.usdg, wallet, 10n * 10n ** 6n)
      const bid = agent.signed("POST", "/api/agent/v1/robinhood/bids/steps", {auction_id: auction.id, usdg_amount: "2", max_price: "0.000001"})
      expect(bid.status, JSON.stringify(bid.json)).toBe(200)
      const placed = (await sendSteps(page, wallet, bid.json.data, "bid 2 USDG", transactions)).at(-1)
      const bidId = placed.logs
        .filter((log: any) => log.address.toLowerCase() === auction.address.toLowerCase())
        .map((log: any) => {
          try {
            return decodeEventLog({abi: abis.auction as Abi, data: log.data, topics: log.topics}) as any
          } catch {
            return null
          }
        })
        .find((event: any) => event?.eventName === "BidSubmitted").args.id
      await clockStep(await read(auction.address, "endBlock"))
      await expect.poll(async () => (await record(auction.id)).state, {timeout: 60_000}).toBe("ended")
      await clockStep(Number((await launchRecord("robinhood", auction.address)).migrationBlock))
      const finish = await given(agent, `/api/agent/v1/auctions/${auction.id}/finish/steps`, {}, "prepare_finish", {auction_id: auction.id})
      await sendSteps(page, wallet, finish, "finish", transactions)
      await expect.poll(async () => (await record(auction.id)).state, {timeout: 60_000}).toBe("graduated")
      const settle = agent.signed("POST", `/api/agent/v1/robinhood/bids/${auction.address.toLowerCase()}:${bidId}/steps`, {})
      expect(settle.status, JSON.stringify(settle.json)).toBe(200)
      await sendSteps(page, wallet, settle.json.data, "return and claim", transactions)
      launched = await graduated("robinhood", auction.address, await listedToken(agent, made.draft.symbol))
      evidence.launch = {auction, token: launched.listing, chain_token: launched.token, splitter: launched.splitter, launch: made.hash, clock: await clock()}
    })

    const token = launched.listing
    const claim = await stakeUnstakeClaim(page, agent, "robinhood", launched, touch, info.project.name, evidence, transactions)

    await test.step("claim: the lab trades nothing, so the claim is each position's collect and the claim, and pays nothing", async () => {
      const names = claim.steps.map((step: any) => step.step)
      expect(names.at(-1)).toBe("claim")
      expect(names.slice(0, -1).every((name: string) => name.startsWith("collect_")), "no staker lane to settle").toBe(true)
      expect(claim.facts.claimable.map((figure: any) => Number(figure.amount))).toEqual([0, 0, 0])
      await sendSteps(page, wallet, claim, "claim", transactions)
      evidence.claim = claim
      const after = await staking(agent, token.id, {kind: "claim"})
      evidence.after_claim = after.facts
      expect(atomic(after.facts.staked)).toBe(atomic(claim.facts.staked))
      await page.goto(new URL(token.url).pathname)
      await ready(page)
      await expect(page.locator(".token-claim__rows")).toContainText("Token rewards")
      await fitsAndPresses(page, touch)
      await shot(page, `staking-robinhood-${info.project.name}-claimed`)
    })

    unpair("did:privy:journey-a", agent.address)
  } finally {
    writeFileSync(out, evidenceText(evidence))
  }
})
