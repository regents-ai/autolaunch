import {readFileSync} from "node:fs"

import {expect, test, type Locator, type Page} from "@playwright/test"
import {installAuthenticatedPrivy} from "./support/authenticated_privy"

const png = readFileSync("test/support/fixtures/launch-draft.png")

// The seeded browser account for the Autolaunch draft fixtures holds this wallet.
const wallet = "0x3333333333333333333333333333333333333333"
// A second wallet, to select while a draft is being written.
const otherWallet = "0x4444444444444444444444444444444444444444"
// Lowercase on purpose: mixed case asserts an EIP-55 checksum, and a launch
// review refuses an address whose checksum does not hold.
const treasury = "0xabcdef0000000000000000000000000000000001"
const browserEoa = "0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
const eoaWarning =
  "This auction will be owned by my EOA private key, and significant harm and token value will happen if it is lost or compromised. I was warned to create a Gnosis Safe or 0xSplits smart account as the owner, and I realize auction bidders and token owners will see that it is EOA-owned and more risky. I accept these problems, and wish to continue with EOA ownership of the token."

const sendsKey = "regent:test:launch-sends"
const rejectKey = "regent:test:launch-reject-next"

// Every submitted hash is unique for the life of the database and the browser
// database is never reset, so each run mints its own. Each test also gets its
// own slot, because the per-context send counter restarts with every test and
// would otherwise mint a hash an earlier test already bound.
const run = `${Date.now().toString(16).padStart(12, "0")}c4`
const unverifiedTreasury = `0xfafa${run}${"0".repeat(22)}`
let slot = 0

