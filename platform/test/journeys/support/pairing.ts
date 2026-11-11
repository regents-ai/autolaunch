import type {Page} from "@playwright/test"
import {Agent} from "./agent"
import {expect, ready} from "./person"
import {onSite} from "./site"

// What the pairing journeys share: the person's side of the pairing window, which
// Pair New Agent opens over the page, and unpairing as regents.sh does it.

// Every harness the pair request accepts here; never ChatGPT.
export const offered = [
  "hermes", "grok_bot", "muse", "openclaw", "nemoclaw", "ironclaw", "pi",
  "claude_code", "codex", "cursor", "gemini_cli", "dots", "other",
]

// The agents the pairing window lists, in its order; any other pairs as any agent.
export const listed = [
  "other", "codex", "grok_bot", "muse", "hermes", "dots", "ironclaw", "openclaw",
  "claude_code", "pi",
]

export const pairingWindow = (page: Page) => page.locator("#shell-pairing")
export const pairingBox = (page: Page) => page.locator("form#shell-pairing-box")

// Unpairs as regents.sh does, through the shared pairing library on the shared database.
export function unpair(person: string, wallet: string) {
  onSite("unpair.exs", {JOURNEY_PERSON: person, JOURNEY_AGENT: wallet})
}

export const codeIn = (message: string) => message.match(/Pairing code: (\S+)/)![1]

// Pair New Agent on the Agents page, which opens the pairing window.
export async function openPairing(page: Page) {
  await page.goto("/account/agents")
  await ready(page)
  await page.locator("#account-agents").getByRole("button", {name: "Pair New Agent"}).click()
  await expect(pairingWindow(page)).toBeVisible()
}

// Picks an agent from the window's dropdown, opening it when a choice closed it, and
// waits for that agent's own message, which carries its own code, so it differs
// from the one on screen before the press.
export async function chooseAgent(page: Page, label: string) {
  const box = pairingBox(page)
  const dropdown = box.locator("details")
  const message = box.locator("pre code")
  const before = (await message.count()) ? await message.textContent() : null
  if (!(await dropdown.evaluate(details => (details as HTMLDetailsElement).open))) {
    await dropdown.locator("summary").click()
  }
  // The choice closes the list, so the radio is looked for hidden too when its check is read.
  const radio = box.getByRole("radio", {name: label, exact: true, includeHidden: true})
  await radio.locator("xpath=ancestor::label").click()
  await expect(radio).toBeChecked()
  await expect.poll(async () => message.textContent()).not.toBe(before)
  return (await message.textContent())!
}

/** The signed-in person makes a code in the pairing window and `agent` signs in and pairs with it. */
export async function pairWith(page: Page, agent: Agent, name: string) {
  await openPairing(page)
  const code = codeIn(await chooseAgent(page, "Claude Code"))
  expect(agent.signIn().status).toBe(0)
  const answer = agent.autolaunch(["agents", "pair"], {code, name, harness: "claude_code"})
  expect(answer.status, answer.stdout).toBe(0)
  return code
}
