import {writeFileSync} from "node:fs"
import type {Page} from "@playwright/test"
import {decodeEventLog, encodeFunctionData, parseAbi, type Hex} from "viem"
import {Agent} from "./support/agent"
import {balanceOf, call, memestock, mineTo, mintStock, receipt, sendAs} from "./support/chain"
import {AAPLC, launch} from "./support/launch"
import {pairWith, unpair} from "./support/pairing"
import {expect, holdWallet, people, ready, signIn, test, type Sent} from "./support/person"

// Agent bids on the copy of Base, with the site switched on for them (scripts/agent-journeys.sh).
// Person A pairs an agent, which fills in a Memestock launch A signs, as L1-L6 do. On that
// auction the agent asks for A's bids' wallet steps through its signed route and through the
// hosted MCP tool (regents mcp); both answers hold the steps the auction page's own review pushes
// to A's page for the same amount and price, and A's wallet sends them, approvals first. The
// site lists that bid as A's. A second bid relies on the approvals already on the chain, and a
// third is paid in USDC through the bid adapter. Another person's bid and a wallet that is not
// A's are refused. A bid prepared two blocks before the auction's end block lands the block
// before it, and once the latest block is the one before the end so is a new bid refused, as it
// could only land when the auction refuses it. Then the agent asks for the first
// bid's return and claim, and A's wallet sends them. On the desktop run the bids pass the
// minimum, the auction graduates, and the return records the fill and the claim delivers the
// tokens; on the phone run they stay under it, the auction fails, and the return pays the whole
// bid back. The agent never holds A's key: every step leaves from A's wallet, the injected test
// wallet the page uses. Feature map: operations/FEATURES.md, Agents.
test.use({wallet: people.a.wallet})

const USDC = "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913"
const USDC_HOLDER = "0xbbbbbbbbbb9cc5e90e3b3af64bdaf62c37eeffcb"
const erc20 = parseAbi([
  "function transfer(address, uint256) returns (bool)",
  "function approve(address, uint256) returns (bool)",
  "function totalSupply() view returns (uint256)",
])

type Step = {kind: string; step: string; to: string; data: string; value: string}

async function read(to: string, name: string): Promise<bigint> {
  const abi = name === "totalSupply" ? erc20 : memestock().abis.auction
  return BigInt(await call(to, encodeFunctionData({abi, functionName: name as any, args: []}) as Hex))
}

/** The auction as the site's public API answers it. */
async function record(id: string): Promise<any> {
  return (await (await fetch(`${process.env.AUTOLAUNCH_URL}/api/v1/auctions/${id}`)).json()).data
}

const state = async (id: string): Promise<string> => (await record(id)).state

/** A decimal amount ("0.5") in raw units of `decimals`. */
function units(text: string, decimals: number): bigint {
  const [whole, fraction = ""] = text.split(".")
  return BigInt(whole + fraction.padEnd(decimals, "0"))
}

/**
 * From now on, keeps each wallet review the site pushes to the page `page` shows, exactly as the
 * page's OnchainSteps hook receives it: LiveView hands every pushed event to the window too, as
 * `phx:onchain-steps:review`. `reviews(page)` answers them, newest last.
 */
async function keepReviews(page: Page) {
  await page.evaluate(() => {
    const kept: unknown[] = ((window as any).journeyReviews = [])
    window.addEventListener("phx:onchain-steps:review", event => kept.push((event as CustomEvent).detail.review))
  })
}

const reviews = (page: Page): Promise<any[]> => page.evaluate(() => (window as any).journeyReviews)

// A Permit2 allowance's expiry is the preparing server's clock plus thirty minutes, so two
// preparations made seconds apart differ only there: the fourth argument of approve.
const EXPIRY = [2 + 8 + 64 * 3, 2 + 8 + 64 * 4] as const
const expiry = (data: string) => Number(BigInt(`0x${data.slice(...EXPIRY)}`))
const masked = (data: string) => data.slice(0, EXPIRY[0]) + data.slice(EXPIRY[1])

