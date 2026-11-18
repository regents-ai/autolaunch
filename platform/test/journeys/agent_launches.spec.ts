import {randomBytes} from "node:crypto"
import {readFileSync, writeFileSync} from "node:fs"
import type {Browser, Page, TestInfo} from "@playwright/test"
import {decodeEventLog, decodeFunctionData, encodeFunctionData, type Abi, type Hex} from "viem"
import {Agent} from "./support/agent"
import {call, memestock, receipt, revstake, sendAs} from "./support/chain"
import {AAPLC} from "./support/launch"
import {pairWith, unpair} from "./support/pairing"
import {onSite} from "./support/site"
import {expect, freshPerson, holdWallet, people, ready, signIn, test} from "./support/person"

// Agent launches on the copy of Base, with the site switched on for them (scripts/agent-journeys.sh),
// for both kinds a Base launch takes: a Revstake on /agent-business and a Memestock on /create.
// Person A pairs an agent, which saves A's whole draft with its picture and asks for the launch
// step through its signed route and through the hosted MCP tool (regents mcp). Both answers are
// alike, and they are the step, chain and facts the create page's own review gives A for the same
// draft. What only A can give stays on the page: until A confirms a Safe or contract treasury the
// agent chose, or acknowledges a treasury a private key holds, the agent is refused with the
// documented code, and once A has, it gets the step. The same request twice is one preparation.
// A's wallet sends the agent's step, and the site's own discovery lists the launch as A's, with
// what the agent's review carried, and starts A's draft over. Then A reviews a second launch on
// the page, the agent changes only its links and prepares it, A's wallet sends it, and the site
// lists the links A reviewed. Another person's draft, a wallet that is not A's, and launches
// paused on the chain are refused; the first two before any chain is read. The agent never holds
// A's key: the step leaves from A's wallet, the injected test wallet the page uses. No journey run
// before this one changes what it finds: the other person is one the site has never seen, and the
// agent's first save puts A's Memestock draft on Base. A's drafts end started over. Feature map:
// operations/FEATURES.md, Agents.
test.use({wallet: people.a.wallet})

type Kind = "revstake" | "memestock"
type Step = {kind: string; step: string; to: string; data: string; value: string}
type Kept = {prepared_by: "person" | "agent"; state: string; review: any}
type Links = {telegram: string; discord: string; other_link_1: string}

const wallet = people.a.wallet
const picture = readFileSync("test/support/fixtures/launch-draft.png").toString("base64")
const reviewed: Links = {telegram: "https://t.me/journey_x", discord: "https://discord.gg/journeyx", other_link_1: "https://example.com/x"}
const relinked: Links = {telegram: "https://t.me/journey_y", discord: "https://discord.gg/journeyy", other_link_1: "https://example.com/y"}

/** The links as a review's facts and a listing carry them. */
const listedLinks = (links: Links) => ({telegram: links.telegram, discord: links.discord, links: [links.other_link_1]})

/** The contract a kind's launches go to, with its ABI, launch event and governance Safe. */
function launchContract(kind: Kind) {
  const {addresses, abis} = kind === "revstake" ? revstake() : memestock()
  return kind === "revstake"
    ? {address: addresses.factory, abi: abis.factory, created: "LaunchCreated", governance: addresses.governance_safe}
    : {address: addresses.launchpad, abi: abis.launchpad, created: "StockLaunchCreated", governance: addresses.governance_safe}
}

async function launchesPaused(kind: Kind): Promise<boolean> {
  const {address, abi} = launchContract(kind)
  return BigInt(await call(address, encodeFunctionData({abi, functionName: "launchesPaused", args: []} as any) as Hex)) !== 0n
}

/** Pauses or opens new launches on the copy, as the governance Safe does. */
async function setPaused(kind: Kind, paused: boolean) {
  const {address, abi, governance} = launchContract(kind)
  const functionName = paused ? "pauseLaunches" : "unpauseLaunches"
  await sendAs(governance, address, encodeFunctionData({abi, functionName, args: []} as any) as Hex)
}

