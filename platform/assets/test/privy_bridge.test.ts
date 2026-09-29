import {afterEach, describe, expect, it, vi} from "vitest"
import React from "react"
import type {PrivyEvents} from "@privy-io/react-auth"

const productionRootRender = vi.hoisted(() => vi.fn())
const productionRootUnmount = vi.hoisted(() => vi.fn())
const productionPrivyHooks = vi.hoisted(() => ({
  tokenCallbacks: {} as PrivyEvents["accessToken"],
  loginCallbacks: {} as PrivyEvents["login"],
  linkCallbacks: {} as PrivyEvents["linkAccount"],
  login: vi.fn(),
  linkTwitter: vi.fn(),
  linkGithub: vi.fn(),
  linkFarcaster: vi.fn(),
  unlinkOAuth: vi.fn(async () => undefined),
  unlinkFarcaster: vi.fn(async () => undefined),
  connectActiveWallet: vi.fn(async () => ({})),
}))

vi.mock("react-dom/client", () => ({
  createRoot: () => ({render: productionRootRender, unmount: productionRootUnmount}),
}))

vi.mock("@privy-io/react-auth", () => ({
  PrivyProvider: "privy-provider",
  usePrivy: () => ({authenticated: false, logout: vi.fn(), ready: true}),
  useWallets: () => ({ready: true, wallets: []}),
  useActiveWallet: () => ({
    wallet: undefined,
    connect: productionPrivyHooks.connectActiveWallet,
  }),
  useToken: (callbacks: PrivyEvents["accessToken"]) => {
    productionPrivyHooks.tokenCallbacks = callbacks
    return {getAccessToken: vi.fn(async () => null)}
  },
  getIdentityToken: vi.fn(async () => null),
  useLogin: (callbacks: PrivyEvents["login"]) => {
    productionPrivyHooks.loginCallbacks = callbacks
    return {login: productionPrivyHooks.login}
  },
  useLinkAccount: (callbacks: PrivyEvents["linkAccount"]) => {
    productionPrivyHooks.linkCallbacks = callbacks
    return {
      linkTwitter: productionPrivyHooks.linkTwitter,
      linkGithub: productionPrivyHooks.linkGithub,
      linkFarcaster: productionPrivyHooks.linkFarcaster,
    }
  },
  useUnlinkOAuth: () => ({unlink: productionPrivyHooks.unlinkOAuth}),
  useUnlinkFarcaster: () => ({unlink: productionPrivyHooks.unlinkFarcaster}),
}))

afterEach(() => {
  vi.useRealTimers()
  vi.unstubAllGlobals()
  vi.restoreAllMocks()
})

import * as bridge from "../js/privy_bridge"
import {
  browserSessionMutations,
  clearLocalSession,
  createLazyAuthLoader,
  createSessionMutationCoordinator,
} from "../js/auth_lazy"
import {
  activeEthereumWallet,
  replaceActiveEthereumWallet,
  selectConnectedEthereumWallet,
  type EthereumProvider,
} from "../js/wallet_actions/connected_wallet"

const {
  createLocalSession,
  createAccountRequestHandler,
  createIdentityRequestHandler,
  createProviderSessionReconciler,
  createSignOutOnlyBridgeState,
  createPrivyLoginCallbacks,
  createPrivyTokenPairSource,
  createSignInRequest,
  createPrivySessionCompletion,
  createPrivyTokenCallbacks,
} = bridge

// One complete pair: the session proof and the signed evidence it was acquired
// with. Establishment never sees anything else.
const verifiedPair = {accessToken: "verified", identityToken: "verified-identity"}
const acquireVerifiedPair = async () => verifiedPair

type HookSlot = {
  deps?: readonly unknown[]
  value?: unknown
}

function installAccountBridgeRenderer() {
  const slots: HookSlot[] = []
  let cursor = 0
  let pendingEffects: React.EffectCallback[] = []
  const unchanged = (left?: readonly unknown[], right?: readonly unknown[]) =>
    left !== undefined &&
    right !== undefined &&
    left.length === right.length &&
    left.every((value, index) => Object.is(value, right[index]))

  vi.spyOn(React, "useRef").mockImplementation(((initial: unknown) => {
    const index = cursor++
    if (!slots[index]) slots[index] = {value: {current: initial}}
    return slots[index].value
  }) as typeof React.useRef)
  vi.spyOn(React, "useMemo").mockImplementation(((factory: () => unknown, deps?: unknown[]) => {
    const index = cursor++
    if (!slots[index] || !unchanged(slots[index].deps, deps)) {
      slots[index] = {deps, value: factory()}
    }
    return slots[index].value
  }) as typeof React.useMemo)
  vi.spyOn(React, "useCallback").mockImplementation(((callback: unknown, deps?: unknown[]) => {
    const index = cursor++
    if (!slots[index] || !unchanged(slots[index].deps, deps)) {
      slots[index] = {deps, value: callback}
    }
    return slots[index].value
  }) as typeof React.useCallback)
  vi.spyOn(React, "useEffect").mockImplementation(((effect: React.EffectCallback, deps?: unknown[]) => {
    const index = cursor++
    if (!slots[index] || !unchanged(slots[index].deps, deps)) {
      slots[index] = {deps}
      pendingEffects.push(effect)
    }
  }) as typeof React.useEffect)

  return (element: React.ReactElement, commit = true) => {
    cursor = 0
    pendingEffects = []
    ;(element.type as (props: unknown) => unknown)(element.props)
    const effects = pendingEffects
    pendingEffects = []
    const commitEffects = () => effects.forEach(effect => effect())
    if (commit) commitEffects()
    return commitEffects
  }
}

// The account control is the only evidence of whether a page is signed in, so
// schedules that turn on it name their marker; the default page shows neither.
function stubBrowserGlobals(accountMarker: "sign-in" | "sign-out" | null = null) {
  const dispatched: string[] = []
  const reload = vi.fn()

  vi.stubGlobal("document", {
    body: {append: vi.fn()},
    createElement: () => ({hidden: false}),
    querySelector: (selector: string) =>
      accountMarker && selector === `#account-control [data-account-target='${accountMarker}']`
        ? {}
        : null,
  })
  vi.stubGlobal("window", {
    addEventListener: () => undefined,
    removeEventListener: () => undefined,
    dispatchEvent: (event: {type: string}) => dispatched.push(event.type),
    location: {origin: "https://regents.sh", reload},
  })
  vi.stubGlobal(
    "CustomEvent",
    class {
      constructor(readonly type: string) {}
    },
  )

  return {dispatched, reload}
}

function stubSessionRequests(): Array<{url: string; method: string}> {
  const requests: Array<{url: string; method: string}> = []

  vi.stubGlobal(
    "fetch",
    vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      requests.push({url: String(input), method: init?.method ?? "GET"})
      return String(input) === "/auth/csrf"
        ? new Response(JSON.stringify({csrf_token: "csrf"}), {status: 200})
        : new Response("{}", {status: 200, headers: {"x-autolaunch-session-changed": "true"}})
    }),
  )

  return requests
}

// The root render is the failure boundary around the provider around the
// account bridge; the bridge is the function component the harness runs.
function renderedAccountBridge(): React.ReactElement {
  const boundaryElement = productionRootRender.mock.calls[0]?.[0] as React.ReactElement<{
    children: React.ReactElement<{children: React.ReactElement}>
  }>
  return boundaryElement.props.children.props.children
}

function ethereumWallet(address: string) {
  const provider: EthereumProvider = {request: vi.fn()}
  return {address, type: "ethereum", provider, getEthereumProvider: async () => provider}
}

// Yields to the event loop until `reached` holds, so an ordering assertion waits
// on the work itself rather than on a duration.
async function until(reached: () => boolean): Promise<void> {
  for (let attempt = 0; attempt < 200 && !reached(); attempt += 1) {
    await new Promise(resolve => setTimeout(resolve, 0))
  }

  if (!reached()) throw new Error("The awaited step never happened.")
}

// The published handle a real click reaches: the lazy loader's same-request
// dedupe in front of the real request handler.
function signInLoader(signIn: () => Promise<void>) {
  return createLazyAuthLoader(async () => ({
    startPrivyBridge: async () => ({
      request: createAccountRequestHandler({
        signIn,
        providerLogout: async () => undefined,
        synchronizeWallets: async () => undefined,
      }),
    }),
  }))
}

function heldPromise() {
  let resolve!: () => void
  return {promise: new Promise<void>(settle => (resolve = settle)), resolve}
}

