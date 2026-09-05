import {readFileSync} from "node:fs"

import {expect, test, type Page} from "@playwright/test"

import {installAuthenticatedPrivy} from "./support/authenticated_privy"

const treasury = "0xabcdef0000000000000000000000000000000001"
const launchName = "Browser Research"

const png = readFileSync("test/support/fixtures/launch-draft.png")

function destChromePath(pathname: string) {
  return (
    pathname.startsWith("/fonts/") ||
    pathname.startsWith("/favicon") ||
    pathname.startsWith("/apple-touch-icon")
  )
}

function cleanBrowser(page: Page) {
  const errors: string[] = []
  page.on("pageerror", error => errors.push(error.message))
  page.on("console", message => {
    if (message.type() !== "error") return
    // Dest still 404s design-system Geist files and the extra favicon PNGs.
    if (message.text().includes("Failed to load resource") && message.text().includes("404")) {
      return
    }
    errors.push(message.text())
  })
  page.on("response", response => {
    if (response.status() !== 404) return
    const pathname = new URL(response.url()).pathname
    if (destChromePath(pathname)) return
    errors.push(`404 ${pathname}`)
  })
  return () => expect(errors).toEqual([])
}

test("Create sends an anonymous visitor home", async ({page}) => {
  const assertCleanBrowser = cleanBrowser(page)
  await page.goto("/create")
  await expect(page).toHaveURL("/")
  await expect(page.getByRole("heading", {name: "Autolaunch"})).toBeVisible()
  assertCleanBrowser()
})

test("Create is one persistent form with a live public preview", async ({page}) => {
  const assertCleanBrowser = cleanBrowser(page)
  const auth = await installAuthenticatedPrivy(page, "other-account")
  await auth.establishLocalSession()
  await page.goto("/create")

  await expect(page.getByRole("heading", {name: "Launch an auction"})).toBeVisible()
  await expect(page.getByRole("navigation", {name: "Launch stages"})).toHaveCount(0)
  await expect(page.locator("#launch-token-details")).toBeVisible()
  await expect(page.locator("#launch-treasury-details")).toBeVisible()
  await expect(page.locator("#launch-transactions")).toBeVisible()
  await expect(page.getByText("Recommended: 400 × 400 px")).toBeVisible()
  await expect(page.locator("#launch-image-url")).toContainText("Paste an image link")
  await expect(page.locator("#autolaunch-create-x-connections-profile")).toContainText("Profile X")
  await expect(page.locator("#autolaunch-create-x-connections-company")).toContainText("Company X")

  const tokenForm = page.locator("#launch-token-details")
  const preview = page.getByRole("complementary", {name: "Live launch preview"})

  await tokenForm.getByLabel("Name", {exact: true}).fill(launchName)
  await tokenForm.getByLabel("Symbol", {exact: true}).fill("BROWSE")
  await tokenForm
    .getByLabel("Description", {exact: true})
    .fill("A persisted browser launch with one public identity.")
  await tokenForm.getByLabel("Website", {exact: true}).fill("https://example.test/browser")
  await tokenForm.getByLabel("Required raise in REGENT", {exact: true}).fill("1000.5")

  await expect(preview.getByRole("heading", {name: launchName})).toBeVisible()
  await expect(preview).toContainText("$BROWSE")
  await expect(preview).toContainText("A persisted browser launch with one public identity.")
  await expect(preview).toContainText("1000.5 REGENT")

  await tokenForm.locator('input[type="file"]').setInputFiles({
    name: "browser-token.png",
    mimeType: "image/png",
    buffer: png,
  })

  await expect(tokenForm.getByRole("img", {name: "Saved token image"})).toBeVisible()
  await expect(preview.getByRole("img", {name: `${launchName} token`})).toBeVisible()

  const treasuryForm = page.locator("#launch-treasury-details")
  await treasuryForm.getByLabel("Immutable treasury recipient", {exact: true}).fill(treasury)

  const transactions = page.locator("#launch-transactions")
  await expect(transactions).toContainText("Ready")
  await expect(transactions.locator("[data-launch-wallet-send]")).toHaveCount(0)

  await page.reload()
  await expect(page.locator("#launch-token-details-name")).toHaveValue(launchName)
  await expect(page.locator("#launch-token-details-symbol")).toHaveValue("BROWSE")
  await expect(page.locator("#launch-token-details-description")).toHaveValue(
    "A persisted browser launch with one public identity.",
  )
  await expect(page.locator("#launch-treasury-details-treasury")).toHaveValue(treasury)
  await expect(page.getByRole("complementary", {name: "Live launch preview"})).toContainText(
    launchName,
  )
  assertCleanBrowser()
})

test("Create stays simple and unclipped from mobile through desktop", async ({page}) => {
  const assertCleanBrowser = cleanBrowser(page)
  const auth = await installAuthenticatedPrivy(page, "other-account")
  await auth.establishLocalSession()

  for (const viewport of [
    {width: 390, height: 844},
    {width: 1440, height: 900},
  ]) {
    await page.setViewportSize(viewport)
    await page.goto("/create")

    const layout = await page.locator("#autolaunch-create").evaluate(node => ({
      pageWidth: document.documentElement.clientWidth,
      scrollWidth: document.documentElement.scrollWidth,
      createRight: node.getBoundingClientRect().right,
      formVisible: Boolean(node.querySelector("#launch-token-details")),
      previewVisible: Boolean(node.querySelector('[aria-label="Live launch preview"]')),
    }))

    expect(layout.scrollWidth).toBeLessThanOrEqual(layout.pageWidth)
    expect(layout.createRight).toBeLessThanOrEqual(layout.pageWidth + 1)
    expect(layout.formVisible).toBe(true)
    expect(layout.previewVisible).toBe(true)
  }

  assertCleanBrowser()
})
