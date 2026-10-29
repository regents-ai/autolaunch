import {readFileSync} from "node:fs"
import {encodeFunctionData, parseAbi, type Hex} from "viem"
import {balanceOf, call, mintStock, rpc, sendAs} from "./support/chain"
import {expect, fitsAndPresses, freshPerson, holdWallet, people, ready, signIn, test, type Sent} from "./support/person"
import type {Locator, Page} from "@playwright/test"

// Covered calls on AMZNc, end to end on the copy of Base with the deployed
// CoveredCallsV1 (base_fork.py covered-calls: the deployed contract's own code at its Base
// address). Person A lists three AMZNc as calls and stops selling what is left after B buys
// one, then the same one again. B is a wallet the site has never seen, made up for the run
// and signing in for the first time, unpaired: buying and exercising ask nothing of a wallet
// beyond what it holds. Each action is reviewed, then sent one wallet step at a time, and the
// page says what moved once the last step lands. In the 24 hours after
// Friday's expiry B exercises both while the issuer has stock transfers paused,
// B's stock waits while A still collects the strike, and once transfers resume B
// and A each collect their AMZNc. Feature map: operations/FEATURES.md, Wallet actions.
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
  "function held(uint256, address) view returns (uint256)",
  "function claimable(uint256, address) view returns (uint256)",
  "function listings(uint256) view returns ((address seller, uint64 expiry, bool stockReturned, uint256 amount, uint256 filled, uint256 exercised, uint256 strikePerToken, uint256 premiumPerToken, uint256 strikePaid, uint256 strikeCollected))",
  "function transfer(address, uint256) returns (bool)",
  "function setPaused(bool)",
])

const contract = (): string =>
  JSON.parse(readFileSync(`${process.env.STACK_STATE}/covered-calls.json`, "utf8")).markets[0].contract

const read = async (name: "listingCount" | "held" | "claimable", args: unknown[] = []) =>
  BigInt(await call(contract(), encodeFunctionData({abi, functionName: name, args: args as any}) as Hex))

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
 * The portfolio row of listing `id` on `side` ("sold" or "held"), once it offers the wallet step
 * `name`: reloading while the shared reading catches up after a press.
 */
async function row(page: Page, side: "sold" | "held", id: bigint, name: string): Promise<Locator> {
  const found = page.locator(`#portfolio-covered-calls-${side}-${id}`)
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
async function collect(page: Page, side: "sold" | "held", id: bigint, name: string, sent: Sent[]) {
  const found = await row(page, side, id, name)
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
  await page.goto("/covered-calls?tab=sell")
  await ready(page)
  await expect(page.getByText("Dividends during the week stay with the tokens.")).toBeVisible()
  // While on, the page's own styles are served (off, that address is not found: switched_off.spec.ts).
  const styles = await page.request.get("/assets/js/covered_calls.css")
  expect(styles.status()).toBe(200)
  expect(styles.headers()["content-type"]).toContain("text/css")
  expect(await styles.text()).toContain(".covered-calls__tabs")
  const unchanged = await page.request.get("/assets/js/covered_calls.css", {headers: {"if-none-match": styles.headers()["etag"]}})
  expect(unchanged.status(), "the browser's copy is kept while the file is the same").toBe(304)
  await page.getByLabel("Amount").fill("3")
  await page.getByLabel("Strike price").fill("300")
  await page.getByLabel("Premium").fill("3")
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
      await b.goto(`/covered-calls?listing=${id}`)
      await ready(b)
      return b.locator(`#covered-call-${id}`).count()
    }, {timeout: 60_000})
    .toBe(1)
  await expect(b.getByText("Available to eligible people outside the US.")).toBeVisible()
  await b.getByLabel("Amount").fill("1")
  await fitsAndPresses(b, touch)
  await review(b, "Buy calls")
  await fitsAndPresses(b, touch)
  await buttonsOnScreen(b)
  const aUsdcBefore = await balanceOf(USDC, people.a.wallet)
  expect((await press(b, bought, "Approve USDC")).status).toBe("0x1")
  expect((await press(b, bought, "Confirm purchase")).status).toBe("0x1")
  await expect(toast(b, "Bought")).toBeVisible()
  expect(await read("held", [id, fresh.wallet])).toBe(UNIT)
  // The form takes the amount left from the listing as it now reads.
  await expect(b.getByLabel("Amount")).toHaveValue("2")
  // The same purchase again is a review of its own: it starts at the approval, never "done".
  await b.getByLabel("Amount").fill("1")
  await review(b, "Buy calls")
  await expect(b.locator("[data-step=usdc_approval]")).toHaveAttribute("data-state", "ready")
  expect((await press(b, bought, "Approve USDC")).status).toBe("0x1")
  expect((await press(b, bought, "Confirm purchase")).status).toBe("0x1")
  await expect(b.locator(".token-swap__review:not([hidden])")).toHaveCount(0)
  expect(await read("held", [id, fresh.wallet])).toBe(2n * UNIT)
  // A received each 3 USDC premium less the 1% fee.
  expect((await balanceOf(USDC, people.a.wallet)) - aUsdcBefore).toBe(5_940_000n)

  // Person A stops selling the one left, from the portfolio.
  const selling = await row(page, "sold", id, "Stop selling")
  await review(selling, "Stop selling")
  expect((await press(selling, sent, "Confirm stop")).status).toBe("0x1")
  expect(await read("claimable", [id, people.a.wallet])).toBe(UNIT)

  // Friday's expiry passes; the issuer pauses AMZNc transfers.
  const expiry = await expiryOf(id)
  await warpTo(expiry + 60)
  await sendAs(USDC_HOLDER, AMZNC, encodeFunctionData({abi, functionName: "setPaused", args: [true]}))

  // B exercises both: only USDC moves, so the pause doesn't stop it.
  const held = await row(b, "held", id, "Exercise")
  await review(held, "Exercise")
  expect((await press(held, bought, "Approve USDC")).status).toBe("0x1")
  expect((await press(held, bought, "Confirm exercise")).status).toBe("0x1")
  expect(await read("claimable", [id, fresh.wallet])).toBe(2n * UNIT)

  // While paused, B's stock can't leave: the press reaches the wallet and reverts, and the page says so.
  expect((await collect(b, "held", id, "Collect AMZNc", bought)).status).toBe("0x0")
  await expect(b.getByText("That did not go through and nothing moved. Close this and review again.")).toBeVisible()

  // A still collects the 600 USDC strike during the pause.
  const aUsdc = await balanceOf(USDC, people.a.wallet)
  expect((await collect(page, "sold", id, "Collect USDC", sent)).status).toBe("0x1")
  expect((await balanceOf(USDC, people.a.wallet)) - aUsdc).toBe(600_000_000n)

  // Transfers resume after the window: B collects the stock bought, A the one never sold.
  await sendAs(USDC_HOLDER, AMZNC, encodeFunctionData({abi, functionName: "setPaused", args: [false]}))
  await warpTo(expiry + 86_400 + 60)
  const bStock = await balanceOf(AMZNC, fresh.wallet)
  expect((await collect(b, "held", id, "Collect AMZNc", bought)).status).toBe("0x1")
  expect((await balanceOf(AMZNC, fresh.wallet)) - bStock).toBe(2n * UNIT)

  expect((await collect(page, "sold", id, "Collect AMZNc", sent)).status).toBe("0x1")
  expect(await balanceOf(AMZNC, people.a.wallet)).toBe(aStock - 2n * UNIT)
  expect(await read("claimable", [id, people.a.wallet])).toBe(0n)

  await buyer.close()
  expect(outside, "requests that left the machine").toEqual([])
})
