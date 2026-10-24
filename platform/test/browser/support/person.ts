import {type Page} from "@playwright/test"
import {expect} from "./test"

// The walk's person, signed in by sign_in.setup.ts before the checks start.
export const signedIn = {storageState: "test/browser/.auth/person.json"}

// The page's buttons answer once its script has connected the page, as they do
// for a person by the time they reach for one.
export async function ready(page: Page) {
  await expect(page.locator("[data-phx-main].phx-connected")).toBeAttached()
}
