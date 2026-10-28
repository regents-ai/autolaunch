// A tool behind a site switch is registered only on a page that says the switch
// is on, and the signed request preparer offers only the signed tools registered
// (AutolaunchWeb.ToolManifest decides the same for /capabilities and the guides).
import {afterEach, expect, it, vi} from "vitest"

type Registered = {name: string; inputSchema: {properties: Record<string, {enum?: string[]}>}}

const coveredCalls = [
  "autolaunch_covered_call_listings",
  "autolaunch_covered_call_quote",
  "autolaunch_my_covered_calls",
  "autolaunch_covered_call_prepare",
]

async function registeredWith(features: string): Promise<Registered[]> {
  const registered: Registered[] = []
  const globals = globalThis as unknown as Record<string, unknown>
  globals.document = {
    modelContext: {registerTool: async (tool: Registered) => { registered.push(tool) }},
    querySelector: (selector: string) => selector.includes("agent-features") ? {content: features} : null,
  }
  globals.window = {location: {origin: "http://localhost:4000"}, addEventListener() {}}
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
})

it("covered-call tools are registered and preparable only while the page says covered calls are on", async () => {
  for (const [features, offered] of [["", false], ["covered_calls", true]] as const) {
    const registered = await registeredWith(features)
    const names = registered.map(tool => tool.name)
    const prepare = registered.find(tool => tool.name === "prepare_agent_request")
    const operations = prepare?.inputSchema.properties.operation.enum ?? []

    expect(coveredCalls.every(name => names.includes(name))).toBe(offered)
    expect(coveredCalls.some(name => names.includes(name))).toBe(offered)
    expect(operations.includes("autolaunch_covered_call_prepare")).toBe(offered)
    expect(operations.includes("autolaunch_my_positions")).toBe(true)
  }
})