// Run the actual AccountBridge and capture the callbacks passed to the SDK.
// HTTP is held at real coordinator/CSRF boundaries, never replaced by a fake
// completion handler. Every schedule drains that coordinator before finishing.
function callbackScenario({
  marker = "sign-in",
  authenticated = true,
  ready = true,
  mode = "profile-only",
  commit = true,
}: {
  marker?: "sign-in" | "sign-out"
  authenticated?: boolean
  ready?: boolean
  mode?: "ordinary" | "profile-only"
  commit?: boolean
} = {}) {
  vi.useFakeTimers()
  const {reload, dispatched} = stubBrowserGlobals(marker)
  const status = {textContent: "current status", hidden: true}
  const csrf = {content: "old-csrf"}
  const remove = vi.fn()
  const querySelector = document.querySelector.bind(document)
  vi.stubGlobal("document", {
    body: {append: vi.fn()},
    createElement: () => ({hidden: false, remove}),
    querySelector: (selector: string) => selector === "#account-auth-status" ? status
      : selector === "meta[name='csrf-token']" ? csrf : querySelector(selector),
  })
  productionRootRender.mockReset()
  productionRootUnmount.mockReset()
  productionPrivyHooks.login = vi.fn()
  const render = installAccountBridgeRenderer()
  const state: bridge.PrivyBridgeProviderState = {
    appId: "public-test-app", authenticated, ready, walletsReady: false, wallets: [],
    getAccessToken: vi.fn(async () => verifiedPair.accessToken),
    getIdentityToken: vi.fn(async () => verifiedPair.identityToken),
    logout: vi.fn(async () => undefined),
  }
  const startup = bridge.startPrivyBridge({mode}, state)
  void startup.catch(() => undefined)
  const element = renderedAccountBridge()
  const commitInitialRender = render(element, commit)
  return {
    state, startup, status, csrf, reload, dispatched, remove, commitInitialRender,
    render: (commit = true) => render(element, commit),
    fail: () => productionRootRender.mock.calls[0][0].props.onFailure(new Error("provider crashed")),
    grant: () => productionPrivyHooks.tokenCallbacks.onAccessTokenGranted?.({} as never),
    complete: () => productionPrivyHooks.loginCallbacks.onComplete?.({} as never),
  }
}

describe("production callback lifetime", () => {
  it("AUTH-LIFETIME-001: disposed work leaves the coordinator queue without starting CSRF", async () => {
    const heldQueue = heldPromise()
    const blocker = browserSessionMutations.establish(() => heldQueue.promise)
    const requests = stubSessionRequests()
    const scenario = callbackScenario()
    const handle = await scenario.startup
    const request = handle.request("sign-in")
    const rejected = expect(request).rejects.toThrow("unavailable")
    await vi.advanceTimersByTimeAsync(0)
    expect(scenario.state.getAccessToken).toHaveBeenCalledOnce()
    expect(requests).toEqual([])
    scenario.fail()
    await rejected
    heldQueue.resolve()
    await blocker
    await browserSessionMutations.establish(async () => undefined)
    await vi.advanceTimersByTimeAsync(1)
    expect(requests).toEqual([])
    expect(scenario.reload).not.toHaveBeenCalled()
  })

  it("AUTH-LIFETIME-001: disposal during recovery logout suppresses its later login", async () => {
    const heldLogout = heldPromise()
    vi.stubGlobal("fetch", vi.fn(async (input: RequestInfo | URL) => input === "/auth/csrf"
      ? new Response(JSON.stringify({csrf_token: "csrf"}))
      : new Response("{}", {status: 401, headers: {"x-autolaunch-provider-relogin": "allowed"}})))
    const scenario = callbackScenario()
    scenario.state.logout = vi.fn(() => heldLogout.promise)
    scenario.render()
    const handle = await scenario.startup
    const request = handle.request("sign-in")
    const rejected = expect(request).rejects.toThrow("unavailable")
    await vi.advanceTimersByTimeAsync(0)
    expect(scenario.state.logout).toHaveBeenCalledOnce()
    scenario.fail()
    await rejected
    heldLogout.resolve()
    await vi.advanceTimersByTimeAsync(1)
    expect(productionPrivyHooks.login).not.toHaveBeenCalled()
    expect(scenario.status).toEqual({textContent: "current status", hidden: true})
  })

  it("AUTH-LIFETIME-001: explicit login completion cannot report a late POST failure after disposal", async () => {
    const heldPost = heldPromise()
    const requests: string[] = []
    vi.stubGlobal("fetch", vi.fn(async (input: RequestInfo | URL) => {
      requests.push(String(input))
      if (input === "/auth/csrf") return new Response(JSON.stringify({csrf_token: "csrf"}))
      await heldPost.promise
      return new Response("{}", {status: 500})
    }))
    const scenario = callbackScenario({authenticated: false})
    const handle = await scenario.startup
    await handle.request("sign-in")
    const savedComplete = productionPrivyHooks.loginCallbacks.onComplete
    savedComplete?.({} as never)
    await vi.advanceTimersByTimeAsync(0)
    expect(requests).toEqual(["/auth/csrf", "/auth/privy/session"])
    scenario.fail()
    await vi.advanceTimersByTimeAsync(1)
    heldPost.resolve()
    await browserSessionMutations.establish(async () => undefined)
    await vi.advanceTimersByTimeAsync(0)
    expect(scenario.status).toEqual({textContent: "current status", hidden: true})
    expect(scenario.reload).not.toHaveBeenCalled()
    savedComplete?.({} as never)
    await vi.advanceTimersByTimeAsync(0)
    expect(requests).toEqual(["/auth/csrf", "/auth/privy/session"])
  })

  it("AUTH-LIFETIME-001: a link refresh held at CSRF cannot POST or notify after disposal", async () => {
    const heldCsrf = heldPromise()
    const requests: string[] = []
    vi.stubGlobal("fetch", vi.fn(async (input: RequestInfo | URL) => {
      requests.push(String(input))
      if (input === "/auth/csrf") {
        await heldCsrf.promise
        return new Response(JSON.stringify({csrf_token: "adopted"}))
      }
      return new Response("{}", {status: 500})
    }))
    const scenario = callbackScenario({marker: "sign-out"})
    await scenario.startup
    productionPrivyHooks.linkCallbacks.onSuccess?.({} as never)
    await vi.advanceTimersByTimeAsync(0)
    expect(requests).toEqual(["/auth/csrf"])
    scenario.fail()
    await vi.advanceTimersByTimeAsync(1)
    heldCsrf.resolve()
    await browserSessionMutations.establish(async () => undefined)
    await vi.advanceTimersByTimeAsync(0)
    expect(requests).toEqual(["/auth/csrf"])
    expect(scenario.dispatched).not.toContain("autolaunch:identity-state")
    expect(scenario.dispatched).not.toContain("regent:profile-link")
  })

  it.each(["success", "recoverable-401", "reset-409"] as const)(
    "AUTH-LIFETIME-001: a late committed %s response cannot start recovery or UI work",
    async outcome => {
      const heldPost = heldPromise()
      const requests: string[] = []
      vi.stubGlobal("fetch", vi.fn(async (input: RequestInfo | URL) => {
        requests.push(String(input))
        if (input === "/auth/csrf") {
          return new Response(JSON.stringify({csrf_token: requests.length === 1 ? "before" : "adopted"}))
        }
        await heldPost.promise
        if (outcome === "recoverable-401") {
          return new Response("{}", {status: 401, headers: {"x-autolaunch-provider-relogin": "allowed"}})
        }
        if (outcome === "reset-409") {
          return new Response(JSON.stringify({error: "session_reset_required"}), {status: 409})
        }
        return new Response("{}", {headers: {"x-autolaunch-session-changed": "true"}})
      }))
      const scenario = callbackScenario()
      const handle = await scenario.startup
      const request = handle.request("sign-in")
      const rejected = expect(request).rejects.toThrow("unavailable")
      await vi.advanceTimersByTimeAsync(0)
      expect(requests).toEqual(["/auth/csrf", "/auth/privy/session"])
      scenario.fail()
      await rejected
      await vi.advanceTimersByTimeAsync(1)
      expect(productionRootUnmount).toHaveBeenCalledOnce()
      heldPost.resolve()
      await browserSessionMutations.establish(async () => undefined)
      await vi.advanceTimersByTimeAsync(0)
      expect(requests).toEqual(outcome === "success"
        ? ["/auth/csrf", "/auth/privy/session", "/auth/csrf"]
        : ["/auth/csrf", "/auth/privy/session"])
      if (outcome === "success") expect(scenario.csrf.content).toBe("adopted")
      expect(scenario.state.logout).not.toHaveBeenCalled()
      expect(productionPrivyHooks.login).not.toHaveBeenCalled()
      expect(scenario.reload).not.toHaveBeenCalled()
      expect(scenario.status).toEqual({textContent: "current status", hidden: true})
    },
  )

  it("AUTH-LIFETIME-001: a saved login error cannot overwrite UI after disposal", async () => {
    const scenario = callbackScenario({authenticated: false})
    const handle = await scenario.startup
    await handle.request("sign-in")
    expect(productionPrivyHooks.login).toHaveBeenCalledOnce()
    const onError = productionPrivyHooks.loginCallbacks.onError
    scenario.fail()
    await vi.advanceTimersByTimeAsync(1)
    expect(productionRootUnmount).toHaveBeenCalledOnce()
    onError?.("exited_auth_flow" as never)
    expect(scenario.status).toEqual({textContent: "current status", hidden: true})
  })

  it("AUTH-LIFETIME-001: disposal during CSRF adoption prevents a new session POST", async () => {
    const heldCsrf = heldPromise()
    const requests: string[] = []
    vi.stubGlobal("fetch", vi.fn(async (input: RequestInfo | URL) => {
      requests.push(String(input))
      if (input === "/auth/csrf") {
        await heldCsrf.promise
        return new Response(JSON.stringify({csrf_token: "adopted-csrf"}))
      }
      return new Response("{}", {headers: {"x-autolaunch-session-changed": "true"}})
    }))
    const scenario = callbackScenario()
    const handle = await scenario.startup
    const request = handle.request("sign-in")
    const rejected = expect(request).rejects.toThrow("unavailable")
    await vi.advanceTimersByTimeAsync(0)
    expect(requests).toEqual(["/auth/csrf"])
    scenario.fail()
    await rejected
    await vi.advanceTimersByTimeAsync(1)
    expect(productionRootUnmount).toHaveBeenCalledOnce()
    heldCsrf.resolve()
    await browserSessionMutations.establish(async () => undefined)
    expect(scenario.csrf.content).toBe("adopted-csrf")
    expect(requests).toEqual(["/auth/csrf"])
    expect(scenario.reload).not.toHaveBeenCalled()
  })
})

