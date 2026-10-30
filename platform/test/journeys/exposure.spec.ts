import {readFileSync} from "node:fs"
import {encodeFunctionData, parseAbi, type Hex} from "viem"
import {balanceOf, call, mintStock, rpc} from "./support/chain"
import {expect, fitsAndPresses, people, ready, signIn, test, type Sent} from "./support/person"
import type {Page} from "@playwright/test"

// Isolated Exposure to After-hours Stocks on AMZNc, end to end on the copy of Base with one series whose
// three prices (a close, an open and a close) fall in the copy's next few hours
// (base_fork.py exposure). Person A records and applies the first close, which opens minting;
// mints a pair; returns part of it as pairs; records and applies the open and the last close,
// which ends the series; then returns each token on its own for its share of the stock.
// Every press goes through the page's own wallet buttons. Feature map:
// operations/FEATURES.md, Isolated Exposure to After-hours Stocks.
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

const abi = parseAbi([
  "function overnight() view returns (address)",
  "function session() view returns (address)",
  "function boundaries(uint256) view returns (uint64)",
  "function settled() view returns (uint64)",
  "function status() view returns (uint8)",
])

const series = (): string =>
  JSON.parse(readFileSync(`${process.env.STACK_STATE}/exposure.json`, "utf8")).series[0]

async function read(name: "overnight" | "session" | "settled" | "status"): Promise<bigint | string> {
  const word = await call(series(), encodeFunctionData({abi, functionName: name}) as Hex)
  return name === "overnight" || name === "session" ? `0x${word.slice(26)}` : BigInt(word)
}

async function boundary(index: number): Promise<number> {
  return Number(BigInt(await call(series(), encodeFunctionData({abi, functionName: "boundaries", args: [BigInt(index)]}) as Hex)))
}

/** Moves the copy's clock to `at` (a Unix time) and mines a block there. */
async function warpTo(at: number) {
  await rpc("evm_setNextBlockTimestamp", [`0x${at.toString(16)}`])
  await rpc("evm_mine")
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

/** Opens the page fresh and waits for the series to be read. */
async function open(page: Page, path = "/stock/isolated-afters") {
  await page.goto(path)
  await ready(page)
  await expect(page.locator("#exposure-overnight")).toBeVisible({timeout: 30_000})
}

/** Records and applies the next price from Series details, an hour after its time. */
async function recordAndApply(page: Page, sent: Sent[], index: number) {
  await warpTo((await boundary(index)) + 3_660)
  await open(page)
  await page.locator("#exposure-details > summary").click()
  await buttonsOnScreen(page)
  expect((await press(page, sent, "Record price")).status).toBe("0x1")
  expect((await press(page, sent, "Apply price")).status).toBe("0x1")
  expect(await read("settled")).toBe(BigInt(index + 1))
}

test("after-hours exposure: record the first close, split, redeem pairs, run to the end and redeem each token", async ({page, sent}, info) => {
  const touch = info.project.name === "phone"
  await mintStock(AMZNC, people.a.wallet, UNIT)
  const start = await balanceOf(AMZNC, people.a.wallet)

  await signIn(page, people.a)
  await open(page)
  await expect(page.getByText("Available to eligible people outside the US.")).toBeVisible()
  await expect(page.getByText("Opens after the close on")).toBeVisible()
  // While on, the page's own styles are served.
  const styles = await page.request.get("/assets/js/exposure.css")
  expect(styles.status()).toBe(200)
  expect(await styles.text()).toContain(".exposure__legs")
  // The terms link opens the exact bytes whose fingerprint the series holds.
  const terms = await page.request.get(await page.getByRole("link", {name: "Full terms"}).getAttribute("href") as string)
  expect(terms.status()).toBe(200)

  // The first close opens minting.
  await recordAndApply(page, sent, 0)
  await expect(page.getByText("Live, 1 of 3 prices applied")).toBeVisible()

  // Split 0.05 AMZNc: an exact approval, then the split.
  await page.getByRole("textbox", {name: "Amount"}).fill("0.05")
  await fitsAndPresses(page, touch)
  await buttonsOnScreen(page)
  expect((await press(page, sent, "Approve AMZNc")).status).toBe("0x1")
  expect((await press(page, sent, "Split AMZNc")).status).toBe("0x1")
  const overnight = (await read("overnight")) as string
  const session = (await read("session")) as string
  expect(await balanceOf(overnight, people.a.wallet)).toBe(5_000_000n)
  expect(await balanceOf(session, people.a.wallet)).toBe(5_000_000n)
  expect(await balanceOf(AMZNC, people.a.wallet)).toBe(start - 5_000_000n)

  // Redeem 0.02 pairs for 0.02 AMZNc.
  await open(page, "/stock/isolated-afters?tab=redeem")
  await page.getByRole("textbox", {name: "Pairs"}).fill("0.02")
  await buttonsOnScreen(page)
  expect((await press(page, sent, "Redeem")).status).toBe("0x1")
  expect(await balanceOf(AMZNC, people.a.wallet)).toBe(start - 3_000_000n)

  // The portfolio lists the 0.03 of each still held, and its Redeem leads back to the Redeem tab.
  await page.goto("/portfolio")
  const held = page.locator("#portfolio-exposure tbody tr")
  await expect(held).toHaveCount(1, {timeout: 30_000})
  await expect(held.locator("td[data-label=After-hours]")).toHaveText("0.03")
  await expect(held.locator("td[data-label=Market-hours]")).toHaveText("0.03")
  await held.getByRole("link", {name: "Redeem"}).click()
  await expect(page.getByRole("textbox", {name: "Pairs"})).toBeVisible({timeout: 30_000})

  // The open and the last close end the series.
  await recordAndApply(page, sent, 1)
  await recordAndApply(page, sent, 2)
  expect(await read("status")).toBe(2n)
  await expect(page.getByText("Ended: term complete")).toBeVisible()

  // After the end each token returns its own share; the copy's feed did not move, so
  // the two halves come back as the 0.03 AMZNc behind them.
  await open(page, "/stock/isolated-afters?tab=redeem")
  await page.getByRole("button", {name: "Max", exact: true}).click()
  await expect(page.getByRole("textbox", {name: "After-hours"})).toHaveValue("0.03")
  await expect(page.getByRole("textbox", {name: "Market-hours"})).toHaveValue("0.03")
  await buttonsOnScreen(page)
  expect((await press(page, sent, "Redeem")).status).toBe("0x1")
  expect(await balanceOf(overnight, people.a.wallet)).toBe(0n)
  expect(await balanceOf(session, people.a.wallet)).toBe(0n)
  expect(await balanceOf(AMZNC, people.a.wallet)).toBe(start)
})
