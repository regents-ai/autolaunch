import {loadProfileAction, type ProfileAction} from "../vendor/regent_identity/profile_client.mjs"
import {installSharedProfile} from "./shared_profile"
export type AccountRequest = "sign-in" | "sign-out" | "sync"

export type IdentityProvider = "x" | "github" | "farcaster"

export type IdentityRequest = {
  action: "link" | "unlink"
  provider: IdentityProvider
  subject?: string
}

export type PrivyBridgeHandle = {
  profile?: ProfileAction
  request: (request: AccountRequest) => Promise<void>
  identity?: (request: IdentityRequest) => Promise<void>
  finishSignOutOnly?: () => void
}

export type PrivyBridgeStartupOptions = {
  mode?: "ordinary" | "sign-out-only" | "profile-only"
}

export type PrivyBridgeModule = {
  startPrivyBridge: (options?: PrivyBridgeStartupOptions) => Promise<PrivyBridgeHandle>
}

type PrivyBridgeImporter = () => Promise<PrivyBridgeModule>

type BrowserPrivyBridgeImporterOptions = {
  bridgeSource: string | null
  runtimeImport?: (url: string) => Promise<PrivyBridgeModule>
  currentOrigin?: string
}

type AccountAuthInstallOptions = {
  clearSession?: () => Promise<void>
  handoffStorage?: Pick<Storage, "getItem" | "setItem" | "removeItem">
  now?: () => number
  providerSignOutTimeoutMs?: number
  reload?: () => void
  sessionMutations?: SessionMutationCoordinator
  signedInStartupTimeoutMs?: number
}

const defaultProviderSignOutTimeoutMs = 1_500
const defaultSignedInStartupTimeoutMs = 5_000
const signOutHandoffKey = "autolaunch:privy-sign-out-handoff:v1"
const signOutHandoffMaxAgeMs = 30_000
const consumedHandoffDocuments = new WeakSet<Document>()
const reloadedDocuments = new WeakSet<Document>()

const bridgePath = /^\/assets\/js\/privy_bridge(?:-[a-f0-9]{32})?\.js$/

export function reloadDocumentOnce(documentRoot: Document, reload: () => void): void {
  if (reloadedDocuments.has(documentRoot)) return
  reloadedDocuments.add(documentRoot)
  reload()
}

export const sessionLifecycles = [
  "session_superseded",
  "session_reset_required",
  "account_switch_required",
] as const

export type SessionLifecycle = (typeof sessionLifecycles)[number]

export class SessionLifecycleError extends Error {
  constructor(readonly lifecycle: SessionLifecycle) {
    super("This browser session changed. Starting it again.")
  }
}

export async function sessionLifecycleError(
  response: Response,
): Promise<SessionLifecycleError | null> {
  if (response.status !== 409) return null
  const {error} = (await response.json()) as {error?: SessionLifecycle}
  return error && sessionLifecycles.includes(error) ? new SessionLifecycleError(error) : null
}

// A superseded, reset or switched lineage recovers from the cookie the winning
// response already left in this browser, in exactly one further attempt.
export async function recoverOnce<T>(attempt: () => Promise<T>): Promise<T> {
  try {
    return await attempt()
  } catch (error) {
    if (!(error instanceof SessionLifecycleError)) throw error
    return attempt()
  }
}

// The page's meta tag is the one place the browser's current CSRF token lives,
// so the lazily imported bridge and the socket always read the same value.
function csrfMeta(): HTMLMetaElement | null {
  return globalThis.document?.querySelector<HTMLMetaElement>("meta[name='csrf-token']") ?? null
}

export function browserCsrfToken(): string {
  return csrfMeta()?.content ?? ""
}

