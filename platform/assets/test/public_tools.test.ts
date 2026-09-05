import {afterEach, beforeEach, describe, expect, it, vi, type Mock} from "vitest"
import type {PublicTool} from "../js/public_tools"

let tools: Map<string, PublicTool>
let windowEvents: EventTarget
let register: Mock<(tool: PublicTool, options: {signal: AbortSignal}) => Promise<void>>
let fetchMock: ReturnType<typeof vi.fn>
let install: typeof import("../js/public_tools").installPublicTools

beforeEach(async () => {
  vi.resetModules()
  tools = new Map()
  windowEvents = new EventTarget()
  register = vi.fn((tool: PublicTool, {signal}: {signal: AbortSignal}) => {
    if (signal.aborted) return Promise.reject(signal.reason)
    if (tools.has(tool.name)) return Promise.reject(new Error("duplicate"))
    tools.set(tool.name, tool)
    signal.addEventListener("abort", () => tools.delete(tool.name), {once: true})
    return Promise.resolve()
  })
  vi.stubGlobal("window", Object.assign(windowEvents, {location: {origin: "https://autolaunch.test"}}))
  vi.stubGlobal("document", {modelContext: {registerTool: register}})
  fetchMock = vi.fn().mockResolvedValue(Response.json({data: []}))
  vi.stubGlobal("fetch", fetchMock)
  ;({installPublicTools: install} = await import("../js/public_tools"))
})

afterEach(() => {
  windowEvents.dispatchEvent(new Event("pagehide"))
  vi.unstubAllGlobals()
  vi.restoreAllMocks()
})

const run = (name: string, input: unknown = {}, signal = new AbortController().signal) =>
  tools.get(name)!.execute(input, {signal})
const settle = async () => { await Promise.resolve(); await Promise.resolve() }

describe("document registration lifecycle", () => {
  it("leaves an unsupported browser usable", () => {
    vi.stubGlobal("document", {})
    expect(install).not.toThrow()
    windowEvents.dispatchEvent(new Event("pageshow"))
    expect(register).not.toHaveBeenCalled()
    expect(fetchMock).not.toHaveBeenCalled()
  })

  it("installs once and restores tools after leaving and returning", async () => {
    install()
    install()
    windowEvents.dispatchEvent(new Event("pageshow"))
    expect(tools.size).toBe(5)
    expect(register).toHaveBeenCalledTimes(5)
    const oldTool = tools.get("autolaunch_auctions")!
    windowEvents.dispatchEvent(new Event("pagehide"))
    expect(tools.size).toBe(0)
    expect(await oldTool.execute({}, {signal: new AbortController().signal})).toMatchObject({error: {code: "aborted"}})
    windowEvents.dispatchEvent(new Event("pageshow"))
    expect(tools.size).toBe(5)
    expect(register).toHaveBeenCalledTimes(10)
    expect(fetchMock).not.toHaveBeenCalled()
  })

  it("handles rejected registration without retrying on duplicate installation", async () => {
    const warn = vi.spyOn(console, "warn").mockImplementation(() => {})
    register.mockRejectedValueOnce(new Error("permission denied"))
    install()
    await settle()
    expect(tools.size).toBe(4)
    expect(warn).toHaveBeenCalledOnce()
    install()
    expect(register).toHaveBeenCalledTimes(5)
    windowEvents.dispatchEvent(new Event("pagehide"))
    windowEvents.dispatchEvent(new Event("pageshow"))
    expect(tools.size).toBe(5)
  })

  it("late registration completion cannot revive or remove tools after navigation", async () => {
    const acknowledgements: Array<() => void> = []
    const immediate = register.getMockImplementation()!
    register.mockImplementation((...args: [PublicTool, {signal: AbortSignal}]) => {
      immediate(...args)
      return new Promise<void>(resolve => acknowledgements.push(resolve))
    })
    install()
    const stale = tools.get("autolaunch_tokens")!
    windowEvents.dispatchEvent(new Event("pagehide"))
    expect(tools.size).toBe(0)
    windowEvents.dispatchEvent(new Event("pageshow"))
    const replacement = tools.get("autolaunch_tokens")
    acknowledgements.forEach(resolve => resolve())
    await settle()
    expect(tools.size).toBe(5)
    expect(tools.get("autolaunch_tokens")).toBe(replacement)
    expect(await stale.execute({}, {signal: new AbortController().signal})).toMatchObject({error: {code: "aborted"}})
  })
})

