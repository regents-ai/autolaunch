import {test as base, expect, type BrowserContext, type Page} from "@playwright/test"
import {randomBytes} from "node:crypto"
import {rpc} from "./chain"

// The journeys' people, as the browser test server's stand-in for Privy knows them
// (test/support/test_privy_verifier.ex). Both hold Anvil development keys, so
// their wallets sign on the copy of Base.
export const people = {
  a: {token: "journey-a", wallet: "0x70997970c51812dc3a010c7d01b50e0d17dc79c8"},
  b: {token: "journey-b", wallet: "0x3c44cdddb6a900fa2b585dd299e03d12fa4293bc"},
} as const

export type Person = {token: string; wallet: string}

/**
 * A person the site has never seen, with a wallet made up for this run: never signed in, never
 * paired, holding nothing until the journey funds it. The copy of Base signs for it as it does
 * for any account it is told to (anvil_impersonateAccount).
 */
export async function freshPerson(): Promise<Person> {
  const wallet = `0x${randomBytes(20).toString("hex")}`
  await rpc("anvil_impersonateAccount", [wallet])
  await rpc("anvil_setBalance", [wallet, "0x56bc75e2d63100000"])
  return {token: `journey-fresh-${wallet}`, wallet}
}

const bridge = /^\/assets\/js\/privy_bridge(-[0-9a-f]+)?\.js$/

/** A transaction the person's wallet was asked to send, as the page handed it over. */
export type Sent = {from: string; to: string; data: string; value: string; hash: string}

// The browser never leaves this machine. The page's sign-in bridge, the one part
// that talks to Privy, is replaced by a stand-in that holds the person's wallet as
// Privy would hold an injected one: the page's own wallet module is told it is the
// active wallet, and every request the page makes of it is answered here, from
// the copy of Base. Only eth_sendTransaction signs, from the person's own key.
// Answers the requests that tried to leave the machine.
export async function holdWallet(context: BrowserContext, baseURL: string, wallet: string | null, sent: Sent[]) {
  const site = new URL(baseURL).host
  const outside: string[] = []
  await context.exposeFunction("journeyWallet", async ({method, params}: {method: string; params: any[]}) => {
    switch (method) {
      case "eth_chainId": return "0x7a69"
      case "eth_accounts":
      case "eth_requestAccounts": return wallet ? [wallet] : []
      case "wallet_switchEthereumChain": return null
      case "wallet_getCapabilities": throw Object.assign(new Error("unsupported"), {code: 4200})
      case "eth_sendTransaction": {
        const [tx] = params
        if (!wallet || tx.from.toLowerCase() !== wallet) throw new Error("not this person's wallet")
        const hash = await rpc("eth_sendTransaction", [{from: wallet, to: tx.to, data: tx.data, value: tx.value}])
        sent.push({from: wallet, to: tx.to.toLowerCase(), data: tx.data, value: tx.value, hash})
        return hash
      }
      default: return rpc(method, params)
    }
  })
  await context.route(() => true, async route => {
    const url = new URL(route.request().url())
    if (url.host !== site) {
      outside.push(`${route.request().method()} ${url.origin}${url.pathname}`)
      return route.abort("blockedbyclient")
    }
    if (bridge.test(url.pathname)) return route.fulfill({contentType: "text/javascript", body: standIn(await (await route.fetch()).text(), wallet)})
    return route.continue()
  })
  return outside
}

export const test = base.extend<{wallet: string | null; sent: Sent[]; onThisMachine: void}>({
  wallet: [null, {option: true}],
  sent: async ({}, use) => use([]),
  onThisMachine: [async ({context, baseURL, wallet, sent}, use) => {
    const outside = await holdWallet(context, baseURL!, wallet, sent)
    await use()
    expect(outside, "requests that left the machine").toEqual([])
  }, {auto: true}],
})

// The stand-in imports the page's own wallet module from the chunk the real
// bridge imports it from.
function standIn(real: string, wallet: string | null): string {
  const chunk = real.match(/import\s*\{[^}]*\breplaceActiveEthereumWallet\b[^}]*\}\s*from\s*"([^"]+)"/)
  if (!chunk) throw new Error("the bridge no longer imports the wallet module")
  return `
import {replaceActiveEthereumWallet, replaceConnectedEthereumWallets} from "${chunk[1]}"
const address = ${JSON.stringify(wallet)}
const provider = {request: ({method, params}) => window.journeyWallet({method, params: params ?? []})}
export async function startPrivyBridge() {
  if (address) {
    replaceConnectedEthereumWallets([[address, {provider, disconnect() {}}]])
    replaceActiveEthereumWallet({address, provider})
    window.dispatchEvent(new CustomEvent("autolaunch:wallet-state"))
  }
  return {isAvailable: () => true, request: async () => {}}
}
`
}

/** Signs `person` in through the site's own sign-in step, as the walk does. */
export async function signIn(page: Page, person: Person) {
  await page.goto("/")
  const status = await page.evaluate(async token => {
    const {csrf_token} = await (await fetch("/auth/csrf")).json()
    const response = await fetch("/auth/privy/session", {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "x-csrf-token": csrf_token,
        authorization: `Bearer ${token}`,
        "privy-id-token": `${token}-identity`,
      },
      body: "{}",
    })
    return response.status
  }, person.token)
  expect(status, `${person.token} signs in`).toBe(200)
}

/** The page's buttons answer once its script has connected it. */
export async function ready(page: Page) {
  await expect(page.locator("[data-phx-main].phx-connected")).toBeAttached()
}

/** Nothing on the page is wider than the screen, and every press is at least 44 px on touch. */
export async function fitsAndPresses(page: Page, touch: boolean) {
  const wide = await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth)
  expect(wide, "sideways scroll").toBeLessThanOrEqual(0)
  if (!touch) return
  const small = await page.evaluate(() =>
    [...document.querySelectorAll<HTMLElement>("button, a[href], [role=button], select, summary")]
      .filter(el => el.offsetParent !== null && !el.closest("[hidden], [inert]"))
      // A link inside a sentence is part of the text, not a standalone press.
      .filter(el => {
        const block = el.tagName === "A" ? el.closest("p, li, td, dd") : null
        return !block || block.textContent!.trim() === el.textContent!.trim()
      })
      // Layout size, so a press animation caught part-way never reads as a small press.
      .filter(el => el.offsetWidth > 0 && (el.offsetHeight < 44 || el.offsetWidth < 44))
      .map(el => `${el.tagName.toLowerCase()} "${(el.textContent ?? "").trim().slice(0, 40)}" ${el.offsetWidth}x${el.offsetHeight}`),
  )
  expect(small, "presses smaller than 44 px on touch").toEqual([])
}

export {expect}
