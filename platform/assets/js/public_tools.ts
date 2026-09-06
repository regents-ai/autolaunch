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
  execute(input: unknown, options: {signal: AbortSignal}): Promise<Result>
}

type ModelContext = {
  registerTool(tool: PublicTool, options: {signal: AbortSignal}): Promise<void>
}

const invalidInput = () => failure("invalid_input", "Use the documented fields and input types.")
const cancelled = () => failure("aborted", "The public read was cancelled.")

function failure(code: Failure["error"]["code"], message: string): Failure {
  return {ok: false, error: {code, message}}
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
    async execute(input, {signal}) {
      const cancellation = AbortSignal.any([lifetime, signal])
      if (cancellation.aborted) return cancelled()
      if (!validInput(input, properties, required)) return invalidInput()

      let target: Request
      try {
        target = request(input)
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
    },
  }
}

function pathValue(value: string | number): string {
  // URL parsing normalizes these segments even when their dots are percent-encoded.
  if (value === "." || value === "..") throw new URIError("Invalid path segment")
  return encodeURIComponent(value)
}

function publicTools(signal: AbortSignal): PublicTool[] {
  const id: Property = {type: "string", description: "Exact public auction UUID."}
  const decimal: Property = {
    type: "string",
    description: "Positive decimal digits with optional fractional digits; no exponent. The API trims whitespace, caps input at 100 bytes, and validates decimal bounds. Sent unchanged, without rounding.",
  }
  const query = (input: Input) =>
    new URLSearchParams(Object.entries(input).map(([key, value]) => [key, String(value)]))

  return [
    tool(
      "autolaunch_auctions",
      "List public Autolaunch auctions. Returns stored public data, not a live chain read.",
      {
        after: {type: "string", description: "Pass pagination.next_cursor unchanged with the same mode and sort. Cursors expire after 24 hours."},
        mode: {type: "string", enum: ["all", "biddable", "live", "failed_minimum", "graduated"]},
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
      "Read one public Autolaunch auction by UUID, including its stored treasury report when available.",
      {id},
      ["id"],
      input => ({path: `/api/v1/auctions/${pathValue(input.id)}`}),
      signal,
    ),
    tool(
      "autolaunch_tokens",
      "List public graduated Autolaunch tokens.",
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
