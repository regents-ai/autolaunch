import {expect, test, type Page} from "@playwright/test"

const active = "a12ee155-c71b-4107-87fd-dab8c7e00001"
const closed = "a12ee155-c71b-4107-87fd-dab8c7e00002"
const treasury = "0x9999999999999999999999999999999999999999"

type Result = {ok: boolean; status?: number; body?: any; error?: {code: string}}

async function registry(page: Page) {
  await page.addInitScript(() => {
    const tools = new Map<string, any>()
    Object.defineProperty(document, "modelContext", {configurable: true, value: {
      registerTool(tool: any, {signal}: {signal: AbortSignal}) {
        if (signal.aborted) return Promise.reject(signal.reason)
        if (tools.has(tool.name)) return Promise.reject(new Error("duplicate registration"))
        tools.set(tool.name, tool)
        signal.addEventListener("abort", () => tools.delete(tool.name), {once: true})
        return Promise.resolve()
      },
    }})
    Object.assign(window, {publicToolFixture: {
      tools,
      walletCalls: 0,
      execute(name: string, input: unknown, signal = new AbortController().signal) {
        return tools.get(name).execute(input, {signal})
      },
    }})
    const wallet = {request() { (window as any).publicToolFixture.walletCalls++; throw new Error("Wallet must not be called") }}
    Object.assign(window, {ethereum: wallet, __autolaunchTestWallet: {address: "0x1111111111111111111111111111111111111111", provider: wallet}})
  })
}

async function execute(page: Page, name: string, input: unknown = {}): Promise<Result> {
  return page.evaluate(({name, input}) => (window as any).publicToolFixture.execute(name, input), {name, input})
}

async function ready(page: Page) {
  await page.waitForFunction(() => (window as any).publicToolFixture?.tools.size === 5)
}

test("unsupported browser retains the normal interface", async ({page, browser}) => {
  await page.goto("/healthz")
  const native = await page.evaluate(() => typeof (document as any).modelContext?.registerTool === "function")
  console.log(`Native document.modelContext available: ${native}; Chromium ${browser.version()}`)
  await test.info().attach("native-webmcp", {body: JSON.stringify({available: native, browser: browser.version()}), contentType: "application/json"})
  await page.addInitScript(() => Object.defineProperty(document, "modelContext", {value: undefined, configurable: true}))
  const errors: string[] = []
  page.on("pageerror", error => errors.push(error.message))
  await page.goto("/launches/launch:webmcp-qa")
  await expect(page.locator("#launch-addresses summary")).toBeVisible()
  await page.locator("#launch-addresses summary").click()
  await expect(page.locator("#launch-addresses")).toHaveAttribute("open", "")
  expect(errors).toEqual([])
})

test("all five tools use real public HTTP APIs independently of visual disclosures", async ({page}) => {
  await registry(page)
  const requests: string[] = []
  page.on("request", request => {if (new URL(request.url()).pathname.startsWith("/api/")) requests.push(request.method()+" "+new URL(request.url()).pathname)})
  await page.goto("/launches/launch:webmcp-qa")
  await ready(page)
  const auctions = await execute(page, "autolaunch_auctions", {mode: "live", sort: "oldest", limit: 50})
  expect(auctions.body.data.some((row: any) => row.id === active)).toBe(true)
  const detail = await execute(page, "autolaunch_auction", {id: active})
  expect(detail.body.data.id).toBe(active)
  await page.locator("#launch-addresses summary").click()
  expect(await execute(page, "autolaunch_auction", {id: active})).toEqual(detail)
  const tokens = await execute(page, "autolaunch_tokens", {limit: 100})
  expect(tokens.body.data.some((row: any) => row.auction_id === closed)).toBe(true)
  const report = await execute(page, "autolaunch_treasury", {address: treasury})
  expect(report.body.data).toMatchObject({classification: "supported_safe", verification_state: "awaiting_current_chain_confirmation", verification_reason: "projector_refresh_not_integrated"})
  const quote = await execute(page, "autolaunch_bid_quote", {id: active, amount: "12.5", max_price: "3"})
  expect(quote.body.data.estimated_tokens_if_end_now).toBe("5")
  const closedQuote = await execute(page, "autolaunch_bid_quote", {id: closed, amount: "12.5", max_price: "3"})
  expect(closedQuote.body.data.warnings).toContain("auction_not_biddable")
  await test.info().attach("public-tool-results", {body: JSON.stringify({auctions, detail, tokens, report, quote, closedQuote}, null, 2), contentType: "application/json"})
  expect(requests.every(request => request.startsWith("GET /api/v1/") || request === `POST /api/v1/auctions/${active}/bid-quote` || request === `POST /api/v1/auctions/${closed}/bid-quote`)).toBe(true)
  expect(await page.evaluate(() => (window as any).publicToolFixture.walletCalls)).toBe(0)
})

