// A tool behind a site switch is registered only on a page the server handed it to
// (AutolaunchWeb.ToolManifest.page_tools/0, the #agent-feature-tools meta while
// the switch is on). A handed public tool makes exactly the request it describes,
// and a handed signed tool takes only its input: the browser host signs it.
import {afterEach, expect, it, vi} from "vitest"
import pageTools from "../../priv/covered_calls_tools.json" with {type: "json"}

type Registered = {
  name: string
  inputSchema: {properties: Record<string, {enum?: string[]}>}
  execute: (input: Record<string, unknown>, client: unknown) => Promise<unknown>
}

const handed = pageTools.tools.map(tool => tool.name)

async function registeredWith(tools: unknown[] | null, fetched: Array<{url: string; init: RequestInit}> = []) {
  const registered: Registered[] = []
  const globals = globalThis as unknown as Record<string, unknown>
  globals.document = {
    modelContext: {registerTool: async (tool: Registered) => { registered.push(tool) }},
    querySelector: (selector: string) =>
      selector === "#agent-feature-tools" && tools ? {getAttribute: () => JSON.stringify(tools)}
      : selector === 'meta[name="agent-request-origin"]' ? {content: "http://localhost:4000"} : null,
  }
  globals.window = {location: {origin: "http://localhost:4000"}, addEventListener() {}}
  globals.fetch = async (url: string, init: RequestInit) => {
    fetched.push({url, init})
    return new Response(JSON.stringify({data: {}}), {status: 200, headers: {"content-type": "application/json"}})
  }
  vi.resetModules()
  const {installPublicTools} = await import("../js/public_tools")
  installPublicTools()
  await Promise.resolve()
  return registered
}

afterEach(() => {
  const globals = globalThis as unknown as Record<string, unknown>
  delete globals.document
  delete globals.window
  delete globals.fetch
})

it("a page's own tools are registered only when the server hands them over", async () => {
  for (const tools of [null, pageTools.tools]) {
    const names = (await registeredWith(tools)).map(tool => tool.name)
    const offered = tools !== null

    expect(handed.every(name => names.includes(name))).toBe(offered)
    expect(handed.some(name => names.includes(name))).toBe(offered)
    expect(names.includes("autolaunch_my_positions")).toBe(true)
  }
})

it("a handed signed tool sends nothing without the browser host's signer, and the signed request with it", async () => {
  const fetched: Array<{url: string; init: RequestInit}> = []
  const registered = await registeredWith(pageTools.tools, fetched)
  const mine = registered.find(tool => tool.name === "autolaunch_my_covered_calls")!

  expect(await mine.execute({symbol: "AMZNc"}, undefined)).toMatchObject({ok: false, error: {code: "agent_auth_required"}})
  expect(fetched).toHaveLength(0)

  const signed: unknown[] = []
  const proof = {
    "x-siwa-signature": "s", "x-siwa-signature-input": "i", "x-siwa-receipt": "r", "x-key-id": "k",
    "x-timestamp": "1", "x-agent-wallet-address": "0x1", "x-agent-chain-id": "8453",
  }
  ;(globalThis as unknown as Record<string, unknown>).regentsSign = async (request: unknown) => {
    signed.push(request)
    return {headers: proof}
  }
  try {
    expect(await mine.execute({symbol: "AMZNc"}, undefined)).toMatchObject({ok: true, status: 200})
  } finally {
    delete (globalThis as unknown as Record<string, unknown>).regentsSign
  }

  expect(signed).toEqual([{
    operation: "autolaunch_my_covered_calls", audience: "autolaunch", origin: "http://localhost:4000",
    method: "GET", path: "/api/agent/v1/covered-calls/AMZNc/positions",
  }])
  expect(fetched).toHaveLength(1)
  expect(fetched[0].init.credentials).toBe("omit")
  expect((fetched[0].init.headers as Record<string, string>)["x-siwa-receipt"]).toBe("r")
})

it("a handed public tool makes the request it describes, from its own input", async () => {
  const fetched: Array<{url: string; init: RequestInit}> = []
  const registered = await registeredWith(pageTools.tools, fetched)
  const quote = registered.find(tool => tool.name === "autolaunch_covered_call_quote")!
  await quote.execute({symbol: "AMZNc", strike_per_token: 260_000_000, expiry: 1_793_394_000}, undefined)

  expect(fetched).toHaveLength(1)
  expect(new URL(fetched[0].url, "http://localhost:4000").pathname).toBe("/api/v1/covered-calls/AMZNc/quote")
  expect(JSON.parse(String(fetched[0].init.body))).toEqual({strike_per_token: 260_000_000, expiry: 1_793_394_000})
})
