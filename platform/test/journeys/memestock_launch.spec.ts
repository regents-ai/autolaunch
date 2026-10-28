import {readFileSync} from "node:fs"
import {decodeFunctionData, type Hex} from "viem"
import {Agent} from "./support/agent"
import {launchCreated, memestock, receipt} from "./support/chain"
import {pairWith, unpair} from "./support/pairing"
import {onSite} from "./support/site"
import {expect, fitsAndPresses, people, ready, signIn, test} from "./support/person"

// Part 2 of the agent test plan, in the shape Autolaunch has: a paired agent fills
// in the whole Memestock draft (text, picture, chain and stock), and its person
// reviews it on /create and signs the one launch step with their own wallet, on
// the copy of Base. Feature map: operations/FEATURES.md, Agents and Wallet actions.
test.use({wallet: people.a.wallet})

const AAPLC = "0xb200000000000000000000c2e324d24d7eecd1fb"
const picture = readFileSync("test/support/fixtures/launch-draft.png").toString("base64")

test("L1-L6: the agent fills in the whole draft, the person reviews it and signs exactly that launch", async ({page, sent}, info) => {
  const touch = info.project.name === "phone"
  await signIn(page, people.a)
  const agent = new Agent(`launch-${info.project.name}`)
  await pairWith(page, agent, `Launcher ${info.project.name}`)
  const tag = agent.address.slice(2, 6).toUpperCase()
  const draft = {
    name: `Agent Apple ${tag}`,
    symbol: `AA${tag}`,
    description: "A memestock its agent filled in and its person launched.",
    website: "https://example.com",
    chain: "base",
    stock_address: AAPLC,
  }

  // L1: the person's stock picker offers exactly the stocks the launchpad admits.
  await page.goto("/create")
  await ready(page)
  const admitted = JSON.parse(readFileSync("../contracts/stocks-v2/deployments/base-mainnet/deployed-manifest.json", "utf8"))
    .admissions.map((admission: any) => admission.symbol).sort()
  await expect.poll(async () => [...new Set(await page.locator(".stock-select__symbol").allTextContents())].sort())
    .toEqual(admitted)

  // L2: the agent saves the whole draft, picture included; what is too big is refused whole.
  const tooLong = agent.autolaunch(["drafts", "memestock", "save"], {name: "x".repeat(65)})
  expect(tooLong.json.error?.code, tooLong.stdout).toBe("invalid_draft")
  const saved = agent.autolaunch(["drafts", "memestock", "save"], {...draft, image: {content_type: "image/png", data: picture}})
  expect(saved.status, saved.stdout).toBe(0)
  expect(saved.json.data).toMatchObject({...draft, chain: "base"})
  expect(saved.json.data.agent_set_fields.sort()).toEqual(["description", "image", "name", "stock_address", "symbol", "website"])

  // The open page shows the save without a reload, and names every field the agent set.
  const named = page.locator("#agent-set-fields")
  await expect(named).toContainText(draft.name)
  for (const value of [draft.symbol, draft.description, draft.website]) await expect(named).toContainText(value)
  await expect(named.locator(`[data-copy-text='${AAPLC}']`)).toBeAttached()
  await fitsAndPresses(page, touch)

  // L3: the person reviews it: the fixed terms, from this wallet, on this chain.
  await page.getByRole("button", {name: "Review launch"}).click()
  const create = page.getByRole("button", {name: /Create the launch/i})
  await expect(create).toBeVisible()
  const card = create.locator("xpath=ancestor::*[@phx-hook='OnchainSteps'][1]")
  for (const term of [draft.name, draft.symbol, "AAPLc"]) await expect(card).toContainText(term)
  await fitsAndPresses(page, touch)

  // L4: the press hands the person's wallet exactly one transaction: the reviewed launch.
  await create.click()
  await expect.poll(() => sent.length).toBe(1)
  const [launch] = sent
  const {launchpad} = memestock().addresses
  expect(launch).toMatchObject({from: people.a.wallet, to: launchpad, value: "0x0"})
  const call = decodeFunctionData({abi: memestock().abis.launchpad, data: launch.data as Hex})
  expect(call.functionName).toBe("launch")
  const [params] = call.args as [any]
  expect({name: params.name, symbol: params.symbol, description: params.description, website: params.website, stock: params.stock.toLowerCase()})
    .toEqual({name: draft.name, symbol: draft.symbol, description: draft.description, website: draft.website, stock: AAPLC})
  expect(params.image).toBe(saved.json.data.image)

  // L5: the launchpad records the person's wallet and the reviewed stock, and the card says it is made.
  const created = launchCreated(await receipt(launch.hash))
  expect(String(created.launcher).toLowerCase()).toBe(people.a.wallet)
  expect(String(created.stock).toLowerCase()).toBe(AAPLC)
  // One launch per review: the page's confirmation and discovery, repeated and at once, list it once.
  const again = JSON.parse(onSite("confirm_again.exs", {
    JOURNEY_LAUNCHER: people.a.wallet, JOURNEY_SYMBOL: draft.symbol, JOURNEY_LAUNCH_HASH: launch.hash,
  }).split("JOURNEY_RESULT ")[1].split("\n")[0])
  expect(new Set(again.answers.map((answer: any) => answer.auction)).size).toBe(1)
  expect(again.auction_rows).toBe(1)
  expect(again.review_state).toBe("chain_verified")

  const launched = page.locator(".launch-placed")
  await expect(launched).toContainText(`Your token ${draft.symbol} is launched.`, {timeout: 60_000})
  await expect(launched).toContainText(launch.hash)

  // L6: the card links its auction once the site lists it, and /auctions lists it too.
  const open = launched.getByRole("link", {name: "Open the auction"})
  await expect(open).toBeVisible({timeout: 60_000})
  await open.click()
  await ready(page)
  await expect(page.locator("main")).toContainText(draft.symbol)
  // Measured once the bid form has read the person's balance, which adds its own press.
  await expect(page.locator(".bid-box__balance")).toBeVisible({timeout: 30_000})
  await fitsAndPresses(page, touch)
  const auctions = await (await fetch(`${process.env.AUTOLAUNCH_URL}/api/v1/auctions?q=${draft.symbol}`)).json()
  expect(auctions.data.map((auction: any) => auction.token_symbol)).toEqual([draft.symbol])
  expect(sent, "the person's wallet was asked for one transaction in all").toHaveLength(1)
  unpair("did:privy:journey-a", agent.address)
})