test("exact decimal strings, invalid inputs, and server errors survive the boundary", async ({page}) => {
  await registry(page)
  await page.goto("/auctions")
  await ready(page)
  const amount = "  12.12345678901234567890123456789  "
  const max_price = "0003.000"
  const request = page.waitForRequest(request => request.url().endsWith("/bid-quote"))
  const quote = await execute(page, "autolaunch_bid_quote", {id: active, amount, max_price})
  expect((await request).postDataJSON()).toEqual({amount, max_price})
  expect(quote.body.data.amount).toBe(amount.trim())
  expect(await execute(page, "autolaunch_bid_quote", {id: active, amount: 12.5, max_price})).toMatchObject({error: {code: "invalid_input"}})
  expect(await execute(page, "autolaunch_bid_quote", {id: active, amount: "1e18", max_price})).toMatchObject({status: 400, body: {error: {code: "invalid_request"}}})
  expect(await execute(page, "autolaunch_auction", {id: "00000000-0000-0000-0000-000000000000"})).toMatchObject({status: 404, body: {error: {code: "not_found"}}})
  expect(await execute(page, "autolaunch_treasury", {address: "not-an-address"})).toMatchObject({status: 400, body: {error: {code: "invalid_request"}}})
  await page.route("**/api/v1/tokens*", route => route.abort())
  expect(await execute(page, "autolaunch_tokens")).toMatchObject({error: {code: "network_error"}})
})

test("page lifecycle unregisters tools, restores them, and cancels a delayed public read", async ({page}) => {
  await registry(page)
  await page.goto("/auctions")
  await ready(page)
  // LiveView navigation keeps the document and must not install a second registry.
  await page.locator('.shell-rail a[href="/tokens"]').click()
  await expect(page).toHaveURL(/\/tokens$/)
  await ready(page)
  await page.goBack()
  await ready(page)
  await page.goto("/healthz")
  await page.goBack()
  await ready(page)
  await page.evaluate(() => window.dispatchEvent(new PageTransitionEvent("pagehide", {persisted: true})))
  expect(await page.evaluate(() => (window as any).publicToolFixture.tools.size)).toBe(0)
  await page.evaluate(() => window.dispatchEvent(new PageTransitionEvent("pageshow", {persisted: true})))
  await ready(page)

  let release!: () => void
  const delayed = new Promise<void>(resolve => {release = resolve})
  let arrived!: () => void
  const arrival = new Promise<void>(resolve => {arrived = resolve})
  await page.route("**/api/v1/tokens*", async route => {
    arrived()
    await delayed
    await route.fulfill({json: {data: []}}).catch(() => {})
  })
  await page.evaluate(() => {
    const fixture = (window as any).publicToolFixture
    fixture.abort = new AbortController()
    fixture.pending = fixture.execute("autolaunch_tokens", {}, fixture.abort.signal)
  })
  await arrival
  await page.evaluate(() => (window as any).publicToolFixture.abort.abort())
  const result = await page.evaluate(() => (window as any).publicToolFixture.pending)
  expect(result).toMatchObject({error: {code: "aborted"}})
  release()
  expect(await page.evaluate(() => (window as any).publicToolFixture.walletCalls)).toBe(0)
})
