// A tool behind a site switch is registered only on a page the server handed it to
// (AutolaunchWeb.ToolManifest.page_tools/0, the #agent-feature-tools meta while
// the switch is on), and a handed public tool makes exactly the request it describes.
// A signed tool takes only its own input: the agent's browser host signs the exact
// request (window.regentsSign), and with no host signer nothing is sent.
import {afterEach, expect, it, vi} from "vitest"
import pageTools from "../../priv/covered_calls_tools.json" with {type: "json"}

// What the page reports to the site's visit log.
const reported: Array<{name: string; where: string; outcome: string}> = []
vi.mock("../js/visit_log", () => ({
  report: (line: {name: string; where: string; outcome: string}) => { reported.push(line) },
  visitId: () => null,
}))

type Registered = {
  name: string
  inputSchema: {properties: Record<string, unknown>}
  execute: (input: Record<string, unknown>, client: unknown) => Promise<unknown>
}

const origin = "http://localhost:4000"
const handed = pageTools.tools.map(tool => tool.name)

async function registeredWith(tools: unknown[] | null, fetched: Array<{url: string; init: RequestInit}> = []) {
  const registered: Registered[] = []
  const globals = globalThis as unknown as Record<string, unknown>
  globals.document = {
    modelContext: {registerTool: async (tool: Registered) => { registered.push(tool) }},
    querySelector: (selector: string) =>
      selector === "#agent-feature-tools" && tools ? {getAttribute: () => JSON.stringify(tools)}
        : selector === 'meta[name="agent-request-origin"]' ? {content: origin}
        : null,
  }
  globals.window = {location: {origin}, addEventListener() {}}
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
  delete globals.regentsSign
  reported.length = 0
})

const proof = {
  "x-siwa-signature": "sig", "x-siwa-signature-input": "input", "x-siwa-receipt": "receipt",
  "x-key-id": "key", "x-timestamp": "1", "x-agent-wallet-address": "0xabc", "x-agent-chain-id": "8453",
  "content-digest": "sha-256=:x:",
}

const {"content-digest": _digest, ...withoutDigest} = proof

function signsEverything() {
  ;(globalThis as unknown as Record<string, unknown>).regentsSign = async (request: {body?: string}) =>
    ({headers: request.body === undefined ? withoutDigest : proof})
}

function networkFails() {
  ;(globalThis as unknown as Record<string, unknown>).fetch = async () => { throw new TypeError("fetch failed") }
}

it("a page's own tools are registered only when the server hands them over", async () => {
  for (const tools of [null, pageTools.tools]) {
    const names = (await registeredWith(tools)).map(tool => tool.name)
    const offered = tools !== null

    expect(handed.every(name => names.includes(name))).toBe(offered)
    expect(handed.some(name => names.includes(name))).toBe(offered)
    expect(names.includes("account_points")).toBe(true)
  }
})

it("a signed tool's input is its own fields, never a request or a proof", async () => {
  const registered = await registeredWith(pageTools.tools)
  const prepare = registered.find(tool => tool.name === "autolaunch_covered_call_prepare")!
  const listed = pageTools.tools.find(tool => tool.name === "autolaunch_covered_call_prepare")!

  expect(prepare.inputSchema).toEqual(listed.input_schema)
  expect(Object.keys(prepare.inputSchema.properties)).not.toContain("proof")
  expect(Object.keys(prepare.inputSchema.properties)).not.toContain("request")
})

it("with no agent signer a signed tool sends nothing and says how to sign", async () => {
  const fetched: Array<{url: string; init: RequestInit}> = []
  const points = (await registeredWith(null, fetched)).find(tool => tool.name === "account_points")!

  expect(await points.execute({}, undefined)).toMatchObject({ok: false, error: {code: "agent_auth_required"}})
  expect(fetched).toHaveLength(0)
})

it("a signer's refusal is the tool's answer, and nothing is sent", async () => {
  const fetched: Array<{url: string; init: RequestInit}> = []
  const points = (await registeredWith(null, fetched)).find(tool => tool.name === "account_points")!
  const refusal = {code: "not_this_call", message: "The agent did not ask for this call."}
  ;(globalThis as unknown as Record<string, unknown>).regentsSign = async () => ({error: refusal})

  expect(await points.execute({}, undefined)).toEqual({ok: false, error: refusal})
  expect(fetched).toHaveLength(0)
})

