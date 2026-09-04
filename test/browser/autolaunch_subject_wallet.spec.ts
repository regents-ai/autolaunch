import {expect, test, type Page} from "@playwright/test"
import {installAuthenticatedPrivy} from "./support/authenticated_privy"

// The seeded browser account for the Autolaunch fixtures holds this wallet.
const wallet = "0x3333333333333333333333333333333333333333"
const subject = "subject:browser:wallet"
const sendsKey = "regent:test:subject-wallet-sends"
const rejectKey = "regent:test:subject-wallet-reject-next"
const wrongChainKey = "regent:test:subject-wallet-wrong-chain"

const card = "#autolaunch-subject-wallet"
const path = `/subjects/${subject}`

// Every submitted hash is unique for the life of the database and the browser
// database is never reset, so each run mints its own. Each test also gets its
// own slot, because the per-context send counter restarts with every test and
// would otherwise mint a hash an earlier test already bound.
const run = `${Date.now().toString(16).padStart(12, "0")}c1`
let slot = 0

async function installWallet(page: Page, testSlot: number) {
  await page.addInitScript(
    ({wallet, sendsKey, rejectKey, wrongChainKey, run, testSlot}) => {
      // The send count lives in session storage so a document reload cannot hide
      // a second wallet request behind a fresh counter.
      const sends = () => Number(sessionStorage.getItem(sendsKey) ?? "0")
      const active = () =>
        (window as Window & {__autolaunchTestWallet?: {address: string}}).__autolaunchTestWallet
          ?.address ?? wallet

      ;(window as Window & {__autolaunchTestWallet?: unknown}).__autolaunchTestWallet = {
        address: wallet,
        provider: {
          request: async ({method}: {method: string; params?: unknown[]}) => {
            switch (method) {
              case "eth_chainId":
                return sessionStorage.getItem(wrongChainKey) ? "0x1" : "0x2105"
              case "wallet_switchEthereumChain":
                return null
              case "eth_accounts":
              case "eth_requestAccounts":
                return [active()]
              case "eth_sendTransaction": {
                // A real wallet rejection: nothing is broadcast and nothing is
                // counted, exactly as EIP-1193 4001 means.
                if (sessionStorage.getItem(rejectKey)) {
                  sessionStorage.removeItem(rejectKey)
                  throw Object.assign(new Error("User rejected the request."), {code: 4001})
                }
                const nonce = sends() + 1
                sessionStorage.setItem(sendsKey, String(nonce))
                const suffix = `${testSlot.toString(16).padStart(2, "0")}${nonce
                  .toString(16)
                  .padStart(4, "0")}`
                return `0x${run}${suffix}${"0".repeat(44)}`
              }
              default:
                return null
            }
          },
        },
      }

      window.addEventListener("autolaunch:wallet-connect", () => {
        window.dispatchEvent(new CustomEvent("autolaunch:wallet-state"))
      })
    },
    {wallet, sendsKey, rejectKey, wrongChainKey, run, testSlot},
  )
}

async function signedIn(page: Page) {
  slot += 1
  const auth = await installAuthenticatedPrivy(page, "other-account")
  await installWallet(page, slot)
  await auth.establishLocalSession()
  return auth
}

const endControls = [
  'button[phx-click="clear_subject_wallet_action"]',
  'button[phx-click="cancel_subject_wallet_review"]',
  'button[phx-click="start_new_subject_wallet_action"]',
]
  .map(selector => `${card} ${selector}`)
  .join(", ")

/**
 * Opens the card ready to review.
 *
 * The account keeps one open action per subject and this database is never reset
 * between runs, so whatever an earlier test left in flight is ended first. That
 * the server shows it at all, in a browser with no stored hint, is the recovery
 * this proves.
 */
async function freshCard(page: Page) {
  await page.goto(path)
  await expect(page.locator(card)).toContainText("Staked", {timeout: 15_000})

  for (let attempt = 0; attempt < 4; attempt += 1) {
    if (await page.locator(`${card}-form`).count()) break

    const control = page.locator(endControls).first()
    await control.click()

    // Wait for the re-render this click causes rather than for a clock, so the
    // next pass reads the card the server actually sent.
    await Promise.race([
      page.locator(`${card}-form`).waitFor({state: "visible", timeout: 10_000}),
      control.waitFor({state: "detached", timeout: 10_000}),
    ]).catch(() => undefined)
  }

  await expect(page.locator(`${card}-form`)).toBeVisible()
}

test("a signed-in wallet reviews, sends once, and reads its outcome from the server", async ({
  page,
}) => {
  await signedIn(page)
  await freshCard(page)

  // The card knows the wallet Privy has selected without being asked twice.
  await expect(page.locator(card)).toContainText("Your wallet on this subject")

  // An unstake needs no approval, so it is one step.
  await page.locator(`${card}-action-unstake`).click()
  await page.locator(`${card}-amount`).fill("10")
  await page.locator(`${card} button[type="submit"]`).click()

  await expect(page.locator(`${card}-review`)).toContainText("Unstake")
  await expect(page.locator(`${card}-review`)).toContainText("10 SUBJECT")
  await expect(page.locator(`${card}-review`)).toContainText("Base")

  // No calldata or selector is ever put in front of the customer.
  await expect(page.locator(card)).not.toContainText("0x2e17de78")

  await page.locator(`${card} [data-subject-wallet-send]`).click()

  // The browser reports the hash and stops; the outcome is the server's own read.
  await expect(page.locator(card)).toContainText("Sent", {timeout: 10_000})
  await expect(page.locator(`${card} a[href^="https://basescan.org/tx/"]`)).toBeVisible()

  // Exactly one wallet send happened, and the claimed step is not offered again.
  expect(await page.evaluate(key => sessionStorage.getItem(key), sendsKey)).toBe("1")
  await expect(page.locator(`${card} [data-subject-wallet-send]`)).toHaveCount(0)
})

