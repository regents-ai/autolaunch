import {existsSync, readFileSync} from "node:fs"
import {expect, test} from "./support/test"
import {ready} from "./support/person"

// A visit can be told again from its lines alone (AutolaunchWeb.VisitLog). A
// visitor opens the home page and signs in, and the lines the server wrote for that
// visit (config/runtime.exs) say so in order: the request, the page, the sign-in
// steps and the site's own account actions, then the home page again, now theirs.
// Every line carries the same visit, says "anonymous" until sign-in and the same
// one-way code for the person after it, holds only the visit fields, and holds
// nothing that names the person.

type Line = {
  time: string
  severity: string
  message: string
  metadata: {
    visit?: string
    actor?: string
    surface?: string
    request_id?: string
    event?: {name: string; where: string; outcome?: string; ms?: number}
  }
}

// The walk's person (Autolaunch.TestPrivyVerifier).
const wallet = `0x${"1".repeat(40)}`

const fields = ["actor", "event", "request_id", "surface", "visit"]

function lines(visit: string): Line[] {
  const file = "tmp/walk-lines.jsonl"
  if (!existsSync(file)) return []
  return readFileSync(file, "utf8")
    .split("\n")
    .filter(text => text.includes(visit))
    .map(text => JSON.parse(text) as Line)
    .filter(line => line.metadata.visit === visit && line.metadata.event)
}

const step = (line: Line) => `${line.metadata.event!.name} ${line.metadata.event!.where}`

test("signing in from the home page replays in order from the visit's lines", async ({page, context}) => {
  await page.goto("/")
  await ready(page)
  // The site's own sign-in step, as sign_in.setup.ts takes it.
  const signedInStatus = await page.evaluate(async () => {
    const {csrf_token} = await (await fetch("/auth/csrf")).json()
    const response = await fetch("/auth/privy/session", {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "x-csrf-token": csrf_token,
        authorization: "Bearer valid",
        "privy-id-token": "valid-identity",
      },
      body: "{}",
    })
    return response.status
  })
  expect(signedInStatus).toBe(200)
  await page.goto("/")
  await ready(page)

  const visit = (await context.cookies()).find(cookie => cookie.name === "_visit")!.value
  await expect.poll(() => lines(visit).filter(line => step(line) === "page /")).toHaveLength(2)
  const told = lines(visit)
  const steps = told.map(step)

  expect(steps[0]).toBe("request /")
  const signedIn = steps.indexOf("request /auth/privy/session")
  const order = [
    steps.indexOf("page /"),
    steps.indexOf("request /auth/csrf"),
    steps.indexOf("action session_authority.bind"),
    signedIn,
    steps.indexOf("request /", signedIn),
    steps.indexOf("page /", signedIn),
  ]
  expect(order.every(index => index > 0)).toBe(true)
  expect([...order].sort((a, b) => a - b)).toEqual(order)

  // Anonymous until the sign-in answered, the person's own code after it. An
  // action inside a request is named when its request ends, on the request's line.
  const before = new Set(told.slice(0, signedIn + 1).map(line => line.metadata.actor).filter(Boolean))
  const after = new Set(told.slice(signedIn + 1).map(line => line.metadata.actor).filter(Boolean))
  expect([...before]).toEqual(["anonymous"])
  expect(after.size).toBe(1)
  expect([...after][0]).toMatch(/^person:[0-9a-f]{16}$/)

  for (const line of told) {
    expect(Object.keys(line).sort()).toEqual(["message", "metadata", "severity", "time"])
    expect(Object.keys(line.metadata).every(key => fields.includes(key))).toBe(true)
    expect(Object.keys(line.metadata.event!).every(key => ["name", "where", "outcome", "ms"].includes(key))).toBe(true)
    const text = JSON.stringify(line)
    for (const written of [wallet, "did:privy", "valid-identity", "Bearer"]) expect(text).not.toContain(written)
  }
})
