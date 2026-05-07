import { isAddress } from "viem"

export class HttpRequestError extends Error {
  status: number

  constructor(message: string, status: number) {
    super(message)
    this.name = "HttpRequestError"
    this.status = status
  }
}

export type AutolaunchWalletConfig = {
  privyAppId?: string
  privySession?: string
}

export function parseConfig(raw: string | null | undefined): AutolaunchWalletConfig | null {
  if (!raw) return null

  try {
    return JSON.parse(raw) as AutolaunchWalletConfig
  } catch {
    return null
  }
}

export function normalizeWalletAddress(value: string | null | undefined): `0x${string}` | null {
  const trimmed = value?.trim()
  if (!trimmed || !isAddress(trimmed)) return null
  return trimmed as `0x${string}`
}

export function shortWallet(value: string | null | undefined): string {
  const address = normalizeWalletAddress(value)
  if (!address) return "Wallet"
  return `${address.slice(0, 6)}...${address.slice(-4)}`
}

export function privyDebugEnabled(): boolean {
  if (typeof window === "undefined") return false

  const params = new URLSearchParams(window.location.search)
  return params.get("debug_privy") === "1" || window.localStorage.getItem("debug:privy") === "1"
}

export function redactWalletForDebug(value: string | null | undefined): string | null {
  const address = normalizeWalletAddress(value)
  if (!address) return null
  return `${address.slice(0, 6)}...${address.slice(-4)}`
}

export function privyDebugLog(
  level: "info" | "warn" | "error",
  event: string,
  details: Record<string, unknown> = {},
) {
  if (!privyDebugEnabled()) return

  const prefix = `[privy-debug] ${event}`

  if (level === "error") {
    console.error(prefix, details)
    return
  }

  if (level === "warn") {
    console.warn(prefix, details)
    return
  }

  console.info(prefix, details)
}

export function debugHttpError(error: unknown): Record<string, unknown> {
  if (error instanceof HttpRequestError) {
    return { name: error.name, message: error.message, status: error.status }
  }

  if (error instanceof Error) {
    return { name: error.name, message: error.message }
  }

  return { message: String(error) }
}

export function getErrorMessage(error: unknown, fallback: string): string {
  if (error instanceof Error && error.message.trim() !== "") return error.message

  if (error && typeof error === "object" && "message" in error) {
    const message = (error as { message?: unknown }).message
    if (typeof message === "string" && message.trim() !== "") return message
  }

  return fallback
}

export function getPrivyDisplayName(privyUser: unknown): string | null {
  if (!privyUser || typeof privyUser !== "object") return null

  if (
    "email" in privyUser &&
    privyUser.email &&
    typeof privyUser.email === "object" &&
    "address" in privyUser.email &&
    typeof privyUser.email.address === "string" &&
    privyUser.email.address.trim()
  ) {
    return privyUser.email.address.trim()
  }

  if (
    "twitter" in privyUser &&
    privyUser.twitter &&
    typeof privyUser.twitter === "object" &&
    "username" in privyUser.twitter &&
    typeof privyUser.twitter.username === "string" &&
    privyUser.twitter.username.trim()
  ) {
    return privyUser.twitter.username.trim()
  }

  return null
}

export async function fetchJson<T>(input: string, init: RequestInit = {}): Promise<T> {
  const csrfToken = document
    .querySelector("meta[name='csrf-token']")
    ?.getAttribute("content")
    ?.trim()

  const method = (init.method ?? "GET").toUpperCase()
  const shouldSendCsrf =
    csrfToken &&
    ["POST", "PUT", "PATCH", "DELETE"].includes(method) &&
    !hasHeader(init.headers, "x-csrf-token")

  const response = await fetch(input, {
    ...init,
    credentials: init.credentials ?? "same-origin",
    headers: {
      accept: "application/json",
      ...(shouldSendCsrf ? { "x-csrf-token": csrfToken } : {}),
      ...(init.headers ?? {}),
    },
  })

  const text = await response.text()
  const payload = tryParseJson(text)

  if (!response.ok) {
    const parsed = payload as
      | { error?: { message?: unknown }; statusMessage?: unknown; message?: unknown }
      | null

    const message =
      (parsed &&
        ((typeof parsed.error?.message === "string" && parsed.error.message) ||
          (typeof parsed.statusMessage === "string" && parsed.statusMessage) ||
          (typeof parsed.message === "string" && parsed.message))) ||
      text ||
      `Request failed (${response.status})`

    throw new HttpRequestError(message, response.status)
  }

  return (payload ?? {}) as T
}

function hasHeader(headers: HeadersInit | undefined, name: string): boolean {
  if (!headers) return false

  const normalized = name.toLowerCase()

  if (headers instanceof Headers) return headers.has(normalized)

  if (Array.isArray(headers)) {
    return headers.some(([headerName]) => headerName.toLowerCase() === normalized)
  }

  return Object.keys(headers).some((headerName) => headerName.toLowerCase() === normalized)
}

function tryParseJson(value: string): unknown {
  if (!value) return null

  try {
    return JSON.parse(value)
  } catch {
    return null
  }
}