export async function csrfToken(
  fetcher: typeof fetch = fetch,
  signal?: AbortSignal,
  renewed: () => void = () => {},
): Promise<string> {
  const response = await fetcher("/auth/csrf", {
    credentials: "same-origin",
    ...(signal ? {signal} : {}),
  })

  try {
    const lifecycle = await sessionLifecycleError(response)
    if (lifecycle) throw lifecycle
    if (!response.ok) throw new Error("Unable to start a secure session change.")
    const body = (await response.json()) as {csrf_token?: unknown}
    if (typeof body.csrf_token !== "string" || body.csrf_token.length === 0) {
      throw new Error("Unable to start a secure session change.")
    }
    const meta = csrfMeta()
    if (meta) meta.content = body.csrf_token
    return body.csrf_token
  } catch (refusal) {
    // The browser took whatever cookie this response carried when its headers
    // landed, so only the body can say what that was. A 200 is a bootstrap that
    // rotated or an observation that wrote nothing, and only the token in it
    // separates them and adopts the result; a 409 is a revoked lineage that
    // dropped unless the body says superseded. A status no branch writes a
    // session on left the cookie alone, and only an adopted token proves this
    // tab reads what it now carries.
    const wroteNothing =
      refusal instanceof SessionLifecycleError && refusal.lifecycle === "session_superseded"
    if ((response.ok || response.status === 409) && !wroteNothing) renewed()
    throw refusal
  }
}

let openRotations = 0
let unreadRenewal = false
let adoptingRenewal: Promise<void> | null = null
const heldSockets = new Set<() => void>()

// True only while this tab is known to hold the CSRF state of the cookie it
// would connect under.
const csrfStateIsCurrent = () => openRotations === 0 && !unreadRenewal

// The pinned phoenix 1.8.9 socket. `types.d.ts` names only the LiveSocket
// surface this application calls, so the transport entry point the barrier owns
// is named here.
export type PinnedSocket = {connect: () => void; transportConnect: () => void}

// `Socket.transportConnect` is the single place phoenix 1.8.9 builds a
// transport. `connect` reaches it for the page's first attempt, every reconnect
// and the pageshow and visibility recoveries; `connectWithFallback` reaches it
// again from both its long-poll timer and its transport-error path, which call
// it directly rather than through `connect`. Refusing it there is what makes
// the barrier real rather than an ordering an independent reconnect never waits
// for. An open socket never reaches it, so a mounted same-account socket
// survives the rotation. A renewal whose own adoption failed left this tab
// closed, and the refusal here is the connection opportunity that reads the
// state the cookie now carries.
export function holdSocketDuringCookieRotation(
  socket: PinnedSocket,
  fetcher: typeof fetch = fetch,
): void {
  const transportConnect = socket.transportConnect.bind(socket)
  let held = false

  heldSockets.add(() => {
    if (!held) return
    held = false
    transportConnect()
  })

  socket.transportConnect = () => {
    if (csrfStateIsCurrent()) return transportConnect()
    held = true
    if (openRotations === 0) adoptUnreadRenewal(fetcher)
  }
}

// One read, shared by every attempt overlapping it, including the long poll the
// pinned `connectWithFallback` swaps in behind the websocket.
function adoptUnreadRenewal(fetcher: typeof fetch): void {
  if (adoptingRenewal) return

  const settled = () => {
    adoptingRenewal = null
  }

  adoptingRenewal = browserSessionMutations.establish(async signal => {
    // Sign in, refresh, switch and sign out are ordered ahead of this retry, so
    // one of them may already have read what the cookie carries by the time it
    // runs. Reading again would answer for a renewal this tab no longer has,
    // and closing it again would strand a transport that is already current.
    if (!unreadRenewal) return
    await csrfToken(fetcher, signal)
    // A rotation that opened while this read was in flight latched a renewal
    // newer than the one it answers for, and only that rotation can say this
    // tab has read it.
    if (openRotations > 0) return
    unreadRenewal = false
    heldSockets.forEach(release => release())
  })
  void adoptingRenewal.then(settled, settled)
}

