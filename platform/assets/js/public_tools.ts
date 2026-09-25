// WebMCP Draft Community Group Report, 4 September 2026: document.modelContext.
// Public HTTP responses remain authoritative; these tools never use wallet hooks.
type Json = null | boolean | number | string | Json[] | {[key: string]: Json}
type Input = Record<string, string | number>
type Property = {
  type: "string" | "integer"
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
type Result = {ok: boolean; status: number; body: Json} | Failure

export type PublicTool = {
  name: string
  description: string
  inputSchema: {
    type: "object"
    properties: Record<string, Property>
    required: string[]
    additionalProperties: false
  }
  annotations: {readOnlyHint: true; untrustedContentHint: true; consequentialHint: false}
  execute(input: unknown, client?: unknown): Promise<Result>
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
const cancelled = () => failure("aborted", "The public read was cancelled.")

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
    return typeof value === "string" && (!property.enum || property.enum.includes(value))
  })
}

type Definition = {
  properties: Record<string, Property>
  required: string[]
  request: (input: Input) => Request
}

function tool(
  name: string,
  description: string,
  properties: Record<string, Property>,
  required: string[],
  request: (input: Input) => Request,
  lifetime: AbortSignal,
): PublicTool {
  return {
    name,
    description,
    inputSchema: {type: "object", properties, required, additionalProperties: false},
    annotations: {readOnlyHint: true, untrustedContentHint: true, consequentialHint: false},
    async execute(input, client) {
      const {signal, release} = executionSignal(lifetime, client)
      try {
        return await read({properties, required, request}, input, signal)
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
        ...failure("invalid_response", "The public API did not return JSON."),
        status: response.status,
      }
    }
    if (cancellation.aborted) return cancelled()
    return {ok: response.ok, status: response.status, body}
  } catch {
    return cancellation.aborted
      ? cancelled()
      : failure("network_error", "The public API could not be reached.")
  }
}

function pathValue(value: string | number): string {
  // URL parsing normalizes these segments even when their dots are percent-encoded.
  if (value === "." || value === "..") throw new URIError("Invalid path segment")
  return encodeURIComponent(value)
}

function publicTools(signal: AbortSignal): PublicTool[] {
  const id: Property = {type: "string", description: "Exact public auction UUID."}
  const auction: Property = {type: "string", description: "Exact public auction UUID (Base), or the auction's contract address (Robinhood)."}
  const decimal: Property = {
    type: "string",
    description: "Positive decimal digits with optional fractional digits; no exponent. The API trims whitespace, caps input at 100 bytes, and validates decimal bounds. Sent unchanged, without rounding.",
  }
  const query = (input: Input) =>
    new URLSearchParams(Object.entries(input).map(([key, value]) => [key, String(value)]))

  return [
    tool(
      "autolaunch_auctions",
      "List public Autolaunch auctions on Base and Robinhood as the site has stored them, in one order across both chains; every entry names its chain. Sort newest (default) puts the latest opening first; oldest puts the earliest first; auctions not yet open come last in both. Mode filters by auction state on both chains. The limit counts both chains. Each auction gives its page url, estimated_end_at, token_allocation, bid_volume and bid_volume_usd, minimum_raise (its launch threshold), currency_raised and percent_met; amounts are exact decimal strings. record_updated_at is when the site last wrote its stored record, not when the chain was last read. A figure not held yet is null and unavailable names why: not_recorded_yet, chain_unreadable (Robinhood's last chain read failed) or no_usd_price.",
      {
        after: {type: "string", description: "Pass pagination.next_cursor unchanged with the same mode and sort. Cursors expire after 24 hours."},
        mode: {type: "string", enum: ["all", "biddable", "live", "ended", "failed_minimum", "graduated"]},
        sort: {type: "string", enum: ["newest", "oldest"]},
        limit: {
          type: "integer", minimum: Number.MIN_SAFE_INTEGER, maximum: Number.MAX_SAFE_INTEGER,
          description: "Safe integer; the API clamps it to 1–50. Defaults to 50.",
        },
      },
      [],
      input => ({path: `/api/v1/auctions?${query(input)}`}),
      signal,
    ),
    tool(
      "autolaunch_auction",
      "Read one public Autolaunch auction as the site has stored it, by its UUID (either chain) or a Robinhood auction by its contract address: its chain, kind, quote_token, launch figures and stored treasury report, with the same fields as each autolaunch_auctions entry.",
      {id: auction},
      ["id"],
      input => ({path: `/api/v1/auctions/${pathValue(input.id)}`}),
      signal,
    ),
    tool(
      "autolaunch_tokens",
      "List public graduated Autolaunch tokens on Base and Robinhood as the site has stored them, newest graduation first across both chains; every entry names its chain.",
      {
        after: {type: "string", description: "Pass pagination.next_cursor unchanged to read the next page. Cursors expire after 24 hours."},
        limit: {
          type: "integer", minimum: Number.MIN_SAFE_INTEGER, maximum: Number.MAX_SAFE_INTEGER,
          description: "Safe integer; the API clamps it to 1–100. Defaults to 100.",
        },
      },
      [],
      input => ({path: `/api/v1/tokens?${query(input)}`}),
      signal,
    ),
    tool(
      "autolaunch_treasury",
      "Read a stored public treasury-security report. A supported Safe classification does not establish current verification; preserve verification_state and verification_reason.",
      {
        address: {
          type: "string",
          description: "Nonzero EVM treasury address. The API validates the address and any mixed-case checksum.",
        },
      },
      ["address"],
      input => ({path: `/api/v1/treasury-security/${pathValue(input.address)}`}),
      signal,
    ),
    tool(
      "autolaunch_bid_quote",
      "Estimate an auction bid from stored public data. This does not prepare or submit a bid, open a wallet, or read the chain. Read all warnings, including auction_not_biddable.",
      {id, amount: decimal, max_price: decimal},
      ["id", "amount", "max_price"],
      input => ({
        path: `/api/v1/auctions/${pathValue(input.id)}/bid-quote`,
        body: {amount: input.amount, max_price: input.max_price},
      }),
      signal,
    ),
  ]
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