describe("production callback readiness", () => {
  it("AUTH-READINESS-002: initial render alone does not authorize passive completion", async () => {
    const requests = stubSessionRequests()
    const scenario = callbackScenario({mode: "ordinary", commit: false})
    scenario.grant()
    scenario.complete()
    await vi.advanceTimersByTimeAsync(0)
    await browserSessionMutations.establish(async () => undefined)
    expect(requests).toEqual([])
    scenario.commitInitialRender()
    await scenario.startup
    await vi.advanceTimersByTimeAsync(0)
    expect(scenario.reload).toHaveBeenCalledOnce()
  })

  it("AUTH-READINESS-002: callbacks use committed readiness and share one completion once ready", async () => {
    const requests = stubSessionRequests()
    const scenario = callbackScenario({ready: false, mode: "ordinary"})
    const savedGrant = productionPrivyHooks.tokenCallbacks.onAccessTokenGranted
    const savedComplete = productionPrivyHooks.loginCallbacks.onComplete
    scenario.state.ready = true
    const commit = scenario.render(false)
    savedGrant?.({} as never)
    savedComplete?.({} as never)
    await vi.advanceTimersByTimeAsync(0)
    expect(requests).toEqual([])
    commit()
    await scenario.startup
    savedGrant?.({} as never)
    savedComplete?.({} as never)
    await vi.advanceTimersByTimeAsync(0)
    await browserSessionMutations.establish(async () => undefined)
    expect(requests).toEqual([
      {url: "/auth/csrf", method: "GET"},
      {url: "/auth/privy/session", method: "POST"},
      {url: "/auth/csrf", method: "GET"},
    ])
    expect(scenario.reload).toHaveBeenCalledOnce()
    expect(scenario.state.logout).not.toHaveBeenCalled()
    expect(productionPrivyHooks.login).not.toHaveBeenCalled()
  })

  it("AUTH-READINESS-002: readiness lost after POST still adopts CSRF without reloading", async () => {
    const heldPost = heldPromise()
    const requests: string[] = []
    vi.stubGlobal("fetch", vi.fn(async (input: RequestInfo | URL) => {
      requests.push(String(input))
      if (input === "/auth/csrf") return new Response(JSON.stringify({csrf_token: "adopted"}))
      await heldPost.promise
      return new Response("{}", {headers: {"x-autolaunch-session-changed": "true"}})
    }))
    const scenario = callbackScenario({mode: "ordinary"})
    await scenario.startup
    const granted = scenario.grant()
    await vi.advanceTimersByTimeAsync(0)
    expect(requests).toEqual(["/auth/csrf", "/auth/privy/session"])
    scenario.state.ready = false
    scenario.render()
    heldPost.resolve()
    await granted
    await browserSessionMutations.establish(async () => undefined)
    expect(requests).toEqual(["/auth/csrf", "/auth/privy/session", "/auth/csrf"])
    expect(scenario.csrf.content).toBe("adopted")
    expect(scenario.reload).not.toHaveBeenCalled()
  })

  it.each((["sign-in", "sign-out"] as const).flatMap(marker =>
    [false, true].flatMap(authenticated => (["grant", "complete"] as const).map(callback =>
      ({marker, authenticated, callback}))),
  ))("AUTH-READINESS-002: pre-ready $callback preserves $marker (authenticated=$authenticated)", async ({marker, authenticated, callback}) => {
    const requests = stubSessionRequests()
    const scenario = callbackScenario({marker, authenticated, ready: false, mode: "ordinary"})
    scenario[callback]()
    await vi.advanceTimersByTimeAsync(0)
    await browserSessionMutations.establish(async () => undefined)
    expect(requests).toEqual([])
    expect(scenario.state.getAccessToken).not.toHaveBeenCalled()
    expect(scenario.state.logout).not.toHaveBeenCalled()
    expect(scenario.reload).not.toHaveBeenCalled()
    expect(scenario.status).toEqual({textContent: "current status", hidden: true})
    scenario.fail()
    await vi.advanceTimersByTimeAsync(1)
  })

  it.each(["grant", "complete"] as const)("AUTH-READINESS-002: ready but unauthenticated passive %s is not explicit login", async callback => {
    const requests = stubSessionRequests()
    const scenario = callbackScenario({authenticated: false, mode: "ordinary"})
    await scenario.startup
    scenario[callback]()
    await vi.advanceTimersByTimeAsync(0)
    await browserSessionMutations.establish(async () => undefined)
    expect(requests).toEqual([])
    expect(scenario.reload).not.toHaveBeenCalled()
    expect(productionPrivyHooks.login).not.toHaveBeenCalled()
  })

  it.each(["ready", "authenticated"] as const)("AUTH-READINESS-002: loss of %s while CSRF is pending prevents passive commit", async field => {
    const heldCsrf = heldPromise()
    const requests: string[] = []
    vi.stubGlobal("fetch", vi.fn(async (input: RequestInfo | URL) => {
      requests.push(String(input))
      if (input === "/auth/csrf") {
        await heldCsrf.promise
        return new Response(JSON.stringify({csrf_token: "adopted-csrf"}))
      }
      return new Response("{}", {headers: {"x-autolaunch-session-changed": "true"}})
    }))
    const scenario = callbackScenario({mode: "ordinary"})
    await scenario.startup
    const granted = scenario.grant()
    await vi.advanceTimersByTimeAsync(0)
    expect(requests).toEqual(["/auth/csrf"])
    scenario.state[field] = false
    scenario.render()
    heldCsrf.resolve()
    await granted
    await browserSessionMutations.establish(async () => undefined)
    expect(requests).toEqual(["/auth/csrf"])
    expect(scenario.csrf.content).toBe("adopted-csrf")
    expect(scenario.state.logout).not.toHaveBeenCalled()
    expect(scenario.reload).not.toHaveBeenCalled()
  })
})

describe("provider lifetime", () => {
  it("releases a stalled module import without mounting its late result", async () => {
    vi.useFakeTimers()
    let finishImport!: (module: {startPrivyBridge: () => Promise<{request: () => Promise<void>}>}) => void
    const lateStart = vi.fn(async () => ({request: vi.fn(async () => undefined)}))
    const recovered = vi.fn(async () => undefined)
    const importer = vi.fn()
      .mockImplementationOnce(() => new Promise(resolve => { finishImport = resolve }))
      .mockResolvedValue({startPrivyBridge: async () => ({request: recovered})})
    const loader = createLazyAuthLoader(importer)
    const first = loader.request("sign-in")
    const refused = expect(first).rejects.toThrow("import")
    await vi.advanceTimersByTimeAsync(15_001)
    await refused
    await loader.request("sign-in")
    finishImport({startPrivyBridge: lateStart})
    await vi.advanceTimersByTimeAsync(0)
    expect(lateStart).not.toHaveBeenCalled()
    expect(recovered).toHaveBeenCalledTimes(1)
  })

  function setupProvider() {
    stubBrowserGlobals("sign-out")
    const remove = vi.fn()
    vi.stubGlobal("document", {
      body: {append: vi.fn()},
      createElement: () => ({hidden: false, remove}),
      querySelector: () => null,
    })
    productionRootRender.mockReset()
    productionRootUnmount.mockReset()
    const providerState: bridge.PrivyBridgeProviderState = {
      appId: "public-test-app", authenticated: false, ready: false,
      walletsReady: false, wallets: [], getAccessToken: async () => null,
      logout: vi.fn(async () => undefined),
    }
    return {providerState, remove}
  }

  it("bounds never-ready startup and unmounts without changing a session", async () => {
    vi.useFakeTimers()
    const {providerState, remove} = setupProvider()
    const fetcher = vi.fn()
    vi.stubGlobal("fetch", fetcher)
    const startup = bridge.startPrivyBridge({}, providerState)
    const refused = expect(startup).rejects.toThrow("did not become ready")
    await vi.advanceTimersByTimeAsync(bridge.providerReadyWindowMs + 1)
    await refused
    expect(productionRootUnmount).toHaveBeenCalledTimes(1)
    expect(remove).toHaveBeenCalledTimes(1)
    expect(fetcher).not.toHaveBeenCalled()
  })

  it("invalidates an already-ready provider, rejects pending work and remounts on retry", async () => {
    vi.useFakeTimers()
    const {providerState, remove} = setupProvider()
    const importer = vi.fn(async () => ({
      startPrivyBridge: () => bridge.startPrivyBridge({}, providerState),
    }))
    const loader = createLazyAuthLoader(importer)
    const first = loader.request("sign-in")
    const refused = expect(first).rejects.toThrow("unavailable")
    await vi.advanceTimersByTimeAsync(0)
    const boundary = productionRootRender.mock.calls[0][0]
    const publish = boundary.props.children.props.children.props.publishRequestHandler
    const pending = vi.fn(() => new Promise<void>(() => undefined))
    publish(pending, pending, () => undefined, true, pending)
    await vi.advanceTimersByTimeAsync(0)
    expect(pending).toHaveBeenCalledTimes(1)
    boundary.props.onFailure(new Error("provider crashed"))
    await refused
    await vi.advanceTimersByTimeAsync(1)
    expect(productionRootUnmount).toHaveBeenCalledTimes(1)
    expect(remove).toHaveBeenCalledTimes(1)

    const retry = loader.request("sign-in")
    await vi.advanceTimersByTimeAsync(0)
    expect(importer).toHaveBeenCalledTimes(2)
    const newBoundary = productionRootRender.mock.calls[1][0]
    const recovered = vi.fn(async () => undefined)
    newBoundary.props.children.props.children.props.publishRequestHandler(
      recovered, recovered, () => undefined, true, recovered,
    )
    await retry
    expect(recovered).toHaveBeenCalledTimes(1)
    expect(pending).toHaveBeenCalledTimes(1)
  })
})

