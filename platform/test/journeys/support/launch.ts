import {readFileSync} from "node:fs"
import type {Page} from "@playwright/test"
import {Agent} from "./agent"
import {expect, ready, type Sent} from "./person"

export const AAPLC = "0xb200000000000000000000c2e324d24d7eecd1fb"
const picture = readFileSync("test/support/fixtures/launch-draft.png").toString("base64")

/** The whole Memestock draft an agent fills in, named after `tag`. */
export const draftFor = (tag: string) => ({
  name: `Agent Apple ${tag}`,
  symbol: `AA${tag}`,
  description: "A memestock its agent filled in and its person launched.",
  website: "https://example.com",
  chain: "base",
  stock_address: AAPLC,
  image: {content_type: "image/png", data: picture},
})

/**
 * The paired `agent` fills in the whole draft, and the signed-in person reviews
 * it on /create and presses Create the launch. Answers the launch's draft, its
 * transaction and its auction page.
 */
export async function launch(page: Page, sent: Sent[], agent: Agent, tag: string) {
  const draft = draftFor(tag)
  const saved = agent.autolaunch(["drafts", "memestock", "save"], draft)
  expect(saved.status, saved.stdout).toBe(0)
  await page.goto("/create")
  await ready(page)
  await expect(page.locator("#agent-set-fields")).toContainText(draft.name)
  await page.getByRole("button", {name: "Review launch"}).click()
  const before = sent.length
  await page.getByRole("button", {name: /Create the launch/i}).click()
  await expect.poll(() => sent.length).toBe(before + 1)
  const launched = page.locator(".launch-placed")
  await expect(launched).toContainText(`Your token ${draft.symbol} is launched.`, {timeout: 60_000})
  const open = launched.getByRole("link", {name: "Open the auction"})
  await expect(open).toBeVisible({timeout: 60_000})
  return {draft, hash: sent[before].hash, auction: (await open.getAttribute("href"))!}
}
