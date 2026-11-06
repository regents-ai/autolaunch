import type {Locator, Page} from "@playwright/test"
import {expect, test} from "./support/test"
import {ready, signedIn, watch} from "./support/person"

// Pairing an agent, the way a person does it: Pair New Agent on the Agents page
// opens the pairing window, where they choose their agent from the dropdown and
// copy its message.
test.use(signedIn)

const pairingWindow = (page: Page) => page.locator("#shell-pairing")
const box = (page: Page) => page.locator("form#shell-pairing-box")
const message = (page: Page) => page.locator("#shell-pairing-box pre")
const dropdown = (page: Page) => box(page).locator("details")

const pairButton = (page: Page) =>
  page.locator("#account-agents").getByRole("button", {name: "Pair New Agent"})

// Opened, and done moving in, so what is measured is where it rests.
async function openWindow(page: Page) {
  await pairButton(page).click()
  await expect(pairingWindow(page)).toBeVisible()
  await expect.poll(() => pairingWindow(page).evaluate(element => element.getAnimations({subtree: true}).length)).toBe(0)
}

// A person opens the dropdown, unless it is already open, and presses the agent's
// name; the radio's label carries it.
async function choose(page: Page, agent: string) {
  const radio = box(page).getByRole("radio", {name: agent, exact: true})
  if (!(await dropdown(page).evaluate(details => (details as HTMLDetailsElement).open))) {
    await dropdown(page).locator("summary").click()
  }
  await radio.locator("xpath=ancestor::label").click()
  await expect(radio).toBeChecked()
  await expect(dropdown(page).locator("summary")).toContainText(agent)
}

// In the browser's own layout steps, 1/64 px: once the window scrolls a fraction of a
// pixel, the measured height carries rounding noise far smaller than one step.
const height = (locator: Locator) =>
  locator.evaluate(element => Math.round(element.getBoundingClientRect().height * 64) / 64)

// Keyfleet, 27 Oct 2026: pressed a second time, Pair New Agent did nothing a person
// could see. Every press opens the window.
test("Pair New Agent on the Agents page opens the pairing window, every press", async ({page}) => {
  const problems = watch(page)
  await page.goto("/account/agents")
  await ready(page)
  await openWindow(page)
  await pairingWindow(page).getByRole("button", {name: "Close"}).click()
  await expect(pairingWindow(page)).toBeHidden()
  await expect(pairButton(page)).toBeFocused()

  // With the agents listed, the first Escape closes the list and the next the window.
  await openWindow(page)
  await page.keyboard.press("Escape")
  await expect(dropdown(page)).not.toHaveAttribute("open", "")
  await expect(pairingWindow(page)).toBeVisible()
  await page.keyboard.press("Escape")
  await expect(pairingWindow(page)).toBeHidden()
  await problems.expect()
})

// The window opens on the list of agents; a choice closes the list, and the
// keyboard goes back to the dropdown, so arrowing to another agent chooses it.
test("the window opens on the agents, and a choice closes the list", async ({page}) => {
  const problems = watch(page)
  await page.goto("/account/agents")
  await ready(page)
  await openWindow(page)
  await expect(dropdown(page)).toHaveAttribute("open", "")
  await expect(box(page).getByRole("radio", {name: "Dots", exact: true})).toBeVisible()

  await choose(page, "Dots")
  await expect(dropdown(page)).not.toHaveAttribute("open", "")
  await expect(message(page)).toContainText(/Pairing code:\s*\S{12,}/)
  await expect(box(page)).toContainText("Paste it to Dots")

  // By keyboard: the summary opens the list, an arrow chooses the next agent, and
  // focus comes back to the summary once the list closes.
  await dropdown(page).locator("summary").focus()
  await page.keyboard.press("Enter")
  await expect(dropdown(page)).toHaveAttribute("open", "")
  await box(page).getByRole("radio", {name: "Dots", exact: true}).focus()
  await page.keyboard.press("ArrowRight")
  await expect(dropdown(page)).not.toHaveAttribute("open", "")
  await expect(dropdown(page).locator("summary")).toBeFocused()
  await expect(dropdown(page).locator("summary")).not.toContainText("Dots")
  await problems.expect()
})

// Choosing never changes the window's height (founder, 2026-10-07).
test("the window keeps one height whatever is chosen", async ({page}) => {
  const problems = watch(page)
  await page.goto("/account/agents")
  await ready(page)
  await openWindow(page)
  const before = await height(box(page))
  await choose(page, "Dots")
  await expect(message(page)).toContainText(/Pairing code/)
  expect(await height(box(page))).toBe(before)
  await choose(page, "Any agent")
  await expect(message(page)).toContainText(/Pairing code/)
  expect(await height(box(page))).toBe(before)
  await problems.expect()
})

test("each agent keeps its own code until a new one is asked for", async ({page}) => {
  const problems = watch(page)
  await page.goto("/account/agents")
  await ready(page)
  await openWindow(page)
  await expect(message(page)).toHaveCount(0)

  await choose(page, "Dots")
  // The agent learns it pairs with the person's Regents Labs account, and on which site.
  await expect(message(page)).toContainText(/^Pair with my Regents Labs account on 127\.0\.0\.1\n/)
  await expect(message(page)).toContainText(/Pairing code:\s*\S{12,}/)
  const first = await message(page).innerText()

  await choose(page, "Hermes")
  await expect(message(page)).not.toHaveText(first)
  await expect(message(page)).toContainText(/Pairing code:\s*\S{12,}/)

  // Coming back shows the same code, so a message already pasted still works.
  await choose(page, "Dots")
  await expect(message(page)).toHaveText(first)

  await box(page).getByRole("button", {name: "Make a new code"}).click()
  await expect(message(page)).not.toHaveText(first)
  await expect(message(page)).toContainText(/Pairing code:\s*\S{12,}/)
  await problems.expect()
})

// A reconnecting page sends the pairing form back with no agent picked, and a
// submit can come before a choice. Neither may crash the pairing box (Sentinel,
// 23 Oct 2026, from Patchbay's error mail).
test("the pairing form with nothing chosen leaves the box as it is", async ({page}) => {
  const problems = watch(page)
  const crashes: string[] = []
  page.on("websocket", socket =>
    socket.on("framereceived", frame => {
      if (String(frame.payload).includes('"phx_error"')) crashes.push(String(frame.payload).slice(0, 120))
    }),
  )
  await page.goto("/account/agents")
  await ready(page)
  await openWindow(page)
  await expect(box(page).getByRole("radio", {checked: true})).toHaveCount(0)

  await box(page).getByRole("radio").first().dispatchEvent("input")
  await box(page).evaluate(element => (element as HTMLFormElement).requestSubmit())

  // The box still answers: choosing an agent shows its code.
  await choose(page, "Dots")
  await expect(message(page)).toContainText(/Pairing code:\s*\S{12,}/)
  expect(crashes).toEqual([])
  await problems.expect()
})
