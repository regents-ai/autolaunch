import {writeFileSync} from "node:fs"
import type {Page} from "@playwright/test"
import {decodeEventLog, encodeFunctionData, type Abi, type Hex} from "viem"
import {Agent} from "./support/agent"
import {draftFor, launch} from "./support/launch"
import {pairWith, unpair} from "./support/pairing"
import {expect, people, ready, signIn, test} from "./support/person"
import {
  balanceOf, call, clock, clockTo, deployment, erc20, lab, mint, permit2, receipt, refusal, rh, sendFrom,
} from "./support/robinhood"

// Agent bids on Robinhood Chain, against the Robinhood lab with the site switched on for them
// (scripts/agent-journeys.sh). Person A pairs an agent, which fills in two Memestock launches on
// the lab, paired with a fixture stock; A signs both on /create. The lab's auctions keep time by a
// block clock the journey moves, as Robinhood Chain's auctions do by its own. Two clock steps
// before the first auction's start block the agent's bid is refused, as the auction is certain to
// refuse it; one step before, its steps are given, as the bid may land at the start. From the start, the
// agent asks for A's USDG bid's wallet steps through its signed route and through the hosted MCP
// tool (regents mcp); both hold the steps the auction page's own review pushes to A's page for the
// same budget and max FDV, and A's wallet sends them, the USDG approval first. A second bid shows
// the approval once it is on the chain. Another person's bid, a bid number no auction can hold
// and a wallet that is not A's are refused. One block before the end the steps are given and
// land; at the end block they are refused, as the auction refuses them. At the claim block the
// agent asks for the first bid's return and claim, and A's wallet sends them: the auction has
// graduated, the return records the fill and the claim delivers the tokens. On the second
// auction A's only bid stays under the minimum, so it fails, and the return pays the whole bid
// back. The agent never holds A's key: every step leaves from A's wallet, the injected test
// wallet the page uses. Feature map: operations/FEATURES.md, Agents.
test.use({wallet: people.a.wallet})

const BID_PATH = "/api/agent/v1/robinhood/bids/steps"
const settlePath = (bid: string) => `/api/agent/v1/robinhood/bids/${bid}/steps`
// The auctions' floor, a price on their grid (StocksPreset.FLOOR_PRICE_Q96).
const FLOOR_Q96 = 4_294_967_300n
const UINT256_MAX = 2n ** 256n - 1n

type Step = {kind: string; step: string; to: string; data: string; value: string}

/** A decimal amount ("0.5") in raw units of `decimals`. */
function units(text: string, decimals: number): bigint {
  const [whole, fraction = ""] = text.split(".")
  return BigInt(whole + fraction.padEnd(decimals, "0"))
}

/** The auction as the site's public API answers it. */
async function record(id: string): Promise<any> {
  return (await (await fetch(`${process.env.AUTOLAUNCH_URL}/api/v1/auctions/${id}`)).json()).data
}

const state = async (id: string): Promise<string> => (await record(id)).state

/** The listed auction of the launch named `symbol`. */
async function listed(symbol: string): Promise<any> {
  const found = (await (await fetch(`${process.env.AUTOLAUNCH_URL}/api/v1/auctions?q=${symbol}`)).json())
    .data.find((auction: any) => auction.token_symbol === symbol)
  expect(found, `the site lists ${symbol}`).toBeTruthy()
  return found
}

async function read(auction: string, name: string): Promise<bigint> {
  return BigInt(await call(auction, encodeFunctionData({abi: deployment().abis.auction, functionName: name, args: []}) as Hex))
}

/** Keeps each wallet review the site pushes to the page `page` shows, as its OnchainSteps hook gets it. */
async function keepReviews(page: Page) {
  await page.evaluate(() => {
    const kept: unknown[] = ((window as any).journeyReviews = [])
    window.addEventListener("phx:onchain-steps:review", event => kept.push((event as CustomEvent).detail.review))
  })
}

const reviews = (page: Page): Promise<any[]> => page.evaluate(() => (window as any).journeyReviews)

