// WebMCP Draft Community Group Report, 4 September 2026: document.modelContext.
// HTTP responses remain authoritative; these tools only read and never use wallet
// hooks (the wallet tools are agent_wallet_tools.ts). Every tool the page
// registers is described once, in priv/tool_manifest.json; this file only adds
// each HTTP request. All requests omit browser credentials.
import manifest from "../../priv/tool_manifest.json" with {type: "json"}

import {signedTools, type SignedOperation, type SignedInput} from "../vendor/regent_agent_access/signed_tools.ts"

function signedTransport() { return signedTools({origin: window.location.origin, trustedOrigins: [document.querySelector<HTMLMetaElement>('meta[name="agent-request-origin"]')?.content ?? ""], audience: manifest.audience, proofHeaders: manifest.proof_headers, operations: manifest.tools.map(entry => ({...entry, input_schema: "operation_input_schema" in entry ? entry.operation_input_schema : entry.input_schema})) as unknown as SignedOperation[]}) }

type Json = null | boolean | number | string | Json[] | {[key: string]: Json}
type Input = Record<string, string | number | boolean>
type Property = {
  type: "string" | "integer" | "boolean"
  description?: string
  enum?: string[]
  minimum?: number
  maximum?: number
}
type Request = {path: string; body?: Input}
type Failure = {
  ok: false
  error: {code: "invalid_input" | "aborted" | "network_error" | "invalid_response"; message: string}
  status?: number
}
type Result = {ok: boolean; status: number; body: Json; retry_after?: number} | Failure

type Schema = {
  type: "object"
  properties: Record<string, Property>
  required: string[]
  additionalProperties: false
}
type Annotations = {readOnlyHint: boolean; untrustedContentHint: boolean; consequentialHint: boolean}
type Entry = {
  name: string
  title: string
  description: string
  input_schema: Schema
  annotations: Annotations
  scope: string
  authentication?: string
}

export type PublicTool = {
  name: string
  title: string
  description: string
  inputSchema: Schema
  annotations: Annotations
  execute(input: unknown, client?: unknown): Promise<unknown>
}

// What a host's cancellation signal must offer; a polyfilled signal qualifies.
type HostSignal = {
  readonly aborted: boolean
  addEventListener(type: "abort", listener: () => void): void
  removeEventListener(type: "abort", listener: () => void): void
}

type ModelContext = {
  registerTool(tool: PublicTool, options: {signal: AbortSignal}): Promise<void>
}

const invalidInput = () => failure("invalid_input", "Use the documented fields and input types.")
const cancelled = () => failure("aborted", "The read was cancelled.")

function failure(code: Failure["error"]["code"], message: string): Failure {
  return {ok: false, error: {code, message}}
}

function hostSignal(client: unknown): HostSignal | undefined {
  if (!client || typeof client !== "object") return undefined
  const signal = (client as {signal?: unknown}).signal
  if (!signal || typeof signal !== "object") return undefined
  const candidate = signal as Partial<HostSignal>
  return typeof candidate.aborted === "boolean" &&
    typeof candidate.addEventListener === "function" &&
    typeof candidate.removeEventListener === "function"
    ? (candidate as HostSignal)
    : undefined
}

// One native signal for a single execution: it aborts when the page lifetime
// ends or when the host cancels, whatever shape of signal the host passes.
// Hosts may pass no second argument, one without a signal, or a polyfill.
function executionSignal(lifetime: AbortSignal, client: unknown) {
  const controller = new AbortController()
  const host = hostSignal(client)
  const abort = () => controller.abort()
  const sources: HostSignal[] = host ? [lifetime, host] : [lifetime]
  if (sources.some(source => source.aborted)) abort()
  else for (const source of sources) source.addEventListener("abort", abort)
  return {
    signal: controller.signal,
    release: () => { for (const source of sources) source.removeEventListener("abort", abort) },
  }
}

function validInput(
  input: unknown,
  properties: Record<string, Property>,
  required: string[],
): input is Input {
  if (!input || typeof input !== "object" || Array.isArray(input)) return false
  const values = input as Record<string, unknown>
  if (required.some(key => !Object.hasOwn(values, key))) return false
  return Object.entries(values).every(([key, value]) => {
    if (!Object.hasOwn(properties, key)) return false
    const property = properties[key]
    if (property.type === "integer") return typeof value === "number" && Number.isSafeInteger(value)
    if (property.type === "boolean") return typeof value === "boolean"
    return typeof value === "string" && (!property.enum || property.enum.includes(value))
  })
}

type Definition = {
  properties: Record<string, Property>
  required: string[]
  request: (input: Input) => Request
}

