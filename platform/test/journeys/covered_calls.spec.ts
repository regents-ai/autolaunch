import {readFileSync} from "node:fs"
import {decodeFunctionResult, encodeFunctionData, parseAbi, type Hex} from "viem"
import {balanceOf, call, mintStock, rpc, sendAs} from "./support/chain"
import {expect, fitsAndPresses, freshPerson, holdWallet, people, ready, signIn, test, type Sent} from "./support/person"
import type {Locator, Page} from "@playwright/test"

// Covered calls on AMZNc, end to end on the copy of Base with a CoveredCallsV2
// (base_fork.py covered-calls: deployed on the copy for AMZNc, Base's USDC and live REGENT
// staking). Person A lists three AMZNc as calls and stops selling what is left after B buys
// one, then the same one again. B is a wallet the site has never seen, made up for the run
// and signing in for the first time, unpaired: buying and exercising ask nothing of a wallet
// beyond what it holds. Each action is reviewed, then sent one wallet step at a time, and the
// page says what moved once the last step lands. In the 24 hours after
// Friday's expiry B exercises both while the issuer has stock transfers paused,
// B's stock waits while A still collects the strike, and once transfers resume B
// and A each collect their AMZNc.
//
// The second journey is a bid. A wallet the site has never seen finds nothing for sale and bids
// for three calls from Buy's Bid ticket. Person A sells two into it from Sell's Bids and is paid
// at once exactly what the ticket said; the bidder raises the bid, stops it and refunds exactly
// the escrow its row showed, then exercises the calls the sale made in their window and collects
// the stock. Feature map: operations/FEATURES.md, Wallet actions.
//
// The journey moves the copy's clock past expiry, so it puts the copy back the way it found it
// when it ends: later journeys' stock prices would otherwise read as days old.
test.use({wallet: people.a.wallet})

let snapshot: string
test.beforeEach(async () => {
  snapshot = await rpc("evm_snapshot")
})
test.afterEach(async () => {
  expect(await rpc("evm_revert", [snapshot]), "the copy of Base is put back").toBe(true)
})

const AMZNC = "0xb200000000000000000000d9192b6b456483c2e8"
const USDC = "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913"
const USDC_HOLDER = "0xbbbbbbbbbb9cc5e90e3b3af64bdaf62c37eeffcb"
const UNIT = 10n ** 8n

const abi = parseAbi([
  "function listingCount() view returns (uint256)",
  "function bidCount() view returns (uint256)",
  "function held(uint256, address) view returns (uint256)",
  "function claimable(uint256, address) view returns (uint256)",
  "function listings(uint256) view returns ((address seller, uint64 expiry, bool stockReturned, uint256 amount, uint256 filled, uint256 exercised, uint256 strikePerToken, uint256 premiumPerToken, uint256 strikePaid, uint256 strikeCollected))",
  "function bids(uint256) view returns ((address bidder, uint64 expiry, uint256 amount, uint256 filled, uint256 strikePerToken, uint256 premiumPerToken, uint256 minSale, uint256 refundDue))",
  "function transfer(address, uint256) returns (bool)",
  "function setPaused(bool)",
])

const contract = (): string =>
  JSON.parse(readFileSync(`${process.env.STACK_STATE}/covered-calls.json`, "utf8")).markets[0].contract

const read = async (name: "listingCount" | "bidCount" | "held" | "claimable", args: unknown[] = []) =>
  BigInt(await call(contract(), encodeFunctionData({abi, functionName: name, args: args as any}) as Hex))

async function bidOf(id: bigint) {
  const data = await call(contract(), encodeFunctionData({abi, functionName: "bids", args: [id]}) as Hex)
  return decodeFunctionResult({abi, functionName: "bids", data})
}

/** A figure the page shows in dollars ("$5.94"), in micro-USDC. */
const usdc = (text: string): bigint => units(text.trim().replace(/^\$/, "").replaceAll(",", ""), 6)

/**
 * A receipt figure in micro-USDC, read once it is plain again: while a figure
 * rolls to a new value its characters are split into moving pieces.
 */
async function dollars(figure: Locator): Promise<bigint> {
  let text = ""
  await expect
    .poll(async () => (text = ((await figure.textContent()) ?? "").trim()), {timeout: 60_000})
    .toMatch(/^\$[\d,]+\.\d{2}$/)
  return usdc(text)
}

/** A decimal amount as typed or shown ("1.5"), in raw units of `decimals`. */
function units(text: string, decimals: number): bigint {
  const [whole, fraction = ""] = text.split(".")
  return BigInt(whole + fraction.padEnd(decimals, "0"))
}