// The interval between a response that rotated or dropped the cookie and this
// tab reading the CSRF state that cookie now carries. No transport may be
// established inside it, because the token it would send belongs to the retired
// session. Callers name the exact endpoint outcomes that write a session and
// call `renewed` for those alone: a rotation failing before one of them changed
// no cookie and leaves reconnects available, while one failing after it stays
// closed until a later rotation reads the current state.
export async function acrossCookieRotation<T>(
  rotation: (renewed: () => void) => Promise<T>,
): Promise<T> {
  openRotations += 1

  try {
    const adopted = await rotation(() => {
      unreadRenewal = true
    })
    // A rotation that opened while this one was reading latched a renewal newer
    // than the read that just landed, so only the rotation `openRotations` still
    // represents alone may say this tab holds what the cookie carries.
    if (openRotations === 1) unreadRenewal = false
    return adopted
  } finally {
    openRotations -= 1
    if (csrfStateIsCurrent()) heldSockets.forEach(release => release())
  }
}

export const csrfRotated = "autolaunch:csrf-rotated:v1"

let crossTabCsrf: BroadcastChannel | null | undefined

function csrfChannel(): BroadcastChannel | null {
  crossTabCsrf ??= globalThis.BroadcastChannel ? new BroadcastChannel(csrfRotated) : null
  return crossTabCsrf
}

// The notice carries no claim and no token. A tab that receives it asks the
// server under the cookie every tab already shares, so nothing secret crosses
// the channel and a tab that misses it simply recovers on its next connection.
export function announceCsrfRotation(): void {
  csrfChannel()?.postMessage(csrfRotated)
}

export function installCrossTabCsrf(fetcher: typeof fetch = fetch): () => void {
  const channel = csrfChannel()
  const adopt = (event: MessageEvent) => {
    if (event.data !== csrfRotated) return
    // The renewal already happened in the tab that sent the notice, so the
    // shared cookie has changed by the time it lands here: the interval opens on
    // delivery, and a connect arriving before the queue reaches the read is held
    // rather than sent under the token that cookie retired. Only the read takes
    // the queue, so no other read of the cookie answers for this renewal first,
    // and a read that fails leaves this tab closed.
    void acrossCookieRotation(renewed => {
      renewed()
      return browserSessionMutations.establish(signal => csrfToken(fetcher, signal))
    }).catch(() => undefined)
  }

  channel?.addEventListener("message", adopt)
  return () => channel?.removeEventListener("message", adopt)
}

// Sign out leads with the token this page holds, which is what lets a stale
// lineage still revoke itself. Only a CSRF refusal means another tab rotated the
// shared cookie underneath this one; that alone earns a single adoption and one
// more attempt at an idempotent delete. Every other failure is final.
export async function clearLocalSession(fetcher: typeof fetch = fetch): Promise<void> {
  const refused = await deleteLocalSession(fetcher, browserCsrfToken())
  if (!refused) return

  const retried = await deleteLocalSession(fetcher, await csrfToken(fetcher))
  if (retried) throw new Error("Sign out could not be completed.")
}

async function deleteLocalSession(fetcher: typeof fetch, csrf: string): Promise<boolean> {
  const response = await fetcher("/auth/privy/session", {
    method: "DELETE",
    credentials: "same-origin",
    headers: {"x-csrf-token": csrf},
  })
  if (response.ok) return false
  if (response.status === 403) return true
  throw new Error("Sign out could not be completed.")
}

type SignOutHandoff = {version: 1; issuedAtMs: number}

function handoffStorageOrNull(
  storage?: Pick<Storage, "getItem" | "setItem" | "removeItem">,
) {
  if (storage) return storage
  try {
    return window.sessionStorage
  } catch {
    return null
  }
}

export function writeSignOutHandoff(
  storage: Pick<Storage, "getItem" | "setItem" | "removeItem"> | null,
  issuedAtMs: number,
): boolean {
  if (!storage || !Number.isInteger(issuedAtMs)) return false
  const value = JSON.stringify({version: 1, issuedAtMs} satisfies SignOutHandoff)

  try {
    storage.setItem(signOutHandoffKey, value)
  } catch {
    return false
  }

  try {
    return storage.getItem(signOutHandoffKey) === value
  } catch {
    return false
  }
}

