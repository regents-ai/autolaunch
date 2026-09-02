import {expect, test} from "@playwright/test"

type Theme = {
  readonly scheme: "dark" | "light"
  readonly background: string
  readonly text: string
}

// The palette's Background and Text, as the browser reports them.
const DARK: Theme = {scheme: "dark", background: "rgb(14, 14, 14)", text: "rgb(229, 227, 210)"}
const LIGHT: Theme = {scheme: "light", background: "rgb(229, 227, 210)", text: "rgb(22, 22, 22)"}

for (const theme of [DARK, LIGHT]) {
  test.describe(`a reader who prefers ${theme.scheme}`, () => {
    test.use({colorScheme: theme.scheme})

    test("gets the Autolaunch palette on that theme's ground", async ({page}) => {
      await page.goto("/")

      await expect(page.locator("html")).toHaveAttribute("data-brand", "autolaunch")
      await expect(page.locator("html")).toHaveAttribute("data-theme", theme.scheme)
      await expect(page.locator("body")).toHaveCSS("background-color", theme.background)
      await expect(page.locator("body")).toHaveCSS("color", theme.text)
    })
  })
}

test.describe("a reader who changes the system theme", () => {
  test.use({colorScheme: LIGHT.scheme})

  test("sees the open page follow", async ({page}) => {
    await page.goto("/")

    await expect(page.locator("html")).toHaveAttribute("data-theme", LIGHT.scheme)
    await expect(page.locator("body")).toHaveCSS("background-color", LIGHT.background)

    await page.emulateMedia({colorScheme: DARK.scheme})

    await expect(page.locator("html")).toHaveAttribute("data-theme", DARK.scheme)
    await expect(page.locator("body")).toHaveCSS("background-color", DARK.background)
  })
})