describe("public HTTP boundary", () => {
  beforeEach(() => install())

  it("uses only the five public routes and marks public content as untrusted", async () => {
    const id = "6355c7fe-9880-47cb-aa8a-edcbb35a6f45"
    const address = "0x9999999999999999999999999999999999999999"
    for (const [name, input, path, method] of [
      ["autolaunch_auctions", {mode: "live", sort: "oldest", limit: 51}, "/api/v1/auctions?mode=live&sort=oldest&limit=51", "GET"],
      ["autolaunch_auction", {id}, `/api/v1/auctions/${id}`, "GET"],
      ["autolaunch_tokens", {limit: -1}, "/api/v1/tokens?limit=-1", "GET"],
      ["autolaunch_treasury", {address}, `/api/v1/treasury-security/${address}`, "GET"],
      ["autolaunch_bid_quote", {id, amount: "12.5", max_price: "3"}, `/api/v1/auctions/${id}/bid-quote`, "POST"],
    ] as const) {
      await run(name, input)
      const [url, options] = fetchMock.mock.lastCall!
      expect(url.href).toBe(`https://autolaunch.test${path}`)
      expect(options).toMatchObject({method, credentials: "omit", mode: "same-origin", redirect: "error"})
      expect(tools.get(name)!.annotations).toEqual({readOnlyHint: true, untrustedContentHint: true, consequentialHint: false})
    }
  })

  it("preserves exact quote strings and all server warnings and custody labels", async () => {
    const amount = "  123456789012345678901234567890.12345678901234567890123456789  "
    const body = {data: {amount: amount.trim(), warnings: ["auction_not_biddable"], treasury_security: {
      classification: "supported_safe", verification_state: "awaiting_current_chain_confirmation", verification_reason: "projector_refresh_not_integrated",
    }}}
    fetchMock.mockResolvedValueOnce(Response.json(body))
    expect(await run("autolaunch_bid_quote", {id: "auction-id", amount, max_price: "0003.000"})).toEqual({ok: true, status: 200, body})
    expect(JSON.parse(fetchMock.mock.lastCall![1].body)).toEqual({amount, max_price: "0003.000"})
  })

  it.each([null, [], "all", {mode: "unknown"}, {limit: "3"}, {limit: Infinity}, {cursor: "next"}, {wallet: "private"}])("rejects malformed list input before a request: %j", async input => {
    expect(await run("autolaunch_auctions", input)).toMatchObject({error: {code: "invalid_input"}})
    expect(fetchMock).not.toHaveBeenCalled()
  })

  it.each([".", ".."])('rejects dot-only path input %s before URL normalization', async value => {
    for (const [name, input] of [
      ["autolaunch_auction", {id: value}],
      ["autolaunch_bid_quote", {id: value, amount: "1", max_price: "2"}],
      ["autolaunch_treasury", {address: value}],
    ] as const) {
      expect(await run(name, input)).toMatchObject({error: {code: "invalid_input"}})
    }
    expect(fetchMock).not.toHaveBeenCalled()
  })

  it("leaves decimal and identifier semantics to the API while rejecting wrong types", async () => {
    const apiError = {error: {code: "invalid_request", message: "The query parameters are invalid."}}
    fetchMock.mockResolvedValue(Response.json(apiError, {status: 400}))
    expect(await run("autolaunch_bid_quote", {id: "missing", amount: "1e18", max_price: "0"})).toEqual({ok: false, status: 400, body: apiError})
    fetchMock.mockClear()
    expect(await run("autolaunch_bid_quote", {id: "missing", amount: 12.5, max_price: "3"})).toMatchObject({error: {code: "invalid_input"}})
    expect(await run("autolaunch_bid_quote", {id: "missing", amount: "12.5"})).toMatchObject({error: {code: "invalid_input"}})
    expect(fetchMock).not.toHaveBeenCalled()
  })

  it("returns API failures intact and distinguishes invalid responses and network failure", async () => {
    const body = {error: {code: "not_found", message: "Auction not found."}}
    fetchMock.mockResolvedValueOnce(Response.json(body, {status: 404}))
    expect(await run("autolaunch_auction", {id: "missing"})).toEqual({ok: false, status: 404, body})
    fetchMock.mockResolvedValueOnce(new Response("<html>Unavailable</html>", {status: 502}))
    expect(await run("autolaunch_tokens")).toMatchObject({status: 502, error: {code: "invalid_response"}})
    fetchMock.mockRejectedValueOnce(new Error("private network diagnostics"))
    const failed = await run("autolaunch_tokens")
    expect(failed).toMatchObject({error: {code: "network_error"}})
    expect(JSON.stringify(failed)).not.toContain("private")
  })

  it.each(["execution", "pagehide"])("cancels a delayed request on %s and ignores a late response", async source => {
    let complete!: (response: Response) => void
    fetchMock.mockImplementationOnce(() => new Promise<Response>(resolve => {complete = resolve}))
    const execution = new AbortController()
    const pending = run("autolaunch_tokens", {}, execution.signal)
    const requestSignal = fetchMock.mock.lastCall![1].signal as AbortSignal
    if (source === "execution") execution.abort()
    else windowEvents.dispatchEvent(new Event("pagehide"))
    expect(requestSignal.aborted).toBe(true)
    complete(Response.json({data: ["late"]}))
    expect(await pending).toMatchObject({error: {code: "aborted"}})
  })
})