it("a signed tool sends the request the host signed, with its proof and no cookie", async () => {
  const fetched: Array<{url: string; init: RequestInit}> = []
  const points = (await registeredWith(null, fetched)).find(tool => tool.name === "account_points")!
  const signedRequests: Array<{method: string; path: string}> = []
  const proof = {
    "x-siwa-signature": "sig", "x-siwa-signature-input": "input", "x-siwa-receipt": "receipt",
    "x-key-id": "key", "x-timestamp": "1", "x-agent-wallet-address": "0xabc", "x-agent-chain-id": "8453",
  }
  ;(globalThis as unknown as Record<string, unknown>).regentsSign = async (request: {method: string; path: string}) => {
    signedRequests.push(request)
    return {headers: proof}
  }

  expect(await points.execute({}, undefined)).toMatchObject({ok: true, status: 200})
  expect(signedRequests).toMatchObject([{method: "GET", path: "/api/agent/v1/account/points"}])
  expect(fetched).toHaveLength(1)
  expect(fetched[0].url).toBe(`${origin}/api/agent/v1/account/points`)
  expect(fetched[0].init.credentials).toBe("omit")
  expect(fetched[0].init.headers).toMatchObject(proof)
})

it("input that doesn't fit a signed tool is refused in words before the signer is asked", async () => {
  const fetched: Array<{url: string; init: RequestInit}> = []
  const points = (await registeredWith(null, fetched)).find(tool => tool.name === "account_points")!
  let asked = 0
  ;(globalThis as unknown as Record<string, unknown>).regentsSign = async () => { asked++; return {headers: {}} }

  expect(await points.execute({input: {}, request: {}, proof: {}}, undefined)).toMatchObject({
    ok: false,
    error: {code: "invalid_request", message: "input is not a field of this tool, or is not the kind of value it takes.", details: {reason: "invalid_field:input"}},
  })
  expect(asked).toBe(0)
  expect(fetched).toHaveLength(0)
})

it("a signed call cancelled before it starts never asks the signer", async () => {
  const points = (await registeredWith(null)).find(tool => tool.name === "account_points")!
  let asked = 0
  ;(globalThis as unknown as Record<string, unknown>).regentsSign = async () => { asked++; return {headers: {}} }
  const cancelled = new AbortController()
  cancelled.abort()

  expect(await points.execute({}, {signal: cancelled.signal})).toMatchObject({ok: false, error: {code: "cancelled"}})
  expect(asked).toBe(0)
})

it("a save whose answer is lost is reported as unknown, and the agent is told to read it back", async () => {
  const save = (await registeredWith(null)).find(tool => tool.name === "autolaunch_revstake_draft_save")!
  signsEverything()
  networkFails()

  expect(await save.execute({}, undefined)).toMatchObject({ok: false, error: {code: "signed_request_failed"}})
  expect(reported).toEqual([{name: "tool.unsent", where: "autolaunch_revstake_draft_save", outcome: "outcome_unknown"}])
})

it("a signed read that can't reach the site says so; a cancelled one is not reported", async () => {
  const points = (await registeredWith(null)).find(tool => tool.name === "account_points")!
  signsEverything()
  networkFails()

  expect(await points.execute({}, undefined)).toMatchObject({ok: false, error: {code: "unreachable"}})
  expect(reported).toEqual([{name: "tool.unsent", where: "account_points", outcome: "unreachable"}])

  reported.length = 0
  const sending = new AbortController()
  ;(globalThis as unknown as Record<string, unknown>).fetch = async () => {
    sending.abort()
    throw new DOMException("aborted", "AbortError")
  }
  expect(await points.execute({}, {signal: sending.signal})).toMatchObject({ok: false, error: {code: "cancelled"}})
  expect(reported).toEqual([])
})

it("a signer that fails sends nothing and says so", async () => {
  const fetched: Array<{url: string; init: RequestInit}> = []
  const points = (await registeredWith(null, fetched)).find(tool => tool.name === "account_points")!
  ;(globalThis as unknown as Record<string, unknown>).regentsSign = async () => { throw new Error("signer crashed") }

  expect(await points.execute({}, undefined)).toMatchObject({ok: false, error: {code: "signer_unavailable"}})
  expect(fetched).toHaveLength(0)
  expect(reported).toEqual([])
})

it("a handed public tool makes the request it describes, from its own input", async () => {
  const fetched: Array<{url: string; init: RequestInit}> = []
  const registered = await registeredWith(pageTools.tools, fetched)
  const quote = registered.find(tool => tool.name === "autolaunch_covered_call_quote")!
  await quote.execute({symbol: "AMZNc", strike_per_token: 260_000_000, expiry: 1_793_394_000}, undefined)

  expect(fetched).toHaveLength(1)
  expect(new URL(fetched[0].url, origin).pathname).toBe("/api/v1/covered-calls/AMZNc/quote")
  expect(JSON.parse(String(fetched[0].init.body))).toEqual({strike_per_token: 260_000_000, expiry: 1_793_394_000})
})
