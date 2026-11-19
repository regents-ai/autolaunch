import {mkdirSync, writeFileSync} from "node:fs"
import type {Locator, Page} from "@playwright/test"
import {encodeFunctionData, type Hex} from "viem"
import {Agent} from "./support/agent"
import {
  clockStep, evidenceText, given, launchRecord, listedAuction, record, refusedBoth, sendSteps, type Landed,
} from "./support/agent_steps"
import {blockNumber, call, memestock, mineTo, mintStock, receipt, rpc} from "./support/chain"
import {AAPLC, draftFor, launch} from "./support/launch"
import {pairWith, unpair} from "./support/pairing"
import {expect, fitsAndPresses, people, ready, signIn, test} from "./support/person"
import {
  call as rhCall, clock, deployment, erc20, lab, mint, permit2, receipt as rhReceipt, sendFrom,
} from "./support/robinhood"

// Agent finishes, with the site switched on for them (scripts/agent-journeys.sh). Person A pairs an
// agent, which fills in two launches A signs on /create, and both auctions take A's bids and end.
// The agent finishes the first: two blocks before its migration block the agent's finish is
// refused, through its signed route and through the hosted MCP tool (regents mcp) alike, with the
// block finishing opens at; one block before, both give the one finish step, and A's wallet sends
// exactly that step, which lands at the migration block. Then the agent is refused, as the auction
// is finished, and so is a wallet that is not A's. A finishes the second from its page: two
// blocks before, the page's Finish card names the block and its button is disabled; one block
// before, the card is ready by itself and its press lands at the migration block. The site lists
// one auction as graduated and the other as failed, and their pages show it. On Base the desktop
// run's agent finishes the auction that raised its minimum and the phone run's the one that did
// not; on Robinhood Chain, whose auctions keep time by a block clock the lab moves, the agent's
// graduates and the page's fails. The agent never holds A's key: every step leaves from A's
// wallet, the injected test wallet the page uses. Feature map: operations/FEATURES.md, Agents.
test.use({wallet: people.a.wallet})

const wallet = people.a.wallet
const finishPath = (id: string) => `/api/agent/v1/auctions/${id}/finish/steps`
const finished = (agent: Agent, id: string) => given(agent, finishPath(id), {}, "prepare_finish", {auction_id: id})
const refused = (agent: Agent, id: string, status: number, code: string, body: object = {}) =>
  refusedBoth(agent, finishPath(id), body, "prepare_finish", {auction_id: id, ...body}, status, code)

// What an auction's page says once the site lists it as finished.
const endedCopy = {
  graduated: "The auction raised its minimum.",
  failed: "The auction did not raise its minimum.",
} as const

type Outcome = keyof typeof endedCopy

/** The auction page's Finish card, its one line and its button. */
function finishCard(page: Page, id: string): {card: Locator; line: Locator} {
  const card = page.locator(`#${id}`)
  return {card, line: card.locator(".finish-auction__line")}
}

async function shot(page: Page, name: string) {
  mkdirSync(`${process.env.AGENT_JOURNEYS_OUT}/shots`, {recursive: true})
  await page.screenshot({path: `${process.env.AGENT_JOURNEYS_OUT}/shots/${name}.png`, fullPage: true})
}

/** The site lists auction `id` as `outcome`, and its page shows it with no Finish card left. */
async function listedFinished(page: Page, path: string, id: string, card: string, outcome: Outcome, name: string) {
  await expect.poll(async () => (await record(id)).state, {message: `the site lists the auction as ${outcome}`, timeout: 120_000})
    .toBe(outcome)
  await page.goto(path)
  await ready(page)
  await expect(page.locator("main")).toContainText(endedCopy[outcome])
  await expect(page.locator(`#${card}`)).toHaveCount(0)
  await shot(page, name)
}

