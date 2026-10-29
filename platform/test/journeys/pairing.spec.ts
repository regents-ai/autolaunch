import {spawnSync} from "node:child_process"
import {readFileSync, statSync} from "node:fs"
import {join} from "node:path"
import {Agent} from "./support/agent"
import {chooseAgent, codeIn, offered, openPairing, unpair} from "./support/pairing"
import {expect, fitsAndPresses, people, ready, signIn, test} from "./support/person"

// Part 1 of the agent test plan: an agent helps its person pair (P1 to P10). The
// regents binary is the agent; the browser is Person A. The refusals are in
// pairing_refusals.spec.ts. Feature map: operations/FEATURES.md, Agents.

test.use({wallet: people.a.wallet})

test("P1-P10: an agent signs in, its person pairs it from their Account page, it checks in and works, and is unpaired", async ({page, context}, info) => {
  const touch = info.project.name === "phone"
  const agent = new Agent(`pair-${info.project.name}`)
  const name = `Journey ${info.project.name} ${agent.address.slice(2, 6)}`

  // P1: the agent signs in with its own key, and a second sign-in reuses it.
  const key = readFileSync(join(agent.home, "key.json"), "utf8")
  let answer = agent.signIn()
  expect(answer.status, answer.stderr).toBe(0)
  expect(answer.json.wallet_address).toBe(agent.address)
  expect(agent.signIn().json.wallet_address).toBe(agent.address)
  expect(readFileSync(join(agent.home, "key.json"), "utf8")).toBe(key)
  expect(statSync(join(agent.home, "key.json")).mode & 0o077).toBe(0)

  // P2: unpaired, it is told so and what its person does next, with no Points.
  answer = agent.autolaunch(["agents", "whoami"])
  expect(answer.status, answer.stderr).toBe(0)
  expect(answer.json.data).toMatchObject({status: "not_paired", pairing: null})
  expect(answer.json.data.next_step).toContain("Pair New Agent on their Account page")
  expect(agent.autolaunch(["account", "points"]).json.error.code).toBe("agent_not_paired")

  // P3: the person opens Pair New Agent from the account menu on every page they
  // might be on, and it takes them to the one pairing box, on their Account page.
  await signIn(page, people.a)
  for (const path of ["/", "/auctions", "/create"]) {
    await page.goto(path)
    await ready(page)
    await page.locator("#account-chip").click()
    await page.locator("#account-menu").getByRole("link", {name: "Pair New Agent"}).click()
    await expect(page).toHaveURL(/\/account#account-pairing$/)
    const choices = await page.locator("#account-pairing input[name='harness']").evaluateAll(inputs =>
      inputs.map(input => (input as HTMLInputElement).value))
    expect(choices, `the agents offered after opening it from ${path}`).toEqual(offered)
    await fitsAndPresses(page, touch)
  }

  // P4: the person picks the agent and copies the message.
  await context.grantPermissions(["clipboard-read", "clipboard-write"])
  await openPairing(page)
  for (const [label, line] of [["Codex", "sandbox"], ["Grok Bot", "public reply"], ["Hermes", "second one"], ["Muse", "SIWA_BROKER"]]) {
    expect(await chooseAgent(page, "#account-pairing", label)).toContain(line)
  }
  const plain = await chooseAgent(page, "#account-pairing", "Claude Code")
  for (const line of ["sandbox", "public reply", "second one", "SIWA_BROKER"]) expect(plain).not.toContain(line)
  const message = await chooseAgent(page, "#account-pairing", "Codex")
  expect(message).toContain(new URL(process.env.AUTOLAUNCH_URL!).host)
  expect(message).toContain(`${process.env.AUTOLAUNCH_URL}/llms.txt`)
  expect(message).toContain("ten minutes")
  await page.locator("#account-pairing [id$='-copy']").click()
  expect(await page.evaluate(() => navigator.clipboard.readText())).toBe(message)
  const code = codeIn(message)

  // P5: the steps the message points at are there, and name the CLI the agent runs.
  const section = message.match(/"([^"]+)" steps at (\S+)/)!
  const guide = await (await fetch(section[2])).text()
  expect(guide, `${section[2]} has the steps the message names`).toContain(`## ${section[1]}`)
  const signed = await (await fetch(`${process.env.AUTOLAUNCH_URL}/agents.md`)).text()
  const version = spawnSync(process.env.REGENTS!, ["--version"], {encoding: "utf8"}).stdout.trim().split(" ").pop()
  expect(signed, "agents.md names the CLI release the journeys run").toContain(`uv tool install --python 3.14 regents-cli==${version}`)
  for (const harness of offered) expect(signed).toContain(`\`${harness}\``)

  // P6: the agent redeems the code from stdin; the code never reaches its output.
  answer = agent.autolaunch(["agents", "pair"], {code, name: name, harness: "codex"})
  expect(answer.status, answer.stderr).toBe(0)
  expect(answer.json.data).toMatchObject({name: name, harness: "codex", wallet: agent.address})
  expect(answer.stdout + answer.stderr).not.toContain(code)

  // P7: the open box gives way to the agent's name, with no reload.
  await expect(page.locator("#account-pairing")).toContainText(name)
  await expect(page.locator("#account-pairing")).not.toContainText(code)

  // P8: the agent checks in for Person A's account, and the account page shows it.
  answer = agent.autolaunch(["agents", "status"])
  expect(answer.status, answer.stderr).toBe(0)
  expect(answer.json.data.account).toMatchObject({wallet_address: people.a.wallet, wallet_addresses: [people.a.wallet]})
  await page.goto("/account")
  await ready(page)
  const row = page.locator("#account-agents").getByText(name).locator("xpath=ancestor::li[1]")
  await expect(row).toBeVisible()
  await expect(row.locator("time")).toBeAttached()
  await fitsAndPresses(page, touch)

  // P9: paired reads answer for Person A.
  for (const command of [["drafts", "memestock", "show"], ["positions"], ["account", "balances"]]) {
    answer = agent.autolaunch(command)
    expect(answer.status, `${command.join(" ")}: ${answer.stdout}`).toBe(0)
  }

  // P10: the person unpairs it, which they do on regents.sh (the account page links
  // there); the open page drops it, and its next signed call is refused.
  unpair("did:privy:journey-a", agent.address)
  await expect(page.locator("#account-agents")).not.toContainText(name)
  expect(agent.autolaunch(["agents", "status"]).json.error.code).toBe("agent_not_paired")
  expect(agent.autolaunch(["agents", "whoami"]).json.data.pairing).toBeNull()
})