async function installWallet(page: Page, testSlot: number) {
  await page.addInitScript(
    ({wallet, sendsKey, rejectKey, run, testSlot}) => {
      // The send count lives in session storage so a document reload cannot hide
      // a second wallet request behind a fresh counter.
      const sends = () => Number(sessionStorage.getItem(sendsKey) ?? "0")

      ;(window as Window & {__autolaunchTestWallet?: unknown}).__autolaunchTestWallet = {
        address: wallet,
        provider: {
          request: async ({method}: {method: string; params?: unknown[]}) => {
            switch (method) {
              case "eth_chainId":
                return "0x2105"
              case "wallet_switchEthereumChain":
                return null
              case "eth_accounts":
              case "eth_requestAccounts":
                return [wallet]
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
    {wallet, sendsKey, rejectKey, run, testSlot},
  )
}

// Privy's selection changing under the page, announced the way the shell
// announces it.
async function selectWallet(page: Page, address: string) {
  await page.evaluate(next => {
    const test = window as Window & {__autolaunchTestWallet?: {address: string}}
    test.__autolaunchTestWallet!.address = next
    window.dispatchEvent(new CustomEvent("autolaunch:wallet-state"))
  }, address)
}

async function signedIn(page: Page) {
  slot += 1
  const auth = await installAuthenticatedPrivy(page, "other-account")
  await installWallet(page, slot)
  await auth.establishLocalSession()
  return auth
}

/**
 * One saved draft, written through the real form, with its own launch card.
 *
 * The account keeps one open launch and this database is never reset between
 * runs, so whatever an earlier test left in flight is ended first. That the
 * server shows it at all, in a browser with no stored hint, is the recovery this
 * proves.
 */
async function draftCard(page: Page): Promise<Locator> {
  await page.goto("/create")
  await expect(page.getByRole("heading", {name: "Launch an auction"})).toBeVisible()

  const card = page.locator(".launch-wallet")
  if (!(await card.count())) await saveDraft(page)
  else await ensureEoaPath(page)
  await expect(card).toBeVisible()
  await endAnyOpenLaunch(page)
  await expect(card.getByRole("button", {name: "Review launch"})).toBeVisible({timeout: 15_000})

  return card
}

// The one draft this proof owns, written through the dest Create form. The
// browser database is never reset, so it is reused rather than piled up.
const draftName = "Launch wallet browser draft"

async function saveDraft(
  page: Page,
  name = draftName,
  recipient = treasury,
  path: "safe" | "eoa" = "eoa",
) {
  const tokenForm = page.locator("#launch-token-details")
  await tokenForm.getByLabel("Name", {exact: true}).fill(name)
  await tokenForm.getByLabel("Symbol", {exact: true}).fill("LWD")
  await tokenForm.getByLabel("Description", {exact: true}).fill("A launch awaiting review.")
  await tokenForm.getByLabel("Website", {exact: true}).fill("https://example.test/launch-wallet")
  await tokenForm.getByLabel("Required raise in REGENT", {exact: true}).fill("1000.5")

  const image = tokenForm.getByRole("img", {name: "Saved token image"})
  if (!(await image.count())) {
    await tokenForm.locator('input[type="file"]').setInputFiles({
      name: "launch-wallet.png",
      mimeType: "image/png",
      buffer: png,
    })
    await expect(image).toBeVisible({timeout: 15_000})
  }

  const treasuryForm = page.locator("#launch-treasury-details")
  if (path === "eoa") {
    await treasuryForm.locator(".autolaunch-custody-path details summary").click()
    await treasuryForm.locator('input[name="launch_draft[treasury_path]"][value="eoa"]').check()
    await treasuryForm.locator('textarea[name="launch_draft[eoa_acknowledgement]"]').fill(eoaWarning)
  }

  await treasuryForm.getByLabel("Immutable treasury recipient", {exact: true}).fill(recipient)
  await expect(page.locator("#launch-transactions")).toContainText("Ready", {timeout: 15_000})
  await expect(page.locator(".launch-wallet")).toBeVisible()
}

async function ensureEoaPath(page: Page) {
  const treasuryForm = page.locator("#launch-treasury-details")
  const eoa = treasuryForm.locator('input[name="launch_draft[treasury_path]"][value="eoa"]')
  if (await eoa.isChecked()) return

  await treasuryForm.locator(".autolaunch-custody-path details summary").click()
  await eoa.check()
  await treasuryForm.locator('textarea[name="launch_draft[eoa_acknowledgement]"]').fill(eoaWarning)
  await expect(page.locator("#launch-transactions")).toContainText("Ready", {timeout: 15_000})
}

// A launch this account left open on any draft blocks a new review, so it is
// ended through whichever control the server is currently offering.
async function endAnyOpenLaunch(page: Page) {
  // Every card offers this prompt until the server has adopted the wallet its
  // hook published, and that same render replays whatever launch this account
  // has open. Reading the controls earlier finds none and leaves it standing.
  await expect(page.locator(".launch-wallet [data-launch-wallet-connect]")).toHaveCount(0, {
    timeout: 15_000,
  })

  const controls = [
    'button[phx-click="clear_launch"]',
    'button[phx-click="cancel_launch_review"]',
    'button[phx-click="start_new_launch"]',
  ]
    .map(selector => `.launch-wallet ${selector}`)
    .join(", ")

  for (let attempt = 0; attempt < 4; attempt += 1) {
    if (!(await page.locator(controls).count())) return

    const control = page.locator(controls).first()
    await control.click()

    // Wait for the re-render this click causes rather than for a clock, so the
    // next pass reads the card the server actually sent.
    await control.waitFor({state: "detached", timeout: 10_000}).catch(() => undefined)
  }
}

async function reviewed(page: Page): Promise<Locator> {
  const card = await draftCard(page)
  // Dest browser observe as the signed-in Human does not persist a Verified
  // Safe report. The EOA path still reviews and is the one these proofs send.
  await card.getByRole("button", {name: "Review launch"}).click()
  await expect(card.locator(".launch-wallet-review")).toBeVisible({timeout: 15_000})
  return card
}

test("stored treasury proof waits for a fresh observation before showing Verified", async ({
  page,
}) => {
  await signedIn(page)
  await page.goto("/create")
  await expect(page.getByRole("heading", {name: "Launch an auction"})).toBeVisible()
  await saveDraft(page, draftName, treasury, "safe")
  const card = page.locator(".launch-wallet")
  await endAnyOpenLaunch(page)
  await expect(card).toContainText("Awaiting current chain confirmation")
  await expect(card).not.toContainText("Verified 2-of-3 Safe")

  const verification = card.locator('form[phx-submit="verify_treasury"]')
  await verification.getByLabel("USDC receipt transaction").fill(`0x${"11".repeat(32)}`)
  await verification.getByLabel("REGENT receipt transaction").fill(`0x${"22".repeat(32)}`)
  await verification
    .getByLabel("Outbound Safe execution transaction")
    .fill(`0x${"33".repeat(32)}`)
  await verification.getByRole("button", {name: "Verify deployed address on Base"}).click()

  await expect(card).toContainText("Verified 2-of-3 Safe", {timeout: 15_000})
})

test("exact EOA acknowledgement with blank evidence reaches high-risk review without a wallet request", async ({
  page,
}) => {
  await signedIn(page)
  await page.goto("/create")
  await expect(page.getByRole("heading", {name: "Launch an auction"})).toBeVisible()

  const name = `EOA browser draft ${run}`
  const tokenForm = page.locator("#launch-token-details")
  await tokenForm.getByLabel("Name", {exact: true}).fill(name)
  await tokenForm.getByLabel("Symbol", {exact: true}).fill("EOA")
  await tokenForm.getByLabel("Description", {exact: true}).fill("A high-risk EOA custody review.")
  await tokenForm.getByLabel("Website", {exact: true}).fill("https://example.test/eoa")
  await tokenForm.getByLabel("Required raise in REGENT", {exact: true}).fill("1000.5")
  await tokenForm.locator('input[type="file"]').setInputFiles({
    name: "eoa.png",
    mimeType: "image/png",
    buffer: png,
  })
  await expect(page.getByRole("status")).toContainText("Image saved", {timeout: 15_000})

  const treasuryForm = page.locator("#launch-treasury-details")
  await treasuryForm.locator(".autolaunch-custody-path details summary").click()
  await treasuryForm.locator('input[name="launch_draft[treasury_path]"][value="eoa"]').check()
  await treasuryForm.locator('textarea[name="launch_draft[eoa_acknowledgement]"]').fill(eoaWarning)
  await treasuryForm.getByLabel("Immutable treasury recipient", {exact: true}).fill(browserEoa)
  await expect(page.locator("#launch-transactions")).toContainText("Ready", {timeout: 15_000})

  const card = page.locator(".launch-wallet")
  await endAnyOpenLaunch(page)
  await card.getByRole("button", {name: "Verify deployed address on Base"}).click()
  await expect(card).toContainText("Unverified")
  await card.getByRole("button", {name: "Review launch"}).click()
  await expect(card.locator(".launch-wallet-review")).toBeVisible({timeout: 15_000})
  await treasuryForm.locator(".autolaunch-custody-path details summary").click()
  await expect(treasuryForm.locator(".autolaunch-custody-warning")).toHaveText(eoaWarning)
  await expect(
    treasuryForm.locator('input[name="launch_draft[treasury_path]"][value="eoa"]'),
  ).toBeChecked()
  expect(await page.evaluate(key => sessionStorage.getItem(key), sendsKey)).toBeNull()
  await card.getByRole("button", {name: "Cancel"}).click()
})

test("each explicit click sends once and a later review is not globally deduplicated", async ({
  page,
}) => {
  await signedIn(page)
  let card = await reviewed(page)

  await card.locator("[data-launch-wallet-send]").click()
  await expect(card).toContainText("Sent", {timeout: 15_000})
  expect(await page.evaluate(key => sessionStorage.getItem(key), sendsKey)).toBe("1")
  await expect(card.locator("[data-launch-wallet-send]")).toHaveCount(0)

  await card.getByRole("button", {name: "Start something else"}).click()
  card = await reviewed(page)
  await card.locator("[data-launch-wallet-send]").click()
  await expect(card).toContainText("Sent", {timeout: 15_000})
  expect(await page.evaluate(key => sessionStorage.getItem(key), sendsKey)).toBe("2")
})

test("reload recovers a submitted review without another wallet request", async ({page}) => {
  await signedIn(page)
  const card = await reviewed(page)
  await card.locator("[data-launch-wallet-send]").click()
  await expect(card).toContainText("Sent", {timeout: 15_000})
  const sendsBefore = await page.evaluate(key => sessionStorage.getItem(key), sendsKey)

  await page.reload()
  const restored = page.locator(".launch-wallet").filter({hasText: "Review this launch"})
  await expect(restored).toContainText("Sent", {timeout: 15_000})
  expect(await page.evaluate(key => sessionStorage.getItem(key), sendsKey)).toBe(sendsBefore)
  await expect(restored.locator("[data-launch-wallet-send]")).toHaveCount(0)
})

test("explicit wallet rejection broadcasts nothing", async ({page}) => {
  await signedIn(page)
  const card = await reviewed(page)
  await page.evaluate(key => sessionStorage.setItem(key, "1"), rejectKey)
  await card.locator("[data-launch-wallet-send]").click()
  await expect(card).toContainText("Your wallet declined this.", {timeout: 15_000})
  expect(await page.evaluate(key => sessionStorage.getItem(key), sendsKey)).toBeNull()
  await expect(card.locator("[data-launch-wallet-send]")).toHaveCount(0)
})

test("technical values remain behind the reviewed-card disclosure", async ({page}) => {
  await signedIn(page)
  const card = await reviewed(page)
  const details = card.locator(".launch-wallet-review details")
  await details.locator("summary").click()
  await expect(details).toContainText("Calldata digest")
  await expect(details).toContainText("Floor price q96")
  await expect(details).toContainText("Max reachable raise")
})

test("the reviewed card fits mobile and desktop viewports without clipping", async ({page}) => {
  await signedIn(page)
  await page.setViewportSize({width: 390, height: 844})
  const card = await reviewed(page)
  await card.locator(".launch-wallet-review details summary").click()

  for (const viewport of [
    {width: 390, height: 844},
    {width: 1440, height: 900},
  ]) {
    await page.setViewportSize(viewport)
    const layout = await card.locator(".launch-wallet-review").evaluate(node => ({
      card: (node.closest(".launch-wallet") as HTMLElement).offsetWidth,
      page: document.documentElement.clientWidth,
      sideways: document.documentElement.scrollWidth - document.documentElement.clientWidth,
      clipped: [node, ...node.querySelectorAll("*")]
        .filter(child => child.scrollWidth > child.clientWidth + 1)
        .map(child => `${child.tagName}.${child.className || "-"}`),
    }))

    expect(layout.sideways).toBeLessThanOrEqual(0)
    expect(layout.card).toBeLessThanOrEqual(layout.page)
    expect(layout.clipped).toEqual([])
  }
})

test("the official Safe path blocks review until the deployed treasury is verified", async ({
  page,
}) => {
  await signedIn(page)
  await page.goto("/create")
  await expect(page.getByRole("heading", {name: "Launch an auction"})).toBeVisible()

  const name = `Unverified Safe browser draft ${run}`
  await saveDraft(page, name, unverifiedTreasury, "safe")
  const card = page.locator(".launch-wallet")
  await endAnyOpenLaunch(page)

  await expect(card).toContainText("Verify immutable treasury")
  await expect(card).toContainText("Unverified")

  // Review still reaches the server; the refusal is a missing treasury report,
  // and nothing is offered to the wallet.
  expect(await page.evaluate(key => sessionStorage.getItem(key), sendsKey)).toBeNull()
  await card.getByRole("button", {name: "Review launch"}).click()
  await expect(card).toContainText("Verify the deployed treasury address before review.")
  await expect(card.locator(".launch-wallet-review")).toHaveCount(0)
  await expect(card.locator("[data-launch-wallet-send]")).toHaveCount(0)
})

test("a blank draft never inherits the connected signer and keeps whatever is typed", async ({
  page,
}) => {
  await signedIn(page)
  await page.goto("/create")
  await expect(page.getByRole("heading", {name: "Launch an auction"})).toBeVisible()

  // Signer selection confers no custody status: whatever is already saved stays.
  const field = page.locator("#launch-treasury-details-treasury")
  const before = await field.inputValue()

  // Switching the signer still writes nothing into custody.
  await selectWallet(page, otherWallet)
  await expect(field).toHaveValue(before)

  // An address the founder enters is theirs, and a later wallet change leaves it
  // exactly as typed.
  await field.fill(treasury)
  await selectWallet(page, wallet)
  await expect(field).toHaveValue(treasury)
})

test("the two Safe paths lead and the EOA warning is exact", async ({page}) => {
  await signedIn(page)
  await page.goto("/create")
  await expect(page.getByRole("heading", {name: "Launch an auction"})).toBeVisible()

  const choices = page.locator("#launch-treasury-details .autolaunch-custody-path")
  await expect(choices).toContainText("Create a 2-of-3 Safe on Base")
  await expect(choices.getByRole("link", {name: "Open the official Safe creation flow"})).toHaveAttribute(
    "href",
    "https://app.safe.global/new-safe/create?chain=base",
  )
  await expect(choices).toContainText("Use existing Safe")

  await choices.locator("summary").click()
  await expect(choices).toContainText("Advanced, high-risk treasury choices")
  await expect(choices.locator(".autolaunch-custody-warning")).toHaveText(eoaWarning)
})

test("a refused save keeps the Treasury it sent back, whatever the wallet does next", async ({
  page,
}) => {
  await signedIn(page)
  await page.goto("/create")
  await expect(page.getByRole("heading", {name: "Launch an auction"})).toBeVisible()

  const tokenForm = page.locator("#launch-token-details")
  const field = page.locator("#launch-treasury-details-treasury")

  // Every field valid except the raise, with the Treasury left exactly as it was
  // found.
  await tokenForm.getByLabel("Name", {exact: true}).fill("Launch wallet echo draft")
  await tokenForm.getByLabel("Symbol", {exact: true}).fill("LWE")
  await tokenForm.getByLabel("Description", {exact: true}).fill("A draft the server refuses.")
  await tokenForm.getByLabel("Website", {exact: true}).fill("https://example.test/echo")
  await field.fill(treasury)

  // Selecting a different wallet now changes nothing. The address on screen
  // belongs to the founder, not to the connected signer.
  await expect(field).toHaveValue(treasury)

  // Selecting a different wallet now changes nothing. The address on screen came
  // back from the server and belongs to the founder, not to the default.
  await selectWallet(page, otherWallet)
  await expect(field).toHaveValue(treasury)
})

test("a signed-out visitor is offered no launch control at all", async ({page}) => {
  await page.goto("/create")

  await expect(page).toHaveURL("/")
  await expect(page.locator("[data-launch-wallet-send]")).toHaveCount(0)
  await expect(page.locator(".launch-wallet")).toHaveCount(0)
})

test("the custody choices fit a 390 pixel viewport and a desktop one without overflowing", async ({
  page,
}) => {
  await signedIn(page)
  await page.goto("/create")
  await expect(page.getByRole("heading", {name: "Launch an auction"})).toBeVisible()

  for (const viewport of [
    {width: 390, height: 844},
    {width: 1440, height: 900},
  ]) {
    await page.setViewportSize(viewport)
    const choices = page.locator("#launch-treasury-details .autolaunch-custody-path")
    await expect(choices).toContainText("Create a 2-of-3 Safe on Base")
    await expect(choices).toContainText("Use existing Safe")
    await choices.locator("summary").click()

    const layout = await page.evaluate(() => {
      const node = document.querySelector(
        "#launch-treasury-details .autolaunch-custody-path",
      ) as HTMLElement

      return {
        choices: node.offsetWidth,
        page: document.documentElement.clientWidth,
        sideways: document.documentElement.scrollWidth - document.documentElement.clientWidth,
        textarea: node.querySelector("textarea")?.offsetWidth ?? 0,
        controls: node.querySelectorAll("a, input, details, textarea").length,
      }
    })

    expect(layout.controls).toBeGreaterThan(0)
    expect(layout.sideways).toBeLessThanOrEqual(0)
    expect(layout.choices).toBeLessThanOrEqual(layout.page)
    expect(layout.textarea).toBeLessThanOrEqual(layout.choices)

    await choices.locator("summary").click()
  }
})