test("agent finish on Base: the agent prepares an ended auction's finish, the person's wallet sends it, and the page's own Finish button finishes another", async ({page, sent}, info) => {
  test.setTimeout(20 * 60_000)
  const touch = info.project.name === "phone"
  const agentGraduates = info.project.name === "desktop"
  const outcomes: {agent: Outcome; page: Outcome} = agentGraduates
    ? {agent: "graduated", page: "failed"}
    : {agent: "failed", page: "graduated"}
  const transactions: Landed[] = []
  const evidence: Record<string, any> = {project: info.project.name, outcomes, transactions}
  const out = `${process.env.AGENT_JOURNEYS_OUT}/agent-finish-base-${info.project.name}.json`
  const auctionAbi = memestock().abis.auction
  const read = async (auction: string, name: string) =>
    Number(BigInt(await call(auction, encodeFunctionData({abi: auctionAbi, functionName: name as any, args: []}) as Hex)))

  try {
    await signIn(page, people.a)
    const agent = new Agent(`finish-${info.project.name}`)
    await pairWith(page, agent, `Finish ${info.project.name}`)
    const tag = agent.address.slice(2, 6).toUpperCase()

    // Two launches ten blocks apart, so the agent's auction can be finished, and refused as
    // finished, while the page's still has blocks to go.
    await test.step("two launches, ten blocks apart, found with the agent's own read tool", async () => {
      const byAgent = await launch(page, sent, agent, tag, {...draftFor(tag), name: `Agent Finish ${tag}`, symbol: `FA${tag}`})
      await rpc("anvil_mine", ["0xa"])
      const byPage = await launch(page, sent, agent, tag, {...draftFor(tag), name: `Page Finish ${tag}`, symbol: `FP${tag}`})
      const x = await listedAuction(agent, byAgent.draft.symbol)
      const y = await listedAuction(agent, byPage.draft.symbol)
      evidence.auctions = {
        agent: {id: x.id, address: x.address.toLowerCase(), symbol: byAgent.draft.symbol, page: byAgent.auction, launch: byAgent.hash},
        page: {id: y.id, address: y.address.toLowerCase(), symbol: byPage.draft.symbol, page: byPage.auction, launch: byPage.hash},
      }
    })
    const {agent: x, page: y} = evidence.auctions

    // A's bids, which the agent prepares: past the minimum (about 0.27 AAPLc) on the auction that
    // graduates, under it on the one that fails.
    await test.step("both auctions open and take A's bids", async () => {
      await mineTo(Math.max(await read(x.address, "startBlock"), await read(y.address, "startBlock")))
      await expect.poll(async () => [(await record(x.id)).state, (await record(y.id)).state], {timeout: 120_000})
        .toEqual(["active", "active"])
      await mintStock(AAPLC, wallet, 10n ** 8n)
      for (const [auction, graduates] of [[x, outcomes.agent === "graduated"], [y, outcomes.page === "graduated"]] as const) {
        const amount = graduates ? "0.5" : "0.1"
        const bid = agent.signed("POST", "/api/agent/v1/bids/steps", {auction_id: auction.id, amount, max_price: "0.00001"})
        expect(bid.status, JSON.stringify(bid.json)).toBe(200)
        await sendSteps(page, wallet, bid.json.data, `bid ${amount} AAPLc on ${auction.symbol}`, transactions)
      }
    })

    let launches: {agent: any; page: any} = {agent: null, page: null}
    await test.step("both auctions end", async () => {
      await mineTo(Math.max(await read(x.address, "endBlock"), await read(y.address, "endBlock")))
      await expect.poll(async () => [(await record(x.id)).state, (await record(y.id)).state], {timeout: 120_000})
        .toEqual(["ended", "ended"])
      launches = {agent: await launchRecord("memestock", x.address), page: await launchRecord("memestock", y.address)}
      evidence.migration_blocks = {agent: Number(launches.agent.migrationBlock), page: Number(launches.page.migrationBlock)}
      expect(evidence.migration_blocks.page - evidence.migration_blocks.agent).toBeGreaterThanOrEqual(4)
    })
    const {agent: mbX, page: mbY} = evidence.migration_blocks as {agent: number; page: number}

    await test.step("two blocks before the migration block the agent's finish is refused, naming the block", async () => {
      await mineTo(mbX - 2)
      const early = await refused(agent, x.id, 409, "finish_not_open")
      expect(early.error.message).toContain(`block ${mbX}`)
      evidence.agent_finish = {two_blocks_before: {block: await blockNumber(), refusal: early}}
    })

    await test.step("one block before, the route and the hosted tool give the finish step, and A's wallet sends it", async () => {
      await mineTo(mbX - 1)
      const open = await finished(agent, x.id)
      expect(open).toMatchObject({
        kind: "finish",
        signer: wallet,
        auction: {id: x.id, address: x.address},
        chain: {chain_id: 31_337},
        block: mbX - 1,
        facts: {migration_block: mbX, clock: mbX - 1},
      })
      expect(open.steps.map((step: any) => step.step)).toEqual(["finish"])
      expect(open.steps[0]).toMatchObject({to: launches.agent.finisher, value: "0x0"})
      expect(open.steps[0].data.startsWith(launches.agent.migrate), "the step is the launchpad's migrate of this launch").toBe(true)
      const [landed] = await sendSteps(page, wallet, open, "the agent's finish", transactions)
      expect(Number(BigInt(landed.blockNumber)), "it lands at the migration block").toBe(mbX)
      evidence.agent_finish.one_block_before = open
    })

    await test.step("finished: the agent is refused, and so is a wallet that is not A's", async () => {
      evidence.agent_finish.after = await refused(agent, x.id, 409, "auction_finished")
      evidence.agent_finish.wrong_signer = await refused(agent, x.id, 403, "wrong_signer", {signer: people.b.wallet})
      evidence.agent_finish.lifecycle = {before: launches.agent.lifecycle, after: (await launchRecord("memestock", x.address)).lifecycle}
      expect(evidence.agent_finish.lifecycle.after).not.toBe(evidence.agent_finish.lifecycle.before)
      await listedFinished(page, x.page, x.id, "autolaunch-finish", outcomes.agent, `finish-base-${info.project.name}-agent-${outcomes.agent}`)
      await fitsAndPresses(page, touch)
    })

    const {card, line} = finishCard(page, "autolaunch-finish")
    await test.step("two blocks before, the page's Finish card names the block and its button is disabled", async () => {
      await mineTo(mbY - 2)
      evidence.page_finish = {two_blocks_before: {block: await blockNumber(), agent: await refused(agent, y.id, 409, "finish_not_open")}}
      await page.goto(y.page)
      await ready(page)
      await expect(line).toHaveText(`Finishing opens at block ${mbY}.`, {timeout: 30_000})
      await expect(card.getByRole("button", {name: "Finish auction"})).toBeDisabled()
      await fitsAndPresses(page, touch)
      await shot(page, `finish-base-${info.project.name}-page-blocked`)
    })

    await test.step("one block before, the card is ready by itself, and its press lands at the migration block", async () => {
      await mineTo(mbY - 1)
      await expect(line).toHaveText("Ready to finish.", {timeout: 30_000})
      const button = card.getByRole("button", {name: "Finish auction"})
      await expect(button).toBeEnabled()
      await shot(page, `finish-base-${info.project.name}-page-ready`)
      const before = sent.length
      await button.click()
      await expect.poll(() => sent.length, {message: "the Finish press reaches the wallet", timeout: 30_000}).toBeGreaterThan(before)
      const press = sent[before]
      const landed = await receipt(press.hash)
      transactions.push({label: "the page's finish", step: "finish", chain_id: 31_337, hash: press.hash, status: landed.status, block: Number(BigInt(landed.blockNumber))})
      expect(landed.status).toBe("0x1")
      expect(Number(BigInt(landed.blockNumber)), "it lands at the migration block").toBe(mbY)
      expect(press.to).toBe(launches.page.finisher)
      expect(press.data.startsWith(launches.page.migrate), "the press sends the launchpad's migrate of this launch").toBe(true)
      evidence.page_finish.after = await refused(agent, y.id, 409, "auction_finished")
      await listedFinished(page, y.page, y.id, "autolaunch-finish", outcomes.page, `finish-base-${info.project.name}-page-${outcomes.page}`)
    })

    unpair("did:privy:journey-a", agent.address)
  } finally {
    writeFileSync(out, evidenceText(evidence))
  }
})