async function expiryOf(id: bigint): Promise<number> {
  const words = await call(contract(), encodeFunctionData({abi, functionName: "listings", args: [id]}) as Hex)
  return Number(BigInt("0x" + words.slice(2 + 64, 2 + 128)))
}

/** Moves the copy's clock to `at` (a Unix time) and mines a block there. */
async function warpTo(at: number) {
  await rpc("evm_setNextBlockTimestamp", [`0x${at.toString(16)}`])
  await rpc("evm_mine")
}

/**
 * Every wallet button on the page sits wholly on screen, so a person never scrolls sideways to
 * find one (at 390 the Buy panel once sat inside a sideways-scrolling table).
 */
async function buttonsOnScreen(page: Page) {
  const off = await page.evaluate(() =>
    [...document.querySelectorAll<HTMLElement>("[data-onchain-step]")]
      .filter(el => el.offsetParent !== null)
      .filter(el => {
        const box = el.getBoundingClientRect()
        return box.left < 0 || box.right > document.documentElement.clientWidth
      })
      .map(el => el.textContent!.trim()),
  )
  expect(off, "wallet buttons off the side of the screen").toEqual([])
}

/**
 * Presses the panel's own button (List calls, Buy calls, Stop selling...) in `scope`, which
 * reviews the action and opens its wallet steps over the form, as Stake does on a token page.
 */
async function review(scope: Page | Locator, name: string) {
  const button = scope.getByRole("button", {name, exact: true})
  await expect(button).toBeEnabled({timeout: 60_000})
  await button.click()
  await expect(scope.locator(".token-swap__review:not([hidden])")).toHaveCount(1)
}

/** The note the panel shows once the chain confirms its last step. */
const toast = (page: Page, title: string) => page.locator(".token-swap__toast", {hasText: title})

/** Presses the named wallet step in `scope` once it can be pressed, and waits for its transaction to land. */
async function press(scope: Page | Locator, sent: Sent[], name: string) {
  const button = scope.getByRole("button", {name, exact: true})
  await expect(button).toBeEnabled({timeout: 60_000})
  const before = sent.length
  await button.click()
  await expect.poll(() => sent.length, {timeout: 60_000}).toBeGreaterThan(before)
  const mined = await waitFor(sent[sent.length - 1].hash)
  return mined
}

/**
 * The portfolio row `key` ("sold-<listing>", "held-<listing>" or "bid-<bid>"), once it offers the
 * wallet step `name`: reloading while the shared reading catches up after a press.
 */
async function row(page: Page, key: string, name: string): Promise<Locator> {
  const found = page.locator(`#portfolio-covered-calls-${key}`)
  await expect
    .poll(async () => {
      await page.goto("/portfolio")
      await ready(page)
      return found.getByRole("button", {name, exact: true}).count()
    }, {timeout: 60_000})
    .toBeGreaterThan(0)
  await buttonsOnScreen(page)
  return found
}

/** Collects from the portfolio row: the row's button reviews it, the wallet step sends it. */
async function collect(page: Page, key: string, name: string, sent: Sent[]) {
  const found = await row(page, key, name)
  await review(found, name)
  return press(found, sent, "Confirm collection")
}

async function waitFor(hash: string): Promise<any> {
  for (let i = 0; i < 120; i++) {
    const found = await rpc("eth_getTransactionReceipt", [hash])
    if (found) return found
    await new Promise(r => setTimeout(r, 250))
  }
  throw new Error(`no receipt for ${hash}`)
}

