import type {Page} from "@playwright/test"
import {Agent} from "./agent"
import {expect, ready} from "./person"
import {onSite} from "./site"

// What the pairing journeys share: the person's side of the pairing box, and
// unpairing as regents.sh does it.

// Every harness the pair request accepts here, in the pairing box's order; never ChatGPT.
export const offered = [
  "hermes", "grok_bot", "muse", "openclaw", "nemoclaw", "ironclaw", "pi",
  "claude_code", "codex", "cursor", "gemini_cli", "dots", "other",
]

// Unpairs as regents.sh does, through the shared pairing library on the shared database.
export function unpair(person: string, wallet: string) {
  onSite("unpair.exs", {JOURNEY_PERSON: person, JOURNEY_AGENT: wallet})
}

export const codeIn = (message: string) => message.match(/Pairing code: (\S+)/)![1]

// The panel opens from the button beside the account name, or from the name
// itself, which is all a phone's top bar has room for.
export const panelToggle = (page: Page) => page.locator("[data-aside-toggle]:visible").first()

export async function openPanel(page: Page) {
  await panelToggle(page).click()
  await expect(page.locator("#shell-pairing")).toBeVisible()
}

// Picks an agent in the box and waits for its own message, which carries that
// agent's own code, so it differs from the one on screen before the click.
export async function chooseAgent(page: Page, root: string, label: string) {
  const message = page.locator(`${root} pre:not([data-unused]) code`)
  const before = (await message.count()) ? await message.textContent() : null
  await page.locator(root).getByText(label, {exact: true}).click()
  await expect(page.locator(`${root} input[name='harness']:checked`)).toHaveAccessibleName(label)
  await expect.poll(async () => message.textContent()).not.toBe(before)
  await expect(message).not.toContainText("XXXXXXXX")
  return (await message.textContent())!
}

/** The signed-in person makes a code in the side panel and `agent` signs in and pairs with it. */
export async function pairWith(page: Page, agent: Agent, name: string) {
  await page.goto("/auctions")
  await ready(page)
  await openPanel(page)
  const code = codeIn(await chooseAgent(page, "#shell-pairing", "Claude Code"))
  expect(agent.signIn().status).toBe(0)
  const answer = agent.autolaunch(["agents", "pair"], {code, name, harness: "claude_code"})
  expect(answer.status, answer.stdout).toBe(0)
  await panelToggle(page).click()
  return code
}
