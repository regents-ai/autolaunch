import {expect, test} from "./support/test"
import {ready} from "./support/person"

// The home page's product cards and the list's choices, as a visitor meets them.
// The walk's site has covered calls and Exposure switched off, so the two launch
// cards are the ones shown; the LiveView tests cover the other two and their lists.

const card = "#home-product-revstake"
const title = "#home-product-revstake-title"
const details = "#home-product-revstake-more"

test("a card opens to its details and closes again, at every width", async ({page, isMobile}) => {
  for (const width of isMobile ? [390, 320] : [1280]) {
    await page.setViewportSize({width, height: 844})
    await page.goto("/")
    await ready(page)
    expect(await page.evaluate(() => document.documentElement.scrollWidth - innerWidth)).toBe(0)
    await expect(page.locator(details)).toBeHidden()

    if (isMobile) await page.locator(title).tap()
    else await page.locator(card).hover()
    await expect(page.locator(title)).toHaveAttribute("aria-expanded", "true")
    await expect(page.locator(details)).toBeVisible()
    await expect(page.locator(details)).toContainText("Holders stake it")
    expect(await page.evaluate(() => document.documentElement.scrollWidth - innerWidth)).toBe(0)

    if (isMobile) await page.locator(title).tap()
    else await page.mouse.move(2, 840)
    await expect(page.locator(title)).toHaveAttribute("aria-expanded", "false")
    await expect(page.locator(details)).toBeHidden()
    // Once every move has finished, nothing is left written on the card's parts.
    await expect.poll(() => page.locator(`${details}, ${details} [data-product-row], ${details} [data-product-fill]`)
      .evaluateAll(els => els.filter(el => el.getAttribute("style")).length)).toBe(0)
  }
})

test("from the keyboard a card opens at once and Escape closes it", async ({page, isMobile}) => {
  test.skip(isMobile, "keyboard on a desktop")
  await page.goto("/")
  await ready(page)
  await page.locator(title).focus()
  await page.keyboard.press("Shift+Tab")
  await page.keyboard.press("Tab")
  await expect(page.locator(title)).toHaveAttribute("aria-expanded", "true")
  await expect(page.locator(details)).toBeVisible()
  expect(await page.locator(card).evaluate(el => el.getAnimations({subtree: true}).length)).toBe(0)
  await page.keyboard.press("Escape")
  await expect(page.locator(title)).toHaveAttribute("aria-expanded", "false")
  await expect(page.locator(title)).toBeFocused()
})

test("with reduced motion a card opens with nothing moving", async ({page, isMobile}) => {
  await page.emulateMedia({reducedMotion: "reduce"})
  await page.goto("/")
  await ready(page)
  if (isMobile) await page.locator(title).tap()
  else await page.locator(card).hover()
  await expect(page.locator(details)).toBeVisible()
  expect(await page.locator(card).evaluate(el => el.getAnimations({subtree: true}).length)).toBe(0)
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
