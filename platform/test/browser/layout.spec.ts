import {expect, test} from "./support/test"
import {ready, signedIn} from "./support/person"

// Layout rules that once broke, as in the template's walk.
test.use(signedIn)

// The template's check (ash-template, layers of 27 Oct): on a phone the open menu covers
// the bottom bar, so it is never left undimmed and pressable beside it. Autolaunch's
// bottom bar is the market ticker, at the card layer. It shows only while there are
// bids or trades from the last hour, and the walk's database has none, so the bar is
// added here as the page draws it. While the menu is open, the page and the bar are
// out of reach (`inert`), and both come back when it closes.
test("on a phone, the open menu covers the bottom bar and makes it and the page inert", async ({page, isMobile}) => {
  test.skip(!isMobile, "the bottom bar meets the menu only on a phone")
  for (const width of [390, 320]) {
    await page.setViewportSize({width, height: 844})
    await page.goto("/auctions")
    await ready(page)
    await page.evaluate(() => {
      const bar = document.createElement("div")
      bar.className = "market-ticker"
      bar.setAttribute("data-shell-behind-menu", "")
      bar.innerHTML = `<button type="button" class="market-ticker__pause">Pause</button>`
      document.body.append(bar)
    })
    const bar = (await page.locator(".market-ticker").boundingBox())!
    const onTop = (x: number, y: number, selector: string) =>
      page.evaluate(([x, y, selector]) => document.elementFromPoint(x, y)?.closest(selector) != null, [x, y, selector] as const)
    const sliding = () =>
      page.evaluate(() => document.getAnimations().filter(a => a instanceof CSSTransition).length)
    const middle = bar.y + bar.height / 2
    const inert = (selector: string) => page.locator(selector).evaluate(element => (element as HTMLElement).inert)

    // The menu slides in from the left edge; it is measured once it is there.
    await page.locator("#mobile-menu-button").click()
    await expect(page.locator("#shell-drawer")).toBeVisible()
    await expect.poll(sliding).toBe(0)
    const drawer = (await page.locator("#shell-drawer").boundingBox())!
    expect(await onTop(drawer.x + 8, middle, "#shell-drawer")).toBe(true)
    // Past the menu's edge, the shade lies over the bottom bar.
    expect(await onTop(drawer.x + drawer.width + 8, middle, "[data-shell-menu-scrim]")).toBe(true)
    // The page and the bottom bar cannot be reached until the menu closes.
    expect(await inert("#shell-content")).toBe(true)
    expect(await inert("#shell-footer")).toBe(true)
    expect(await inert(".market-ticker")).toBe(true)
    await page.locator("[data-shell-menu-close]").click()
    await expect(page.locator("#shell-drawer")).toBeHidden()
    expect(await inert("#shell-content")).toBe(false)
    expect(await inert("#shell-footer")).toBe(false)
    expect(await inert(".market-ticker")).toBe(false)
  }
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
// the page, so the phone menu opened behind the header and hid its close button. The walk's site is not a lab, so the line is added here as
// the page draws it.
test("on a lab site the header, account menu and phone menu open under the lab line", async ({page, isMobile}) => {
  for (const width of isMobile ? [320, 390] : [1280]) {
    await page.setViewportSize({width, height: 900})
    await page.goto("/auctions")
    await ready(page)
    await page.evaluate(() => {
      const line = document.createElement("p")
      line.className = "autolaunch-lab-warning"
      line.textContent = "Local Base fork · test assets · no mainnet value · sign in with Privy"
      document.body.prepend(line)
      // Room to scroll on every width, whatever the walk's database holds. It goes
      // after the page, where LiveView's updates never take it away.
      const room = document.createElement("div")
      room.style.blockSize = "200vh"
      document.body.append(room)
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

    const menu = page.locator("#account-menu")
    await page.locator("#account-chip").click()
    await expect(menu).toBeVisible()
    await expect.poll(sliding).toBe(0)
    // The account menu hangs from the account's button, under the header's bottom line.
    expect((await box("#account-menu")).y).toBeGreaterThanOrEqual(headerBottom)
    await page.keyboard.press("Escape")
    await expect(menu).toBeHidden()
    // Opening and closing move focus into the header; the page stays where it was.
    expect(await page.evaluate(() => window.scrollY)).toBe(400)

    if (isMobile) {
      await page.locator("#mobile-menu-button").click()
      await expect(page.locator("#shell-drawer")).toBeVisible()
      await expect.poll(sliding).toBe(0)
      expect((await box("#shell-drawer")).y).toBeCloseTo(headerBottom, 0)
      await page.locator("[data-shell-menu-close]").click()
      await expect(page.locator("#shell-drawer")).toBeHidden()
      expect(await page.evaluate(() => window.scrollY)).toBe(400)
    }

    // A jump to a part of the page, or Skip to content, stops right under the header.
    // Within a pixel: the header's height can land on a half pixel.
    for (const target of ["auctions-market", "shell-content"]) {
      await page.evaluate(() => window.scrollTo(0, 400))
      await page.evaluate(target => { location.hash = target }, target)
      await expect.poll(async () => Math.abs((await box(`#${target}`)).y - headerBottom)).toBeLessThanOrEqual(1)
    }

    // A window drawn over the page scrolls on its own: focusing a field already in
    // view leaves it where it is. Added here as the auction details window draws it.
    const scrolled = await page.evaluate(async () => {
      const sheet = document.createElement("div")
      sheet.popover = "manual"
      sheet.className = "auction-details-window"
      sheet.style.cssText = "block-size: 300px; overflow: auto"
      sheet.innerHTML = `<div style="block-size: 600px"></div><input id="lab-field"><div style="block-size: 600px"></div>`
      document.querySelector("#shell-content")!.append(sheet)
      sheet.showPopover()
      // The field sits 40px from the window's top, in full view.
      sheet.scrollTop = 560
      document.getElementById("lab-field")!.focus()
      await new Promise(requestAnimationFrame)
      const top = sheet.scrollTop
      sheet.remove()
      return top
    })
    expect(scrolled).toBe(560)
  }
})
