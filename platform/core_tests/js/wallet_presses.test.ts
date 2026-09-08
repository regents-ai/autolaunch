import {afterEach, describe, expect, it, vi} from "vitest"
import {installWalletPresses, retainedReports, retainReport, releaseReport} from "../../assets/js/hooks/wallet_presses"
import {replaceActiveEthereumWallet} from "../../assets/js/wallet_actions/connected_wallet"
import {sendBidStep, sendableStep as bidStep, type BidOperation} from "../../assets/js/wallet_actions/autolaunch_bids"
import {sendLaunchStep, sendableStep as launchStep, type LaunchOperation} from "../../assets/js/wallet_actions/autolaunch_launch"
import {sendSubjectStep, sendableStep as subjectStep, type SubjectWalletOperation} from "../../assets/js/wallet_actions/autolaunch_subject_wallet"
import type {Address, Hash} from "viem"
const signer = "0x1111111111111111111111111111111111111111" as Address
const to = "0x2222222222222222222222222222222222222222" as Address
const hashA = `0x${"aa".repeat(32)}` as Hash
const actionA = "11".repeat(32)
const actionB = "22".repeat(32)
const hashB = `0x${"bb".repeat(32)}` as Hash
function storage(): Storage {
  const values = new Map<string, string>()
  return {getItem: key => values.get(key) ?? null, setItem: (key, value) => { values.set(key, value) },
    removeItem: key => { values.delete(key) }, clear: () => values.clear(), key: i => [...values.keys()][i] ?? null,
    get length() { return values.size }}
}
function deferred<T>() { let resolve!: (v: T) => void; let reject!: (e: unknown) => void
  const promise = new Promise<T>((a,b) => {resolve=a; reject=b}); return {promise, resolve, reject} }
afterEach(() => { replaceActiveEthereumWallet(null); vi.unstubAllGlobals() })

for (const kind of ["bid"] as readonly ("bid" | "launch" | "subject")[]) describe(`${kind} provider press isolation`, () => {
  it("two presses reach pending provider requests, survive B review, and replay only independent reports", async () => {
    const retained = storage()
    vi.stubGlobal("sessionStorage", retained)
    vi.stubGlobal("window", {location: {origin: "http://fixture.invalid"}, dispatchEvent: vi.fn(), addEventListener: vi.fn(), removeEventListener: vi.fn()})
    const preflight = deferred<unknown>()
    let delayPreflight = true
    const provider = {request: vi.fn(async () => delayPreflight ? preflight.promise : [signer])}
    replaceActiveEthereumWallet({address: signer, provider})
    const a = deferred<Hash>(), b = deferred<Hash>()
    const requests: unknown[] = []
    const clients = {addresses: async () => [signer], chainId: async () => 8453,
      switchToBase: async () => {}, send: (request: unknown) => { requests.push(request); return requests.length === 1 ? a.promise : b.promise }}
    const step = kind === "subject" ? "action" : kind
    const op = {action_id: actionA, signer, terminal: false, chain_id: 8453,
      lab: null, lab_anchor: null, subject_id: "subject", component_id: "panel",
      steps: [{step, to, data: "0x1234"}]} as unknown as BidOperation & LaunchOperation & SubjectWalletOperation
    const callbacks = new Map<string, (p: any) => any>()
    const events: [string, any][] = []
    let clicked!: (event: any) => Promise<void>
    const el = {id: "panel", dataset: {walletScope: "scope-a"}, addEventListener: (_: string, cb: typeof clicked) => {clicked = cb}, removeEventListener: vi.fn()} as unknown as HTMLElement
    const hook = {el, handleEvent: (name: string, cb: (p: any) => void) => {callbacks.set(name, cb)},
      pushEventTo: (_: HTMLElement, name: string, payload: unknown) => {events.push([name, payload])}}
    const send = (held: typeof op, name: string, started: () => void) => {
      const resolve = () => ({address: signer, provider})
      if (kind === "bid") return sendBidStep(held, bidStep(held, held.action_id, name), resolve, started, () => clients)
      if (kind === "launch") return sendLaunchStep(held, launchStep(held, held.action_id, name), resolve, started, () => clients)
      return sendSubjectStep(held, subjectStep(held, held.action_id, name), resolve, started, clients)
    }
    const config = {prefix: "review", selector: "[data-send]", connect: "[data-connect]", send}
    installWalletPresses(hook, config)
    callbacks.get("review:operation")!(op)
    const initialEvents = events.length
    callbacks.get("review:operation")!({...op, action_id: "foreign-card", component_id: "other-panel"})
    expect(events).toHaveLength(initialEvents)
    const button = {dataset: {walletStep: step}, getAttribute: () => actionA}
    const event = {target: {closest: (selector: string) => selector === "[data-send]" ? button : null}}
    const clickA = clicked(event), clickB = clicked(event)
    callbacks.get("review:operation")!({...op, action_id: actionB, steps: [{step, to, data: "0xbeef"}]})
    delayPreflight = false; preflight.resolve([signer]); await Promise.all([clickA, clickB])
    const dispatches = events.filter(([name]) => name === "wallet_press_dispatch").map(([,p]) => p)
    expect(dispatches).toHaveLength(2)
    expect(dispatches[0].press_id).not.toBe(dispatches[1].press_id)
    const sendA = callbacks.get("wallet-press:send")!(dispatches[0])
    const sendB = callbacks.get("wallet-press:send")!(dispatches[1])
    await vi.waitFor(() => expect(requests).toHaveLength(2))
    expect(requests).toEqual([expect.objectContaining({data: "0x1234"}), expect.objectContaining({data: "0x1234"})])
    await callbacks.get("wallet-press:send")!(dispatches[0])
    expect(requests).toHaveLength(2) // same delivery, not a distinct click
    b.resolve(hashB); await sendB
    a.resolve(hashA); await sendA
    expect(retainedReports(retained)).toHaveLength(2)
    const reports = retainedReports(retained)
    // JSON key order across the wire is not identity.
    releaseReport({...reports[0], step: reports[0].step}, retained)
    expect(retainedReports(retained)).toEqual([reports[1]])
    events.length = 0
    installWalletPresses(hook, config)
    expect(events.filter(([name]) => name === "wallet_press_report")).toHaveLength(1)
    expect(events.some(([name]) => name === "wallet_press_dispatch")).toBe(false)
    expect(requests).toHaveLength(2)
  })
})

