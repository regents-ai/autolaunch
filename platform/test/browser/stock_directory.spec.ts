import {expect, test} from "./support/test"
import {ready} from "./support/person"

test("stock filters keep their network and availability across navigation", async ({page}) => {
  await page.goto("/stocks")
  await ready(page)

  const directory = page.locator("#stock-directory-filters")
  await directory.getByRole("searchbox", {name: "Search stocks"}).fill("apple")
  await directory.getByLabel("Network").selectOption("base")
  await directory.getByLabel("Availability").selectOption("available")
  await directory.getByRole("button", {name: "Apply"}).press("Enter")

  await expect(page).toHaveURL(/q=apple/)
  await expect(page.locator("#stock-directory-count")).toHaveText("1 stock")
  const result = page.getByRole("link", {name: "AAPLc on Base: stock details"})
  await expect(result).toBeVisible()
  await expect(page.getByRole("link", {name: "AAPL on Robinhood: stock details"})).toHaveCount(0)
  expect(await page.evaluate(() => document.documentElement.scrollWidth - innerWidth)).toBe(0)

  await page.reload()
  await ready(page)
  await expect(directory.getByLabel("Network")).toHaveValue("base")
  await result.click()
  await expect(page).toHaveURL(/\/stocks\/AAPLc\?/)
  await expect(page.getByRole("heading", {level: 1})).toContainText("AAPLc")

  await page.getByRole("link", {name: "← Onchain Stocks"}).click()
  await ready(page)
  await expect(page.locator("#stock-directory-count")).toHaveText("1 stock")
  await directory.getByRole("link", {name: "Reset"}).click()
  await expect(page).toHaveURL(/\/stocks$/)
  await expect(page.getByRole("link", {name: "AAPL on Robinhood: stock details"})).toBeVisible()
})