export function clearSignOutHandoff(
  storage: Pick<Storage, "getItem" | "setItem" | "removeItem"> | null,
): void {
  if (!storage) return

  try {
    storage.removeItem(signOutHandoffKey)
  } catch {
    try {
      storage.setItem(signOutHandoffKey, "")
    } catch {
      return
    }
  }

  try {
    if (storage.getItem(signOutHandoffKey) !== null) {
      storage.setItem(signOutHandoffKey, "")
      void storage.getItem(signOutHandoffKey)
    }
  } catch {
    // Cleanup is best-effort and must never mask the local sign-out failure.
  }
}

function validSignOutHandoff(value: string, nowMs: number): boolean {
  try {
    const parsed = JSON.parse(value) as unknown
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return false
    const record = parsed as Record<string, unknown>
    if (Object.keys(record).sort().join(",") !== "issuedAtMs,version") return false
    if (record.version !== 1 || !Number.isInteger(record.issuedAtMs)) return false
    const issuedAtMs = record.issuedAtMs as number
    return issuedAtMs <= nowMs && nowMs - issuedAtMs <= signOutHandoffMaxAgeMs
  } catch {
    return false
  }
}

export function consumeSignOutHandoff(
  documentRoot: Document,
  storage: Pick<Storage, "getItem" | "setItem" | "removeItem"> | null,
  nowMs: number,
): boolean {
  if (consumedHandoffDocuments.has(documentRoot)) return false
  consumedHandoffDocuments.add(documentRoot)
  if (!storage) return false

  let captured: string | null
  try {
    captured = storage.getItem(signOutHandoffKey)
  } catch {
    return false
  }

  try {
    storage.removeItem(signOutHandoffKey)
  } catch {
    return false
  }

  try {
    if (storage.getItem(signOutHandoffKey) !== null) return false
  } catch {
    return false
  }

  return captured !== null && validSignOutHandoff(captured, nowMs)
}

// The one place account-action failure copy lives, so a failure raised inside
// the Privy bridge's own login callbacks says exactly what a failure raised here
// says.
export function showAccountAuthFailure(
  request: AccountRequest,
  documentRoot: Document | undefined = globalThis.document,
): void {
  const status = documentRoot?.querySelector<HTMLElement>("#account-auth-status")
  if (!status) return
  status.textContent = {
    "sign-in": "Sign in couldn’t start. Try again.",
    "sign-out": "Sign out couldn’t finish. Try again.",
    sync: "Account connection couldn’t refresh. Try again.",
  }[request]
  status.hidden = false
}

export async function proveAnonymousSession(fetcher: typeof fetch = fetch): Promise<boolean> {
  try {
    const response = await fetcher("/auth/session", {
      credentials: "same-origin",
      redirect: "error",
    })
    if (!response.ok || response.redirected) return false
    const body = (await response.json()) as unknown
    return Boolean(
      body &&
        typeof body === "object" &&
        (body as {authenticated?: unknown}).authenticated === false,
    )
  } catch {
    return false
  }
}

export type SessionMutation<T> = (signal: AbortSignal, commit: () => void) => Promise<T>

export type SessionMutationCoordinator = {
  establish<T>(mutation: SessionMutation<T>): Promise<T>
  signOut(clearSession: () => Promise<void>): Promise<void>
}

function cancelledSessionEstablishment(signal: AbortSignal): never {
  throw signal.reason ?? new Error("Local sign out has already started.")
}

