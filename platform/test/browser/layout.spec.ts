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