/** `other` sends what `one` sends, in order: each step's name, contract, calldata and value. */
function sameSteps(one: Step[], other: Step[], seconds: number, what: string) {
  expect(other.map(step => step.step), what).toEqual(one.map(step => step.step))
  one.forEach((step, index) => {
    const that = other[index]
    expect({to: that.to, value: that.value}, `${what}: ${step.step}`).toEqual({to: step.to, value: step.value})
    if (step.step === "permit2_approval") {
      expect(masked(that.data), `${what}: ${step.step}`).toBe(masked(step.data))
      expect(Math.abs(expiry(that.data) - expiry(step.data)), `${what}: the allowance's expiry`).toBeLessThanOrEqual(seconds)
    } else {
      expect(that.data, `${what}: ${step.step}`).toBe(step.data)
    }
  })
}

/** What the hosted tool answered: its result, or its refusal's error. */
function tool(result: any): {data?: any; error?: any} {
  if (result.isError) return JSON.parse(result.content[0].text)
  return {data: result.structuredContent}
}

/** The events named `name` that `address` logged in a receipt, decoded with the deployment's ABI. */
function events(mined: any, address: string, abi: any, name: string): Record<string, any>[] {
  return mined.logs
    .filter((log: any) => log.address.toLowerCase() === address)
    .flatMap((log: any) => {
      try {
        const event = decodeEventLog({abi, data: log.data, topics: log.topics}) as any
        return event.eventName === name ? [event.args] : []
      } catch {
        return []
      }
    })
}