const storageKey = "regent:autolaunch:wallet-reports:v2"
for (const bad of [null, {}, 123, "text", [null, {}, "x", "x".repeat(1000)]]) {

}
it("skips corrupt entries independently and retains a subsequent valid hash", () => {
  const held = storage()
  const valid = {component_id: "panel", action_id: actionA, press_id: crypto.randomUUID(), step: "bid", transaction_hash: hashA}
  const invalid = [null, 1, [], {}, {...valid, action_id: "bad"}, {...valid, press_id: "bad"},
    {...valid, component_id: "x".repeat(1000)}, {...valid, step: "arbitrary"},
    {...valid, transaction_hash: "0x123"}, {...valid, transaction_hash: undefined, outcome: "arbitrary"},
    {...valid, outcome: "not_started"}]
  held.setItem(storageKey, JSON.stringify(Object.fromEntries(invalid.map((value, i) => [`bad${i}`, value]))))
  expect(retainedReports(held)).toEqual([])
  retainReport(valid, held)
  expect(retainedReports(held)).toEqual([valid])
  held.setItem(storageKey, JSON.stringify({bad: null, [valid.press_id]: {...valid, extra: "x".repeat(1000)}}))
  expect(retainedReports(held)).toEqual([valid])
  releaseReport(valid, held)
  expect(retainedReports(held)).toEqual([])
})

it("a late A acknowledgment cannot remove B's hash, rejection or unknown report", () => {
  const held = storage()
  const a = {component_id: "p", action_id: actionA, press_id: crypto.randomUUID(), step: "bid", transaction_hash: hashA}
  const b = {component_id: "p", action_id: actionB, press_id: crypto.randomUUID(), step: "bid", outcome: "not_sent"}
  retainReport(a, held); retainReport(b, held)
  releaseReport(a, held)
  expect(retainedReports(held)).toEqual([b])
  retainReport({...a, outcome: "submission_unknown", transaction_hash: undefined}, held)
  releaseReport(a, held)
  expect(retainedReports(held)).toHaveLength(2)
})