test("covered calls: list, buy, stop selling, exercise through a pause, collect stock and USDC", async ({page, sent, browser}, info) => {
  const touch = info.project.name === "phone"
  await mintStock(AMZNC, people.a.wallet, 3n * UNIT)
  const aStock = await balanceOf(AMZNC, people.a.wallet)

  // Person A lists three AMZNc as calls at a 300 USDC strike and a 3 USDC premium.
  await signIn(page, people.a)
  await page.goto("/stock/covered-call")
  await ready(page)
  await page.getByRole("button", {name: "About the amount"}).click()
  await expect(page.getByText(/Dividends during the week stay with the tokens/)).toBeVisible()
  // While on, the page's own styles are served (off, that address is not found: switched_off.spec.ts).
  const styles = await page.request.get("/assets/js/covered_calls.css")
  expect(styles.status()).toBe(200)
  expect(styles.headers()["content-type"]).toContain("text/css")
  expect(await styles.text()).toContain(".covered-calls__tabs")
  const unchanged = await page.request.get("/assets/js/covered_calls.css", {headers: {"if-none-match": styles.headers()["etag"]}})
  expect(unchanged.status(), "the browser's copy is kept while the file is the same").toBe(304)
  await page.getByLabel("Amount", {exact: true}).fill("3")
  await page.getByRole("button", {name: "Custom", exact: true}).click()
  await page.getByLabel("Custom strike").fill("300")
  await page.getByLabel("Premium", {exact: true}).fill("3")
  await fitsAndPresses(page, touch)
  await review(page, "List calls")
  await fitsAndPresses(page, touch)
  await buttonsOnScreen(page)
  expect((await press(page, sent, "Approve AMZNc")).status).toBe("0x1")
  expect((await press(page, sent, "Confirm listing")).status).toBe("0x1")
  await expect(toast(page, "Listed")).toBeVisible()
  const id = await read("listingCount")
  expect(await balanceOf(AMZNC, people.a.wallet)).toBe(aStock - 3n * UNIT)

  // B, a wallet the site has never seen, buys one of them from the Buy tab, then one more.
  const fresh = await freshPerson()
  await sendAs(USDC_HOLDER, USDC, encodeFunctionData({abi, functionName: "transfer", args: [fresh.wallet as Hex, 1_000n * 10n ** 6n]}))
  const buyer = await browser.newContext({...info.project.use, baseURL: process.env.AUTOLAUNCH_URL})
  const bought: Sent[] = []
  const outside = await holdWallet(buyer, process.env.AUTOLAUNCH_URL!, fresh.wallet, bought)
  const b = await buyer.newPage()
  await signIn(b, fresh)
  await expect
    .poll(async () => {
      await b.goto(`/stock/covered-call?listing=${id}`)
      await ready(b)
      return b.locator(`#covered-call-${id}`).count()
    }, {timeout: 60_000})
    .toBe(1)
  await expect(b.getByText("Available to eligible people outside the US.")).toBeVisible()
  await b.getByLabel("Amount", {exact: true}).fill("1")
  await fitsAndPresses(b, touch)
  await review(b, "Buy calls")
  await fitsAndPresses(b, touch)
  await buttonsOnScreen(b)
  const aUsdcBefore = await balanceOf(USDC, people.a.wallet)
  expect((await press(b, bought, "Approve USDC")).status).toBe("0x1")
  expect((await press(b, bought, "Confirm purchase")).status).toBe("0x1")
  await expect(toast(b, "Bought")).toBeVisible()
  expect(await read("held", [id, fresh.wallet])).toBe(UNIT)
  // The ticket takes the amount left from the listing as it now reads.
  await expect(b.getByLabel("Amount", {exact: true})).toHaveValue("2")
  // The same purchase again is a review of its own: it starts at the approval, never "done".
  await b.getByLabel("Amount", {exact: true}).fill("1")
  await review(b, "Buy calls")
  await expect(b.locator("[data-step=usdc_approval]")).toHaveAttribute("data-state", "ready")
  expect((await press(b, bought, "Approve USDC")).status).toBe("0x1")
  expect((await press(b, bought, "Confirm purchase")).status).toBe("0x1")
  await expect(b.locator(".token-swap__review:not([hidden])")).toHaveCount(0)
  expect(await read("held", [id, fresh.wallet])).toBe(2n * UNIT)
  // A received each 3 USDC premium less the 1% fee.
  expect((await balanceOf(USDC, people.a.wallet)) - aUsdcBefore).toBe(5_940_000n)

  // Person A stops selling the one left, from the portfolio.
  const selling = await row(page, `sold-${id}`, "Stop selling")
  await review(selling, "Stop selling")
  expect((await press(selling, sent, "Confirm stop")).status).toBe("0x1")
  expect(await read("claimable", [id, people.a.wallet])).toBe(UNIT)

  // Friday's expiry passes; the issuer pauses AMZNc transfers.
  const expiry = await expiryOf(id)
  await warpTo(expiry + 60)
  await sendAs(USDC_HOLDER, AMZNC, encodeFunctionData({abi, functionName: "setPaused", args: [true]}))

  // B exercises both: only USDC moves, so the pause doesn't stop it.
  const held = await row(b, `held-${id}`, "Exercise")
  await review(held, "Exercise")
  expect((await press(held, bought, "Approve USDC")).status).toBe("0x1")
  expect((await press(held, bought, "Confirm exercise")).status).toBe("0x1")
  expect(await read("claimable", [id, fresh.wallet])).toBe(2n * UNIT)

  // While paused, B's stock can't leave: the press reaches the wallet and reverts, and the page says so.
  expect((await collect(b, `held-${id}`, "Collect AMZNc", bought)).status).toBe("0x0")
  await expect(b.getByText("That did not go through and nothing moved.").first()).toBeVisible()

  // A still collects the 600 USDC strike during the pause.
  const aUsdc = await balanceOf(USDC, people.a.wallet)
  expect((await collect(page, `sold-${id}`, "Collect USDC", sent)).status).toBe("0x1")
  expect((await balanceOf(USDC, people.a.wallet)) - aUsdc).toBe(600_000_000n)

  // Transfers resume after the window: B collects the stock bought, A the one never sold.
  await sendAs(USDC_HOLDER, AMZNC, encodeFunctionData({abi, functionName: "setPaused", args: [false]}))
  await warpTo(expiry + 86_400 + 60)
  const bStock = await balanceOf(AMZNC, fresh.wallet)
  expect((await collect(b, `held-${id}`, "Collect AMZNc", bought)).status).toBe("0x1")
  expect((await balanceOf(AMZNC, fresh.wallet)) - bStock).toBe(2n * UNIT)

  expect((await collect(page, `sold-${id}`, "Collect AMZNc", sent)).status).toBe("0x1")
  expect(await balanceOf(AMZNC, people.a.wallet)).toBe(aStock - 2n * UNIT)
  expect(await read("claimable", [id, people.a.wallet])).toBe(0n)

  await buyer.close()
  expect(outside, "requests that left the machine").toEqual([])
})

