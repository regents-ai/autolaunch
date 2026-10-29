// WebMCP Draft Community Group Report, 4 September 2026: document.modelContext.
// HTTP responses remain authoritative; these tools never use wallet hooks. Every
// tool the page registers is described once, in priv/tool_manifest.json; this
// file only adds each HTTP request. All requests omit browser credentials. A signed
// tool takes only its input; the agent's browser host signs the exact request
// (window.regentsSign), so no key, signature or receipt passes through the page.
import manifest from "../../priv/tool_manifest.json" with {type: "json"}

import {Refused, signedTools, type SignedOperation} from "../vendor/regent_agent_access/signed_tools.ts"
import {report, visitId} from "./visit_log"

function signedTransport() { return signedTools({
  origin: window.location.origin,
  trustedOrigins: [document.querySelector<HTMLMetaElement>('meta[name="agent-request-origin"]')?.content ?? ""],
  audience: manifest.audience,
  proofHeaders: manifest.proof_headers,
  requestHeaders: client,
  // Only the signed tools are operations.
  operations: offered().filter(entry => entry.authentication === "siwa_per_request") as unknown as SignedOperation[],
}) }

// Tools the page is handed beside the ones built in here, while a feature is on
// (AutolaunchWeb.ToolManifest.page_tools/0); none otherwise.
function pageTools(): Entry[] {
  const json = document.querySelector?.("#agent-feature-tools")?.getAttribute("content")
  return json ? (JSON.parse(json) as Entry[]) : []
}

// Every tool this page offers: the built-in ones, then the page's.
function offered(): Entry[] {
  return [...(manifest.tools as unknown as Entry[]), ...pageTools()]
}

// A page tool's own request: its path with each {field} filled from the input,
// and the input fields it posts.
function described({path, body}: NonNullable<Entry["request"]>): (input: Input) => Request {
  return input => ({
    path: path.replace(/\{(\w+)\}/g, (_match, field: string) => pathValue(input[field])),
    ...(body && {body: Object.fromEntries(body.map(field => [field, input[field]]))}),
  })
}

// Every call names its tool and this visit, so the site's log can put the call
// beside the rest of the visit (AutolaunchWeb.VisitLog). Neither is a credential.
function client(tool: string): Record<string, string> {
  const visit = visitId()
  return {"x-regent-client": `webmcp/${tool}`, ...(visit && {"x-regent-visit": visit})}
}

// A call that got no answer. Anything but a read may already have reached the
// site, so its outcome is unknown. The site never heard it, so the page reports it.
function unsent(entry: Entry): void {
  report({name: "tool.unsent", where: entry.name, outcome: entry.annotations.readOnlyHint ? "unreachable" : "outcome_unknown"})
}

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
  // A page tool's own HTTP request (AutolaunchWeb.ToolManifest.page_tools/0).
  request?: {path: string; body?: string[]}
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
        if (entry.authentication === "siwa_per_request") return await signed(entry, input as Record<string, unknown>, signal)
        return await read(entry, {properties, required, request}, input, signal)
      } finally {
        release()
      }
    },
  }
}

// fetch fails with a TypeError when the network fails and an AbortError when
// cancelled. Before anything is sent, the transport refuses with a plain Error for
// input that does not fit the tool, or with Refused when there is no agent signer,
// it fails or says no, or the call was cancelled while it signed; Refused carries
// the words for the agent.
const lost = (error: unknown) =>
  error instanceof TypeError || (error instanceof DOMException && error.name === "AbortError")

async function signed(entry: Entry, input: Record<string, unknown>, signal: AbortSignal) {
  if (signal.aborted) {
    return {ok: false, error: {code: "cancelled", message: "The call was cancelled before it was sent; nothing changed."}}
  }
  let response: Response
  try {
    response = await signedTransport().execute(entry.name, input, signal)
  } catch (error) {
    if (error instanceof Refused) return {ok: false, error: error.refusal}
    return lost(error) ? unanswered(entry, signal) : invalid(error)
  }
  try {
    return {ok: response.ok, status: response.status, body: await response.json()}
  } catch {
    return unanswered(entry, signal)
  }
}