/** The launch call a step makes, decoded with the deployment's own ABI. */
function launchCall(kind: Kind, step: Step): Record<string, any> {
  const decoded = decodeFunctionData({abi: launchContract(kind).abi, data: step.data as Hex})
  expect(decoded.functionName).toBe("launch")
  return (decoded.args as any[])[0]
}

/** The events named `name` that `address` logged in a receipt, decoded with the deployment's ABI. */
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

const steps = (draft: string) => `/api/agent/v1/launches/${draft}/steps`

/** One request both ways: the signed route, then the hosted tool. The tool answers as the route's body. */
async function bothWays(agent: Agent, draft: string, body: Record<string, string> = {}) {
  const route = agent.signed("POST", steps(draft), body)
  const [hosted] = await agent.mcp([{name: "prepare_launch", input: {draft, ...body}}])
  const tool = hosted.isError ? JSON.parse(hosted.content[0].text) : {data: hosted.structuredContent}
  return {route, tool}
}

/** The launch step, both ways alike. */
async function prepared(agent: Agent, draft: string, body: Record<string, string> = {}): Promise<any> {
  const {route, tool} = await bothWays(agent, draft, body)
  expect(route.status, JSON.stringify(route.json)).toBe(200)
  expect(tool, "the hosted tool answers as the route does").toEqual(route.json)
  return route.json.data
}

/** A refusal, both ways alike: its status and code, and no step. */
async function refused(agent: Agent, draft: string, status: number, code: string, body: Record<string, string> = {}) {
  const {route, tool} = await bothWays(agent, draft, body)
  expect(route.status, JSON.stringify(route.json)).toBe(status)
  expect(route.json.error?.code).toBe(code)
  expect(route.json.data).toBeUndefined()
  expect(tool, "the hosted tool refuses as the route does").toEqual(route.json)
  return route
}

/** The reviews the site keeps for draft `draft` of the launch named `symbol`, oldest first. */
function kept(kind: Kind, draft: string, symbol: string): Kept[] {
  const printed = onSite("launch_reviews.exs", {JOURNEY_KIND: kind, JOURNEY_DRAFT: draft})
  return JSON.parse(printed.split("JOURNEY_RESULT ")[1].split("\n")[0])
    .filter((row: Kept) => row.review.facts.symbol === symbol)
}

const states = (rows: Kept[]) => rows.map(row => [row.prepared_by, row.state])
const persons = (rows: Kept[]) => rows.filter(row => row.prepared_by === "person")

/** A review's facts without the block they were read at, which a preparation's sameness leaves out too. */
function unread(facts: Record<string, any>) {
  const {block_number: _number, block_hash: _hash, ...rest} = facts
  return rest
}

/** ...and without the links, which this site keeps and the launch does not carry. */
function unlinked(facts: Record<string, any>) {
  const {telegram: _telegram, discord: _discord, links: _links, ...rest} = unread(facts)
  return rest
}

/** Keeps each wallet review the site pushes to the page from now on (as in agent_bids.spec.ts). */
async function keepReviews(page: Page) {
  await page.evaluate(() => {
    const kept: unknown[] = ((window as any).journeyReviews = [])
    window.addEventListener("phx:onchain-steps:review", event => kept.push((event as CustomEvent).detail.review))
  })
}

/** Presses Review launch, and answers the launch review the site pushes to the page. */
async function reviewOnPage(page: Page): Promise<any> {
  await keepReviews(page)
  await page.getByRole("button", {name: "Review launch"}).click()
  const launches = async () =>
    ((await page.evaluate(() => (window as any).journeyReviews)) as any[])
      .filter(review => review?.steps.some((step: Step) => step.step === "launch"))
  await expect.poll(async () => (await launches()).length, {message: "the create page's own review", timeout: 60_000})
    .toBeGreaterThan(0)
  return (await launches()).at(-1)
}