export function createSessionMutationCoordinator(): SessionMutationCoordinator {
  let establishmentTail: Promise<void> = Promise.resolve()
  let signingOut = false
  let signOutAttempt: Promise<void> | null = null
  const cancellable = new Set<AbortController>()

  return {
    establish<T>(mutation: SessionMutation<T>): Promise<T> {
      if (signingOut) {
        return Promise.reject(new Error("Local sign out has already started."))
      }

      const controller = new AbortController()
      cancellable.add(controller)
      // A mutation commits at the point a response could renew the cookie.
      // After that it is no longer cancellable, so sign out can never run
      // against a renewed cookie whose token this tab has not adopted yet.
      const commit = () => cancellable.delete(controller)
      const attempt = establishmentTail.then(() => {
        if (signingOut || controller.signal.aborted) {
          cancelledSessionEstablishment(controller.signal)
        }
        return mutation(controller.signal, commit)
      })

      void attempt.then(commit, commit)
      establishmentTail = attempt.then(
        () => undefined,
        () => undefined,
      )
      return attempt
    },
    signOut(clearSession: () => Promise<void>): Promise<void> {
      if (signOutAttempt) return signOutAttempt
      signingOut = true
      cancellable.forEach(controller => controller.abort())

      const attempt = establishmentTail.then(clearSession)
      signOutAttempt = attempt
      void attempt.catch(() => {
        if (signOutAttempt === attempt) signOutAttempt = null
      })
      return attempt
    },
  }
}

export const browserSessionMutations = createSessionMutationCoordinator()

function withinWindow<T>(
  attempt: Promise<T>,
  timeoutMs: number,
  timeoutMessage: string,
): Promise<T> {
  return new Promise((resolve, reject) => {
    const timeout = globalThis.setTimeout(
      () => reject(new Error(timeoutMessage)),
      timeoutMs,
    )
    void attempt.then(
      value => {
        globalThis.clearTimeout(timeout)
        resolve(value)
      },
      error => {
        globalThis.clearTimeout(timeout)
        reject(error)
      },
    )
  })
}

function validatedBridgeUrl(bridgeSource: string | null, currentOrigin: string): URL | null {
  if (!bridgeSource) return null

  try {
    const candidate = new URL(bridgeSource, currentOrigin)
    const allowedQuery = candidate.search === "" || candidate.search === "?vsn=d"

    return candidate.origin === currentOrigin &&
      candidate.username === "" &&
      candidate.password === "" &&
      candidate.hash === "" &&
      allowedQuery &&
      bridgePath.test(candidate.pathname)
      ? candidate
      : null
  } catch {
    return null
  }
}

export function createBrowserPrivyBridgeImporter({
  bridgeSource,
  runtimeImport = url => import(url),
  currentOrigin = window.location.origin,
}: BrowserPrivyBridgeImporterOptions): PrivyBridgeImporter {
  let retryNumber = 0

  return async () => {
    const bridgeUrl = validatedBridgeUrl(bridgeSource, currentOrigin)
    if (!bridgeUrl) throw new Error("Privy bridge source is unavailable")

    bridgeUrl.searchParams.set("autolaunch_retry", String(retryNumber))
    retryNumber += 1
    return runtimeImport(bridgeUrl.href)
  }
}

