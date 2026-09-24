import {afterEach, describe, expect, it, vi} from "vitest"
import {installWalletPresses} from "../../assets/js/hooks/wallet_presses"
import {replaceActiveEthereumWallet} from "../../assets/js/wallet_actions/connected_wallet"
import {sendBidStep, sendableStep as bidStep, type BidOperation} from "../../assets/js/wallet_actions/autolaunch_bids"
import {sendLaunchStep, sendableStep as launchStep, type LaunchOperation} from "../../assets/js/wallet_actions/autolaunch_launch"
import type {Address, Hash} from "viem"
const signer = "0x1111111111111111111111111111111111111111" as Address
const to = "0x2222222222222222222222222222222222222222" as Address
const hashA = `0x${"aa".repeat(32)}` as Hash
const actionA = "11".repeat(32)
const actionB = "22".repeat(32)
const hashB = `0x${"bb".repeat(32)}` as Hash
function deferred<T>() { let resolve!: (v: T) => void; let reject!: (e: unknown) => void
  const promise = new Promise<T>((a,b) => {resolve=a; reject=b}); return {promise, resolve, reject} }
afterEach(() => { replaceActiveEthereumWallet(null); vi.unstubAllGlobals() })

for (const kind of ["bid"] as readonly ("bid" | "launch")[]) describe(`${kind} provider press isolation`, () => {
  it("two presses reach pending provider requests, survive B review, and nothing replays on remount", async () => {
    vi.stubGlobal("window", {location: {origin: "http://fixture.invalid"}, dispatchEvent: vi.fn(), addEventListener: vi.fn(), removeEventListener: vi.fn()})
    const preflight = deferred<unknown>()
    let delayPreflight = true
    const a = deferred<Hash>(), b = deferred<Hash>()
    const requests: unknown[] = []
    // One wallet on Base: the press preflight's account read is held until released,
    // and each send is answered by its own deferred hash.
    const provider = {request: vi.fn(async ({method, params}: {method: string; params?: unknown[]}) => {
      if (method === "eth_chainId") return "0x2105"
      if (method === "eth_accounts") return delayPreflight ? preflight.promise : [signer]
      if (method === "eth_sendTransaction") { requests.push(params?.[0]); return requests.length === 1 ? a.promise : b.promise }
      throw new Error(`Unexpected provider method ${method}`)
    })}
    replaceActiveEthereumWallet({address: signer, provider})
    const step = kind
    const lab = {run_id: "base-2026-09", rpc_url: "https://base.example.test", chain_id: 8453, addresses: {regent: to}}
    const op = {action_id: actionA, signer, terminal: false, chain_id: 8453,
      lab, lab_anchor: {block_number: 30_000_000, block_hash: hashA}, component_id: "panel",
      steps: [{step, to, data: "0x1234"}]} as unknown as BidOperation & LaunchOperation
    const callbacks = new Map<string, (p: any) => any>()
    const events: [string, any][] = []
    let clicked!: (event: any) => Promise<void>
    const el = {id: "panel", dataset: {walletScope: "scope-a"}, addEventListener: (_: string, cb: typeof clicked) => {clicked = cb}, removeEventListener: vi.fn()} as unknown as HTMLElement
    const hook = {el, handleEvent: (name: string, cb: (p: any) => void) => {callbacks.set(name, cb)},
      pushEventTo: (_: HTMLElement, name: string, payload: unknown) => {events.push([name, payload])}}
    const send = (held: typeof op, name: string, started: () => void) => {
      const resolve = () => ({address: signer, provider})
      if (kind === "bid") return sendBidStep(held, bidStep(held, held.action_id, name), resolve, started)
      return sendLaunchStep(held, launchStep(held, held.action_id, name), resolve, started)
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
    const reports = events.filter(([name]) => name === "wallet_press_report").map(([,p]) => p)
    expect(reports.map(r => r.transaction_hash).sort()).toEqual([hashA, hashB].sort())
    expect(new Set(reports.map(r => r.press_id)).size).toBe(2)
    events.length = 0
    installWalletPresses(hook, config)
    expect(events).toHaveLength(0)
    expect(requests).toHaveLength(2)
  })
})