// One sign in driven through the real seams. `pairs` is the sequence of
// provider sessions and only a provider logout reaches the next one, so a
// replayed pair is visible in the recorded order.
function signInScenario({
  answer,
  authenticated = true,
  logout = async () => undefined,
  pairs = ["stale"],
}: {
  answer: (bearer: string) => "marked" | "unmarked" | "ok"
  authenticated?: boolean
  logout?: () => Promise<void>
  pairs?: string[]
}) {
  const order: string[] = []
  const reload = vi.fn(() => void order.push("reload"))
  const loginOpen = {current: false}
  const recoveryAvailable = {current: true}
  let live = authenticated
  let session = 0

  const fetcher = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
    if (String(input) === "/auth/csrf") {
      order.push("csrf")
      return new Response(JSON.stringify({csrf_token: "csrf"}), {status: 200})
    }
    const bearer = (init?.headers as Record<string, string>).authorization
    order.push(`post ${bearer}`)
    const outcome = answer(bearer)
    if (outcome === "ok") {
      return new Response("{}", {status: 200, headers: {"x-autolaunch-session-changed": "true"}})
    }
    return new Response(JSON.stringify({error: "unauthorized"}), {
      status: 401,
      ...(outcome === "marked" ? {headers: {"x-autolaunch-provider-relogin": "allowed"}} : {}),
    })
  }) as unknown as typeof fetch

  const completeLogin = createPrivySessionCompletion({
    acquireTokens: async () => ({
      accessToken: pairs[session],
      identityToken: `${pairs[session]}-identity`,
    }),
    fetcher,
    localSessionNeeded: () => true,
    reload,
  })
  const providerLogout = vi.fn(async () => {
    order.push("logout")
    live = false
    session = Math.min(session + 1, pairs.length - 1)
    await logout()
  })
  const openLogin = vi.fn(() => void order.push("login"))
  const request = createSignInRequest({
    authenticated: () => live,
    completeLogin,
    providerLogout,
    openLogin,
    loginOpen,
    recoveryAvailable,
  })

  return {
    completeLogin,
    loginOpen,
    openLogin,
    order,
    providerLogout,
    recoveryAvailable,
    reload,
    request,
    completeFreshLogin() {
      live = true
      loginOpen.current = false
    },
    // Startup adoption and the granted-token callback: they share the one
    // completion and stand aside during an explicit recovery.
    automaticCompletion: () =>
      request.recovering() ? Promise.resolve() : completeLogin(),
  }
}