export function createLazyAuthLoader(
  importer: PrivyBridgeImporter,
  startupOptions: PrivyBridgeStartupOptions = {},
) {
  let state: "ordinary" | "handoff-preterminal" | "handoff-terminal" =
    startupOptions.mode === "sign-out-only" ? "handoff-preterminal" : "ordinary"
  let handle: PrivyBridgeHandle | null = null
  let preparing: Promise<void> | null = null
  let pending: AccountRequest | IdentityRequest | null = null
  let delivering: {
    request: AccountRequest | IdentityRequest
    promise: Promise<void>
  } | null = null

  const sameRequest = (
    first: AccountRequest | IdentityRequest,
    second: AccountRequest | IdentityRequest,
  ) =>
    typeof first === "string" || typeof second === "string"
      ? first === second
      : first.action === second.action &&
        first.provider === second.provider &&
        first.subject === second.subject

  const deliverPending = (): Promise<void> => {
    if (!handle) return Promise.resolve()
    if (delivering) {
      return pending === null || sameRequest(delivering.request, pending)
        ? delivering.promise
        : delivering.promise.then(deliverPending, deliverPending)
    }
    if (!pending) return Promise.resolve()

    const request = pending
    pending = null
    const attempt =
      typeof request === "string"
        ? handle.request(request)
        : handle.identity
          ? handle.identity(request)
          : Promise.reject(new Error("Privy identity bridge is not ready"))
    const settle = () => {
      if (delivering?.promise === attempt) delivering = null
      void deliverPending().catch(() => undefined)
    }
    delivering = {request, promise: attempt}
    void attempt.then(settle, settle)
    return attempt
  }

  const prepare = (profileOnly = false): Promise<void> => {
    const attempt = importer()
      .then(module => {
        if (typeof module.startPrivyBridge !== "function") {
          throw new Error("Privy bridge module is invalid")
        }
        return profileOnly && !startupOptions.mode
          ? module.startPrivyBridge({mode: "profile-only"})
          : startupOptions.mode
          ? module.startPrivyBridge(startupOptions)
          : module.startPrivyBridge()
      })
      .then(readyHandle => {
        if (!readyHandle || typeof readyHandle.request !== "function") {
          throw new Error("Privy bridge handle is invalid")
        }
        handle = readyHandle
        preparing = null
        if (state === "handoff-terminal") handle.finishSignOutOnly?.()
        return deliverPending()
      })

    preparing = attempt
    void attempt.catch(() => {
      if (preparing === attempt) preparing = null
    })
    return attempt
  }

  return {
    request(request: AccountRequest): Promise<void> {
      if (state === "handoff-preterminal" && request !== "sign-out") {
        return Promise.reject(new Error("Provider sign out is still in progress."))
      }
      if (state === "handoff-terminal") {
        if (request === "sign-out") return Promise.resolve()
        if (request === "sync") {
          return Promise.reject(new Error("Automatic reconciliation is disabled."))
        }
      }
      if (
        delivering &&
        sameRequest(delivering.request, request) &&
        pending === null
      ) {
        return delivering.promise
      }
      pending = request
      if (handle) return deliverPending()
      return preparing ?? prepare()
    },
    identity(request: IdentityRequest): Promise<void> {
      if (state === "handoff-preterminal") {
        return Promise.reject(new Error("Provider sign out is still in progress."))
      }
      if (
        delivering &&
        sameRequest(delivering.request, request) &&
        pending === null
      ) {
        return delivering.promise
      }
      pending = request
      if (handle) return deliverPending()
      return preparing ?? prepare()
    },
    async profile(...args: Parameters<ProfileAction>): ReturnType<ProfileAction> {
      if (state === "handoff-preterminal") {
        return {ok: false, status: null, error: {code: "authentication_required", outcome_unknown: false}}
      }
      return loadProfileAction(async () => {
        if (!handle) await (preparing ?? prepare(true))
        if (!handle?.profile) throw new Error("Profile bridge is unavailable")
        return handle.profile
      }, ...args)
    },
    finishHandoff(): void {
      if (state !== "handoff-preterminal") return
      state = "handoff-terminal"
      pending = null
      handle?.finishSignOutOnly?.()
    },
  }
}

