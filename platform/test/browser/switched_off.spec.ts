import {expect, test} from "./support/test"
import {signedIn} from "./support/person"

// The walk's server runs with covered calls switched off, as main does. Off, the
// site is what it was before them: no page, script, stylesheet or script chunk a
// page loads names them, and the page registers none of their tools. The pages
// include the stock page, which links to them while on; every page carries the
// layout that hands over their tools while on. The portfolio, which reads the
// chain, and the documents are held by ExUnit (AutolaunchWeb.CoveredCallsOffTest).
test.use(signedIn)

const named = /covered[-_ ]?calls?|coveredcall/i

for (const path of ["/", "/auctions", "/stock-listing/AMZNc", "/docs"]) {
  test(`switched off, ${path} and everything it loads never name covered calls`, async ({page, baseURL}) => {
    const site = new URL(baseURL!).host
    const loaded: Promise<{url: string; body: string}>[] = []
    page.on("response", response => {
      const url = new URL(response.url())
      if (url.host === site && ["document", "script", "stylesheet"].includes(response.request().resourceType()))
        loaded.push(response.text().then(body => ({url: url.pathname, body})))
    })

    await page.goto(path, {waitUntil: "networkidle"})
    const bodies = await Promise.all(loaded)

    expect(bodies.some(({url}) => url.startsWith("/assets/js/app")), "the page's own script was read").toBe(true)
    expect(bodies.filter(({body}) => named.test(body)).map(({url}) => url)).toEqual([])
    expect(await page.locator("#agent-feature-tools").count()).toBe(0)
  })
}