/** `other` sends exactly what `one` sends, in order: each step's name, contract, calldata and value. */
function sameSteps(one: Step[], other: Step[], what: string) {
  expect(other.map(step => ({step: step.step, to: step.to, data: step.data, value: step.value})), what)
    .toEqual(one.map(step => ({step: step.step, to: step.to, data: step.data, value: step.value})))
}

/** What the hosted tool answered: its result, or its refusal's error. */
function tool(result: any): {data?: any; error?: any} {
  if (result.isError) return JSON.parse(result.content[0].text)
  return {data: result.structuredContent}
}

/** The events named `name` that `address` logged in a receipt, decoded with `abi`. */
function events(mined: any, address: string, abi: Abi, name: string): Record<string, any>[] {
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

test("agent Robinhood bids: an agent prepares its person's USDG bids, return and claim on Robinhood Chain, and the person's wallet sends them", async ({page, sent}, info) => {
  test.setTimeout(20 * 60_000)
  const wallet = people.a.wallet
  const other = people.b.wallet
  const {addresses, abis} = deployment()
  const adapter = addresses.bid_adapter.toLowerCase()
  const usdg = addresses.usdg.toLowerCase()
  const evidence: Record<string, any> = {project: info.project.name, steps: [], transactions: [], clock: {}}
  const out = `${process.env.AGENT_JOURNEYS_OUT}/agent-robinhood-bids-${info.project.name}.json`

  // The journey's steps as they ran, each with its time and whether every check in it passed:
  // `step` closes the one in progress and opens the next; one a failure stopped is closed as failed.
  let open: {step: string; from: number; errors: number} | undefined
  const close = (passed: boolean) => {
    if (open) evidence.steps.push({step: open.step, seconds: (Date.now() - open.from) / 1000, passed})
    open = undefined
  }
  const step = (name?: string) => {
    close(open !== undefined && info.errors.length === open.errors)
    if (name) open = {step: name, from: Date.now(), errors: info.errors.length}
  }

  /** Person A's wallet, the page's injected one, moves to the steps' chain and sends each in order; each must land. */
  const send = async (answer: {chain: {chain_id: number}; steps: Step[]}, label: string) => {
    await page.evaluate(
      chainId => (window as any).journeyWallet({method: "wallet_switchEthereumChain", params: [{chainId}]}),
      `0x${answer.chain.chain_id.toString(16)}`,
    )
    const mined: any[] = []
    for (const step of answer.steps) {
      const hash = await page.evaluate(
        tx => (window as any).journeyWallet({method: "eth_sendTransaction", params: [tx]}),
        {from: wallet, to: step.to, data: step.data, value: step.value},
      )
      const landed = await receipt(hash)
      evidence.transactions.push({label, step: step.step, hash, status: landed.status, block: Number(BigInt(landed.blockNumber)), clock: await clock()})
      expect(landed.status, `${label}: ${step.step} lands`).toBe("0x1")
      mined.push(landed)
    }
    return mined
  }

  const agent = new Agent(`rh-bids-${info.project.name}`)
  const prepare = (body: object) => {
    const answer = agent.signed("POST", BID_PATH, body)
    expect(answer.status, JSON.stringify(answer.json)).toBe(200)
    return answer.json.data
  }

  try {
    step("A signs in and pairs the agent")
    await signIn(page, people.a)
    await pairWith(page, agent, `Robinhood bids ${info.project.name}`)

    // Two launches on the lab, paired with its first fixture stock, at one reading of its clock,
    // so they keep one schedule.
    step("two launches on the lab, one schedule")
    const stock = lab().stocks[0]
    const tag = agent.address.slice(2, 6).toUpperCase()
    const onRobinhood = (name: string, symbol: string) =>
      ({...draftFor(tag), name, symbol, chain: "robinhood", stock_address: stock.address})
    const launchedAt = await clock()
    const graduating = await launch(page, sent, agent, tag, onRobinhood(`Agent Robin ${tag}`, `AR${tag}`))
    const failing = await launch(page, sent, agent, tag, onRobinhood(`Agent Robin Low ${tag}`, `AL${tag}`))
    expect(await clock(), "nothing moved the block clock during the launches").toBe(launchedAt)
    const g = await listed(graduating.draft.symbol)
    const f = await listed(failing.draft.symbol)
    const auction = (g.address as string).toLowerCase()
    const failed = (f.address as string).toLowerCase()
    const token = `0x${(await read(auction, "token")).toString(16).padStart(40, "0")}`
    const failedToken = `0x${(await read(failed, "token")).toString(16).padStart(40, "0")}`
    const [start, end, claim] = [await read(auction, "startBlock"), await read(auction, "endBlock"), await read(auction, "claimBlock")].map(Number)
    expect([await read(failed, "startBlock"), await read(failed, "endBlock"), await read(failed, "claimBlock")].map(Number)).toEqual([start, end, claim])
    evidence.auctions = {
      graduating: {id: g.id, address: auction, symbol: graduating.draft.symbol, page: graduating.auction},
      failing: {id: f.id, address: failed, symbol: failing.draft.symbol},
      stock,
      schedule: {launched_at_clock: launchedAt, start, end, claim},
    }

    // A holds USDG and the stock, and no USDG allowance to the bid adapter, whatever an earlier
    // run left, so the first bid needs the approval.
    step("A holds USDG and the stock, with no allowance")
    await mint(usdg, wallet, 1_000n * 10n ** 6n)
    await mint(stock.address, wallet, 10n ** 18n)
    await sendFrom(wallet, usdg, encodeFunctionData({abi: erc20, functionName: "approve", args: [adapter as Hex, 0n]}))

    // The first bid: 2 USDG at most 0.000001 of the stock a token, which with the token's supply
    // is the max FDV typed on the page.
    const amount = "2"
    const maxPrice = "0.000001"
    const supply = BigInt(await call(token, encodeFunctionData({abi: erc20, functionName: "totalSupply", args: []})))
    expect(supply % 10n ** 24n, "the supply times the price is a whole FDV").toBe(0n)
    const fdv = (supply / 10n ** 24n).toString()
    const input = {auction_id: g.id, usdg_amount: amount, max_price: maxPrice}
    const submitBid = (owner: string) =>
      encodeFunctionData({abi: abis.auction, functionName: "submitBid", args: [FLOOR_Q96 * 2n, 1n, owner as Hex, FLOOR_Q96, "0x"]}) as Hex

    // Before the start block the auction refuses a bid (AuctionNotStarted). Its clock never runs
    // back, so two steps before the start a bid sent now is certain to be refused, and so is the
    // agent's.
    step("start-2: auction_not_started, as the auction refuses")
    await clockTo(start - 2)
    const early = agent.signed("POST", BID_PATH, input)
    const [earlyTool] = await agent.mcp([{name: "prepare_robinhood_bid", input}])
    const notStarted = await refusal(auction, submitBid(wallet), wallet, abis.auction)
    evidence.clock.before_start = {clock: await clock(), route: early, hosted_tool: tool(earlyTool), auction_refuses: notStarted, listed_as: await state(g.id)}
    expect(notStarted).toBe("AuctionNotStarted")
    expect(early.status, JSON.stringify(early.json)).toBe(409)
    expect(early.json.error.code).toBe("auction_not_started")
    expect(tool(earlyTool)).toEqual({error: expect.objectContaining({code: "auction_not_started"})})

    // What the auction page offers A before the start, for the record: whether it reviews a bid
    // and offers its wallet button. Nothing is pressed.
    await page.goto(graduating.auction)
    await ready(page)
    await keepReviews(page)
    const budget = page.getByRole("textbox", {name: "Max budget"})
    await page.waitForTimeout(2_000)
    const formShown = await budget.isVisible()
    if (formShown) {
      await budget.fill(amount)
      await page.getByRole("textbox", {name: "Max FDV"}).fill(fdv)
      await page.waitForTimeout(5_000)
    }
    const button = page.locator("[data-onchain-step]:visible").first()
    evidence.clock.before_start.page = {
      form_shown: formShown,
      reviews: (await reviews(page)).map(review => ({inputs: review?.inputs, steps: review?.steps?.map((step: Step) => step.step)})),
      wallet_button: (await button.count())
        ? {text: (await button.textContent())?.trim(), disabled: await button.isDisabled()}
        : null,
      notices: await page.locator(".bid-panel [role=alert]:visible, .bid-panel [role=status]:visible").allTextContents(),
    }

    // One step before the start the bid may land at the start, which takes it, so its steps are
    // given. Nothing is sent: on the lab the clock moves only when the journey moves it.
    step("start-1: the steps are given, as the bid may land at the start")
    await clockTo(start - 1)
    const lastStep = agent.signed("POST", BID_PATH, input)
    expect(lastStep.status, JSON.stringify(lastStep.json)).toBe(200)
    expect(lastStep.json.data.steps.at(-1).step).toBe("usdg_bid")
    evidence.clock.one_step_before_start = {clock: await clock(), steps: lastStep.json.data.steps.map((step: Step) => step.step)}

    step("start: B's bid, and A's under-minimum bid on the second auction")
    await clockTo(start)
    await expect.poll(() => state(g.id), {message: "the site reads the auction as open", timeout: 60_000}).toBe("active")

    // Person B bids on the same auction straight through the bid adapter from B's own wallet.
    await mint(usdg, other, 10n * 10n ** 6n)
    await sendFrom(other, usdg, encodeFunctionData({abi: erc20, functionName: "approve", args: [adapter as Hex, 10n ** 6n]}))
    const now = Number(BigInt((await rh("eth_getBlockByNumber", ["latest", false])).timestamp))
    const bMined = await sendFrom(other, adapter, encodeFunctionData({
      abi: abis.bid_adapter,
      functionName: "bidWithUsdg",
      args: [auction as Hex, 10n ** 6n, 1n, FLOOR_Q96 * 2n, FLOOR_Q96, BigInt(now + 3_600)],
    }))
    const bBid = events(bMined, auction, abis.auction, "BidSubmitted")[0]
    expect(String(bBid.owner).toLowerCase()).toBe(other)
    const bBidId = `${auction}:${bBid.id}`

    // On the second auction A's only bid is a millionth of a millionth of a share, straight to the
    // auction, under its minimum raise (StocksPreset.REQUIRED_STOCK_RAISED, some 27 million units).
    const tiny = 10n ** 6n
    await sendFrom(wallet, stock.address, encodeFunctionData({abi: erc20, functionName: "approve", args: [addresses.permit2 as Hex, tiny]}))
    await sendFrom(wallet, addresses.permit2, encodeFunctionData({abi: permit2, functionName: "approve", args: [stock.address as Hex, failed as Hex, tiny, 2 ** 40]}))
    const fMined = await sendFrom(wallet, failed, encodeFunctionData({abi: abis.auction, functionName: "submitBid", args: [FLOOR_Q96 * 2n, tiny, wallet as Hex, FLOOR_Q96, "0x"]}) as Hex)
    const fBid = events(fMined, failed, abis.auction, "BidSubmitted")[0]
    expect(String(fBid.owner).toLowerCase()).toBe(wallet)
    const fBidId = `${failed}:${fBid.id}`

    // The auction page's own review for A, the same auction, budget and max FDV, as the site pushes
    // it to A's page; nothing on the page is pressed.
    step("route and hosted tool steps equal the auction page's review")
    await page.goto(graduating.auction)
    await ready(page)
    await keepReviews(page)
    await page.getByRole("textbox", {name: "Max budget"}).fill(amount)
    await page.getByRole("textbox", {name: "Max FDV"}).fill(fdv)
    // The page shows the FDV with its thousands separated: "1,000".
    const ours = async () =>
      (await reviews(page)).filter(review =>
        review?.inputs.amount === amount &&
        review.inputs.fdv.replaceAll(",", "") === fdv &&
        review.steps.some((step: Step) => step.step === "usdg_bid"))
    await expect.poll(async () => (await ours()).length, {message: "the page's own review", timeout: 60_000}).toBeGreaterThan(0)
    const pageReview = (await ours()).at(-1)
    expect(pageReview.signer).toBe(wallet)

    // The agent asks for the same bid through its signed route and through the hosted tool. The
    // lab mines nothing in between, so all three are read at one block.
    const routed = agent.signed("POST", BID_PATH, input)
    const [hosted] = await agent.mcp([{name: "prepare_robinhood_bid", input}])
    await page.goto("/")
    expect(routed.status, JSON.stringify(routed.json)).toBe(200)
    const first = routed.json.data
    const byTool = tool(hosted)
    evidence.first_bid = {input, fdv, page_review: pageReview, route: first, hosted_tool: byTool.data ?? byTool}
    expect(byTool.error, "the hosted tool answers").toBeUndefined()
    expect(first).toMatchObject({kind: "bid", signer: wallet, approved: false, auction: {id: g.id, address: auction}, chain: {chain_id: 31338}})
    expect(first.steps.map((step: Step) => step.step)).toEqual(["usdg_approval", "usdg_bid"])
    expect(byTool.data).toEqual(first)
    sameSteps(pageReview.steps, first.steps, "the agent's steps are the auction page's")
    expect(first.chain).toEqual(pageReview.chain)

    // A's wallet sends them, the approval first; the auction records the bid as A's, and A's USDG
    // goes down by exactly the budget.
    step("USDG approval and first bid land")
    const usdgBefore = await balanceOf(usdg, wallet)
    const landed = await send(first, "first bid")
    const placed = events(landed.at(-1), adapter, abis.bid_adapter, "StockBidPlaced")
    expect(placed).toHaveLength(1)
    expect(String(placed[0].owner).toLowerCase()).toBe(wallet)
    expect(placed[0].usdgSpent).toBe(units(amount, 6))
    expect(placed[0].stockCommitted).toBeGreaterThanOrEqual(units(first.facts.min_stock_out, 18))
    const bid = events(landed.at(-1), auction, abis.auction, "BidSubmitted")
    expect(bid).toHaveLength(1)
    expect(String(bid[0].owner).toLowerCase()).toBe(wallet)
    expect(bid[0].amount).toBe(placed[0].stockCommitted)
    expect(usdgBefore - (await balanceOf(usdg, wallet))).toBe(units(amount, 6))
    const bidId = `${auction}:${bid[0].id}`

    // The site lists it as A's, read from the chain when asked.
    step("positions list the bid as A's")
    let position: any
    await expect.poll(() => {
      position = agent.autolaunch(["positions"]).json?.data?.bids?.find((found: any) => found.bid === bidId)
      return position
    }, {message: "the site lists A's bid as A's", timeout: 60_000, intervals: [2_000]}).toBeTruthy()
    expect(position).toMatchObject({chain: "robinhood", symbol: graduating.draft.symbol})
    evidence.first_bid.position = position

    // A second bid: its approval is on the chain once A's wallet has sent it, and the steps
    // prepared again then are the bid alone.
    step("second bid shows approved")
    const secondInput = {...input, usdg_amount: "1"}
    const second = prepare(secondInput)
    expect(second.approved).toBe(false)
    expect(second.steps.map((step: Step) => step.step)).toEqual(["usdg_approval", "usdg_bid"])
    await send({...second, steps: second.steps.slice(0, 1)}, "second bid's approval")
    const again = prepare(secondInput)
    expect(again.approved).toBe(true)
    expect(again.steps.map((step: Step) => step.step)).toEqual(["usdg_bid"])
    const secondBid = events((await send(again, "second bid")).at(-1), auction, abis.auction, "BidSubmitted")
    expect(String(secondBid[0].owner).toLowerCase()).toBe(wallet)
    evidence.second_bid = {prepared: second, prepared_again: again}

    // Refusals: another person's bid, bid numbers past what an auction can hold or holds, and a
    // wallet that is not one of A's.
    step("not_your_bid, bid ids near 2^256-1, wrong_signer")
    const largest = `${auction}:${UINT256_MAX}`
    const pastLargest = `${auction}:${UINT256_MAX + 1n}`
    const tooLong = `${auction}:1${"0".repeat(78)}`
    const refused = {
      not_your_bid: agent.signed("POST", settlePath(bBidId), {}),
      largest: agent.signed("POST", settlePath(largest), {}),
      past_largest: agent.signed("POST", settlePath(pastLargest), {}),
      too_long: agent.signed("POST", settlePath(tooLong), {}),
      wrong_signer: agent.signed("POST", BID_PATH, {...input, signer: other}),
    }
    const [notYoursTool, largestTool, pastLargestTool, tooLongTool, wrongSignerTool] = await agent.mcp([
      {name: "prepare_robinhood_bid_settlement", input: {bid: bBidId}},
      {name: "prepare_robinhood_bid_settlement", input: {bid: largest}},
      {name: "prepare_robinhood_bid_settlement", input: {bid: pastLargest}},
      {name: "prepare_robinhood_bid_settlement", input: {bid: tooLong}},
      {name: "prepare_robinhood_bid", input: {...input, signer: other}},
    ])
    evidence.refusals = {
      route: refused,
      hosted_tool: {
        not_your_bid: tool(notYoursTool), largest: tool(largestTool), past_largest: tool(pastLargestTool),
        too_long: tool(tooLongTool), wrong_signer: tool(wrongSignerTool),
      },
    }
    for (const [name, answer, toolAnswer, status, code] of [
      ["another person's bid", refused.not_your_bid, notYoursTool, 404, "not_your_bid"],
      ["the largest bid number, which this auction holds no bid at", refused.largest, largestTool, 404, "not_your_bid"],
      ["a bid number past the largest", refused.past_largest, pastLargestTool, 404, "not_your_bid"],
      ["a bid number longer than any", refused.too_long, tooLongTool, 422, "invalid_request"],
      ["a wallet that is not A's", refused.wrong_signer, wrongSignerTool, 403, "wrong_signer"],
    ] as const) {
      // Each refusal is checked on its own, so one that differs does not hide the steps after it.
      expect.soft({status: answer.status, code: answer.json.error?.code}, name).toEqual({status, code})
      expect.soft(tool(toolAnswer), `${name}, through the hosted tool`).toEqual({error: answer.json.error})
    }

    // The auction refuses a bid from its end block on (submitBid reverts AuctionIsOver once its
    // clock reaches endBlock). One block before, the agent still gets its steps, and they land.
    step("end-1: steps given and land")
    await clockTo(end - 1)
    const lastOpen = prepare(input)
    expect(lastOpen.steps.map((step: Step) => step.step)).toEqual(["usdg_approval", "usdg_bid"])
    const lastBid = events((await send(lastOpen, "bid one block before the end")).at(-1), auction, abis.auction, "BidSubmitted")
    expect(String(lastBid[0].owner).toLowerCase()).toBe(wallet)
    // Steps prepared one block before the end, whose approval lands and whose bid is held.
    const held = prepare(input)
    await send({...held, steps: held.steps.slice(0, 1)}, "held bid's approval")
    step("end: bidding_ended, as the auction refuses (AuctionIsOver)")
    await clockTo(end)
    const listedAtEnd = await state(g.id)
    const ended = agent.signed("POST", BID_PATH, input)
    const [endedTool] = await agent.mcp([{name: "prepare_robinhood_bid", input}])
    const heldBid = held.steps.at(-1)
    const errors = [...abis.auction, ...abis.bid_adapter] as Abi
    evidence.clock.end = {
      end_block: end,
      one_block_before: {clock: end - 1, steps: lastOpen.steps.map((step: Step) => step.step), landed: lastBid[0].id},
      at_end: {
        clock: await clock(),
        listed_as_before_route: listedAtEnd,
        route: ended,
        hosted_tool: tool(endedTool),
        held_bid_refused_with: await refusal(heldBid.to, heldBid.data as Hex, wallet, errors),
        auction_refuses: await refusal(auction, submitBid(wallet), wallet, abis.auction),
      },
    }
    expect(evidence.clock.end.at_end.held_bid_refused_with, "the steps given one block before the end").toBe("AuctionIsOver")
    expect(evidence.clock.end.at_end.auction_refuses).toBe("AuctionIsOver")
    expect(ended.status, JSON.stringify(ended.json)).toBe(409)
    expect(ended.json.error.code).toBe("bidding_ended")
    expect(ended.json.data).toBeUndefined()
    expect(tool(endedTool)).toEqual({error: expect.objectContaining({code: "bidding_ended"})})

    // At the claim block the agent asks both ways for the first bid's return and claim, and A's
    // wallet sends them. Any bid of USDG passes the minimum raise, so this auction graduates.
    step("graduated: return then claim land")
    await clockTo(claim)
    const settle = agent.signed("POST", settlePath(bidId), {})
    const [settleTool] = await agent.mcp([{name: "prepare_robinhood_bid_settlement", input: {bid: bidId}}])
    expect(settle.status, JSON.stringify(settle.json)).toBe(200)
    const settlement = settle.json.data
    expect(tool(settleTool).data).toEqual(settlement)
    expect(settlement).toMatchObject({kind: "settle", signer: wallet, bid: bidId, auction: {id: g.id, address: auction}, facts: {graduated: true}})
    expect(settlement.steps.map((step: Step) => step.step)).toEqual(["exit", "claim"])
    const before = {stock: await balanceOf(stock.address, wallet), token: await balanceOf(token, wallet)}
    const settled = await send(settlement, "return and claim")
    const after = {stock: await balanceOf(stock.address, wallet), token: await balanceOf(token, wallet)}
    evidence.settlement = {
      route: settlement,
      hosted_tool: tool(settleTool).data,
      balances: {
        before: {[stock.symbol]: String(before.stock), [graduating.draft.symbol]: String(before.token)},
        after: {[stock.symbol]: String(after.stock), [graduating.draft.symbol]: String(after.token)},
      },
    }
    const exited = events(settled[0], auction, abis.auction, "BidExited")
    expect(exited).toHaveLength(1)
    expect(String(exited[0].owner).toLowerCase()).toBe(wallet)
    expect(exited[0].tokensFilled).toBeGreaterThan(0n)
    expect(exited[0].currencyRefunded).toBe(units(settlement.facts.stock_refunded, 18))
    expect(after.stock - before.stock, "the return reaches A's wallet").toBe(exited[0].currencyRefunded)
    const claimed = events(settled[1], auction, abis.auction, "TokensClaimed")
    expect(String(claimed[0].owner).toLowerCase()).toBe(wallet)
    expect(claimed[0].tokensFilled).toBe(units(settlement.facts.tokens_claimed, 18))
    expect(after.token - before.token, "the claim reaches A's wallet").toBe(claimed[0].tokensFilled)

    // The second auction raised less than its minimum, so it fails and the whole bid comes back.
    step("failed: the whole bid returns")
    const returning = agent.signed("POST", settlePath(fBidId), {})
    const [returningTool] = await agent.mcp([{name: "prepare_robinhood_bid_settlement", input: {bid: fBidId}}])
    expect(returning.status, JSON.stringify(returning.json)).toBe(200)
    const giveBack = returning.json.data
    expect(tool(returningTool).data).toEqual(giveBack)
    expect(giveBack).toMatchObject({kind: "settle", signer: wallet, bid: fBidId, auction: {id: f.id, address: failed}, facts: {graduated: false}})
    expect(giveBack.steps.map((step: Step) => step.step)).toEqual(["exit"])
    const fBefore = {stock: await balanceOf(stock.address, wallet), token: await balanceOf(failedToken, wallet)}
    const returned = await send(giveBack, "return on the failed auction")
    const fAfter = {stock: await balanceOf(stock.address, wallet), token: await balanceOf(failedToken, wallet)}
    const fExited = events(returned[0], failed, abis.auction, "BidExited")
    expect(String(fExited[0].owner).toLowerCase()).toBe(wallet)
    expect(fExited[0].currencyRefunded).toBe(tiny)
    expect(fExited[0].tokensFilled).toBe(0n)
    expect(fAfter.stock - fBefore.stock, "the whole bid reaches A's wallet").toBe(tiny)
    expect(fAfter.token).toBe(fBefore.token)
    const returnedAgain = agent.signed("POST", settlePath(fBidId), {})
    evidence.failed_settlement = {
      route: giveBack,
      hosted_tool: tool(returningTool).data,
      balances: {before: {[stock.symbol]: String(fBefore.stock)}, after: {[stock.symbol]: String(fAfter.stock)}},
      asked_again: returnedAgain,
    }
    expect({status: returnedAgain.status, code: returnedAgain.json.error?.code}).toEqual({status: 409, code: "failed_bid_returned"})

    step("A unpairs the agent")
    unpair("did:privy:journey-a", agent.address)
    step()
  } finally {
    close(false)
    writeFileSync(out, JSON.stringify(evidence, (_key, value) => (typeof value === "bigint" ? String(value) : value), 1))
  }
})