export function installAccountAuthLazyLoader(
  documentRoot: Document = document,
  importer?: PrivyBridgeImporter,
  {
    clearSession = clearLocalSession,
    handoffStorage,
    now = () => Date.now(),
    providerSignOutTimeoutMs = defaultProviderSignOutTimeoutMs,
    reload = () => window.location.reload(),
    sessionMutations = browserSessionMutations,
    signedInStartupTimeoutMs = defaultSignedInStartupTimeoutMs,
  }: AccountAuthInstallOptions = {},
): () => void {
  const storage = handoffStorageOrNull(handoffStorage)
  const consumedHandoff = consumeSignOutHandoff(documentRoot, storage, now())
  const bridgeSource = documentRoot.querySelector<HTMLMetaElement>(
    "meta[name='privy-bridge-src']",
  )?.content
  const loader = createLazyAuthLoader(
    importer ?? createBrowserPrivyBridgeImporter({bridgeSource: bridgeSource ?? null}),
    consumedHandoff ? {mode: "sign-out-only"} : {},
  )
  const stopProfile = installSharedProfile(documentRoot, loader)
  const clearStatus = () => {
    const status = documentRoot.querySelector<HTMLElement>("#account-auth-status")
    if (!status) return
    status.textContent = ""
    status.hidden = true
  }
  const showLoadFailure = (request: AccountRequest) =>
    showAccountAuthFailure(request, documentRoot)
  // The leading clear owns this click's startup. Nothing clears afterwards: a
  // login callback that failed while the request was settling has already
  // written the failure this click must leave visible.
  const request = (accountRequest: AccountRequest) => {
    clearStatus()
    void loader.request(accountRequest).catch(() => showLoadFailure(accountRequest))
  }
  let signOutInFlight: Promise<void> | null = null
  const signOut = () => {
    if (signOutInFlight) return
    clearStatus()

    if (!writeSignOutHandoff(storage, now())) {
      showLoadFailure("sign-out")
      return
    }

    const attempt = (async () => {
      try {
        await sessionMutations.signOut(clearSession)
      } catch {
        clearSignOutHandoff(storage)
        showLoadFailure("sign-out")
        return
      }
      clearStatus()
      reloadDocumentOnce(documentRoot, reload)
    })()

    signOutInFlight = attempt
    void attempt.finally(() => {
      if (signOutInFlight === attempt) signOutInFlight = null
    })
  }
  const onClick = (event: Event) => {
    const target = event.target instanceof Element ? event.target : null
    const accountTarget = target?.closest<HTMLElement>("[data-account-target]")?.dataset
      .accountTarget

    if (accountTarget === "sign-in") request("sign-in")
    if (accountTarget === "sign-out") signOut()
  }
  const onIdentityRequest = (event: Event) => {
    if (!(event instanceof CustomEvent) || !isIdentityRequest(event.detail)) return
    clearStatus()
    void loader
      .identity(event.detail)
      .then(clearStatus)
      .catch(() => showIdentityFailure())
  }
  const showIdentityFailure = () => {
    const status = documentRoot.querySelector<HTMLElement>("#account-auth-status")
    if (!status) return
    status.textContent = "That connection couldn’t be updated. Try again."
    status.hidden = false
  }

  const reconcileSignedInStartup = () => {
    clearStatus()
    void withinWindow(
      loader.request("sync"),
      signedInStartupTimeoutMs,
      "Provider session reconciliation did not become ready.",
    ).catch(() => undefined)
  }

  documentRoot.addEventListener("click", onClick)
  documentRoot.addEventListener("autolaunch:identity-request", onIdentityRequest)
  if (consumedHandoff) {
    void proveAnonymousSession().then(async anonymous => {
      if (!anonymous) {
        loader.finishHandoff()
        return
      }

      try {
        await withinWindow(
          loader.request("sign-out"),
          providerSignOutTimeoutMs,
          "Provider sign out did not become ready.",
        )
      } catch {
        // Provider cleanup is best-effort background work.
      } finally {
        loader.finishHandoff()
      }
    })
  } else if (documentRoot.querySelector("#account-control [data-account-target='sign-out']")) {
    reconcileSignedInStartup()
  }
  return () => {
    stopProfile()
    documentRoot.removeEventListener("click", onClick)
    documentRoot.removeEventListener("autolaunch:identity-request", onIdentityRequest)
  }
}

function isIdentityRequest(value: unknown): value is IdentityRequest {
  if (!value || typeof value !== "object") return false
  const request = value as Partial<IdentityRequest>
  return (
    (request.action === "link" || request.action === "unlink") &&
    (request.provider === "x" ||
      request.provider === "github" ||
      request.provider === "farcaster") &&
    (request.subject === undefined || typeof request.subject === "string")
  )
}
