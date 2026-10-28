import {encodeFunctionData, type Hex} from "viem"
import {Agent} from "./support/agent"
import {balanceOf, call, memestock, mineTo, mintStock} from "./support/chain"
import {AAPLC, launch} from "./support/launch"
import {pairWith, unpair} from "./support/pairing"
import {expect, holdWallet, people, ready, signIn, test, type Sent} from "./support/person"

// Part 2's auction, L7 and L8: the launch Person A signed runs on the copy of
// Base. On the desktop run Person B bids past the minimum, the auction graduates
// and B claims the tokens bought; on the phone run B bids under the minimum, the
// auction fails and B takes the whole bid back. Either way anyone may finish it,
// from its page. Feature map: operations/FEATURES.md, Wallet actions.
test.use({wallet: people.a.wallet})

async function read(auction: string, name: string): Promise<bigint> {
  const abi = memestock().abis.auction
  return BigInt(await call(auction, encodeFunctionData({abi, functionName: name as any, args: []}) as Hex))
}

// The card's next wallet step, pressed whether or not its review has arrived:
// a press before it asks the card for one and sends that.
const nextStep = (page: import("@playwright/test").Page) =>
  page.locator("[data-onchain-step]:visible:not([disabled])").first()

async function state(id: string): Promise<string> {
  return (await (await fetch(`${process.env.AUTOLAUNCH_URL}/api/v1/auctions/${id}`)).json()).data.state
}

test("L7-L8: the auction opens, takes bids or none, ends, and is finished from its page", async ({page, sent, browser}, info) => {
  const graduates = info.project.name === "desktop"
  await signIn(page, people.a)
  const agent = new Agent(`auction-${info.project.name}`)
  await pairWith(page, agent, `Auction ${info.project.name}`)
  const {draft, auction: path} = await launch(page, sent, agent, agent.address.slice(2, 6).toUpperCase())
  const listed = (await (await fetch(`${process.env.AUTOLAUNCH_URL}/api/v1/auctions?q=${draft.symbol}`)).json()).data[0]
  const auction = listed.address as string
  expect(await state(listed.id)).toBe("created")

  // L7: it opens at its start block, takes Person B's bid or none, and ends.
  await mineTo(Number(await read(auction, "startBlock")))
  await expect.poll(() => state(listed.id), {timeout: 120_000}).toBe("active")

  const bidder = await browser.newContext({...info.project.use, baseURL: process.env.AUTOLAUNCH_URL})
  const bids: Sent[] = []
  const outside = await holdWallet(bidder, process.env.AUTOLAUNCH_URL!, people.b.wallet, bids)
  const b = await bidder.newPage()
  await mintStock(AAPLC, people.b.wallet, 10n ** 8n)
  const held = await balanceOf(AAPLC, people.b.wallet)
  {
    await signIn(b, people.b)
    await b.goto(path)
    await ready(b)
    await b.locator(".bid-switch label", {hasText: "AAPLc"}).click()
    // The minimum raise is 0.26969531 AAPLc.
    await b.getByRole("textbox", {name: "Max budget"}).fill(graduates ? "0.5" : "0.1")
    // The max FDV it opens with, 10,000 AAPLc, sits far above the opening price.
    // Each wallet step the bid needs is its own press: approvals first, then the bid.
    const placed = b.locator(".bid-placed")
    for (let press = 0; press < 4 && !(await placed.isVisible()); press++) {
      const before = bids.length
      await nextStep(b).click()
      await expect.poll(() => bids.length, {timeout: 30_000}).toBeGreaterThan(before)
      await b.waitForTimeout(1_000)
    }
    await expect(placed).toBeVisible({timeout: 60_000})
  }

  await mineTo(Number(await read(auction, "endBlock")))
  await expect.poll(() => state(listed.id), {timeout: 120_000}).toBe("ended")

  // L8: from its migration block anyone may finish it, here Person B from the page.
  await mineTo(Number(await read(auction, "claimBlock")) + 200)
  await b.goto(path)
  await ready(b)
  await b.getByRole("button", {name: /^Finish/}).click()
  await expect.poll(() => state(listed.id), {timeout: 120_000}).toBe(graduates ? "graduated" : "failed")

  if (graduates) {
    // Person B claims the tokens they bought, from the auction's page.
    const token = `0x${(await read(auction, "token")).toString(16).padStart(40, "0")}`
    expect(await balanceOf(token, people.b.wallet)).toBe(0n)
    await b.goto(path)
    await ready(b)
    const claims = bids.length
    for (let press = 0; press < 3 && (await balanceOf(token, people.b.wallet)) === 0n; press++) {
      await nextStep(b).click()
      await expect.poll(() => bids.length, {timeout: 30_000}).toBeGreaterThan(claims + press)
    }
    expect(await balanceOf(token, people.b.wallet)).toBeGreaterThan(0n)
  } else {
    // Below the minimum every bidder takes back their whole bid, from the page.
    expect(await balanceOf(AAPLC, people.b.wallet)).toBeLessThan(held)
    await b.goto(path)
    await ready(b)
    const returns = bids.length
    for (let press = 0; press < 3 && (await balanceOf(AAPLC, people.b.wallet)) < held; press++) {
      await nextStep(b).click()
      await expect.poll(() => bids.length, {timeout: 30_000}).toBeGreaterThan(returns + press)
    }
    expect(await balanceOf(AAPLC, people.b.wallet)).toBe(held)
  }

  await bidder.close()
  expect(outside, "requests that left the machine").toEqual([])
  unpair("did:privy:journey-a", agent.address)
})
