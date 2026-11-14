// Invariant: Save on the Account page's Public Display Name writes the name to
// the profile it just read, with the page's own sign-in, and never writes after
// a read that failed. Every step of one save belongs to one person: a switch of
// account part way through writes nothing, and a save waiting its turn belongs to
// the person signed in at its press. Two quick presses keep the name pressed
// last, and a save that fails outright never leaves the form busy.
import {afterEach, expect, it, vi} from "vitest"
import {PublicName} from "../js/hooks/public_name"

afterEach(() => vi.unstubAllGlobals())

// The site as RegentIdentity.HTTP serves it behind its owner plug: each request
// acts for the person the browser's session cookie names, and a change needs that
// session's forms token. A sign-in renews the session and its token.
function site(first: string | null) {
  let session = first ? {person: first, token: `token-${first}`} : null
  const profiles = new Map<string, {profile_id: string; display_name: string | null}>()
  const writes: string[] = []
  const signedOut = () => Response.json({error: {code: "authentication_required"}}, {status: 401})
  const fetch = (async (path: string, init: RequestInit) => {
    const headers = init.headers as Record<string, string>
    const caller = session
    if (!caller) return signedOut()
    const mine = profiles.get(caller.person)
    if (init.method === "GET") {
      return mine
        ? Response.json({profile: mine})
        : Response.json({error: {code: "profile_not_created"}}, {status: 404})
    }
    if (headers["x-csrf-token"] !== caller.token) return signedOut()
    const expected = headers["x-regent-profile-id"]
    if (!mine || (expected && expected !== mine.profile_id)) {
      return Response.json({error: {code: "invalid_profile_update"}}, {status: 422})
    }
    writes.push(`${init.method} ${path} ${caller.person}`)
    mine.display_name = JSON.parse(String(init.body)).display_name
    return Response.json({profile: mine})
  }) as typeof globalThis.fetch
  const signIn = (person: string) => {
    session = {person, token: `token-${person}`}
    if (!profiles.has(person)) profiles.set(person, {profile_id: `profile-${person}`, display_name: null})
  }
  if (first) signIn(first)
  // The page's forms token: the one it was served with, until the page adopts a new one.
  let pageToken = session?.token ?? ""
  const adoptToken = () => { pageToken = session?.token ?? "" }
  vi.stubGlobal("document", {
    querySelector: (selector: string) => selector === "meta[name='csrf-token']" ? {content: pageToken} : null,
  })
  return {fetch, profiles, writes, signIn, adoptToken}
}

// The form as the page holds it: just what the design system's mountProfile reads
// and writes, mounted by the page's own hook.
function accountPage(fetch: typeof globalThis.fetch) {
  vi.stubGlobal("fetch", fetch)
  let submit: ((event: {preventDefault(): void}) => Promise<void>) | null = null
  const attributes = new Map<string, string>()
  const status = {textContent: ""}
  const name = {value: ""}
  const element = {
    elements: {namedItem: () => name},
    addEventListener: (_: string, listener: typeof submit) => { submit = listener },
    setAttribute: (key: string, value: string) => attributes.set(key, value),
    removeAttribute: (key: string) => attributes.delete(key),
  }
  const root = {querySelector: (selector: string) => selector === "[data-profile-form]" ? element : status}
  const saved: unknown[] = []
  PublicName.mounted!.call({el: root, pushEvent: (event: string) => saved.push(event)})
  const press = (typed: string) => { name.value = typed; return submit!({preventDefault() {}}) }
  return {attributes, status, name, press, saved}
}

it("a save writes the name to the profile it read, with the page's forms token", async () => {
  const service = site("did:a")
  const page = accountPage(service.fetch)

  await page.press("Ada")
  expect(service.profiles.get("did:a")?.display_name).toBe("Ada")
  expect(service.writes).toEqual(["PATCH /api/v1/profile did:a"])
  expect(page.name.value).toBe("Ada")
  expect(page.saved).toEqual(["public_name_saved"])
})

it("nothing is written without a sign-in", async () => {
  const service = site(null)
  const page = accountPage(service.fetch)

  await page.press("Ada")
  expect(service.writes).toEqual([])
  expect(page.attributes.has("aria-busy")).toBe(false)
  expect(page.status.textContent).not.toBe("")
  expect(page.saved).toEqual([])
})

it("a switch of account after the first read saves nothing to either account", async () => {
  const service = site("did:a")
  // Another tab signs in as someone else once this save has read the profile.
  const switching: typeof globalThis.fetch = async (input, init) => {
    const answer = await service.fetch(input, init)
    if (init?.method === "GET") { service.signIn("did:b"); service.adoptToken() }
    return answer
  }
  const page = accountPage(switching)

  await page.press("Ada")
  expect(service.writes).toEqual([])
  expect(service.profiles.get("did:a")?.display_name).toBe(null)
  expect(service.profiles.get("did:b")?.display_name).toBe(null)
  expect(page.saved).toEqual([])
})

it("a save pressed before a switch of account, still waiting its turn, saves to neither account", async () => {
  const service = site("did:a")
  // The first save's change reaches the server, then the person switches account,
  // and the page adopts the new session's token, while the second save waits.
  const switchDuringFirstWrite: typeof globalThis.fetch = async (input, init) => {
    const answer = await service.fetch(input, init)
    if (init?.method === "PATCH") { service.signIn("did:b"); service.adoptToken() }
    return answer
  }
  const page = accountPage(switchDuringFirstWrite)

  await Promise.all([page.press("Ada"), page.press("Grace")])
  expect(service.profiles.get("did:a")?.display_name).toBe("Ada")
  expect(service.profiles.get("did:b")?.display_name).toBe(null)
  expect(service.writes).toEqual(["PATCH /api/v1/profile did:a"])
  // Only the save pressed last speaks for the form, and it saved nothing.
  expect(page.saved).toEqual([])
  expect(page.attributes.has("aria-busy")).toBe(false)
})

it("a save that fails outright says so and leaves the form ready", async () => {
  site("did:a")
  const page = accountPage(async () => { throw new TypeError("network down") })

  await page.press("Ada")
  expect(page.attributes.has("aria-busy")).toBe(false)
  expect(page.status.textContent).not.toBe("")
  expect(page.saved).toEqual([])
})

it("two quick saves keep the name pressed last, however slow the first is", async () => {
  const service = site("did:a")
  let firstRead = true
  const slowFirstRead: typeof globalThis.fetch = async (input, init) => {
    if (init?.method === "GET" && firstRead) {
      firstRead = false
      await new Promise(resolve => setTimeout(resolve, 20))
    }
    return service.fetch(input, init)
  }
  const page = accountPage(slowFirstRead)

  await Promise.all([page.press("Ada"), page.press("Grace")])
  expect(service.profiles.get("did:a")?.display_name).toBe("Grace")
  expect(page.name.value).toBe("Grace")
  expect(page.attributes.has("aria-busy")).toBe(false)
  expect(page.saved).toEqual(["public_name_saved"])
})