// A signed call that got no answer may already have reached the site, so its
// outcome is unknown.
function unanswered(entry: Entry, signal: AbortSignal) {
  if (!signal.aborted) unsent(entry)
  return {ok: false, error: {code: "signed_request_failed", message: "The site's answer was lost, so it is not known whether this happened.", hint: "Read back a draft after an unanswered save before you try again."}}
}

// Reasons that mean the tool itself is set up wrongly, not the agent's input.
const siteFaults = new Set(["invalid_operation", "invalid_path", "invalid_request_header", "unsupported_field_type"])

// The signing transport refuses with a reason such as "missing_field:title".
// The agent reads it in words; the reason itself stays in details.
function invalid(error: unknown) {
  const reason = error instanceof Error ? error.message : String(error)
  return {ok: false, error: {
    code: "invalid_request",
    message: explain(reason),
    hint: siteFaults.has(reason.split(":", 1)[0])
      ? "Use another way in, such as the API, and tell the site's team."
      : "Check the input against this tool's schema, then call the tool again.",
    details: {reason},
  }}
}

function explain(reason: string): string {
  const [kind, field] = reason.split(":", 2)
  switch (kind) {
    case "invalid_input": return "Send an object of named fields."
    case "missing_field": return `${field} is required.`
    case "invalid_field": return `${field} is not a field of this tool, or is not the kind of value it takes.`
    case "invalid_path_field": return `${field} must be a name: not empty, "." or "..".`
    case "unexpected_read_body": return "This tool reads only. Send only the fields its address names."
    case "invalid_raw_body": return "Send the body as JSON text, and nothing else."
    case "invalid_operation":
    case "invalid_path":
    case "invalid_request_header":
    case "unsupported_field_type":
      return "This tool is set up wrongly on the site, so nothing was sent."
    case "operation_unavailable": return "No signed tool has that name. Use a name from this page's tools."
    case "operation_id_required": return "operation_id is required. Use a new one for each change and keep it when retrying."
    case "body_too_large": return "The input is too large."
    case "input_complexity_exceeded": return "The input has too many parts or is nested too deeply."
    case "invalid_signer_answer":
    case "proof_required":
    case "invalid_proof":
    case "incomplete_proof":
    case "body_proof_required":
    case "unexpected_body_proof":
      return "Your agent's signer gave an incomplete answer, so nothing was sent. Update regents-cli and open this site again with regents browser."
    case "untrusted_origin":
    case "insecure_origin":
      return "This page can't send signed requests."
    default: return "The input doesn't fit this tool's schema."
  }
}

async function read(entry: Entry, definition: Definition, input: unknown, cancellation: AbortSignal): Promise<Result> {
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
        ...client(entry.name),
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
    if (cancellation.aborted) return cancelled()
    unsent(entry)
    return failure("network_error", "The site's API could not be reached.")
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
  autolaunch_auction_counts: () => ({path: "/api/v1/auction-counts"}),
  autolaunch_tokens: input => ({path: `/api/v1/tokens?${query(input)}`}),
  autolaunch_token: input => ({path: `/api/v1/tokens/${pathValue(input.id)}`}),
  autolaunch_treasury: input => ({path: `/api/v1/treasury-security/${pathValue(input.address)}`}),
  autolaunch_bid_quote: input => ({
    path: `/api/v1/auctions/${pathValue(input.id)}/bid-quote`,
    body: {amount: input.amount, max_price: input.max_price},
  }),
}

// Public requests and explicitly signed manifest operations register here.
function publicTools(signal: AbortSignal): PublicTool[] {
  return offered()
    .filter(entry => entry.scope === "site" && (Object.hasOwn(requests, entry.name) || entry.request || entry.authentication === "siwa_per_request"))
    .map(entry => tool(entry, requests[entry.name] ?? (entry.request ? described(entry.request) : () => { throw new Error("Signed request required") }), signal))
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