// The auctions' floor, a price on their grid (StocksPreset.FLOOR_PRICE_Q96).
const FLOOR_Q96 = 4_294_967_300n

test("agent finish on Robinhood Chain: the agent prepares an ended auction's finish, the person's wallet sends it, and the page's own Finish button finishes another", async ({page, sent}, info) => {
  test.setTimeout(20 * 60_000)
  const touch = info.project.name === "phone"
  const {addresses, abis} = deployment()
  const transactions: Landed[] = []
  const evidence: Record<string, any> = {project: info.project.name, transactions, clock: {}}
  const out = `${process.env.AGENT_JOURNEYS_OUT}/agent-finish-robinhood-${info.project.name}.json`
  const read = async (auction: string, name: string) =>
    Number(BigInt(await rhCall(auction, encodeFunctionData({abi: abis.auction, functionName: name, args: []}) as Hex)))

  try {
    await signIn(page, people.a)
    const agent = new Agent(`rh-finish-${info.project.name}`)
    await pairWith(page, agent, `Robinhood finish ${info.project.name}`)
    const tag = agent.address.slice(2, 6).toUpperCase()
    const stock = lab().stocks[0]

    // Two launches on the lab at one reading of its clock, so they keep one schedule.
    await test.step("two launches on the lab, one schedule", async () => {
      const onRobinhood = (name: string, symbol: string) =>
        ({...draftFor(tag), name, symbol, chain: "robinhood", stock_address: stock.address})
      const launchedAt = await clock()
      const byAgent = await launch(page, sent, agent, tag, onRobinhood(`Agent Robin Finish ${tag}`, `RF${tag}`))
      const byPage = await launch(page, sent, agent, tag, onRobinhood(`Page Robin Finish ${tag}`, `RP${tag}`))
      expect(await clock(), "nothing moved the block clock during the launches").toBe(launchedAt)
      const g = await listedAuction(agent, byAgent.draft.symbol)
      const f = await listedAuction(agent, byPage.draft.symbol)
      evidence.auctions = {
        agent: {id: g.id, address: g.address.toLowerCase(), symbol: byAgent.draft.symbol, page: byAgent.auction, launch: byAgent.hash},
        page: {id: f.id, address: f.address.toLowerCase(), symbol: byPage.draft.symbol, page: byPage.auction, launch: byPage.hash},
      }
    })
    const {agent: g, page: f} = evidence.auctions
    const [start, end] = [await read(g.address, "startBlock"), await read(g.address, "endBlock")]
    expect([await read(f.address, "startBlock"), await read(f.address, "endBlock")]).toEqual([start, end])

    // Any bid of USDG passes the minimum raise, so the agent's auction graduates on A's USDG bid,
    // which the agent prepares. A's only bid on the page's auction is a millionth of a millionth of
    // a share, straight to the auction, under its minimum, so that one fails.
    await test.step("both auctions open and take A's bids", async () => {
      await clockStep(start)
      await expect.poll(async () => [(await record(g.id)).state, (await record(f.id)).state], {timeout: 60_000})
        .toEqual(["active", "active"])
      await mint(addresses.usdg, wallet, 10n * 10n ** 6n)
      const bid = agent.signed("POST", "/api/agent/v1/robinhood/bids/steps", {auction_id: g.id, usdg_amount: "2", max_price: "0.000001"})
      expect(bid.status, JSON.stringify(bid.json)).toBe(200)
      await sendSteps(page, wallet, bid.json.data, `bid 2 USDG on ${g.symbol}`, transactions)
      const tiny = 10n ** 6n
      await mint(stock.address, wallet, tiny)
      await sendFrom(wallet, stock.address, encodeFunctionData({abi: erc20, functionName: "approve", args: [addresses.permit2 as Hex, tiny]}))
      await sendFrom(wallet, addresses.permit2, encodeFunctionData({abi: permit2, functionName: "approve", args: [stock.address as Hex, f.address as Hex, tiny, 2 ** 40]}))
      await sendFrom(wallet, f.address, encodeFunctionData({abi: abis.auction, functionName: "submitBid", args: [FLOOR_Q96 * 2n, tiny, wallet as Hex, FLOOR_Q96, "0x"]}) as Hex)
    })

    let launches: {agent: any; page: any} = {agent: null, page: null}
    await test.step("both auctions end", async () => {
      await clockStep(end)
      await expect.poll(async () => [(await record(g.id)).state, (await record(f.id)).state], {timeout: 60_000})
        .toEqual(["ended", "ended"])
      launches = {agent: await launchRecord("robinhood", g.address), page: await launchRecord("robinhood", f.address)}
      expect(launches.page.migrationBlock).toBe(launches.agent.migrationBlock)
      evidence.migration_block = Number(launches.agent.migrationBlock)
    })
    const mb: number = evidence.migration_block

    const {card, line} = finishCard(page, "autolaunch-robinhood-finish")
    await test.step("two clock steps before the migration block the agent is refused and the page's button is disabled", async () => {
      await clockStep(mb - 2)
      const early = await refused(agent, g.id, 409, "finish_not_open")
      expect(early.error.message).toContain(`block ${mb}`)
      evidence.clock.two_before = {clock: await clock(), agent: early}
      await page.goto(f.page)
      await ready(page)
      await expect(line).toHaveText(`Finishing opens at block ${mb}.`, {timeout: 30_000})
      await expect(card.getByRole("button", {name: "Finish auction"})).toBeDisabled()
      await fitsAndPresses(page, touch)
      await shot(page, `finish-robinhood-${info.project.name}-page-blocked`)
    })

    let open: any
    await test.step("one clock step before, the card is ready by itself and the agent gets the finish step", async () => {
      await clockStep(mb - 1)
      await expect(line).toHaveText("Ready to finish.", {timeout: 30_000})
      await expect(card.getByRole("button", {name: "Finish auction"})).toBeEnabled()
      await shot(page, `finish-robinhood-${info.project.name}-page-ready`)
      open = await finished(agent, g.id)
      expect(open).toMatchObject({
        kind: "finish",
        signer: wallet,
        auction: {id: g.id, address: g.address},
        chain: {chain_id: 31_338},
        facts: {migration_block: mb, clock: mb - 1},
      })
      expect(open.steps.map((step: any) => step.step)).toEqual(["finish"])
      expect(open.steps[0]).toMatchObject({to: launches.agent.finisher, value: "0x0"})
      expect(open.steps[0].data.startsWith(launches.agent.migrate), "the step is the launchpad's migrate of this launch").toBe(true)
      evidence.clock.one_before = {clock: await clock(), agent: open}
    })

    // On Robinhood Chain the clock moves on by itself; on the lab the journey moves it, to the
    // migration block, where the step given one clock step before lands.
    await test.step("at the migration block the agent's step and the page's press both land", async () => {
      await clockStep(mb)
      await sendSteps(page, wallet, open, "the agent's finish", transactions)
      const before = sent.length
      await card.getByRole("button", {name: "Finish auction"}).click()
      await expect.poll(() => sent.length, {message: "the Finish press reaches the wallet", timeout: 30_000}).toBeGreaterThan(before)
      const press = sent[before]
      const landed = await rhReceipt(press.hash)
      transactions.push({label: "the page's finish", step: "finish", chain_id: 31_338, hash: press.hash, status: landed.status, block: Number(BigInt(landed.blockNumber))})
      expect(landed.status).toBe("0x1")
      expect(press.to).toBe(launches.page.finisher)
      expect(press.data.startsWith(launches.page.migrate), "the press sends the launchpad's migrate of this launch").toBe(true)
    })

    await test.step("finished: both are refused to the agent, and the site lists one graduated and one failed", async () => {
      evidence.after = {
        agent: await refused(agent, g.id, 409, "auction_finished"),
        page: await refused(agent, f.id, 409, "auction_finished"),
        wrong_signer: await refused(agent, g.id, 403, "wrong_signer", {signer: people.b.wallet}),
      }
      await listedFinished(page, g.page, g.id, "autolaunch-robinhood-finish", "graduated", `finish-robinhood-${info.project.name}-agent-graduated`)
      await listedFinished(page, f.page, f.id, "autolaunch-robinhood-finish", "failed", `finish-robinhood-${info.project.name}-page-failed`)
      await fitsAndPresses(page, touch)
    })

    unpair("did:privy:journey-a", agent.address)
  } finally {
    writeFileSync(out, evidenceText(evidence))
  }
})
