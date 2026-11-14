import {readFileSync} from "node:fs"
import {encodeFunctionData, formatUnits, parseAbi, type Hex} from "viem"
import {balanceOf, call, mintStock, rpc, sendAs} from "./support/chain"
import {expect, fitsAndPresses, people, ready, signIn, test, type Sent} from "./support/person"
import type {Page} from "@playwright/test"

// Isolated Exposure to After-hours Stocks on AMZNc, end to end on the copy of Base, against the
// weekly factory and its stand-in feed (base_fork.py exposure). The journey moves the copy's clock
// to the start of next week, which nobody has opened. Person A's deposit opens it; a holder opens
// a pool for each token; A buys After-hours and sells it back; the clock passes the Monday open and
// A presses Update prices; A redeems pairs; the clock passes the week's last close and A redeems
// each token on its own for its share of the stock. Every press goes through the page's own wallet
// buttons. Feature map: operations/FEATURES.md, Isolated Exposure to After-hours Stocks.
//
// The journey moves the copy's clock, so it puts the copy back the way it found it when it ends.
test.use({wallet: people.a.wallet})

let snapshot: string
test.beforeEach(async () => {
  snapshot = await rpc("evm_snapshot")
})
test.afterEach(async () => {
  expect(await rpc("evm_revert", [snapshot]), "the copy of Base is put back").toBe(true)
})

const AMZNC = "0xb200000000000000000000d9192b6b456483c2e8"
const UNIT = 10n ** 8n
const USDC = "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913"
const USDC_HOLDER = "0xbbbbbbbbbb9cc5e90e3b3af64bdaf62c37eeffcb"
const ROUTER = "0xcf77a3ba9a5ca399b7c97c74d54e5b1beb874e43"
const POOL_PAIR = UNIT / 5n

const abi = parseAbi([
  "function approve(address,uint256) returns (bool)",
  "function transfer(address,uint256) returns (bool)",
  "function addLiquidity(address,address,bool,uint256,uint256,uint256,uint256,address,uint256) returns (uint256,uint256,uint256)",
  "function currentWeek() view returns (uint256)",
  "function startOf(uint256) view returns (uint64)",
  "function seriesOf(uint256) view returns (address)",
  "function predictSeries(uint256) view returns (address)",
  "function deposit(uint256,uint256) returns (address)",
  "function overnight() view returns (address)",
  "function session() view returns (address)",
  "function boundaries(uint256) view returns (uint64)",
  "function boundaryCount() view returns (uint256)",
  "function maturityAt() view returns (uint64)",
  "function settled() view returns (uint64)",
  "function status() view returns (uint8)",
  "function previewRedeem(uint256,uint256) view returns (uint256)",
  "function symbol() view returns (string)",
])

const data = (functionName: string, args: unknown[] = []) => encodeFunctionData({abi, functionName, args} as any) as Hex

/** A number read from `to`. */
async function read(to: string, functionName: string, args: unknown[] = []): Promise<bigint> {
  return BigInt(await call(to, data(functionName, args)))
}

/** An address read from `to`, as 0x and forty lowercase hex digits. */
async function address(to: string, functionName: string, args: unknown[] = []): Promise<string> {
  return `0x${(await call(to, data(functionName, args))).slice(26)}`
}

async function symbol(token: string): Promise<string> {
  const word = await call(token, data("symbol"))
  const length = Number(BigInt(`0x${word.slice(66, 130)}`))
  return Buffer.from(word.slice(130, 130 + length * 2), "hex").toString("utf8")
}

const factory = (): string => JSON.parse(readFileSync(`${process.env.STACK_STATE}/exposure.json`, "utf8")).factory

/** Moves the copy's clock to `at` (a Unix time) and mines a block there. */
async function warpTo(at: bigint) {
  await rpc("evm_setNextBlockTimestamp", [`0x${at.toString(16)}`])
  await rpc("evm_mine")
}

/** Opens a pool for each token against USDC, 0.2 of it beside 25 USDC, from a funded holder who deposits for them. */
async function seedPools(week: bigint, overnight: string, session: string) {
  await mintStock(AMZNC, USDC_HOLDER, POOL_PAIR)
  await sendAs(USDC_HOLDER, AMZNC, data("approve", [factory(), POOL_PAIR]))
  await sendAs(USDC_HOLDER, factory(), data("deposit", [week, POOL_PAIR]))
  for (const token of [overnight, session]) {
    await sendAs(USDC_HOLDER, token, data("approve", [ROUTER, POOL_PAIR]))
    await sendAs(USDC_HOLDER, USDC, data("approve", [ROUTER, 25_000_000n]))
    await sendAs(USDC_HOLDER, ROUTER, data("addLiquidity", [token, USDC, false, POOL_PAIR, 25_000_000n, 0n, 0n, USDC_HOLDER, 2n ** 40n]))
  }
}

