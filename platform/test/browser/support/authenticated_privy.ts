import {expect, type Page} from "@playwright/test"

const authenticatedPrivyBridgePathPattern =
  /^\/assets\/js\/privy_bridge(?:-[a-f0-9]{32})?\.js\?(?:vsn=d&)?autolaunch_retry=\d+$/

export function matchesAuthenticatedPrivyBridgeUrl(url: string, ashOrigin: string): boolean {
  try {
    const candidate = new URL(url)

    return (
      candidate.origin === ashOrigin &&
      authenticatedPrivyBridgePathPattern.test(`${candidate.pathname}${candidate.search}`)
    )
  } catch {
    return false
  }
}

type ExpectedCounts = {
  documents: number
  sessionChecks: number
  syncs: number
}

type SessionCheck = {
  authenticated: boolean
  status: number
}

type SyncCall = {
  bearer: string
  reconciled: boolean
  request: string
}

export type AuthenticatedPrivy = {
  establishLocalSession(): Promise<void>
  expectAuthenticatedSession(): Promise<void>
  expectCounts(expected: ExpectedCounts): Promise<void>
}

const recordSync = "__authenticatedPrivyRecordSync"

// The deterministic partner of an access token. `Autolaunch.TestPrivyVerifier`
// builds the same partner on the server and has to stay in step with this.
export function identityTokenFor(accessToken: string): string {
  return `${accessToken}-identity`
}

export async function installAuthenticatedPrivy(
  page: Page,
  bearer: string,
): Promise<AuthenticatedPrivy> {
  const bridgeRequests: string[] = []
  const documentRequests: string[] = []
  const sessionChecks: SessionCheck[] = []
  const sessionDeletes: string[] = []
  const syncCalls: SyncCall[] = []
  const csrfResponse = await page.request.get("/auth/csrf")
  const ashOrigin = new URL(csrfResponse.url()).origin
  const {csrf_token: csrfToken} = (await csrfResponse.json()) as {csrf_token: string}

  await page.exposeFunction(recordSync, (call: SyncCall) => syncCalls.push(call))
  page.on("request", request => {
    if (request.isNavigationRequest() && request.resourceType() === "document") {
      documentRequests.push(request.url())
    }
    if (request.method() === "DELETE" && request.url().endsWith("/auth/privy/session")) {
      sessionDeletes.push(request.url())
    }
  })
  await page.route(
    url => matchesAuthenticatedPrivyBridgeUrl(url.href, ashOrigin),
    async route => {
      bridgeRequests.push(route.request().url())
      await route.fulfill({
        body: authenticatedBridgeStub(bearer),
        contentType: "application/javascript",
      })
    },
  )

  return {
    async establishLocalSession() {
      const response = await page.request.post("/auth/privy/session", {
        headers: {
          authorization: `Bearer ${bearer}`,
          "privy-id-token": identityTokenFor(bearer),
          "x-csrf-token": csrfToken,
        },
        data: {},
      })

      expect(response.status()).toBe(200)
    },

    async expectAuthenticatedSession() {
      const response = await page.request.get("/auth/session")
      const {authenticated} = (await response.json()) as {authenticated: boolean}
      sessionChecks.push({authenticated, status: response.status()})

      expect(response.status()).toBe(200)
      expect(authenticated).toBe(true)
    },

    async expectCounts(expected) {
      await expect.poll(() => syncCalls).toEqual(
        Array.from({length: expected.syncs}, () => ({
          bearer,
          reconciled: true,
          request: "sync",
        })),
      )
      expect(bridgeRequests).toHaveLength(expected.syncs)
      expect(documentRequests).toHaveLength(expected.documents)
      expect(sessionChecks).toHaveLength(expected.sessionChecks)
      expect(sessionChecks.every(check => check.status === 200 && check.authenticated)).toBe(true)
      expect(sessionDeletes).toHaveLength(0)
    },
  }
}

function authenticatedBridgeStub(bearer: string): string {
  return `
import {
  createProviderSessionReconciler
} from "/assets/js/privy_bridge.js?authenticated_privy_original=1"

export async function startPrivyBridge() {
  return {
    async request(request) {
      if (request !== "sync") {
        throw new Error("Authenticated Privy fixture only supports startup sync")
      }
      const reconcile = createProviderSessionReconciler({
        clearSession: async () => { throw new Error("Authenticated provider cleared the session") },
        getAccessToken: async () => ${JSON.stringify(bearer)},
        hasLinkedWallet: () => true,
        providerAuthenticated: () => true,
        reload: () => window.location.reload()
      })
      const reconciled = await reconcile()
      await window.${recordSync}({
        bearer: ${JSON.stringify(bearer)},
        reconciled,
        request
      })
    }
  }
}
`
}
