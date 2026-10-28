import {expect, test} from "./support/test"
import {ready, signedIn} from "./support/person"

// Layout rules that once broke, as in the template's walk.
test.use(signedIn)

// Found on Patchbay on 21 Oct, and on Autolaunch on 23 Oct, where the panel did not
// line up with the top bar in every browser: the header runs the whole width, over
// the panel, and the panel opens under the header's bottom line.
test("the side panel opens under the header", async ({page, isMobile}) => {
  for (const width of isMobile ? [390] : [1280, 2000]) {
    await page.setViewportSize({width, height: 900})
    await page.goto("/auctions")
    await ready(page)
    const aside = page.locator("#shell-aside")
    if (!(await aside.isVisible())) await page.locator("[data-aside-toggle]:visible").last().click()
    await expect(aside).toBeVisible()
    // Measured once the panel has finished sliding in.
    const sliding = () =>
      page.evaluate(() => document.getAnimations().filter(a => a instanceof CSSTransition).length)
    await expect.poll(sliding).toBe(0)

    const header = (await page.locator("#home-top").boundingBox())!
    const panel = (await aside.boundingBox())!
    // Below the header, never beside it; on a phone it may reach past the page's margins.
    expect(panel.y).toBeCloseTo(header.y + header.height, 0)
    expect(panel.x).toBeLessThan(header.x + header.width)
    expect(panel.x + panel.width).toBeGreaterThan(header.x)
  }
})

// The template's check (ash-template, layers of 27 Oct): on a phone the open menu and
// side panel cover the bottom bar, so it is never left undimmed and pressable beside
// them. Autolaunch's bottom bar is the market ticker, at the card layer. It shows only
// while there are bids or trades from the last hour, and the walk's database has none,
// so the bar is added here as the page draws it. Before the layers, the side panel
// stopped above it.
test("on a phone, the open menu and side panel cover the bottom bar", async ({page, isMobile}) => {
  test.skip(!isMobile, "the bottom bar meets the panels only on a phone")
  await page.goto("/auctions")
  await ready(page)
  await page.evaluate(() => {
    const bar = document.createElement("div")
    bar.className = "market-ticker"
    bar.innerHTML = `<button type="button" class="market-ticker__pause">Pause</button>`
    document.body.append(bar)
  })
  const bar = (await page.locator(".market-ticker").boundingBox())!
  const onTop = (x: number, y: number, selector: string) =>
    page.evaluate(([x, y, selector]) => document.elementFromPoint(x, y)?.closest(selector) != null, [x, y, selector] as const)
  const sliding = () =>
    page.evaluate(() => document.getAnimations().filter(a => a instanceof CSSTransition).length)
  const middle = bar.y + bar.height / 2

  // The menu slides in from the left edge; it is measured once it is there.
  await page.locator("#mobile-menu-button").click()
  await expect(page.locator("#shell-drawer")).toBeVisible()
  await expect.poll(sliding).toBe(0)
  const drawer = (await page.locator("#shell-drawer").boundingBox())!
  expect(await onTop(drawer.x + 8, middle, "#shell-drawer")).toBe(true)
  // Past the menu's edge, the shade lies over the bottom bar.
  expect(await onTop(drawer.x + drawer.width + 8, middle, "[data-shell-menu-scrim]")).toBe(true)
  await page.locator("[data-shell-menu-close]").click()
  await expect(page.locator("#shell-drawer")).toBeHidden()

  await page.locator("[data-aside-toggle]:visible").last().click()
  await expect(page.locator("#shell-aside")).toBeVisible()
  await expect.poll(sliding).toBe(0)
  expect(await onTop(bar.x + bar.width / 2, middle, "#shell-aside")).toBe(true)
})

// Found on Autolaunch on 19 Oct: while a sign-in can't be read the top bar shows
// nothing to the right of Regents Products, and that button's hover name, centred
// under it, reached 3px past a 390px phone's screen, so the page scrolled sideways.
test("the Regents Products name stays on screen with nothing to its right", async ({page, isMobile}) => {
  test.skip(!isMobile, "a phone's top bar")
  await page.goto("/how-it-works")
  await ready(page)
  // What the top bar holds to the button's right while a sign-in can't be read: nothing.
  await page.evaluate(() => {
    const button = document.getElementById("shell-apps-button")!
    for (let next = button.nextElementSibling; next; next = next.nextElementSibling)
      if (!next.matches("#shell-apps")) (next as HTMLElement).style.display = "none"
  })
  const sideways = () =>
    page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth)
  expect(await sideways()).toBeLessThanOrEqual(0)
})

// Found on Autolaunch on 28 Oct: on a lab site the lab line sat above the header in
// the page, so the side panel and the phone menu opened behind the header and hid
// their close buttons. The walk's site is not a lab, so the line is added here as
// the page draws it.
test("on a lab site the header, side panel and menu open under the lab line", async ({page, isMobile}) => {
  for (const width of isMobile ? [320, 390] : [1280]) {
    await page.setViewportSize({width, height: 900})
    await page.goto("/auctions")
    await ready(page)
    await page.evaluate(() => {
      const line = document.createElement("p")
      line.className = "autolaunch-lab-warning"
      line.textContent = "Local Base fork · test assets · no mainnet value · sign in with Privy"
      document.body.prepend(line)
      // Room to scroll on every width, whatever the walk's database holds.
      const room = document.createElement("div")
      room.style.blockSize = "200vh"
      document.querySelector("#shell-content")!.append(room)
    })
    await page.evaluate(() => window.scrollTo(0, 400))
    expect(await page.evaluate(() => window.scrollY)).toBe(400)
    const sliding = () =>
      page.evaluate(() => document.getAnimations().filter(a => a instanceof CSSTransition).length)
    const lab = page.locator(".autolaunch-lab-warning")
    const box = async (selector: string) => (await page.locator(selector).boundingBox())!

    // The whole line shows at the top of the screen, and the header sits right under it.
    expect(await lab.evaluate(line => line.scrollHeight <= line.clientHeight)).toBe(true)
    expect((await box(".autolaunch-lab-warning")).y).toBe(0)
    const labBottom = (await box(".autolaunch-lab-warning")).height
    expect((await box("#home-top")).y).toBeCloseTo(labBottom, 0)
    const headerBottom = (await box("#home-top")).y + (await box("#home-top")).height

    const aside = page.locator("#shell-aside")
    if (!(await aside.isVisible())) await page.locator("[data-aside-toggle]:visible").last().click()
    await expect(aside).toBeVisible()
    await expect.poll(sliding).toBe(0)
    expect((await box("#shell-aside")).y).toBeCloseTo(headerBottom, 0)
    await page.getByRole("button", {name: "Close the side panel"}).click()
    await expect(aside).toBeHidden()

    if (isMobile) {
      await page.locator("#mobile-menu-button").click()
      await expect(page.locator("#shell-drawer")).toBeVisible()
      await expect.poll(sliding).toBe(0)
      expect((await box("#shell-drawer")).y).toBeCloseTo(headerBottom, 0)
      await page.locator("[data-shell-menu-close]").click()
      await expect(page.locator("#shell-drawer")).toBeHidden()
    }
  }
})