test("agent bids: an agent prepares its person's bids, return and claim, and the person's wallet sends them", async ({page, sent, browser}, info) => {
  // Up to two of the auction reader's five-minute turns, on top of the launch and the auction.
  test.setTimeout(25 * 60_000)
  const graduates = info.project.name === "desktop"
  const wallet = people.a.wallet
  const evidence: Record<string, any> = {project: info.project.name, transactions: []}
  const out = `${process.env.AGENT_JOURNEYS_OUT}/agent-bids-${info.project.name}.json`

  /** Person A's wallet, the page's injected one, sends each step in order; each must land. */
  const send = async (steps: Step[], label: string) => {
    const mined: any[] = []
    for (const step of steps) {
      const hash = await page.evaluate(
        tx => (window as any).journeyWallet({method: "eth_sendTransaction", params: [tx]}),
        {from: wallet, to: step.to, data: step.data, value: step.value},
      )
      const landed = await receipt(hash)
      evidence.transactions.push({label, step: step.step, hash, status: landed.status, block: Number(BigInt(landed.blockNumber))})
      expect(landed.status, `${label}: ${step.step} lands`).toBe("0x1")
      mined.push(landed)
    }
    return mined
  }

  try {
    await signIn(page, people.a)
    const agent = new Agent(`bids-${info.project.name}`)
    await pairWith(page, agent, `Bids ${info.project.name}`)
    const {draft, auction: path} = await launch(page, sent, agent, agent.address.slice(2, 6).toUpperCase())
    const listed = (await (await fetch(`${process.env.AUTOLAUNCH_URL}/api/v1/auctions?q=${draft.symbol}`)).json())
      .data.find((found: any) => found.token_symbol === draft.symbol)
    const auction = (listed.address as string).toLowerCase()
    const token = `0x${(await read(auction, "token")).toString(16).padStart(40, "0")}`
    evidence.auction = {id: listed.id, address: auction, symbol: draft.symbol}
    await mineTo(Number(await read(auction, "startBlock")))
    await expect.poll(() => state(listed.id), {timeout: 120_000}).toBe("active")

    // Person B bids from the auction page, as L7 does: another person's bid on the same auction.
    const other = await browser.newContext({...info.project.use, baseURL: process.env.AUTOLAUNCH_URL})
    const bSent: Sent[] = []
    const outside = await holdWallet(other, process.env.AUTOLAUNCH_URL!, people.b.wallet, bSent)
    const b = await other.newPage()
    await mintStock(AAPLC, people.b.wallet, 10n ** 8n)
    // A's own AAPLc pays for every AAPLc bid A's wallet sends here and covers the one the agent
    // is prepared at the end block, so the run never leans on stock an earlier run left: 0.5 and
    // 0.1 sent and 0.5 prepared on the desktop, 1.1 in all; 0.25 on the phone.
    await mintStock(AAPLC, wallet, 2n * 10n ** 8n)
    // A's AAPLc starts with no allowance to Permit2, whatever an earlier run left, so the first
    // bid needs every approval.
    const permit2 = memestock().addresses.permit2
    await sendAs(wallet, AAPLC, encodeFunctionData({abi: erc20, functionName: "approve", args: [permit2 as Hex, 0n]}))
    await signIn(b, people.b)
    await b.goto(path)
    await ready(b)
    await b.locator(".bid-switch label", {hasText: "AAPLc"}).click()
    const bAmount = graduates ? "0.1" : "0.05"
    await b.getByRole("textbox", {name: "Max budget"}).fill(bAmount)
    const placed = b.locator(".bid-placed")
    for (let press = 0; press < 4 && !(await placed.isVisible()); press++) {
      const before = bSent.length
      await b.locator("[data-onchain-step]:visible:not([disabled])").first().click()
      await expect.poll(() => bSent.length, {timeout: 30_000}).toBeGreaterThan(before)
      await b.waitForTimeout(1_000)
    }
    await expect(placed).toBeVisible({timeout: 60_000})
    const bBid = events(await receipt(bSent[bSent.length - 1].hash), auction, memestock().abis.auction, "BidSubmitted")[0]
    expect(String(bBid.owner).toLowerCase()).toBe(people.b.wallet)
    const bBidId = `lab:${auction.slice(2)}:${bBid.id}`

    // The auction's reader reads what the auction had raised at each bid's block, and this copy
    // of Base keeps no past block's state (support/base_fork.py starts it with a bare
    // --prune-history), so the reader can read a bid only while its block is the newest. Nothing
    // is sent until it has read B's, which B's press asks for ten seconds on.
    await expect.poll(async () => units((await record(listed.id)).bid_volume, 8), {
      message: "the auction's reader reads B's bid",
      timeout: 330_000,
      intervals: [5_000],
    }).toBe(units(bAmount, 8))

    // The first bid: 0.5 AAPLc (0.1 on the phone) at most 0.00001 AAPLc a token, which with the
    // token's supply is the max FDV typed on the page.
    const amount = graduates ? "0.5" : "0.1"
    const maxPrice = "0.00001"
    const supply = await read(token, "totalSupply")
    expect(supply % 10n ** 23n, "the supply times the price is a whole FDV").toBe(0n)
    const fdv = (supply / 10n ** 23n).toString()

    // The auction page's own review for A, the same auction, amount and price, as the site pushes
    // it to A's page; nothing on the page is pressed.
    await page.goto(path)
    await ready(page)
    await keepReviews(page)
    await page.locator(".bid-switch label", {hasText: "AAPLc"}).click()
    await page.getByRole("textbox", {name: "Max budget"}).fill(amount)
    await page.getByRole("textbox", {name: "Max FDV"}).fill(fdv)
    // The page shows the FDV with its thousands separated: "10,000".
    const ours = async () =>
      (await reviews(page)).filter(review =>
        review?.inputs.amount === amount &&
        review.inputs.fdv.replaceAll(",", "") === fdv &&
        review.steps.some((step: Step) => step.step === "bid"))
    await expect.poll(async () => (await ours()).length, {message: "the page's own review", timeout: 60_000}).toBeGreaterThan(0)
    const started = Date.now()
    const pageReview = (await ours()).at(-1)
    expect(pageReview.signer).toBe(wallet)

    // The agent asks for the same bid through its signed route and through the hosted tool.
    const input = {auction_id: listed.id, amount, max_price: maxPrice}
    const routed = agent.signed("POST", "/api/agent/v1/bids/steps", input)
    const [hosted] = await agent.mcp([{name: "prepare_bid", input}])
    // The page's review was built at most a poll before it was seen.
    const seconds = Math.ceil((Date.now() - started) / 1000) + 5
    await page.goto("/")
    expect(routed.status, JSON.stringify(routed.json)).toBe(200)
    const first = routed.json.data
    const byTool = tool(hosted)
    expect(byTool.error, "the hosted tool answers").toBeUndefined()
    evidence.first_bid = {input, page_review: pageReview, route: first, hosted_tool: byTool.data}
    expect(first).toMatchObject({kind: "bid", signer: wallet, approved: false, auction: {id: listed.id, address: auction}})
    expect(first.steps.map((step: Step) => step.step)).toEqual(["token_approval", "permit2_approval", "bid"])
    sameSteps(first.steps, byTool.data.steps, seconds, "the hosted tool's steps are the route's")
    expect({...byTool.data, steps: null, block: null}).toEqual({...first, steps: null, block: null})
    sameSteps(pageReview.steps, first.steps, seconds, "the agent's steps are the auction page's")
    expect(first.chain).toEqual(pageReview.chain)

    // A's wallet sends them, approvals first; the auction records the bid as A's.
    const stockBefore = await balanceOf(AAPLC, wallet)
    const landed = await send(first.steps, "first bid")
    const bid = events(landed.at(-1), auction, memestock().abis.auction, "BidSubmitted")
    expect(bid).toHaveLength(1)
    expect(String(bid[0].owner).toLowerCase()).toBe(wallet)
    expect(bid[0].amount).toBe(units(amount, 8))
    expect(await balanceOf(AAPLC, wallet)).toBe(stockBefore - units(amount, 8))
    const bidId = `lab:${auction.slice(2)}:${bid[0].id}`

    // The site lists it as A's once the auction's reader has read it, at its next turn: every
    // five minutes for an auction it has caught up with, as no page press asks for one sooner.
    // A's wallet sends nothing until then, so the bid's block is still the newest.
    let position: any
    await expect.poll(() => {
      const answer = agent.autolaunch(["positions"])
      position = answer.json?.data?.bids?.find((found: any) => found.bid === bidId)
      return position
    }, {message: "the site lists A's bid as A's", timeout: 360_000, intervals: [10_000]}).toBeTruthy()
    expect(position).toMatchObject({chain: "base", symbol: draft.symbol})
    expect(units(position.amount, 8)).toBe(units(amount, 8))
    evidence.first_bid.position = position

    // A second bid: its approvals are on the chain once A's wallet has sent them, and the steps
    // prepared again then are the bid alone.
    const prepare = (body: object) => {
      const answer = agent.signed("POST", "/api/agent/v1/bids/steps", body)
      expect(answer.status, JSON.stringify(answer.json)).toBe(200)
      return answer.json.data
    }
    const secondAmount = graduates ? "0.1" : "0.05"
    const second = prepare({...input, amount: secondAmount})
    expect(second.approved).toBe(false)
    expect(second.steps.map((step: Step) => step.step)).toEqual(["token_approval", "permit2_approval", "bid"])
    await send(second.steps.slice(0, 2), "second bid's approvals")
    const again = prepare({...input, amount: secondAmount})
    expect(again.approved).toBe(true)
    expect(again.steps.map((step: Step) => step.step)).toEqual(["bid"])
    const secondBid = events((await send(again.steps, "second bid")).at(-1), auction, memestock().abis.auction, "BidSubmitted")
    expect(String(secondBid[0].owner).toLowerCase()).toBe(wallet)
    expect(secondBid[0].amount).toBe(units(secondAmount, 8))
    evidence.second_bid = {prepared: second, prepared_again: again}

    // A third, paid in USDC through the bid adapter, which buys the stock and bids it as A's.
    await sendAs(USDC_HOLDER, USDC, encodeFunctionData({abi: erc20, functionName: "transfer", args: [wallet as Hex, 10n * 10n ** 6n]}))
    const usdcBefore = await balanceOf(USDC, wallet)
    const paid = prepare({...input, amount: "5", pay_with: "USDC"})
    expect(paid.steps.map((step: Step) => step.step)).toEqual(["usdc_approval", "usdc_bid"])
    const adapter = memestock().addresses.bid_adapter.toLowerCase()
    const usdcBid = events((await send(paid.steps, "USDC bid")).at(-1), adapter, memestock().abis.bid_adapter, "StockBidPlaced")
    expect(usdcBid).toHaveLength(1)
    expect(String(usdcBid[0].owner).toLowerCase()).toBe(wallet)
    expect(String(usdcBid[0].auction).toLowerCase()).toBe(auction)
    expect(usdcBid[0].stockCommitted).toBeGreaterThanOrEqual(units(paid.facts.min_stock_out, 8))
    expect(usdcBefore - (await balanceOf(USDC, wallet))).toBe(5_000_000n)
    evidence.usdc_bid = {prepared: paid, placed: usdcBid[0]}

    // Refusals: another person's bid, and a wallet that is not one of A's.
    await expect.poll(async () => {
      const mine = await (await b.request.get("/api/v1/me/positions")).json()
      return mine.data?.bids?.some((found: any) => found.bid === bBidId)
    }, {message: "the site lists B's bid as B's", timeout: 300_000, intervals: [10_000]}).toBe(true)
    const notYours = agent.signed("POST", `/api/agent/v1/bids/${bBidId}/steps`, {})
    expect(notYours.status).toBe(404)
    expect(notYours.json.error.code).toBe("not_your_bid")
    const wrongSigner = agent.signed("POST", "/api/agent/v1/bids/steps", {...input, signer: people.b.wallet})
    expect(wrongSigner.status).toBe(403)
    expect(wrongSigner.json.error.code).toBe("wrong_signer")
    const [notYoursTool, wrongSignerTool] = await agent.mcp([
      {name: "prepare_bid_settlement", input: {bid: bBidId}},
      {name: "prepare_bid", input: {...input, signer: people.b.wallet}},
    ])
    expect(tool(notYoursTool).error.code).toBe("not_your_bid")
    expect(tool(wrongSignerTool).error.code).toBe("wrong_signer")
    evidence.refusals = {not_your_bid: notYours, wrong_signer: wrongSigner}

    // The auction refuses a bid at its end block or after (submitBid reverts AuctionIsOver once
    // block.number >= endBlock), whatever the site's record of it says yet, and a step prepared at
    // the latest block lands in the next one at the earliest. Two blocks before the end the agent
    // still gets a bid's steps, and A's wallet sends the bid, which lands the block before the end;
    // one block before the end it is refused, with none, as that bid could only land in the end
    // block. The late bid is small, so the phone run stays under the minimum. Its approvals are
    // sent first, so the bid prepared two blocks before the end is one transaction.
    const endBlock = Number(await read(auction, "endBlock"))
    const late = {...input, amount: "0.001"}
    const lateApprovals = prepare(late)
    expect(lateApprovals.block, "the end is far enough off to send the late bid's approvals first").toBeLessThan(endBlock - 4)
    await send(lateApprovals.steps.filter((step: Step) => step.step !== "bid"), "late bid's approvals")
    await mineTo(endBlock - 2)
    const lastOpen = prepare(late)
    expect(lastOpen.block).toBe(endBlock - 2)
    expect(lastOpen.approved).toBe(true)
    expect(lastOpen.steps.map((step: Step) => step.step)).toEqual(["bid"])
    const lastLanded = await send(lastOpen.steps, "bid two blocks before the end")
    expect(Number(BigInt(lastLanded[0].blockNumber)), "the late bid lands the block before the end").toBe(endBlock - 1)
    const lateBid = events(lastLanded[0], auction, memestock().abis.auction, "BidSubmitted")
    expect(String(lateBid[0].owner).toLowerCase()).toBe(wallet)
    const ended = agent.signed("POST", "/api/agent/v1/bids/steps", input)
    const [endedTool] = await agent.mcp([{name: "prepare_bid", input}])
    evidence.refusals.bidding_ended = {
      end_block: endBlock,
      two_blocks_before: {block: lastOpen.block, steps: lastOpen.steps.map((step: Step) => step.step), landed_in: endBlock - 1},
      refused_at: endBlock - 1,
      listed_as: await state(listed.id),
      route: ended,
      hosted_tool: tool(endedTool),
    }
    expect(ended.status, JSON.stringify(ended.json)).toBe(409)
    expect(ended.json.error.code).toBe("bidding_ended")
    expect(ended.json.data).toBeUndefined()
    expect(tool(endedTool)).toEqual({error: expect.objectContaining({code: "bidding_ended"})})

    // The first bid's return and claim, once claims are open: the agent asks both ways, and A's
    // wallet sends the steps.
    await mineTo(Number(await read(auction, "claimBlock")))
    const settle = agent.signed("POST", `/api/agent/v1/bids/${bidId}/steps`, {})
    expect(settle.status, JSON.stringify(settle.json)).toBe(200)
    const [settleTool] = await agent.mcp([{name: "prepare_bid_settlement", input: {bid: bidId}}])
    const settlement = settle.json.data
    expect({...tool(settleTool).data, block: null}).toEqual({...settlement, block: null})
    expect(settlement).toMatchObject({kind: "settle", signer: wallet, bid: bidId, facts: {graduated: graduates}})
    expect(settlement.steps.map((step: Step) => step.step)).toEqual(graduates ? ["exit", "claim"] : ["exit"])
    const before = {stock: await balanceOf(AAPLC, wallet), token: await balanceOf(token, wallet)}
    const settled = await send(settlement.steps, "return and claim")
    const after = {stock: await balanceOf(AAPLC, wallet), token: await balanceOf(token, wallet)}
    evidence.settlement = {
      route: settlement,
      hosted_tool: tool(settleTool).data,
      balances: {
        before: {AAPLc: String(before.stock), [draft.symbol]: String(before.token)},
        after: {AAPLc: String(after.stock), [draft.symbol]: String(after.token)},
      },
    }

    const exited = events(settled[0], auction, memestock().abis.auction, "BidExited")
    expect(exited).toHaveLength(1)
    expect(String(exited[0].owner).toLowerCase()).toBe(wallet)
    expect(exited[0].currencyRefunded).toBe(units(settlement.facts.currency_refunded, 8))
    expect(after.stock - before.stock, "the return reaches A's wallet").toBe(exited[0].currencyRefunded)
    if (graduates) {
      expect(exited[0].tokensFilled).toBeGreaterThan(0n)
      const claimed = events(settled[1], auction, memestock().abis.auction, "TokensClaimed")
      expect(String(claimed[0].owner).toLowerCase()).toBe(wallet)
      expect(claimed[0].tokensFilled).toBe(units(settlement.facts.tokens_claimed, 18))
      expect(after.token - before.token, "the claim reaches A's wallet").toBe(claimed[0].tokensFilled)
    } else {
      // Under the minimum the auction fails and the whole bid comes back.
      expect(exited[0].currencyRefunded).toBe(units(amount, 8))
      expect(after.token).toBe(before.token)
    }

    await other.close()
    expect(outside, "requests that left the machine").toEqual([])
    unpair("did:privy:journey-a", agent.address)
  } finally {
    writeFileSync(out, JSON.stringify(evidence, (_key, value) => (typeof value === "bigint" ? String(value) : value), 1))
  }
})