/** A Revstake with no X, GitHub or ENS connected: the person types the page's warning to go on. */
async function launchWithoutConnections(page: Page) {
  await page.getByRole("button", {name: "Skip connections"}).click()
  const dialog = page.locator("#launch-no-connections-dialog")
  await expect(dialog).toBeVisible()
  const warning = (await dialog.locator("#launch-no-connections-warning").textContent())!.trim()
  await dialog.locator("#launch-no-connections-typed").fill(warning)
  await dialog.getByRole("button", {name: "Continue"}).click()
  await expect(page.locator("#launch-no-connections")).toBeHidden()
}

/** Person A's wallet, the page's injected one, sends one step; it must land. */
async function send(page: Page, step: Step) {
  const hash: string = await page.evaluate(
    tx => (window as any).journeyWallet({method: "eth_sendTransaction", params: [tx]}),
    {from: wallet, to: step.to, data: step.data, value: step.value},
  )
  const landed = await receipt(hash)
  expect(landed.status, "the launch lands").toBe("0x1")
  return landed
}

/**
 * The site's listing of `symbol`, once its own discovery has found the launch: every five minutes,
 * as nothing on a page confirms it. The auction list answers six requests a minute, so it is
 * polled slowly. Nothing is sent meanwhile: this copy of Base keeps no past block's state
 * (support/base_fork.py), so discovery verifies a launch only while its block is the newest.
 */
async function listed(symbol: string): Promise<any> {
  let found: any
  await expect.poll(async () => {
    const answer = await (await fetch(`${process.env.AUTOLAUNCH_URL}/api/v1/auctions?q=${symbol}`)).json()
    return (found = answer.data?.find((auction: any) => auction.token_symbol === symbol))
  }, {message: `the site lists ${symbol}`, timeout: 8 * 60_000, intervals: [15_000]}).toBeTruthy()
  return found
}

function auctionRow(auction: string): any {
  return JSON.parse(onSite("auction_row.exs", {JOURNEY_AUCTION: auction, JOURNEY_PERSON: "did:privy:journey-a"})
    .split("JOURNEY_RESULT ")[1].split("\n")[0])
}

/** The person's draft starts over once the launch is listed, as after a launch from the page. */
function expectStartedOver(agent: Agent, kind: Kind) {
  const shown = agent.autolaunch(["drafts", kind, "show"])
  expect(shown.status, shown.stdout).toBe(0)
  expect(shown.json.data).toMatchObject({
    name: "", symbol: "", description: null, website: null, telegram: null, discord: null,
    other_link_1: null, image: null, agent_set_fields: [],
  })
  return shown.json.data
}

/**
 * Another person, one the site has never seen, signed in in a browser of their own, with an agent
 * that saves their draft of `kind`: a draft of no person another journey uses.
 */
async function otherPersonsDraft(browser: Browser, info: TestInfo, kind: Kind) {
  const other = await freshPerson()
  const context = await browser.newContext({...info.project.use, baseURL: process.env.AUTOLAUNCH_URL})
  const outside = await holdWallet(context, process.env.AUTOLAUNCH_URL!, other.wallet, [])
  const page = await context.newPage()
  await signIn(page, other)
  const agent = new Agent(`launches-other-${kind}-${info.project.name}`)
  await pairWith(page, agent, `Other ${kind} ${info.project.name}`)
  const saved = agent.autolaunch(["drafts", kind, "save"], {name: "Another person's own draft"})
  expect(saved.status, saved.stdout).toBe(0)
  return {
    draft: saved.json.data.id as string,
    async close() {
      await context.close()
      expect(outside, "requests that left the machine").toEqual([])
      unpair(`did:privy:${other.token}`, agent.address)
    },
  }
}

/** The launch the step made: its event, from A's wallet. */
function made(kind: Kind, mined: any): Record<string, any> {
  const {address, abi, created} = launchContract(kind)
  const found = events(mined, address, abi, created)
  expect(found).toHaveLength(1)
  expect(String(found[0].launcher).toLowerCase()).toBe(wallet)
  return found[0]
}

function save(agent: Agent, kind: Kind, fields: Record<string, unknown>) {
  const saved = agent.autolaunch(["drafts", kind, "save"], fields)
  expect(saved.status, saved.stdout).toBe(0)
  return saved.json.data
}

const write = (out: string, evidence: object) =>
  writeFileSync(out, JSON.stringify(evidence, (_key, value) => (typeof value === "bigint" ? String(value) : value), 1))

