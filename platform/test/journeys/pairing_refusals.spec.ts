import {readFileSync} from "node:fs"
import {Agent} from "./support/agent"
import {chooseAgent, codeIn, openPairing, pairWith, unpair} from "./support/pairing"
import {expect, people, ready, signIn, test} from "./support/person"

// Part 1's refusals: what an agent is told when pairing or a paired call cannot
// go ahead, through the regents binary and the site's own signed routes. They do
// not depend on the screen, so they run once, at desktop width. Feature map:
// operations/FEATURES.md, Agents.
test.beforeEach(({}, info) => test.skip(info.project.name !== "desktop", "one run is enough"))
test.use({wallet: people.a.wallet})

const site = process.env.AUTOLAUNCH_URL!

test("a code works once, for the agent that used it and for any other", async ({page}) => {
  await signIn(page, people.a)
  const first = new Agent("once-first")
  const code = await pairWith(page, first, "Once first")
  const second = new Agent("once-second")
  expect(second.signIn().status).toBe(0)
  for (const agent of [first, second]) {
    const answer = agent.autolaunch(["agents", "pair"], {code, name: "Again", harness: "codex"})
    expect(answer.json.error).toMatchObject({code: "pairing_failed", status: 400})
  }
  unpair("did:privy:journey-a", first.address)
})

test("two agents redeeming one code at the same moment: exactly one pairs", async ({page}) => {
  await signIn(page, people.a)
  await openPairing(page)
  const code = codeIn(await chooseAgent(page, "#account-pairing", "Pi"))
  const agents = [new Agent("race-one"), new Agent("race-two"), new Agent("race-three")]
  for (const agent of agents) expect(agent.signIn().status).toBe(0)
  const answers = await Promise.all(agents.map(agent =>
    agent.autolaunchAtOnce(["agents", "pair"], {code, name: "Race", harness: "pi"})))
  expect(answers.filter(answer => answer.status === 0)).toHaveLength(1)
  for (const answer of answers.filter(answer => answer.status !== 0))
    expect(answer.json.error.code).toBe("pairing_failed")
  const winner = agents[answers.findIndex(answer => answer.status === 0)]
  unpair("did:privy:journey-a", winner.address)
})

test("ChatGPT and made-up harnesses are refused before the code is spent", async ({page}) => {
  await signIn(page, people.a)
  await openPairing(page)
  const code = codeIn(await chooseAgent(page, "#account-pairing", "Codex"))
  const agent = new Agent("harness")
  expect(agent.signIn().status).toBe(0)
  for (const harness of ["chatgpt", "made_up"]) {
    const answer = agent.autolaunch(["agents", "pair"], {code, name: "Harness", harness})
    expect(answer.json.error).toMatchObject({code: "harness_unknown", status: 400})
  }
  expect(agent.autolaunch(["agents", "pair"], {code, name: "Harness", harness: "codex"}).status).toBe(0)
  unpair("did:privy:journey-a", agent.address)
})

test("an agent no one paired is refused every private route", async () => {
  const agent = new Agent("never-paired")
  expect(agent.signIn().status).toBe(0)
  for (const command of [["agents", "status"], ["drafts", "memestock", "show"], ["positions"], ["account", "balances"], ["account", "points"]]) {
    const answer = agent.autolaunch(command)
    expect(answer.json.error, command.join(" ")).toMatchObject({code: "agent_not_paired", status: 403})
  }
  const save = agent.autolaunch(["drafts", "memestock", "save"], {name: "Not yours"})
  expect(save.json.error).toMatchObject({code: "agent_not_paired", status: 403})
})

test("an unsigned request, or one with a query string, is refused", async () => {
  const unsigned = await fetch(`${site}/api/agents/v1/me`)
  expect(unsigned.status).toBe(401)
  expect((await unsigned.json()).error.code).toBe("http_headers_missing")
  const query = await fetch(`${site}/api/agent/v1/positions?wallet=0x1`)
  expect(query.status).toBe(401)
  expect((await query.json()).error.code).toBe("unsupported_query")
})

test("while the sign-in service is down a paired call says so, and works once it is back", async ({page}) => {
  await signIn(page, people.a)
  const agent = new Agent("siwa-down")
  await pairWith(page, agent, "Siwa down")
  const siwa = Number(readFileSync(`${process.env.STACK_STATE}/siwa.pid`, "utf8"))
  process.kill(siwa, "SIGSTOP")
  try {
    const answer = agent.autolaunch(["agents", "status"])
    expect(answer.json.error).toMatchObject({code: "siwa_request_failed", status: 503})
  } finally {
    process.kill(siwa, "SIGCONT")
  }
  expect(agent.autolaunch(["agents", "status"]).status).toBe(0)
  unpair("did:privy:journey-a", agent.address)
})