describe("Privy session bridge", () => {
  it("synchronizes wallets without changing the local or provider session", async () => {
    const signIn = vi.fn(async () => undefined)
    const providerLogout = vi.fn(async () => undefined)
    const synchronizeWallets = vi.fn(async () => undefined)
    const request = createAccountRequestHandler({
      signIn,
      providerLogout,
      synchronizeWallets,
    })

    await request("sync")

    expect(synchronizeWallets).toHaveBeenCalledOnce()
    expect(signIn).not.toHaveBeenCalled()
    expect(providerLogout).not.toHaveBeenCalled()
  })

  it("creates a local session with only the verified bearer and CSRF headers", async () => {
    const calls: Array<[RequestInfo | URL, RequestInit | undefined]> = []
    const fetcher = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      calls.push([input, init])
      return input === "/auth/csrf"
        ? new Response(JSON.stringify({csrf_token: "csrf"}), {status: 200})
        : new Response("{}", {
            status: 200,
            headers: {"x-autolaunch-session-changed": "false"},
          })
    }) as typeof fetch

    await expect(createLocalSession(verifiedPair, fetcher)).resolves.toEqual({
      sessionChanged: false,
    })

    expect(calls[1]).toEqual([
      "/auth/privy/session",
      {
        method: "POST",
        credentials: "same-origin",
        headers: {
          authorization: "Bearer verified",
          "privy-id-token": "verified-identity",
          "x-csrf-token": "csrf",
        },
      },
    ])
  })

  it("COMPLETE_PAIR_ACQUISITION: reads the signed evidence before the session proof", async () => {
    const order: string[] = []
    const acquire = createPrivyTokenPairSource({
      getIdentityToken: async () => {
        order.push("identity")
        return "verified-identity"
      },
      getAccessToken: async () => {
        order.push("access")
        return "verified"
      },
    })

    await expect(acquire()).resolves.toEqual(verifiedPair)
    expect(order).toEqual(["identity", "access"])
  })

  it.each([
    ["identity", null, "verified"],
    ["identity", "   ", "verified"],
    ["access", "verified-identity", null],
    ["access", "verified-identity", "   "],
  ])(
    "COMPLETE_PAIR_ACQUISITION: an absent or blank %s token yields no pair at all",
    async (_missing, identityToken, accessToken) => {
      const acquire = createPrivyTokenPairSource({
        getIdentityToken: async () => identityToken,
        getAccessToken: async () => accessToken,
      })

      await expect(acquire()).rejects.toThrow("Sign in could not be completed.")
    },
  )

  it("COMPLETE_PAIR_ACQUISITION: a failed acquisition sends no half pair and changes no session", async () => {
    const reload = vi.fn()
    const fetcher = vi.fn() as unknown as typeof fetch
    const completeLogin = createPrivySessionCompletion({
      acquireTokens: createPrivyTokenPairSource({
        getIdentityToken: async () => {
          throw new Error("provider unavailable")
        },
        getAccessToken: async () => "verified",
      }),
      fetcher,
      localSessionNeeded: () => true,
      reload,
    })

    await expect(completeLogin()).rejects.toThrow("provider unavailable")
    expect(fetcher).not.toHaveBeenCalled()
    expect(reload).not.toHaveBeenCalled()
  })

  it("returns a verified identity conflict from the refreshed local session", async () => {
    const fetcher = vi.fn(async (input: RequestInfo | URL) =>
      input === "/auth/csrf"
        ? new Response(JSON.stringify({csrf_token: "csrf"}), {status: 200})
        : new Response("{}", {
            status: 200,
            headers: {
              "x-autolaunch-session-changed": "false",
              "x-autolaunch-identity-error": "already-connected",
            },
          }),
    ) as typeof fetch

    await expect(createLocalSession(verifiedPair, fetcher)).resolves.toEqual({
      sessionChanged: false,
      identityError: "already-connected",
    })
  })

  it("routes link and unlink commands through Privy before refreshing the session", async () => {
    const linkX = vi.fn()
    const linkGithub = vi.fn()
    const linkFarcaster = vi.fn()
    const unlinkOAuth = vi.fn(async () => undefined)
    const unlinkFarcaster = vi.fn(async () => undefined)
    const refreshSession = vi.fn(async () => undefined)
    const request = createIdentityRequestHandler({
      linkX,
      linkGithub,
      linkFarcaster,
      unlinkOAuth,
      unlinkFarcaster,
      refreshSession,
    })

    await request({action: "link", provider: "x"})
    await request({action: "link", provider: "github"})
    await request({action: "link", provider: "farcaster"})

    expect(linkX).toHaveBeenCalledOnce()
    expect(linkGithub).toHaveBeenCalledOnce()
    expect(linkFarcaster).toHaveBeenCalledOnce()
    expect(refreshSession).not.toHaveBeenCalled()

    await request({action: "unlink", provider: "x", subject: "twitter-42"})
    await request({action: "unlink", provider: "github", subject: "github-7"})
    await request({action: "unlink", provider: "farcaster", subject: "12345"})

    expect(unlinkOAuth).toHaveBeenNthCalledWith(1, "twitter", "twitter-42")
    expect(unlinkOAuth).toHaveBeenNthCalledWith(2, "github", "github-7")
    expect(unlinkFarcaster).toHaveBeenCalledWith(12345)
    expect(refreshSession).toHaveBeenCalledTimes(3)
  })

  it("rejects unlink commands without a verified provider subject", async () => {
    const request = createIdentityRequestHandler({
      linkX: vi.fn(),
      linkGithub: vi.fn(),
      linkFarcaster: vi.fn(),
      unlinkOAuth: vi.fn(),
      unlinkFarcaster: vi.fn(),
      refreshSession: vi.fn(),
    })

    await expect(
      request({action: "unlink", provider: "farcaster", subject: "not-a-fid"}),
    ).rejects.toThrow("unavailable")
    await expect(request({action: "unlink", provider: "x"})).rejects.toThrow(
      "unavailable",
    )
  })

  it("aborts a never-settling bootstrap before one local deletion", async () => {
    const sessionMutations = createSessionMutationCoordinator()
    let bootstrapStarted = false
    const fetchMock = vi.fn((input: RequestInfo | URL, init?: RequestInit) => {
      if (input !== "/auth/csrf") throw new Error("The session POST was never reachable.")
      bootstrapStarted = true
      return new Promise<Response>((_resolve, reject) =>
        init?.signal?.addEventListener("abort", () => reject(init.signal?.reason), {once: true}),
      )
    })
    const fetcher = fetchMock as unknown as typeof fetch

    const establishment = createLocalSession(verifiedPair, fetcher, sessionMutations)
    await until(() => bootstrapStarted)
    const establishmentFailure = expect(establishment).rejects.toMatchObject({name: "AbortError"})

    const clearSession = vi.fn(async () => undefined)
    await sessionMutations.signOut(clearSession)
    expect(clearSession).toHaveBeenCalledOnce()

    await establishmentFailure
    expect(fetchMock).not.toHaveBeenCalledWith("/auth/privy/session", expect.anything())

    const fetchCallCount = fetchMock.mock.calls.length
    await expect(createLocalSession(verifiedPair, fetcher, sessionMutations)).rejects.toThrow(
      "Local sign out has already started.",
    )
    expect(fetchMock).toHaveBeenCalledTimes(fetchCallCount)
  })

  it("holds a queued sign out until a dispatched session POST has adopted its token", async () => {
    const sessionMutations = createSessionMutationCoordinator()
    const order: string[] = []
    let releasePost: (() => void) | undefined
    const fetchMock = vi.fn((input: RequestInfo | URL) => {
      if (input === "/auth/csrf") {
        order.push("csrf")
        return Promise.resolve(new Response(JSON.stringify({csrf_token: "csrf"}), {status: 200}))
      }
      order.push("post")
      return new Promise<Response>(resolve => {
        releasePost = () =>
          resolve(new Response("{}", {status: 200, headers: {"x-autolaunch-session-changed": "false"}}))
      })
    })
    const fetcher = fetchMock as unknown as typeof fetch

    const establishment = createLocalSession(verifiedPair, fetcher, sessionMutations)
    await until(() => order.includes("post"))

    const clearSession = vi.fn(async () => void order.push("delete"))
    const signOut = sessionMutations.signOut(clearSession)
    expect(clearSession).not.toHaveBeenCalled()

    releasePost?.()
    await expect(establishment).resolves.toEqual({sessionChanged: false})
    await signOut

    // The dispatched POST may already have renewed the cookie, so sign out runs
    // only after the adoption fetch that follows it.
    expect(order).toEqual(["csrf", "post", "csrf", "delete"])
  })

  it("completes the local session from Privy's access-token grant", async () => {
    const reload = vi.fn()
    const fetcher = vi.fn(async (input: RequestInfo | URL) =>
      input === "/auth/csrf"
        ? new Response(JSON.stringify({csrf_token: "csrf"}), {status: 200})
        : new Response("{}", {
            status: 200,
            headers: {"x-autolaunch-session-changed": "true"},
          }),
    ) as typeof fetch

    const completeLogin = createPrivySessionCompletion({
      acquireTokens: acquireVerifiedPair,
      fetcher,
      localSessionNeeded: () => true,
      reload,
    })

    await Promise.all([completeLogin(), completeLogin()])

    expect(fetcher).toHaveBeenCalledWith(
      "/auth/privy/session",
      expect.objectContaining({method: "POST"}),
    )
    expect(reload).toHaveBeenCalledOnce()
  })

  it("finishes sign in when Privy grants the token after wallet authentication settles", async () => {
    vi.useFakeTimers()

    try {
      const reload = vi.fn()
      const fetcher = vi.fn(async (input: RequestInfo | URL) =>
        input === "/auth/csrf"
          ? new Response(JSON.stringify({csrf_token: "csrf"}), {status: 200})
          : new Response("{}", {
              status: 200,
              headers: {"x-autolaunch-session-changed": "true"},
            }),
      ) as typeof fetch

      const completeLogin = createPrivySessionCompletion({
        acquireTokens: acquireVerifiedPair,
        fetcher,
        localSessionNeeded: () => true,
        reload,
      })
      const tokenCallbacks = createPrivyTokenCallbacks(completeLogin)

      // The grant is only the signal to acquire; the pair Privy is asked for
      // afterwards is the one that establishes the session.
      const completion = new Promise<void>(resolve => {
        setTimeout(() => void tokenCallbacks.onAccessTokenGranted().then(resolve), 10_000)
      })
      await vi.advanceTimersByTimeAsync(10_000)
      await completion

      expect(fetcher).toHaveBeenCalledWith(
        "/auth/privy/session",
        expect.objectContaining({method: "POST"}),
      )
      expect(reload).toHaveBeenCalledOnce()
    } finally {
      vi.useRealTimers()
    }
  })

  it("finishes the local session from the first successful wallet login", async () => {
    const completeLogin = vi.fn(async () => undefined)
    const loginOpen = {current: true}
    const showFailure = vi.fn()
    const loginCallbacks = createPrivyLoginCallbacks({completeLogin, loginOpen, showFailure})

    await loginCallbacks.onComplete?.(
      {} as Parameters<NonNullable<typeof loginCallbacks.onComplete>>[0],
    )

    expect(completeLogin).toHaveBeenCalledOnce()
    expect(loginOpen.current).toBe(false)
    expect(showFailure).not.toHaveBeenCalled()
  })

  // This page opened this modal, so it speaks for both of Privy's outcomes.
  it("ONE_RECOVERY_PER_PAGE: both login outcomes release the guard and say what failed", async () => {
    const loginOpen = {current: true}
    const showFailure = vi.fn()
    const failing = createPrivyLoginCallbacks({
      completeLogin: async () => {
        throw new Error("Sign in could not be completed.")
      },
      loginOpen,
      showFailure,
    })

    failing.onComplete?.({} as Parameters<NonNullable<typeof failing.onComplete>>[0])
    expect(loginOpen.current).toBe(false)
    await until(() => showFailure.mock.calls.length === 1)

    loginOpen.current = true
    failing.onError?.("exited_auth_flow" as Parameters<NonNullable<typeof failing.onError>>[0])
    expect(loginOpen.current).toBe(false)
    expect(showFailure).toHaveBeenCalledTimes(2)
  })

  it("ONE_RECOVERY_PER_PAGE: the marked refusal spends one logout, one login and one fresh pair", async () => {
    const heldLogout = heldPromise()
    const marked = signInScenario({
      answer: bearer => (bearer === "Bearer stale" ? "marked" : "ok"),
      logout: () => heldLogout.promise,
      pairs: ["stale", "fresh"],
    })
    const loader = signInLoader(marked.request.signIn)

    // Two deliberate clicks and an automatic adoption while the logout is still
    // running: the rejected pair is offered exactly once and never again.
    const first = loader.request("sign-in")
    const repeated = loader.request("sign-in")
    await until(() => marked.providerLogout.mock.calls.length === 1)
    expect(marked.request.recovering()).toBe(true)
    await marked.automaticCompletion()
    expect(marked.order).toEqual(["csrf", "post Bearer stale", "logout"])

    heldLogout.resolve()
    await Promise.all([first, repeated])

    expect(marked.order).toEqual(["csrf", "post Bearer stale", "logout", "login"])
    expect(marked.recoveryAvailable.current).toBe(false)
    expect(marked.request.recovering()).toBe(false)
    expect(marked.reload).not.toHaveBeenCalled()

    marked.completeFreshLogin()
    await marked.completeLogin()

    expect(marked.order).toEqual([
      "csrf",
      "post Bearer stale",
      "logout",
      "login",
      "csrf",
      "post Bearer fresh",
      "csrf",
      "reload",
    ])
    expect(marked.providerLogout).toHaveBeenCalledOnce()
    expect(marked.openLogin).toHaveBeenCalledOnce()
    expect(marked.reload).toHaveBeenCalledOnce()
  })

  it.each(["unmarked", "marked"] as const)(
    "ONE_RECOVERY_PER_PAGE: a %s refusal with no recovery left leaves Privy alone",
    async answer => {
      const refused = signInScenario({answer: () => answer})
      if (answer === "marked") refused.recoveryAvailable.current = false

      await expect(refused.request.signIn()).rejects.toThrow("Sign in could not be completed.")

      expect(refused.order).toEqual(["csrf", "post Bearer stale"])
      expect(refused.providerLogout).not.toHaveBeenCalled()
      expect(refused.openLogin).not.toHaveBeenCalled()
      expect(refused.reload).not.toHaveBeenCalled()
      // Only the exact marked refusal may spend the recovery, so an unmarked one
      // leaves the cap for a marked refusal that may still follow it.
      expect(refused.recoveryAvailable.current).toBe(answer === "unmarked")
    },
  )

  it("ONE_RECOVERY_PER_PAGE: an automatic completion takes the marked refusal and leaves Privy alone", async () => {
    const automatic = signInScenario({answer: () => "marked", pairs: ["stale", "fresh"]})
    const showFailure = vi.fn()
    const bootstrap = createPrivyLoginCallbacks({
      completeLogin: automatic.completeLogin,
      loginOpen: automatic.loginOpen,
      showFailure,
    })

    // Privy restores the stale session on its own: it fires its login completion
    // for a modal this page never opened, and the granted token joins the same
    // attempt.
    bootstrap.onComplete?.({} as Parameters<NonNullable<typeof bootstrap.onComplete>>[0])
    await expect(automatic.automaticCompletion()).rejects.toThrow(
      "Sign in could not be completed.",
    )

    expect(automatic.order).toEqual(["csrf", "post Bearer stale"])
    expect(automatic.providerLogout).not.toHaveBeenCalled()
    expect(automatic.openLogin).not.toHaveBeenCalled()
    expect(showFailure).not.toHaveBeenCalled()
    expect(automatic.recoveryAvailable.current).toBe(true)
  })

  it("ONE_RECOVERY_PER_PAGE: the click behind an automatic completion spends the one recovery", async () => {
    const queued = signInScenario({
      answer: bearer => (bearer === "Bearer stale" ? "marked" : "ok"),
      pairs: ["stale", "fresh"],
    })
    const showFailure = vi.fn()
    const bootstrap = createPrivyLoginCallbacks({
      completeLogin: queued.completeLogin,
      loginOpen: queued.loginOpen,
      showFailure,
    })

    // Privy's bootstrap reaches the refusal first and the click joins the one
    // attempt already in flight, so the refused pair is offered exactly once and
    // only the click that owns the page recovers it.
    bootstrap.onComplete?.({} as Parameters<NonNullable<typeof bootstrap.onComplete>>[0])
    await queued.request.signIn()

    expect(queued.order).toEqual(["csrf", "post Bearer stale", "logout", "login"])
    expect(queued.providerLogout).toHaveBeenCalledOnce()
    expect(queued.openLogin).toHaveBeenCalledOnce()
    expect(showFailure).not.toHaveBeenCalled()
    expect(queued.recoveryAvailable.current).toBe(false)
    expect(queued.reload).not.toHaveBeenCalled()
  })

  it("ONE_RECOVERY_PER_PAGE: a second marked refusal stops instead of recovering again", async () => {
    const twice = signInScenario({answer: () => "marked", pairs: ["stale", "fresh"]})

    await twice.request.signIn()
    twice.completeFreshLogin()
    await expect(twice.completeLogin()).rejects.toThrow("Sign in could not be completed.")
    await expect(twice.request.signIn()).rejects.toThrow("Sign in could not be completed.")

    expect(twice.providerLogout).toHaveBeenCalledOnce()
    expect(twice.openLogin).toHaveBeenCalledOnce()
    expect(twice.order.filter(step => step === "post Bearer stale")).toHaveLength(1)
    expect(twice.reload).not.toHaveBeenCalled()
  })

  it("ONE_RECOVERY_PER_PAGE: a provider logout that fails stops before login", async () => {
    const stuck = signInScenario({
      answer: () => "marked",
      logout: async () => {
        throw new Error("provider unavailable")
      },
    })

    await expect(stuck.request.signIn()).rejects.toThrow("provider unavailable")

    expect(stuck.openLogin).not.toHaveBeenCalled()
    expect(stuck.recoveryAvailable.current).toBe(false)
    expect(stuck.request.recovering()).toBe(false)
    expect(stuck.reload).not.toHaveBeenCalled()
  })

  it("ONE_RECOVERY_PER_PAGE: a cancelled modal reopens on the next click and refunds nothing", async () => {
    const cancelled = signInScenario({answer: () => "marked", pairs: ["stale", "fresh"]})

    await cancelled.request.signIn()
    cancelled.loginOpen.current = false
    await cancelled.request.signIn()

    expect(cancelled.openLogin).toHaveBeenCalledTimes(2)
    expect(cancelled.providerLogout).toHaveBeenCalledOnce()
    expect(cancelled.recoveryAvailable.current).toBe(false)
  })

  it("EXPLICIT_SIGN_IN_BRANCHES: a valid provider establishes without touching login or logout", async () => {
    const valid = signInScenario({answer: () => "ok", pairs: ["verified"]})

    await valid.request.signIn()

    expect(valid.order).toEqual(["csrf", "post Bearer verified", "csrf", "reload"])
    expect(valid.openLogin).not.toHaveBeenCalled()
    expect(valid.providerLogout).not.toHaveBeenCalled()
    expect(valid.recoveryAvailable.current).toBe(true)
  })

  it("EXPLICIT_SIGN_IN_BRANCHES: an anonymous provider opens login once and sends nothing", async () => {
    const anonymous = signInScenario({authenticated: false, answer: () => "ok"})

    await anonymous.request.signIn()
    await anonymous.request.signIn()

    expect(anonymous.order).toEqual(["login"])
    expect(anonymous.providerLogout).not.toHaveBeenCalled()
    expect(anonymous.recoveryAvailable.current).toBe(true)
  })

  it("clears Autolaunch before provider logout is attempted", async () => {
    const fetcher = vi.fn(async (input: RequestInfo | URL) =>
      input === "/auth/csrf"
        ? new Response(JSON.stringify({csrf_token: "csrf"}), {status: 200})
        : new Response("{}", {status: 200}),
    ) as typeof fetch

    await clearLocalSession(fetcher)
    expect(fetcher).toHaveBeenLastCalledWith(
      "/auth/privy/session",
      expect.objectContaining({method: "DELETE"}),
    )
  })

  it("leaves local deletion and reload to the always-loaded sign-out path", async () => {
    const order: string[] = []
    const request = createAccountRequestHandler({
      signIn: vi.fn(async () => undefined),
      providerLogout: vi.fn(async () => {
        order.push("provider")
        throw new Error("provider unavailable")
      }),
      synchronizeWallets: vi.fn(async () => undefined),
    })

    await expect(request("sign-out")).rejects.toThrow("provider unavailable")

    expect(order).toEqual(["provider"])
  })

  it("keeps sign-out-only startup preterminal until one provider attempt settles", async () => {
    let finishProviderLogout: (() => void) | undefined
    const ordinaryRequest = vi.fn(
      (request: "sign-in" | "sign-out" | "sync") =>
        request === "sign-out"
          ? new Promise<void>(resolve => {
              finishProviderLogout = resolve
            })
          : Promise.resolve(),
    )
    const ordinaryIdentity = vi.fn(async () => undefined)
    const onTerminal = vi.fn()
    const state = createSignOutOnlyBridgeState({
      ordinaryRequest,
      ordinaryIdentity,
      onTerminal,
    })

    await expect(state.request("sign-in")).rejects.toThrow("still in progress")
    await expect(state.request("sync")).rejects.toThrow("still in progress")
    await expect(state.identity({action: "link", provider: "x"})).rejects.toThrow(
      "still in progress",
    )
    const firstSignOut = state.request("sign-out")
    const joinedSignOut = state.request("sign-out")
    expect(ordinaryRequest).toHaveBeenCalledOnce()
    finishProviderLogout?.()
    await Promise.all([firstSignOut, joinedSignOut])
    expect(onTerminal).toHaveBeenCalledOnce()

    await state.request("sign-out")
    await expect(state.request("sync")).rejects.toThrow("disabled")
    await state.request("sign-in")
    await state.identity({action: "link", provider: "github"})
    expect(ordinaryRequest.mock.calls.map(([request]) => request)).toEqual([
      "sign-out",
      "sign-in",
    ])
    expect(ordinaryIdentity).toHaveBeenCalledOnce()
  })

  it.each(["resolve", "reject"] as const)(
    "holds explicit work after timeout until late provider %s",
    async outcome => {
      let resolveProvider: (() => void) | undefined
      let rejectProvider: ((error: Error) => void) | undefined
      const order: string[] = []
      const ordinaryRequest = vi.fn((request: "sign-in" | "sign-out" | "sync") => {
        order.push(request)
        return request === "sign-out"
          ? new Promise<void>((resolve, reject) => {
              resolveProvider = resolve
              rejectProvider = reject
            })
          : Promise.resolve()
      })
      const ordinaryIdentity = vi.fn(async () => {
        order.push("identity")
      })
      const onTerminal = vi.fn()
      const state = createSignOutOnlyBridgeState({
        ordinaryRequest,
        ordinaryIdentity,
        onTerminal,
      })

      const providerAttempt = state.request("sign-out")
      const providerSettled = providerAttempt.catch(() => undefined)
      state.finish()
      state.finish()
      expect(onTerminal).toHaveBeenCalledOnce()

      const signIn = state.request("sign-in")
      const identity = state.identity({action: "link", provider: "github"})
      await Promise.resolve()
      expect(order).toEqual(["sign-out"])
      expect(ordinaryIdentity).not.toHaveBeenCalled()

      await state.request("sign-out")
      await expect(state.request("sync")).rejects.toThrow("disabled")
      order.push("provider-settled")
      if (outcome === "resolve") resolveProvider?.()
      else rejectProvider?.(new Error("provider logout failed"))

      await providerSettled
      await Promise.all([signIn, identity])
      expect(onTerminal).toHaveBeenCalledOnce()
      expect(order).toEqual(["sign-out", "provider-settled", "sign-in", "identity"])
      expect(ordinaryRequest.mock.calls.map(([request]) => request)).toEqual([
        "sign-out",
        "sign-in",
      ])
      expect(ordinaryIdentity).toHaveBeenCalledOnce()
    },
  )

  it.each(["resolve", "reject"] as const)(
    "keeps the production component queue through a rerender until provider %s",
    async outcome => {
      productionRootRender.mockReset()
      const renderAccountBridge = installAccountBridgeRenderer()
      const firstLogin = vi.fn()
      const firstLinkGithub = vi.fn()
      const order: string[] = []
      productionPrivyHooks.login = firstLogin
      productionPrivyHooks.linkGithub = firstLinkGithub
      stubBrowserGlobals()

      let resolveProvider: (() => void) | undefined
      let rejectProvider: ((error: Error) => void) | undefined
      const providerLogout = vi.fn(
        () =>
          new Promise<void>((resolve, reject) => {
            resolveProvider = resolve
            rejectProvider = reject
          }),
      )
      const getAccessToken = vi.fn(async () => "unexpected-token")
      const providerState = {
        appId: "test-app",
        authenticated: true,
        getAccessToken,
        logout: providerLogout,
        ready: true,
        walletsReady: true,
        wallets: [],
      }
      const startup = bridge.startPrivyBridge({mode: "sign-out-only"}, providerState)
      const accountElement = renderedAccountBridge()
      renderAccountBridge(accountElement)
      const handle = await startup

      const providerAttempt = handle.request("sign-out")
      const providerSettled = providerAttempt.catch(() => undefined)
      handle.finishSignOutOnly?.()

      // The provider signed out, so the queued click belongs to an anonymous
      // provider and must reach the login of the latest committed render.
      const latestLogin = vi.fn(() => order.push("sign-in"))
      const latestLinkGithub = vi.fn(() => order.push("identity"))
      productionPrivyHooks.login = latestLogin
      productionPrivyHooks.linkGithub = latestLinkGithub
      providerState.authenticated = false
      renderAccountBridge(accountElement)

      const signIn = handle.request("sign-in")
      const identity = handle.identity?.({action: "link", provider: "github"})
      await Promise.resolve()
      expect(order).toEqual([])
      expect(firstLogin).not.toHaveBeenCalled()
      expect(firstLinkGithub).not.toHaveBeenCalled()
      expect(latestLogin).not.toHaveBeenCalled()
      expect(latestLinkGithub).not.toHaveBeenCalled()

      await handle.request("sign-out")
      await expect(handle.request("sync")).rejects.toThrow("disabled")
      order.push("provider-settled")
      if (outcome === "resolve") resolveProvider?.()
      else rejectProvider?.(new Error("provider logout failed"))

      await providerSettled
      await Promise.all([signIn, identity])
      expect(order).toEqual(["provider-settled", "sign-in", "identity"])
      expect(providerLogout).toHaveBeenCalledOnce()
      expect(latestLogin).toHaveBeenCalledOnce()
      expect(latestLinkGithub).toHaveBeenCalledOnce()
      expect(getAccessToken).not.toHaveBeenCalled()
    },
  )

  it("SIGNED_IN_STALE_PROVIDER_EXITS: clears a stale server session when Privy is unauthenticated", async () => {
    const clearSession = vi.fn(async () => undefined)
    const reload = vi.fn()
    const reconcile = createProviderSessionReconciler({
      clearSession,
      providerAuthenticated: () => false,
      reload,
      signedIn: () => true,
    })

    await expect(reconcile()).resolves.toBe(false)
    expect(clearSession).toHaveBeenCalledOnce()
    expect(reload).toHaveBeenCalledOnce()
  })

  it("POSITIVE_SIGN_OUT_OWNS_DELETION: a page showing neither account marker deletes nothing", async () => {
    const clearSession = vi.fn(async () => undefined)
    const reload = vi.fn()
    const reconcile = createProviderSessionReconciler({
      clearSession,
      providerAuthenticated: () => false,
      reload,
      signedIn: () => false,
    })

    await expect(reconcile()).resolves.toBe(false)
    expect(clearSession).not.toHaveBeenCalled()
    expect(reload).not.toHaveBeenCalled()
  })

  // The page can be replaced while the provider state is sampled, so the only
  // reading of the account control that may end a session is the last one.
  it("POSITIVE_SIGN_OUT_OWNS_DELETION: a marker lost during the provider sample authorizes nothing", async () => {
    const clearSession = vi.fn(async () => undefined)
    const reload = vi.fn()
    let signedIn = true
    const reconcile = createProviderSessionReconciler({
      clearSession,
      providerAuthenticated: () => {
        signedIn = false
        return false
      },
      reload,
      signedIn: () => signedIn,
    })

    await expect(reconcile()).resolves.toBe(false)
    expect(clearSession).not.toHaveBeenCalled()
    expect(reload).not.toHaveBeenCalled()
  })

  it("ORDINARY_SIGNED_IN_STARTUP_IS_STABLE: a still-signed-in account writes no session", async () => {
    const clearSession = vi.fn(async () => undefined)
    const reload = vi.fn()
    const fetcher = vi.fn()
    vi.stubGlobal("fetch", fetcher)
    const reconcile = createProviderSessionReconciler({
      clearSession,
      providerAuthenticated: () => true,
      reload,
      signedIn: () => true,
    })

    await expect(reconcile()).resolves.toBe(true)

    // Startup reconciliation only reads the provider, so nothing reaches the
    // server: no generation advances, no cookie renews and nothing reloads.
    expect(fetcher).not.toHaveBeenCalled()
    expect(clearSession).not.toHaveBeenCalled()
    expect(reload).not.toHaveBeenCalled()
  })

  it("does not own or inject server-rendered account markup", () => {
    expect(bridge).not.toHaveProperty("loadLocalSession")
  })

  // The anonymous page is where sign in starts, so Privy has nothing to report
  // yet. Reading that emptiness as a stale session deletes the session the
  // customer is deliberately browsing under and reloads away from the chooser.
  it("ANONYMOUS_LOGIN_IS_NONDESTRUCTIVE: the first sign-in click reaches login and deletes nothing", async () => {
    productionRootRender.mockReset()
    replaceActiveEthereumWallet(null)
    const renderAccountBridge = installAccountBridgeRenderer()
    const {dispatched, reload} = stubBrowserGlobals("sign-in")
    const sessionRequests = stubSessionRequests()
    const login = vi.fn()
    productionPrivyHooks.login = login

    const startup = bridge.startPrivyBridge(
      {},
      {
        appId: "test-app",
        authenticated: false,
        getAccessToken: async () => null,
        logout: async () => undefined,
        ready: true,
        walletsReady: true,
        wallets: [],
      },
    )
    renderAccountBridge(renderedAccountBridge())
    const handle = await startup
    await until(() => dispatched.includes("autolaunch:wallet-state"))

    await handle.request("sign-in")

    expect(login).toHaveBeenCalledOnce()
    expect(sessionRequests).toEqual([])
    expect(reload).not.toHaveBeenCalled()
    expect(activeEthereumWallet()).toBeNull()
  })

  // Once the provider reports a complete session, the selected wallet is Stake's
  // wallet again. The page is still anonymous to the server until the verified
  // pair establishes a session and reloads, and nothing else may write one.
  it("ANONYMOUS_LOGIN_IS_NONDESTRUCTIVE: a completed provider session publishes its wallet and establishes by pair", async () => {
    productionRootRender.mockReset()
    replaceActiveEthereumWallet(null)
    const renderAccountBridge = installAccountBridgeRenderer()
    const {reload} = stubBrowserGlobals("sign-in")
    const sessionRequests = stubSessionRequests()
    const wallet = ethereumWallet("0x1111111111111111111111111111111111111111")

    const startup = bridge.startPrivyBridge({}, {
      appId: "test-app",
      authenticated: true,
      getAccessToken: async () => "verified",
      getIdentityToken: async () => "verified-identity",
      logout: async () => undefined,
      ready: true,
      walletsReady: true,
      wallets: [wallet],
      activeWallet: wallet,
    } as unknown as bridge.PrivyBridgeProviderState)
    renderAccountBridge(renderedAccountBridge())
    await startup
    await until(() => activeEthereumWallet()?.provider === wallet.provider)
    await until(() => reload.mock.calls.length > 0)

    expect(sessionRequests).toEqual([
      {url: "/auth/csrf", method: "GET"},
      {url: "/auth/privy/session", method: "POST"},
      {url: "/auth/csrf", method: "GET"},
    ])
    expect(reload).toHaveBeenCalledOnce()
  })

  // The startup restore is the one place a signed-in page would establish
  // without anyone clicking. A provider that will not issue signed evidence
  // leaves the anonymous page anonymous instead of sending the proof alone.
  it("COMPLETE_PAIR_ACQUISITION: a provider with no identity token establishes nothing at startup", async () => {
    productionRootRender.mockReset()
    replaceActiveEthereumWallet(null)
    const renderAccountBridge = installAccountBridgeRenderer()
    const {dispatched, reload} = stubBrowserGlobals("sign-in")
    const sessionRequests = stubSessionRequests()
    const wallet = ethereumWallet("0x1111111111111111111111111111111111111111")

    const startup = bridge.startPrivyBridge({}, {
      appId: "test-app",
      authenticated: true,
      getAccessToken: async () => "verified",
      getIdentityToken: async () => null,
      logout: async () => undefined,
      ready: true,
      walletsReady: true,
      wallets: [wallet],
      activeWallet: wallet,
    } as unknown as bridge.PrivyBridgeProviderState)
    renderAccountBridge(renderedAccountBridge())
    await startup
    await until(() => dispatched.includes("autolaunch:wallet-state"))
    await new Promise(resolve => setTimeout(resolve, 0))

    expect(sessionRequests).toEqual([])
    expect(reload).not.toHaveBeenCalled()
  })

  // A signed-in page whose wallet hook is still loading has no wallet evidence
  // yet. Ending its valid session on that emptiness would sign the customer out
  // of a session the provider still supports.
  it("BOTH_PROVIDER_LAYERS_MUST_BE_READY: a loading wallet hook drops wallets without ending the session", async () => {
    productionRootRender.mockReset()
    const renderAccountBridge = installAccountBridgeRenderer()
    const {dispatched, reload} = stubBrowserGlobals("sign-out")
    const sessionRequests = stubSessionRequests()
    const wallet = ethereumWallet("0x1111111111111111111111111111111111111111")
    replaceActiveEthereumWallet({address: wallet.address, provider: wallet.provider})

    const getAccessToken = vi.fn(async () => null)
    const startup = bridge.startPrivyBridge({}, {
      appId: "test-app",
      authenticated: true,
      getAccessToken,
      logout: async () => undefined,
      ready: true,
      walletsReady: false,
      wallets: [wallet],
      activeWallet: wallet,
    } as unknown as bridge.PrivyBridgeProviderState)
    renderAccountBridge(renderedAccountBridge())
    await startup
    await until(() => dispatched.includes("autolaunch:wallet-state"))
    // The wallets are dropped without awaiting anything, so the signed-in
    // startup token read has to settle before this page can be called quiet.
    await new Promise(resolve => setTimeout(resolve, 0))

    expect(activeEthereumWallet()).toBeNull()
    expect(sessionRequests).toEqual([])
    expect(getAccessToken).not.toHaveBeenCalled()
    expect(reload).not.toHaveBeenCalled()
  })

  it("ORDINARY_SIGNED_IN_STARTUP_IS_STABLE: an authenticated walletless provider reads no token", async () => {
    productionRootRender.mockReset()
    const renderAccountBridge = installAccountBridgeRenderer()
    const {dispatched, reload} = stubBrowserGlobals("sign-out")
    const sessionRequests = stubSessionRequests()
    const getAccessToken = vi.fn(async () => null)

    const startup = bridge.startPrivyBridge({}, {
      appId: "test-app",
      authenticated: true,
      getAccessToken,
      logout: async () => undefined,
      ready: true,
      walletsReady: true,
      wallets: [],
    } as unknown as bridge.PrivyBridgeProviderState)
    renderAccountBridge(renderedAccountBridge())
    await startup
    await until(() => dispatched.includes("autolaunch:wallet-state"))

    expect(getAccessToken).not.toHaveBeenCalled()
    expect(sessionRequests).toEqual([])
    expect(reload).not.toHaveBeenCalled()
  })

  it("SIGNED_IN_STALE_PROVIDER_EXITS: unauthenticated truth revokes before wallet readiness", async () => {
    productionRootRender.mockReset()
    const renderAccountBridge = installAccountBridgeRenderer()
    const {reload} = stubBrowserGlobals("sign-out")
    const sessionRequests = stubSessionRequests()

    const startup = bridge.startPrivyBridge({}, {
      appId: "test-app",
      authenticated: false,
      getAccessToken: vi.fn(async () => null),
      logout: async () => undefined,
      ready: true,
      walletsReady: false,
      wallets: [],
    } as unknown as bridge.PrivyBridgeProviderState)
    renderAccountBridge(renderedAccountBridge())
    await startup
    await until(() => reload.mock.calls.length > 0)

    expect(sessionRequests).toEqual([{url: "/auth/privy/session", method: "DELETE"}])
    expect(reload).toHaveBeenCalledOnce()
  })

  // Privy can move the selection without changing the connected set. Stake reads
  // the selection, so that change has to reach the page as a wallet-state event.
  it("P1_ACTIVE_WALLET_ONLY: publishes the selection and announces a selection-only change", async () => {
    productionRootRender.mockReset()
    replaceActiveEthereumWallet(null)
    const renderAccountBridge = installAccountBridgeRenderer()
    const {dispatched} = stubBrowserGlobals()
    const first = ethereumWallet("0x1111111111111111111111111111111111111111")
    const second = ethereumWallet("0x2222222222222222222222222222222222222222")
    const solana = {address: "SoLaNa1111111111111111111111111111111111111", type: "solana"}
    const providerState = {
      appId: "test-app",
      authenticated: true,
      getAccessToken: async () => "current-token",
      logout: async () => undefined,
      ready: true,
      walletsReady: true,
      wallets: [first, second],
      activeWallet: first,
    }

    const startup = bridge.startPrivyBridge(
      {},
      providerState as unknown as bridge.PrivyBridgeProviderState,
    )
    const accountElement = renderedAccountBridge()
    renderAccountBridge(accountElement)
    await startup
    await until(() => activeEthereumWallet()?.provider === first.provider)
    expect(dispatched).toEqual(["autolaunch:wallet-state"])

    // The connected set is identical; only the selection moved.
    providerState.activeWallet = second
    renderAccountBridge(accountElement)
    await until(() => activeEthereumWallet()?.provider === second.provider)

    // A Solana selection is no Stake wallet, and no other wallet stands in.
    providerState.activeWallet = solana as unknown as typeof first
    renderAccountBridge(accountElement)
    await until(() => dispatched.length === 5)
    expect(activeEthereumWallet()).toBeNull()
    expect(new Set(dispatched)).toEqual(new Set(["autolaunch:wallet-state"]))
  })

  // The customer's new choice is known before any of the reconciliation it
  // starts can finish. The wallet they left has to stop being Stake's wallet at
  // once, or the page could prepare and send for it during that gap.
  it("P1_ACTIVE_WALLET_ONLY: the wallet left behind is unavailable before the new one resolves", async () => {
    productionRootRender.mockReset()
    replaceActiveEthereumWallet(null)
    const renderAccountBridge = installAccountBridgeRenderer()
    stubBrowserGlobals()
    const first = ethereumWallet("0x1111111111111111111111111111111111111111")
    const chosenProvider: EthereumProvider = {request: vi.fn()}
    let release: (() => void) | undefined
    let resolutions = 0
    const chosen = {
      address: "0x2222222222222222222222222222222222222222",
      type: "ethereum",
      getEthereumProvider: () =>
        ++resolutions === 1
          ? Promise.resolve(chosenProvider)
          : new Promise<EthereumProvider>(resolve => {
              release = () => resolve(chosenProvider)
            }),
    }
    const providerState = {
      appId: "test-app",
      authenticated: true,
      getAccessToken: async () => "current-token",
      logout: async () => undefined,
      ready: true,
      walletsReady: true,
      wallets: [first, chosen],
      activeWallet: first,
    }

    const startup = bridge.startPrivyBridge(
      {},
      providerState as unknown as bridge.PrivyBridgeProviderState,
    )
    const accountElement = renderedAccountBridge()
    renderAccountBridge(accountElement)
    await startup
    await until(() => activeEthereumWallet()?.provider === first.provider)

    providerState.activeWallet = chosen as unknown as typeof first
    renderAccountBridge(accountElement)

    // The choice has only been made; nothing has resolved yet.
    expect(activeEthereumWallet()).toBeNull()
    await until(() => release !== undefined)
    expect(activeEthereumWallet()).toBeNull()

    release?.()
    await until(() => activeEthereumWallet()?.provider === chosenProvider)
    expect(activeEthereumWallet()?.address).toBe(chosen.address)
  })

  // A selection whose provider cannot be resolved is no Stake wallet. Keeping
  // the previous one would let a page act for a wallet the customer has left.
  it("P1_ACTIVE_WALLET_ONLY: a selection whose provider fails leaves no active wallet", async () => {
    productionRootRender.mockReset()
    replaceActiveEthereumWallet(null)
    const renderAccountBridge = installAccountBridgeRenderer()
    const {dispatched} = stubBrowserGlobals()
    const first = ethereumWallet("0x1111111111111111111111111111111111111111")
    const unavailable = {
      address: "0x2222222222222222222222222222222222222222",
      type: "ethereum",
      getEthereumProvider: async () => {
        throw new Error("provider unavailable")
      },
    }
    const providerState = {
      appId: "test-app",
      authenticated: true,
      getAccessToken: async () => "current-token",
      logout: async () => undefined,
      ready: true,
      walletsReady: true,
      wallets: [first, unavailable],
      activeWallet: first,
    }

    const startup = bridge.startPrivyBridge(
      {},
      providerState as unknown as bridge.PrivyBridgeProviderState,
    )
    const accountElement = renderedAccountBridge()
    renderAccountBridge(accountElement)
    await startup
    await until(() => activeEthereumWallet()?.provider === first.provider)

    // The connected set is identical; only the selection moved, and this
    // wallet's provider does not resolve.
    providerState.activeWallet = unavailable as unknown as typeof first
    renderAccountBridge(accountElement)
    const announced = dispatched.length
    await until(() => dispatched.length > announced)
    expect(activeEthereumWallet()).toBeNull()
  })

  it("selects the signer-bound wallet regardless of provider order", () => {
    const first = {request: vi.fn()}
    const expected = {request: vi.fn()}
    const wallets: Array<[string, EthereumProvider]> = [
      ["0x2222222222222222222222222222222222222222", first],
      ["0x1111111111111111111111111111111111111111", expected],
    ]

    expect(
      selectConnectedEthereumWallet(
        wallets,
        "0x1111111111111111111111111111111111111111",
      )?.provider,
    ).toBe(expected)
  })
})


it("profile-only provider bootstrap never establishes a session, but explicit sign-in can", async () => {
  const completeLogin = vi.fn(async () => {})
  const loginOpen = {current: false}
  const callbacks = createPrivyLoginCallbacks({completeLogin, loginOpen, allowAutomatic: false, showFailure: vi.fn()})
  callbacks.onComplete?.({} as never)
  expect(completeLogin).not.toHaveBeenCalled()
  loginOpen.current = true
  callbacks.onComplete?.({} as never)
  expect(completeLogin).toHaveBeenCalledTimes(1)
})