/** Every wallet button on the page sits wholly on screen. */
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

async function waitFor(hash: string): Promise<any> {
  for (let i = 0; i < 120; i++) {
    const found = await rpc("eth_getTransactionReceipt", [hash])
    if (found) return found
    await new Promise(r => setTimeout(r, 250))
  }
  throw new Error(`no receipt for ${hash}`)
}

/** Presses the named wallet step on the page once it can be pressed, and waits for its transaction to land. */
async function press(page: Page, sent: Sent[], name: string) {
  const button = page.getByRole("button", {name, exact: true})
  await expect(button).toBeEnabled({timeout: 60_000})
  const before = sent.length
  await button.click()
  await expect.poll(() => sent.length, {timeout: 60_000}).toBeGreaterThan(before)
  return waitFor(sent[sent.length - 1].hash)
}

/** Opens the page fresh and waits for the week to be read. */
async function open(page: Page, path = "/stock/isolated-afters") {
  await page.goto(path)
  await ready(page)
  await expect(page.locator("#exposure-status")).toBeVisible({timeout: 30_000})
}

test("after-hours exposure: open a week with a deposit, trade, update prices, redeem pairs, and redeem each token after the end", async ({page, sent}, info) => {
  const touch = info.project.name === "phone"
  // Next week, an hour after its first close, when it takes its first deposit.
  const week = (await read(factory(), "currentWeek")) + 1n
  await warpTo((await read(factory(), "startOf", [week])) + 3_660n)
  expect(await read(factory(), "currentWeek")).toBe(week)
  await mintStock(AMZNC, people.a.wallet, UNIT)
  const start = await balanceOf(AMZNC, people.a.wallet)

  await signIn(page, people.a)
  await open(page)
  await expect(page.getByText("Available to eligible people outside the US.")).toBeVisible()
  await expect(page.locator("#exposure-status")).toHaveText("Opens with the first deposit")
  await expect(page.locator("#exposure-opens")).toBeVisible()
  await expect(page.locator("#exposure-act-tab-deposit")).toHaveAttribute("aria-selected", "true")
  // While on, the page's own styles are served.
  const styles = await page.request.get("/assets/js/exposure.css")
  expect(styles.status()).toBe(200)
  expect(await styles.text()).toContain(".exposure__legs")
  // The terms link opens the exact bytes whose fingerprint the factory gives the week.
  const terms = await page.request.get((await page.locator("#exposure-terms").getAttribute("href")) as string)
  expect(terms.status()).toBe(200)

  // A's deposit of 0.05 AMZNc opens the week at its predicted address: an exact approval of the
  // factory, then the deposit, which mints 0.05 of each token.
  await page.getByRole("textbox", {name: "Amount"}).fill("0.05")
  await fitsAndPresses(page, touch)
  await buttonsOnScreen(page)
  expect((await press(page, sent, "Approve AMZNc")).status).toBe("0x1")
  expect((await press(page, sent, "Deposit AMZNc")).status).toBe("0x1")
  await expect(page.locator("#exposure-done")).toContainText("Deposited")
  const series = await address(factory(), "seriesOf", [week])
  expect(series).toBe(await address(factory(), "predictSeries", [week]))
  const overnight = await address(series, "overnight")
  const session = await address(series, "session")
  expect(await balanceOf(overnight, people.a.wallet)).toBe(5_000_000n)
  expect(await balanceOf(session, people.a.wallet)).toBe(5_000_000n)
  expect(await balanceOf(AMZNC, people.a.wallet)).toBe(start - 5_000_000n)
  const count = await read(series, "boundaryCount")
  await open(page)
  await expect(page.locator("#exposure-status")).toHaveText(`Live, 1 of ${count} prices applied`)

  // With a pool for each token the page leads with Buy. A buys After-hours with 5 USDC and sells
  // what it bought back.
  await seedPools(week, overnight, session)
  await sendAs(USDC_HOLDER, USDC, data("transfer", [people.a.wallet, 5_000_000n]))
  const usdcBefore = await balanceOf(USDC, people.a.wallet)
  await open(page)
  await expect(page.locator("#exposure-act-tab-buy")).toHaveAttribute("aria-selected", "true")
  await page.getByRole("textbox", {name: "Spend"}).fill("5")
  await buttonsOnScreen(page)
  expect((await press(page, sent, "Approve USDC")).status).toBe("0x1")
  expect((await press(page, sent, "Buy")).status).toBe("0x1")
  const bought = (await balanceOf(overnight, people.a.wallet)) - 5_000_000n
  expect(bought).toBeGreaterThan(0n)
  expect(await balanceOf(USDC, people.a.wallet)).toBe(usdcBefore - 5_000_000n)
  await expect(page.locator("#exposure-done")).toContainText("Bought")
  await expect(page.locator("#exposure-done").getByRole("link", {name: "View portfolio"})).toBeVisible()

  await open(page, "/stock/isolated-afters?tab=sell")
  await page.getByRole("textbox", {name: "Sell"}).fill(formatUnits(bought, 8))
  await fitsAndPresses(page, touch)
  await buttonsOnScreen(page)
  expect((await press(page, sent, `Approve ${await symbol(overnight)}`)).status).toBe("0x1")
  expect((await press(page, sent, "Sell")).status).toBe("0x1")
  expect(await balanceOf(overnight, people.a.wallet)).toBe(5_000_000n)
  expect(await balanceOf(USDC, people.a.wallet)).toBeGreaterThan(usdcBefore - 5_000_000n)

  // An hour after the Monday open the page already counts its price; Update prices writes it.
  await warpTo((await read(series, "boundaries", [1n])) + 3_660n)
  await open(page)
  await expect(page.locator("#exposure-status")).toHaveText(`Live, 2 of ${count} prices applied`)
  await buttonsOnScreen(page)
  expect((await press(page, sent, "Update prices")).status).toBe("0x1")
  expect(await read(series, "settled")).toBe(2n)

  // Redeem 0.02 pairs for 0.02 AMZNc.
  await open(page, "/stock/isolated-afters?tab=redeem")
  await page.getByRole("textbox", {name: "Pairs"}).fill("0.02")
  await buttonsOnScreen(page)
  expect((await press(page, sent, "Redeem")).status).toBe("0x1")
  expect(await balanceOf(AMZNC, people.a.wallet)).toBe(start - 3_000_000n)

  // The portfolio lists the 0.03 of each still held, and its Redeem leads back to the week's Redeem tab.
  await page.goto("/portfolio")
  const held = page.locator(`#portfolio-exposure-${week}`)
  await expect(held).toBeVisible({timeout: 30_000})
  await expect(held.locator("td[data-label=After-hours]")).toHaveText("0.03")
  await expect(held.locator("td[data-label=Market-hours]")).toHaveText("0.03")
  await held.getByRole("link", {name: "Redeem"}).click()
  await expect(page.getByRole("textbox", {name: "Pairs"})).toBeVisible({timeout: 30_000})

  // An hour after the last close the week has ended and the next one takes deposits. The week's
  // own page shows the end before anyone writes it; Update prices writes it.
  await warpTo((await read(series, "maturityAt")) + 3_660n)
  expect(await read(factory(), "currentWeek")).toBe(week + 1n)
  await open(page, `/stock/isolated-afters?week=${week}`)
  await expect(page.locator("#exposure-status")).toHaveText("Ended: week complete")
  expect((await press(page, sent, "Update prices")).status).toBe("0x1")
  expect(await read(series, "status")).toBe(2n)
  expect(await read(series, "settled")).toBe(count)

  // After the end each token redeems on its own for its share of the stock.
  for (const [leg, other, amounts] of [
    ["After-hours", "Market-hours", [3_000_000n, 0n]],
    ["Market-hours", "After-hours", [0n, 3_000_000n]],
  ] as const) {
    await open(page, `/stock/isolated-afters?tab=redeem&week=${week}`)
    await page.getByRole("textbox", {name: leg}).fill("0.03")
    await page.getByRole("textbox", {name: other}).fill("")
    await fitsAndPresses(page, touch)
    await buttonsOnScreen(page)
    const owed = await read(series, "previewRedeem", [...amounts])
    expect(owed).toBeGreaterThan(0n)
    const before = await balanceOf(AMZNC, people.a.wallet)
    expect((await press(page, sent, "Redeem")).status).toBe("0x1")
    expect(await balanceOf(AMZNC, people.a.wallet)).toBe(before + owed)
  }
  expect(await balanceOf(overnight, people.a.wallet)).toBe(0n)
  expect(await balanceOf(session, people.a.wallet)).toBe(0n)
  // The two shares make up the 0.03 AMZNc behind them, short by at most a raw unit each.
  expect(start - (await balanceOf(AMZNC, people.a.wallet))).toBeLessThanOrEqual(2n)
})
