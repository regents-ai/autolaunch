import {expect, test, type Page} from "@playwright/test"

import {installAuthenticatedPrivy} from "./support/authenticated_privy"

const DARK = "dark"
const LIGHT = "light"

function cleanBrowser(page: Page) {
  const errors: string[] = []
  page.on("pageerror", error => errors.push(error.message))
  return () => expect(errors).toEqual([])
}

test("the rail links are present and open their pages", async ({page}) => {
  const assertCleanBrowser = cleanBrowser(page)
  await page.goto("/")

  const rail = page.getByRole("navigation", {name: "Site"})
  await expect(rail.getByRole("link", {name: "Home"})).toBeVisible()
  await expect(rail.getByRole("link", {name: "Create"})).toBeVisible()
  await expect(rail.getByRole("link", {name: "Auctions"})).toBeVisible()
  await expect(rail.getByRole("link", {name: "Tokens"})).toBeVisible()
  await expect(rail.getByRole("link", {name: "Portfolio"})).toBeVisible()
  await expect(rail.getByRole("link", {name: "REGENT"})).toBeVisible()

  await rail.getByRole("link", {name: "Tokens"}).click()
  await expect(page).toHaveURL("/tokens")
  await expect(rail.getByRole("link", {name: "Tokens"})).toHaveAttribute("aria-current", "page")

  await rail.getByRole("link", {name: "REGENT"}).click()
  await expect(page).toHaveURL("/regent")
  assertCleanBrowser()
})

test("search submits to home with q", async ({page}) => {
  const assertCleanBrowser = cleanBrowser(page)
  await page.goto("/auctions")
  await page.locator("#shell-search-q").fill("research")
  await page.locator("#shell-search-q").press("Enter")
  await expect(page).toHaveURL("/?q=research")
  assertCleanBrowser()
})

test("signed-out account control shows Sign in", async ({page}) => {
  const assertCleanBrowser = cleanBrowser(page)
  await page.goto("/")
  await expect(page.locator("#account-control")).toHaveAttribute("data-account-kind", "sign_in")
  await expect(page.locator("#account-control [data-account-target='sign-in']")).toHaveText(
    "Sign in",
  )
  await expect(page.locator("#account-auth-status")).toBeHidden()
  assertCleanBrowser()
})

test("signed-in account control shows the label and Sign out", async ({page}) => {
  const assertCleanBrowser = cleanBrowser(page)
  const auth = await installAuthenticatedPrivy(page, "valid")
  await auth.establishLocalSession()
  await page.goto("/portfolio")

  await expect(page.locator("#account-control")).toHaveAttribute("data-account-kind", "signed_in")
  await expect(page.locator("#account-control")).toContainText("0x1111…1111")
  await expect(page.locator("#account-control [data-account-target='sign-out']")).toHaveText(
    "Sign out",
  )
  await expect(page.getByRole("link", {name: "Portfolio"}).first()).toBeVisible()
  assertCleanBrowser()
})

for (const scheme of [DARK, LIGHT]) {
  test.describe(`shell in the ${scheme} scheme`, () => {
    test.use({colorScheme: scheme})

    test("renders the rail and top bar", async ({page}) => {
      const assertCleanBrowser = cleanBrowser(page)
      await page.goto("/")
      await expect(page.locator("html")).toHaveAttribute("data-theme", scheme)
      await expect(page.getByRole("navigation", {name: "Site"})).toBeVisible()
      await expect(page.locator("#shell-search-q")).toBeVisible()
      await expect(page.locator("#account-control")).toBeVisible()
      assertCleanBrowser()
    })
  })
}

test("records desktop and phone frames in both schemes", async ({page}) => {
  const frames = [
    {scheme: DARK, width: 1440, height: 900, path: "/tmp/u5-dark-1440.png"},
    {scheme: DARK, width: 390, height: 844, path: "/tmp/u5-dark-390.png"},
    {scheme: LIGHT, width: 1440, height: 900, path: "/tmp/u5-light-1440.png"},
    {scheme: LIGHT, width: 390, height: 844, path: "/tmp/u5-light-390.png"},
  ]

  for (const frame of frames) {
    await page.emulateMedia({colorScheme: frame.scheme})
    await page.setViewportSize({width: frame.width, height: frame.height})
    await page.goto("/")
    await expect(page.locator("html")).toHaveAttribute("data-theme", frame.scheme)
    await page.screenshot({path: frame.path, fullPage: true})
  }
})