test("agent launches, Revstake: the agent prepares its person's launch, the person's wallet sends it, and the site lists it as theirs", async ({page, browser}, info) => {
  // Two of the discovery cycle's five-minute turns, on top of the pages.
  test.setTimeout(30 * 60_000)
  const kind: Kind = "revstake"
  const {address: factory} = launchContract(kind)
  const evidence: Record<string, any> = {project: info.project.name, kind}
  const out = `${process.env.AGENT_JOURNEYS_OUT}/agent-launches-${kind}-${info.project.name}.json`

  try {
    expect(await launchesPaused(kind), "launches are open on the copy").toBe(false)
    await signIn(page, people.a)
    const agent = new Agent(`launches-${kind}-${info.project.name}`)
    await pairWith(page, agent, `Launches ${kind} ${info.project.name}`)
    const other = await otherPersonsDraft(browser, info, kind)
    const tag = agent.address.slice(2, 6).toUpperCase()

    // The agent's draft: a treasury it chose, a smart contract account on the phone run and a
    // Safe on the desktop run, which the person has not seen yet.
    const treasury = `0x${randomBytes(20).toString("hex")}`
    const path = info.project.name === "phone" ? "contract" : "safe"
    const draft = {
      name: `Agent Revstake ${tag}`,
      symbol: `RA${tag}`,
      description: "A Revstake its agent filled in and prepared, and its person launched.",
      website: "https://example.com",
      ...reviewed,
      treasury,
      treasury_path: path,
    }
    let id = ""
    let image = ""
    let first: any
    evidence.first_launch = {draft, treasury_path: path}

    await test.step("person only: a treasury the agent chose waits for the person's confirmation", async () => {
      const saved = save(agent, kind, {...draft, image: {content_type: "image/png", data: picture}})
      id = saved.id
      image = saved.image
      evidence.first_launch.unconfirmed = await refused(agent, id, 409, "agent_treasury_unconfirmed")
      expect(kept(kind, id, draft.symbol), "a refusal keeps no review").toEqual([])

      await page.goto("/agent-business")
      await ready(page)
      const confirm = page.locator("#launch-agent-treasury")
      await expect(confirm).toContainText(new RegExp(treasury, "i"))
      await confirm.getByText("This smart contract will receive all treasury funds").click()
      await expect(confirm).toBeHidden()
      first = await prepared(agent, id)
      evidence.first_launch.prepared = first
    })

    await test.step("draft and step: the route, the hosted tool and the create page's review give the same launch", async () => {
      expect(first).toMatchObject({kind: "launch", signer: wallet, draft: {id, kind}, block: first.facts.block_number})
      expect(first.steps).toHaveLength(1)
      expect(first.steps[0]).toMatchObject({kind: "transaction", step: "launch", to: factory, value: "0x0"})
      const params = launchCall(kind, first.steps[0])
      expect({...params, treasury: String(params.treasury).toLowerCase()}).toEqual({
        name: draft.name, symbol: draft.symbol, description: draft.description, website: draft.website, image, treasury,
      })
      expect(first.facts).toMatchObject({
        draft_id: id, name: draft.name, symbol: draft.symbol, description: draft.description, website: draft.website,
        ...listedLinks(reviewed), image, treasury, treasury_path: path,
      })
      const agents = kept(kind, id, draft.symbol)
      expect(states(agents)).toEqual([["agent", "prepared"]])
      expect(agents[0].review.facts).toEqual(first.facts)
      expect(agents[0].review.step).toEqual(first.steps[0])

      // The create page's own review of the same draft for the same wallet, as the site pushes it to
      // A's page; nothing on the page is sent.
      await launchWithoutConnections(page)
      const pageReview = await reviewOnPage(page)
      await page.goto("/")
      evidence.first_launch.page_review = pageReview
      expect(pageReview.signer).toBe(wallet)
      expect(pageReview.chain).toEqual(first.chain)
      expect(pageReview.steps).toEqual(first.steps)
      const person = persons(kept(kind, id, draft.symbol))
      expect(person).toHaveLength(1)
      expect(person[0].review.step).toEqual(first.steps[0])
      expect(unread(person[0].review.facts)).toEqual(unread(first.facts))
      evidence.first_launch.page_facts = person[0].review.facts
    })

    await test.step("reuse: the same request again is the same step and one preparation", async () => {
      expect(await prepared(agent, id)).toEqual(first)
      expect(states(kept(kind, id, draft.symbol))).toEqual([["agent", "prepared"], ["person", "prepared"]])
    })

    await test.step("send and listing: the person's wallet sends the agent's step and the site lists the launch as theirs", async () => {
      // The agent changes the description and prepares again: a new step, which only the agent's
      // review carries, so the listing can come from nothing else.
      const description = "A Revstake its agent prepared again with new words, and its person launched."
      save(agent, kind, {description})
      const launched = await prepared(agent, id)
      evidence.first_launch.sent = launched
      expect(launched.facts.description).toBe(description)
      expect(launched.steps[0].data).not.toBe(first.steps[0].data)
      expect(unread({...launched.facts, description: draft.description})).toEqual(unread(first.facts))
      expect(states(kept(kind, id, draft.symbol)))
        .toEqual([["agent", "prepared"], ["person", "prepared"], ["agent", "prepared"]])

      const landed = await send(page, launched.steps[0])
      const launch = made(kind, landed)
      expect(String(launch.treasury).toLowerCase()).toBe(treasury)
      const auction = String(launch.auction).toLowerCase()
      evidence.first_launch.transaction = {hash: landed.transactionHash, block: Number(BigInt(landed.blockNumber)), auction}

      const listing = await listed(draft.symbol)
      expect(listing.address.toLowerCase()).toBe(auction)
      const row = auctionRow(auction)
      evidence.first_launch.listing = {listing, row}
      expect(row).toMatchObject({
        origin: "site", persons_account: true, creator_wallet: wallet, title: draft.name, symbol: draft.symbol,
        description, website: draft.website, ...listedLinks(reviewed), image,
      })
      expect(states(kept(kind, id, draft.symbol)))
        .toEqual([["agent", "prepared"], ["person", "prepared"], ["agent", "chain_verified"]])
      evidence.first_launch.started_over = expectStartedOver(agent, kind)
    })

    // The second launch: a treasury A's own key holds, which takes A's typed acknowledgement.
    const second = {
      name: `Agent Revstake B${tag}`,
      symbol: `RB${tag}`,
      description: "A Revstake its person reviewed first, which its agent prepared after.",
      website: "https://example.com",
      ...reviewed,
      treasury: wallet,
      treasury_path: "eoa",
    }
    let secondImage = ""
    let acknowledged: any
    evidence.second_launch = {draft: second}

    await test.step("person only: a treasury a private key holds waits for the person's acknowledgement", async () => {
      const saved = save(agent, kind, {...second, image: {content_type: "image/png", data: picture}})
      expect(saved.id).toBe(id)
      secondImage = saved.image
      evidence.second_launch.unacknowledged = await refused(agent, id, 409, "launch_treasury_invalid")

      await page.goto("/agent-business")
      await ready(page)
      const typed = page.locator("#launch-treasury-details-eoa-acknowledgement")
      await typed.fill((await page.locator("#launch-treasury-details-eoa-acknowledgement-warning").textContent())!.trim())
      await typed.blur()
      await expect(page.getByText("Warning typed exactly. Risk acknowledged.")).toBeVisible()
      // Saved as the person leaves the box.
      await expect.poll(() => agent.signed("POST", steps(id), {}).status, {
        message: "the agent gets the step once the acknowledgement is saved",
        timeout: 30_000,
      }).toBe(200)
      acknowledged = await prepared(agent, id)
      evidence.second_launch.acknowledged = acknowledged
      expect(acknowledged.facts).toMatchObject({treasury: wallet, treasury_path: "eoa", ...listedLinks(reviewed)})
    })

    await test.step("refusals: another person's draft and a wallet not theirs before any chain read, and launches paused", async () => {
      const refusals: Record<string, any> = (evidence.refusals = {})
      refusals.not_theirs = await refused(agent, other.draft, 404, "launch_draft_not_found")
      refusals.wrong_signer = await refused(agent, id, 403, "wrong_signer", {signer: people.b.wallet})
      await setPaused(kind, true)
      try {
        expect(await launchesPaused(kind)).toBe(true)
        refusals.paused = await refused(agent, id, 409, "launches_paused")
        // Paused, a read of the chain would refuse these too; they are refused for what they are.
        refusals.not_theirs_paused = await refused(agent, other.draft, 404, "launch_draft_not_found")
        refusals.wrong_signer_paused = await refused(agent, id, 403, "wrong_signer", {signer: people.b.wallet})
      } finally {
        await setPaused(kind, false)
      }
      expect(await prepared(agent, id), "open again, the newest preparation").toEqual(acknowledged)
    })

    await test.step("person first: the agent changes only the links after the person's review, and the listing keeps the person's", async () => {
      await page.goto("/agent-business")
      await ready(page)
      await launchWithoutConnections(page)
      const pageReview = await reviewOnPage(page)
      await page.goto("/")
      const [person] = persons(kept(kind, id, second.symbol))
      expect(person.review.facts).toMatchObject(listedLinks(reviewed))
      evidence.second_launch.page_review = pageReview
      evidence.second_launch.page_facts = person.review.facts

      save(agent, kind, relinked)
      const latest = await prepared(agent, id)
      evidence.second_launch.sent = latest
      expect(latest.facts).toMatchObject(listedLinks(relinked))
      expect(latest.steps, "the links are not in the launch, so the step is the page's").toEqual(pageReview.steps)
      expect(latest.chain).toEqual(pageReview.chain)
      expect(unlinked(latest.facts)).toEqual(unlinked(person.review.facts))
      expect(states(kept(kind, id, second.symbol)))
        .toEqual([["agent", "prepared"], ["person", "prepared"], ["agent", "prepared"]])

      const landed = await send(page, latest.steps[0])
      const launch = made(kind, landed)
      expect(String(launch.treasury).toLowerCase()).toBe(wallet)
      const auction = String(launch.auction).toLowerCase()
      evidence.second_launch.transaction = {hash: landed.transactionHash, block: Number(BigInt(landed.blockNumber)), auction}

      const listing = await listed(second.symbol)
      expect(listing.address.toLowerCase()).toBe(auction)
      const row = auctionRow(auction)
      evidence.second_launch.listing = {listing, row}
      expect(row).toMatchObject({
        origin: "site", persons_account: true, creator_wallet: wallet, title: second.name, symbol: second.symbol,
        description: second.description, website: second.website, ...listedLinks(reviewed), image: secondImage,
      })
      expect(states(kept(kind, id, second.symbol)))
        .toEqual([["agent", "prepared"], ["person", "chain_verified"], ["agent", "prepared"]])
      evidence.second_launch.started_over = expectStartedOver(agent, kind)
    })

    await other.close()
    unpair("did:privy:journey-a", agent.address)
  } finally {
    if (await launchesPaused(kind)) await setPaused(kind, false)
    write(out, evidence)
  }
})

