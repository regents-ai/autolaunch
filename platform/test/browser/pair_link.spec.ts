import type {Page} from "@playwright/test"
import {expect, test} from "./support/test"
import {ready, signedIn, watch} from "./support/person"

// A "Pair New Agent" link (/pair?to=<page>): the person pairs their agent there,
// and the message they paste sends the agent to that page once it is paired. A
// link to anywhere but a page on this site opens plain pairing.

const message = (page: Page) => page.locator("#pair-pairing-box pre")

// The page opens on the list of agents, as the pairing window does. A choice
// closes the list, so the radio is looked for hidden too when its check is read.
async function choose(page: Page, agent: string) {
  const radio = page
    .locator("#pair-pairing-box")
    .getByRole("radio", {name: agent, exact: true, includeHidden: true})
  await expect(page.locator("#pair-pairing-box details")).toHaveAttribute("open", "")
  await radio.locator("xpath=ancestor::label").click()
  await expect(radio).toBeChecked()
}

test.describe("signed in", () => {
  test.use(signedIn)

  test("the message sends the agent to the link's page once paired", async ({page}) => {
    const problems = watch(page)
    await page.goto("/pair?to=%2Fauctions")
    await ready(page)
    const start = page.locator("#pair-start a")
    await expect(start).toHaveText(/^https?:\/\/[^/]+\/auctions$/)

    await choose(page, "Dots")
    await expect(message(page)).toContainText(/Pairing code:\s*\S{12,}/)
    const text = (await message(page).innerText()).trimEnd()
    expect(text.endsWith(`\nOnce paired, start at ${await start.innerText()}`)).toBe(true)
    await problems.expect()
  })

  // The pairing page holds the same box as the window: the picture in a low band,
  // and nothing under it moves when an agent is chosen.
  test("the picture sits in a low band, and choosing moves nothing under it", async ({page}) => {
    const problems = watch(page)
    await page.goto("/pair?to=%2Fauctions")
    await ready(page)
    const stage = page.locator("#pair-pairing-box .rg-account__stage")
    const steps = page.locator("#pair-pairing-box ol")
    const before = await steps.evaluate(list => list.getBoundingClientRect().top)

    await choose(page, "Dots")
    await expect(message(page)).toContainText(/Pairing code/)
    const band = await stage.evaluate(box => box.getBoundingClientRect())
    expect(band.height).toBeLessThanOrEqual((band.width * 9) / 16 / 2)
    expect(await steps.evaluate(list => list.getBoundingClientRect().top)).toBe(before)
    await problems.expect()
  })

  test("a link to another site opens plain pairing", async ({page}) => {
    await page.goto("/pair?to=%2F%2Fexample.com")
    await ready(page)
    await expect(page.locator("#pair-start")).toHaveCount(0)

    await choose(page, "Dots")
    await expect(message(page)).toContainText(/Pairing code:\s*\S{12,}/)
    await expect(message(page)).not.toContainText("Once paired")
  })
})

test("a visitor signs in first, and still sees where their agent will start", async ({page}) => {
  const problems = watch(page)
  await page.goto("/pair?to=%2Fauctions")
  await expect(page.locator("#pair-signed-out").getByRole("button", {name: "Sign in"})).toBeVisible()
  await expect(page.locator("#pair-start a")).toHaveText(/\/auctions$/)
  await expect(message(page)).toHaveCount(0)
  await problems.expect()
})
