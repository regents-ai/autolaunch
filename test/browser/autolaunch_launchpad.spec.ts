import {expect, test, type Page} from "@playwright/test"

function cleanBrowser(page: Page) {
  const errors: string[] = []
  page.on("pageerror", error => errors.push(error.message))
  return () => expect(errors).toEqual([])
}

test("launchpad collection and detail routes render on dest paths", async ({page}) => {
  const assertCleanBrowser = cleanBrowser(page)

  await page.goto("/auctions")
  await expect(page.locator("#autolaunch-auctions")).toContainText("Auctions")

  await page.goto("/tokens")
  await expect(page.locator("#autolaunch-tokens")).toContainText("Tokens")

  await page.goto("/launches")
  await expect(page.locator("#autolaunch-launches")).toContainText("Launches")

  await page.goto("/subjects")
  await expect(page.locator("#autolaunch-subjects")).toBeVisible()

  await page.goto("/auctions/auction-42")
  await expect(page.locator("#autolaunch-auction-detail")).toContainText("Auction not found")

  await page.goto("/tokens/token-42")
  await expect(page.locator("#autolaunch-token-detail")).toContainText("Token not found")

  await page.goto("/launches/launch-42")
  await expect(page.locator("#autolaunch-launch-detail")).toContainText("Launch not found")

  await page.goto("/subjects/subject-42")
  await expect(page.locator("#autolaunch-subject-detail")).toContainText("Subject not found")

  await page.goto("/subjects/subject:browser:wallet")
  await expect(page.locator("#autolaunch-subject-detail")).toContainText("subject:browser:wallet")

  assertCleanBrowser()
})