test("agent launches, Memestock on Base: the agent prepares its person's launch, the person's wallet sends it, and the site lists it as theirs", async ({page, browser}, info) => {
  test.setTimeout(30 * 60_000)
  const kind: Kind = "memestock"
  const {address: launchpad} = launchContract(kind)
  const evidence: Record<string, any> = {project: info.project.name, kind}
  const out = `${process.env.AGENT_JOURNEYS_OUT}/agent-launches-${kind}-${info.project.name}.json`

  try {
    expect(await launchesPaused(kind), "launches are open on the copy").toBe(false)
    await signIn(page, people.a)
    const agent = new Agent(`launches-${kind}-${info.project.name}`)
    await pairWith(page, agent, `Launches ${kind} ${info.project.name}`)
    const other = await otherPersonsDraft(browser, info, kind)
    const tag = agent.address.slice(2, 6).toUpperCase()

    const draft = {
      name: `Agent Memestock ${tag}`,
      symbol: `MA${tag}`,
      description: "A memestock its agent filled in and prepared, and its person launched.",
      website: "https://example.com",
      ...reviewed,
      chain: "base",
      stock_address: AAPLC,
    }
    let id = ""
    let image = ""
    let first: any
    evidence.first_launch = {draft}

    await test.step("draft and step: the route, the hosted tool and the create page's review give the same launch", async () => {
      const saved = save(agent, kind, {...draft, image: {content_type: "image/png", data: picture}})
      id = saved.id
      image = saved.image
      first = await prepared(agent, id)
      evidence.first_launch.prepared = first
      expect(first).toMatchObject({kind: "launch", signer: wallet, draft: {id, kind}, block: first.facts.block_number})
      expect(first.steps).toHaveLength(1)
      expect(first.steps[0]).toMatchObject({kind: "transaction", step: "launch", to: launchpad, value: "0x0"})
      const params = launchCall(kind, first.steps[0])
      expect({
        name: params.name, symbol: params.symbol, description: params.description, website: params.website,
        image: params.image, stock: String(params.stock).toLowerCase(),
      }).toEqual({name: draft.name, symbol: draft.symbol, description: draft.description, website: draft.website, image, stock: AAPLC})
      expect(first.facts).toMatchObject({
        draft_id: id, name: draft.name, symbol: draft.symbol, description: draft.description, website: draft.website,
        ...listedLinks(reviewed), image, stock: AAPLC,
      })
      const agents = kept(kind, id, draft.symbol)
      expect(states(agents)).toEqual([["agent", "prepared"]])
      expect(agents[0].review.facts).toEqual(first.facts)
      expect(agents[0].review.step).toEqual(first.steps[0])

      await page.goto("/create")
      await ready(page)
      await expect(page.locator("#agent-set-fields")).toContainText(draft.name)
      const pageReview = await reviewOnPage(page)
      await page.goto("/")
      evidence.first_launch.page_review = pageReview
      expect(pageReview.signer).toBe(wallet)
      expect(pageReview.chain).toEqual(first.chain)
      expect(pageReview.steps).toEqual(first.steps)
      const person = persons(kept(kind, id, draft.symbol))
      expect(person).toHaveLength(1)
      expect(person[0].review.step).toEqual(first.steps[0])
      expect(unread(person[0].review.facts)).toEqual(unread(first.facts))
      evidence.first_launch.page_facts = person[0].review.facts
    })

    await test.step("reuse: the same request again is the same step and one preparation", async () => {
      expect(await prepared(agent, id)).toEqual(first)
      expect(states(kept(kind, id, draft.symbol))).toEqual([["agent", "prepared"], ["person", "prepared"]])
    })

    await test.step("send and listing: the person's wallet sends the agent's step and the site lists the launch as theirs", async () => {
      const description = "A memestock its agent prepared again with new words, and its person launched."
      save(agent, kind, {description})
      const launched = await prepared(agent, id)
      evidence.first_launch.sent = launched
      expect(launched.facts.description).toBe(description)
      expect(launched.steps[0].data).not.toBe(first.steps[0].data)
      expect(unread({...launched.facts, description: draft.description})).toEqual(unread(first.facts))
      expect(states(kept(kind, id, draft.symbol)))
        .toEqual([["agent", "prepared"], ["person", "prepared"], ["agent", "prepared"]])

      const landed = await send(page, launched.steps[0])
      const launch = made(kind, landed)
      expect(String(launch.stock).toLowerCase()).toBe(AAPLC)
      const auction = String(launch.auction).toLowerCase()
      evidence.first_launch.transaction = {hash: landed.transactionHash, block: Number(BigInt(landed.blockNumber)), auction}

      const listing = await listed(draft.symbol)
      expect(listing.address.toLowerCase()).toBe(auction)
      const row = auctionRow(auction)
      evidence.first_launch.listing = {listing, row}
      expect(row).toMatchObject({
        origin: "site", persons_account: true, creator_wallet: wallet, title: draft.name, symbol: draft.symbol,
        description, website: draft.website, ...listedLinks(reviewed), image,
      })
      expect(states(kept(kind, id, draft.symbol)))
        .toEqual([["agent", "prepared"], ["person", "prepared"], ["agent", "chain_verified"]])
      evidence.first_launch.started_over = expectStartedOver(agent, kind)
    })

    const second = {
      name: `Agent Memestock B${tag}`,
      symbol: `MB${tag}`,
      description: "A memestock its person reviewed first, which its agent prepared after.",
      website: "https://example.com",
      ...reviewed,
      chain: "base",
      stock_address: AAPLC,
    }
    let secondImage = ""
    let open: any
    evidence.second_launch = {draft: second}

    await test.step("refusals: another person's draft and a wallet not theirs before any chain read, and launches paused", async () => {
      const saved = save(agent, kind, {...second, image: {content_type: "image/png", data: picture}})
      expect(saved.id).toBe(id)
      secondImage = saved.image
      const refusals: Record<string, any> = (evidence.refusals = {})
      refusals.not_theirs = await refused(agent, other.draft, 404, "launch_draft_not_found")
      refusals.wrong_signer = await refused(agent, id, 403, "wrong_signer", {signer: people.b.wallet})
      await setPaused(kind, true)
      try {
        expect(await launchesPaused(kind)).toBe(true)
        refusals.paused = await refused(agent, id, 409, "launches_paused")
        refusals.not_theirs_paused = await refused(agent, other.draft, 404, "launch_draft_not_found")
        refusals.wrong_signer_paused = await refused(agent, id, 403, "wrong_signer", {signer: people.b.wallet})
      } finally {
        await setPaused(kind, false)
      }
      expect(kept(kind, id, second.symbol), "a refusal keeps no review").toEqual([])
      open = await prepared(agent, id)
      evidence.second_launch.open_again = open
      expect(open.facts).toMatchObject(listedLinks(reviewed))
    })

    await test.step("person first: the agent changes only the links after the person's review, and the listing keeps the person's", async () => {
      await page.goto("/create")
      await ready(page)
      await expect(page.locator("#agent-set-fields")).toContainText(second.name)
      const pageReview = await reviewOnPage(page)
      await page.goto("/")
      const [person] = persons(kept(kind, id, second.symbol))
      expect(person.review.facts).toMatchObject(listedLinks(reviewed))
      evidence.second_launch.page_review = pageReview
      evidence.second_launch.page_facts = person.review.facts

      save(agent, kind, relinked)
      const latest = await prepared(agent, id)
      evidence.second_launch.sent = latest
      expect(latest.facts).toMatchObject(listedLinks(relinked))
      expect(latest.steps, "the links are not in the launch, so the step is the page's").toEqual(pageReview.steps)
      expect(latest.chain).toEqual(pageReview.chain)
      expect(unlinked(latest.facts)).toEqual(unlinked(person.review.facts))
      expect(states(kept(kind, id, second.symbol)))
        .toEqual([["agent", "prepared"], ["person", "prepared"], ["agent", "prepared"]])

      const landed = await send(page, latest.steps[0])
      const auction = String(made(kind, landed).auction).toLowerCase()
      evidence.second_launch.transaction = {hash: landed.transactionHash, block: Number(BigInt(landed.blockNumber)), auction}

      const listing = await listed(second.symbol)
      expect(listing.address.toLowerCase()).toBe(auction)
      const row = auctionRow(auction)
      evidence.second_launch.listing = {listing, row}
      expect(row).toMatchObject({
        origin: "site", persons_account: true, creator_wallet: wallet, title: second.name, symbol: second.symbol,
        description: second.description, website: second.website, ...listedLinks(reviewed), image: secondImage,
      })
      expect(states(kept(kind, id, second.symbol)))
        .toEqual([["agent", "prepared"], ["person", "chain_verified"], ["agent", "prepared"]])
      evidence.second_launch.started_over = expectStartedOver(agent, kind)
    })

    await other.close()
    unpair("did:privy:journey-a", agent.address)
  } finally {
    if (await launchesPaused(kind)) await setPaused(kind, false)
    write(out, evidence)
  }
})