test("a reload recovers the open action and never sends it a second time", async ({page}) => {
  await signedIn(page)
  await freshCard(page)

  await page.locator(`${card}-action-unstake`).click()
  await page.locator(`${card}-amount`).fill("5")
  await page.locator(`${card} button[type="submit"]`).click()
  await expect(page.locator(`${card}-review`)).toContainText("Unstake")

  await page.locator(`${card} [data-subject-wallet-send]`).click()
  await expect(page.locator(card)).toContainText("Sent", {timeout: 10_000})

  const sendsBefore = await page.evaluate(key => sessionStorage.getItem(key), sendsKey)

  await page.reload()

  // The same action comes back from the owning account's own row, still sent,
  // and the reload asked no wallet for anything.
  await expect(page.locator(`${card}-review`)).toContainText("Unstake", {timeout: 10_000})
  await expect(page.locator(`${card} a[href^="https://basescan.org/tx/"]`)).toBeVisible()
  expect(await page.evaluate(key => sessionStorage.getItem(key), sendsKey)).toBe(sendsBefore)
  await expect(page.locator(`${card} [data-subject-wallet-send]`)).toHaveCount(0)
})

test("an explicit wallet rejection ends the action and broadcasts nothing", async ({page}) => {
  await signedIn(page)
  await freshCard(page)

  await page.evaluate(key => sessionStorage.setItem(key, "1"), rejectKey)

  await page.locator(`${card}-action-unstake`).click()
  await page.locator(`${card}-amount`).fill("3")
  await page.locator(`${card} button[type="submit"]`).click()
  await page.locator(`${card} [data-subject-wallet-send]`).click()

  await expect(page.locator(card)).toContainText("Your wallet declined this.", {timeout: 10_000})
  expect(await page.evaluate(key => sessionStorage.getItem(key), sendsKey)).toBeNull()
  await expect(page.locator(`${card} [data-subject-wallet-send]`)).toHaveCount(0)
})

test("a payment review states the exact amount each part of the split receives", async ({page}) => {
  await signedIn(page)
  await freshCard(page)

  await page.locator(`${card}-action-pay`).click()
  await page.locator(`${card}-asset`).selectOption("usdc")
  await page.locator(`${card}-amount`).fill("2")
  await page.locator(`${card} button[type="submit"]`).click()

  // Only a sliver of the whole SUBJECT supply is staked here, so the staker part
  // really is zero. The review says so in exact amounts rather than a share, and
  // only for the moment it was reviewed.
  const review = page.locator(`${card}-review`)
  await expect(review).toContainText(
    "Of this 2 USDC, 0.04 USDC goes to the protocol. As things stand right now, the remaining 1.96 USDC divides into 0 USDC for everyone staking SUBJECT on this subject and 1.96 USDC for its treasury. If staking changes before this goes through, those last two amounts change with it.",
  )
  await expect(review).not.toContainText("98%")

  // A payment needs an allowance first, so the review is two steps.
  await expect(page.locator(`${card} li[data-step="approval"]`)).toBeVisible()
  await expect(page.locator(`${card} li[data-step="action"]`)).toBeVisible()
})

test("a sweep review says the signer receives nothing", async ({page}) => {
  await signedIn(page)
  await freshCard(page)

  await page.locator(`${card}-action-sweep`).click()
  await page.locator(`${card}-asset`).selectOption("usdc")
  await page.locator(`${card} button[type="submit"]`).click()

  await expect(page.locator(`${card}-review`)).toContainText("Nothing is sent to your wallet")
  await expect(page.locator(`${card}-review`)).toContainText("another sweep before yours")
})

test("a signed-out visitor is offered no wallet control at all", async ({page}) => {
  await page.goto(path)

  await expect(page.locator(card)).toContainText("Sign in to continue")
  await expect(page.locator(`${card} [data-subject-wallet-send]`)).toHaveCount(0)
  await expect(page.locator(`${card} form`)).toHaveCount(0)
})

test("the card fits a 390 pixel viewport and a desktop one without overflowing", async ({page}) => {
  await signedIn(page)

  for (const viewport of [
    {width: 390, height: 844},
    {width: 1440, height: 900},
  ]) {
    await page.setViewportSize(viewport)
    await freshCard(page)

    await page.locator(`${card}-action-pay`).click()
    await page.locator(`${card}-amount`).fill("1.234567")
    await page.locator(`${card} button[type="submit"]`).click()
    await expect(page.locator(`${card}-review`)).toBeVisible()

    // Layout width, not the bounding box: the shell animates route content, and
    // a transform mid-flight would make a box measurement lie about the layout.
    const layout = await page.evaluate(
      ({root}) => {
        const node = document.querySelector(root) as HTMLElement

        return {
          card: node.offsetWidth,
          page: document.documentElement.clientWidth,
          sideways:
            document.documentElement.scrollWidth - document.documentElement.clientWidth,
          clipped: [node, ...node.querySelectorAll("*")]
            .filter(child => child.scrollWidth > child.clientWidth + 1)
            .map(child => `${child.tagName}.${child.className || "-"}`),
          controls: node.querySelectorAll("button, input, select").length,
        }
      },
      {root: card},
    )

    // The page never scrolls sideways, the card fits the screen, and nothing
    // inside it is cut off.
    expect(layout.controls).toBeGreaterThan(0)
    expect(layout.sideways).toBeLessThanOrEqual(0)
    expect(layout.card).toBeLessThanOrEqual(layout.page)
    expect(layout.clipped).toEqual([])
  }
})