test("covered-call bids: bid, sell into it, raise, stop, refund, exercise and collect", async ({page, sent, browser}, info) => {
  const touch = info.project.name === "phone"

  // B, a wallet the site has never seen, bids for three AMZNc calls at a 300 USDC strike and a
  // 3 USDC premium, from the Bid side of Buy.
  const fresh = await freshPerson()
  await sendAs(USDC_HOLDER, USDC, encodeFunctionData({abi, functionName: "transfer", args: [fresh.wallet as Hex, 1_000n * 10n ** 6n]}))
  const bidder = await browser.newContext({...info.project.use, baseURL: process.env.AUTOLAUNCH_URL})
  const bidding: Sent[] = []
  const outside = await holdWallet(bidder, process.env.AUTOLAUNCH_URL!, fresh.wallet, bidding)
  const b = await bidder.newPage()
  await signIn(b, fresh)
  await b.goto("/stock/covered-call?tab=buy")
  await ready(b)
  await b.getByRole("button", {name: "Bid", exact: true}).click()
  await expect(b).toHaveURL(/[?]tab=bid$/)
  await b.getByLabel("Amount", {exact: true}).fill("3")
  await b.getByRole("button", {name: "Custom", exact: true}).click()
  await b.getByLabel("Custom strike").fill("300")
  await b.getByLabel("Premium", {exact: true}).fill("3")
  await expect(b.locator("#covered-calls-bid-pay")).toHaveText("$9.00")
  await expect(b.locator("#covered-calls-bid-exercise")).toHaveText("$900.00")
  await fitsAndPresses(b, touch)
  await review(b, "Place bid")
  await fitsAndPresses(b, touch)
  await buttonsOnScreen(b)
  const bUsdcBefore = await balanceOf(USDC, fresh.wallet)
  expect((await press(b, bidding, "Approve USDC")).status).toBe("0x1")
  expect((await press(b, bidding, "Confirm bid")).status).toBe("0x1")
  await expect(toast(b, "Bid placed")).toBeVisible()
  const bidId = await read("bidCount")
  expect(bUsdcBefore - (await balanceOf(USDC, fresh.wallet)), "the escrow is what the ticket said").toBe(9_000_000n)
  expect((await bidOf(bidId)).minSale, "the page's minimum sale: one whole token").toBe(UNIT)

  // Person A finds the bid under Sell and sells two calls into it.
  await mintStock(AMZNC, people.a.wallet, 2n * UNIT)
  await signIn(page, people.a)
  const listed = page.locator(`#covered-call-bids-${bidId}`)
  await expect
    .poll(async () => {
      await page.goto("/stock/covered-call")
      await ready(page)
      return listed.count()
    }, {timeout: 60_000})
    .toBe(1)
  await expect(listed).toContainText("3 AMZNc")
  await fitsAndPresses(page, touch)
  await listed.getByRole("link", {name: "Sell", exact: true}).click()
  await expect(page).toHaveURL(new RegExp(`[?]bid=${bidId}$`))
  const ticket = page.locator(`#covered-call-sell-${bidId}`)
  const amount = ticket.getByLabel("Amount", {exact: true})
  const aStock = await balanceOf(AMZNC, people.a.wallet)
  await ticket.getByRole("button", {name: "Max", exact: true}).click()
  await expect.poll(async () => units(await amount.inputValue(), 8)).toBe(aStock < 3n * UNIT ? aStock : 3n * UNIT)
  await amount.fill("2")
  const promised = await dollars(ticket.locator(`#covered-call-sell-${bidId}-receive`))
  expect(promised, "2 calls at a 3 USDC premium, less the 1% fee").toBe(5_940_000n)
  await fitsAndPresses(page, touch)
  await review(ticket, "Sell now")
  await fitsAndPresses(page, touch)
  await buttonsOnScreen(page)
  expect((await press(ticket, sent, "Approve AMZNc")).status).toBe("0x1")
  const aUsdc = await balanceOf(USDC, people.a.wallet)
  expect((await press(ticket, sent, "Confirm sale")).status).toBe("0x1")
  expect((await balanceOf(USDC, people.a.wallet)) - aUsdc, "paid in the sale's own transaction").toBe(promised)
  await expect(toast(page, "Sold")).toBeVisible()
  const id = await read("listingCount")
  expect(await read("held", [id, fresh.wallet])).toBe(2n * UNIT)
  expect(await balanceOf(AMZNC, people.a.wallet)).toBe(aStock - 2n * UNIT)

  // B raises the bid by two more from the portfolio.
  let mine = await row(b, `bid-${bidId}`, "Raise")
  await expect(mine.locator(`#portfolio-covered-calls-bid-${bidId}-sold`)).toContainText("2 of 3 AMZNc")
  await mine.getByLabel("Amount", {exact: true}).fill("2")
  await review(mine, "Raise")
  await buttonsOnScreen(b)
  let bUsdc = await balanceOf(USDC, fresh.wallet)
  expect((await press(mine, bidding, "Approve USDC")).status).toBe("0x1")
  expect((await press(mine, bidding, "Confirm raise")).status).toBe("0x1")
  expect(bUsdc - (await balanceOf(USDC, fresh.wallet)), "two more calls' premium").toBe(6_000_000n)
  expect((await bidOf(bidId)).amount).toBe(5n * UNIT)

  // Then stops it, and refunds exactly the escrow its row showed for the three unsold.
  const sold = b.locator(`#portfolio-covered-calls-bid-${bidId}-sold`)
  await expect
    .poll(async () => {
      await b.goto("/portfolio")
      await ready(b)
      return (await sold.count()) ? sold.innerText() : ""
    }, {timeout: 60_000})
    .toContain("2 of 5 AMZNc")
  mine = b.locator(`#portfolio-covered-calls-bid-${bidId}`)
  const escrow = usdc(await mine.locator(`#portfolio-covered-calls-bid-${bidId}-escrow > span`).first().innerText())
  expect(escrow).toBe(9_000_000n)
  await review(mine, "Stop")
  expect((await press(mine, bidding, "Confirm stop")).status).toBe("0x1")
  expect((await bidOf(bidId)).refundDue).toBe(escrow)

  mine = await row(b, `bid-${bidId}`, "Refund")
  await expect(mine.locator(`#portfolio-covered-calls-bid-${bidId}-escrow`)).toHaveCount(0)
  expect(usdc(await mine.locator(`#portfolio-covered-calls-bid-${bidId}-refund > span`).first().innerText())).toBe(escrow)
  await fitsAndPresses(b, touch)
  await review(mine, "Refund")
  bUsdc = await balanceOf(USDC, fresh.wallet)
  expect((await press(mine, bidding, "Confirm refund")).status).toBe("0x1")
  expect((await balanceOf(USDC, fresh.wallet)) - bUsdc, "the unspent escrow, exactly").toBe(escrow)
  expect((await bidOf(bidId)).refundDue).toBe(0n)

  // Friday's expiry passes: in the window B exercises the two calls the sale made, then collects the stock.
  await warpTo(Number((await bidOf(bidId)).expiry) + 60)
  const held = await row(b, `held-${id}`, "Exercise")
  await review(held, "Exercise")
  expect((await press(held, bidding, "Approve USDC")).status).toBe("0x1")
  expect((await press(held, bidding, "Confirm exercise")).status).toBe("0x1")
  expect(await read("claimable", [id, fresh.wallet])).toBe(2n * UNIT)
  const bStock = await balanceOf(AMZNC, fresh.wallet)
  expect((await collect(b, `held-${id}`, "Collect AMZNc", bidding)).status).toBe("0x1")
  expect((await balanceOf(AMZNC, fresh.wallet)) - bStock).toBe(2n * UNIT)

  await bidder.close()
  expect(outside, "requests that left the machine").toEqual([])
})