function tool(entry: Entry, request: (input: Input) => Request, lifetime: AbortSignal): PublicTool {
  const {properties, required} = entry.input_schema
  return {
    name: entry.name,
    title: entry.title,
    description: entry.description,
    inputSchema: entry.input_schema,
    annotations: entry.annotations,
    async execute(input, client) {
      const {signal, release} = executionSignal(lifetime, client)
      try {
        if (entry.name === "prepare_agent_request") {
          const args = input as {operation: string; input: Record<string, unknown>}
          return {ok: true, request: signedTransport().prepare(args.operation, args.input)}
        }
        if (entry.authentication === "siwa_per_request") {
          const response = await signedTransport().execute(entry.name, input as SignedInput, signal)
          return {ok: response.ok, status: response.status, body: await response.json()}
        }
        return await read({properties, required, request}, input, signal)
      } catch (error) {
        return {ok: false, error: {code: "signed_request_failed", message: String(error), hint: "Read back a draft after an unanswered save before retrying with fresh proof."}}
      } finally {
        release()
      }
    },
  }
}

async function read(definition: Definition, input: unknown, cancellation: AbortSignal): Promise<Result> {
  if (cancellation.aborted) return cancelled()
  if (!validInput(input, definition.properties, definition.required)) return invalidInput()

  let target: Request
  try {
    target = definition.request(input)
  } catch {
    return invalidInput()
  }

  try {
    const response = await fetch(new URL(target.path, window.location.origin), {
      method: target.body ? "POST" : "GET",
      headers: {
        Accept: "application/json",
        ...(target.body ? {"Content-Type": "application/json"} : {}),
      },
      body: target.body ? JSON.stringify(target.body) : undefined,
      credentials: "omit",
      mode: "same-origin",
      redirect: "error",
      cache: "no-store",
      signal: cancellation,
    })
    let body: Json
    try {
      body = await response.json()
    } catch {
      if (cancellation.aborted) return cancelled()
      return {
        ...failure("invalid_response", "The site's API did not return JSON."),
        status: response.status,
      }
    }
    if (cancellation.aborted) return cancelled()
    // Past a rate limit the agent is told how many seconds to wait.
    const retryAfter = Number(response.headers.get("retry-after"))
    return response.status === 429 && retryAfter > 0
      ? {ok: response.ok, status: response.status, body, retry_after: retryAfter}
      : {ok: response.ok, status: response.status, body}
  } catch {
    return cancellation.aborted
      ? cancelled()
      : failure("network_error", "The site's API could not be reached.")
  }
}

function pathValue(value: Input[string]): string {
  // URL parsing normalizes these segments even when their dots are percent-encoded.
  if (value === "." || value === "..") throw new URIError("Invalid path segment")
  return encodeURIComponent(value)
}

const query = (input: Input) =>
  new URLSearchParams(Object.entries(input).map(([key, value]) => [key, String(value)]))

const requests: Record<string, (input: Input) => Request> = {
  autolaunch_auctions: input => ({path: `/api/v1/auctions?${query(input)}`}),
  autolaunch_auction: input => ({path: `/api/v1/auctions/${pathValue(input.id)}`}),
  autolaunch_tokens: input => ({path: `/api/v1/tokens?${query(input)}`}),
  autolaunch_treasury: input => ({path: `/api/v1/treasury-security/${pathValue(input.address)}`}),
  autolaunch_bid_quote: input => ({
    path: `/api/v1/auctions/${pathValue(input.id)}/bid-quote`,
    body: {amount: input.amount, max_price: input.max_price},
  }),
}

// Public requests and explicitly signed manifest operations register here.
function publicTools(signal: AbortSignal): PublicTool[] {
  return (manifest.tools as unknown as Entry[])
    .filter(entry => entry.scope === "site" && (Object.hasOwn(requests, entry.name) || entry.authentication === "siwa_per_request" || entry.name === "prepare_agent_request"))
    .map(entry => tool(entry, requests[entry.name] ?? (() => { throw new Error("Signed request required") }), signal))
}

let installed = false

export function installPublicTools(): void {
  const context = (document as Document & {modelContext?: ModelContext}).modelContext
  if (!context || typeof context.registerTool !== "function" || installed) return
  installed = true
  let lifetime: AbortController | undefined

  const start = () => {
    if (lifetime) return
    const current = new AbortController()
    lifetime = current
    for (const definition of publicTools(current.signal)) {
      // Registration may fail or settle after pagehide. Its signal owns removal;
      // a late promise never removes or replaces a newer page's registrations.
      void (async () => {
        try {
          await context.registerTool(definition, {signal: current.signal})
        } catch {
          if (!current.signal.aborted) console.warn(`Autolaunch tool unavailable: ${definition.name}`)
        }
      })()
    }
  }
  window.addEventListener("pagehide", () => {
    lifetime?.abort()
    lifetime = undefined
  })
  window.addEventListener("pageshow", start)
  start()
}
