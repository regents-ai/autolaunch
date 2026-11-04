import {expect, test} from "./support/test"
import {ready} from "./support/person"

// The home page's product cards and the list's choices, as a visitor meets them.
// The walk's site has covered calls switched off, so the two launch cards are the
// ones shown; the LiveView tests cover the other one and its list.

test("a card fits at every width and says launches open soon", async ({page, isMobile}) => {
  for (const width of isMobile ? [390, 320] : [1280]) {
    await page.setViewportSize({width, height: 844})
    await page.goto("/")
    await ready(page)
    expect(await page.evaluate(() => document.documentElement.scrollWidth - innerWidth)).toBe(0)
    await expect(page.locator("#home-product-revstake h2")).toHaveText("Revstake")
    await expect(page.locator("#home-product-revstake")).toContainText("Opens soon")
  }
})

test("Tokens shows its types under the list's choices, and Auctions hides them", async ({page}) => {
  await page.goto("/")
  await ready(page)
  await expect(page.locator("#home-kinds")).toHaveCount(0)
  await page.locator("#home-lists a", {hasText: "Tokens"}).click()
  await expect(page).toHaveURL(/\/\?view=tokens$/)
  await expect(page.locator("#home-kinds a[aria-current=page]")).toHaveText("All")
  await page.locator("#home-kinds a", {hasText: "Memestock"}).click()
  await expect(page).toHaveURL(/kind=memestock/)
  await expect(page.locator("#home-kinds a[aria-current=page]")).toHaveText("Memestock")
  await page.locator("#home-lists a", {hasText: "Auctions"}).click()
  await expect(page.locator("#home-kinds")).toHaveCount(0)
  expect(await page.evaluate(() => document.documentElement.scrollWidth - innerWidth)).toBe(0)
})
