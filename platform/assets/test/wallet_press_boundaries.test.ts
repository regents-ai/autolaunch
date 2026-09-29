import {afterEach, expect, it, vi} from "vitest"
import {AutolaunchBidWallet} from "../js/hooks/autolaunch_bid_wallet"
import {AutolaunchLaunchWallet} from "../js/hooks/autolaunch_launch_wallet"
import {AutolaunchSubjectWallet} from "../js/hooks/autolaunch_subject_wallet"
import {replaceActiveEthereumWallet} from "../js/wallet_actions/connected_wallet"
import {retainedReports} from "../js/hooks/wallet_presses"

const seams = vi.hoisted(() => new Map<unknown, any>())
vi.mock("viem", async original => ({...await original<typeof import("viem")>(),
  custom: (provider: unknown) => provider,
  createWalletClient: ({transport}: any) => seams.get(transport),
}))
const signer = "0x1111111111111111111111111111111111111111"
const other = "0x2222222222222222222222222222222222222222"
const hash = `0x${"aa".repeat(32)}`
function deferred<T>() { let resolve!: (value: T) => void; let reject!: (value: unknown) => void
  const promise = new Promise<T>((a, b) => {resolve = a; reject = b}); return {promise, resolve, reject} }
function memory(): Storage { const entries = new Map<string, string>(); return {
  getItem: key => entries.get(key) ?? null, setItem: (key, value) => {entries.set(key, value)},
  removeItem: key => {entries.delete(key)}, clear: () => entries.clear(), key: () => null,
  get length() {return entries.size},
} }
afterEach(() => {replaceActiveEthereumWallet(null); vi.unstubAllGlobals(); seams.clear()})
const kinds = [
  ["bid", AutolaunchBidWallet, "autolaunch-bid", "[data-bid-send]", "bid"],
  ["launch", AutolaunchLaunchWallet, "autolaunch-launch", "[data-launch-wallet-send]", "launch"],
  ["subject", AutolaunchSubjectWallet, "autolaunch-subject-wallet", "[data-subject-wallet-send]", "action"],
] as const
function fixture(entry: typeof kinds[number], initialScope = "scope-a") {
  const [, definition, prefix, selector, step] = entry
  const window = Object.assign(new EventTarget(), {location: {origin: "http://fixture.invalid"}})
  vi.stubGlobal("window", window); vi.stubGlobal("sessionStorage", memory())
  const provider = {request: vi.fn(async () => [signer])}
  const clients = {getAddresses: vi.fn(async () => [signer]), getChainId: vi.fn(async () => 8453),
    switchChain: vi.fn(async () => {}), sendTransaction: vi.fn(async () => hash)}
  seams.set(provider, clients); replaceActiveEthereumWallet({address: signer, provider})
  const callbacks = new Map<string, (payload: any) => any>(), events: [string, any][] = []
  let click!: (event: any) => Promise<void>
  let disconnected = false
  const el = {id: "panel", dataset: {walletScope: initialScope},
    addEventListener: (_: string, cb: typeof click) => {click = cb}, removeEventListener: vi.fn()}
  const hook = {el, handleEvent: (name: string, cb: any) => {
    const previous = callbacks.get(name)
    callbacks.set(name, previous ? payload => {previous(payload); return cb(payload)} : cb)
  },
    pushEventTo: (_: any, name: string, value: any) => {
      if (disconnected) throw new Error("Hook transport is gone")
      events.push([name, value])
    }}
  definition.mounted!.call(hook as any)
  const action_id = "11".repeat(32)
  const operation = {action_id, signer, component_id: "panel", terminal: false, chain_id: 8453,
    subject_id: "subject", lab: null, lab_anchor: null, steps: [{step, to: other, data: "0x1234"}]}
  callbacks.get(`${prefix}:operation`)!(operation)
  const button = {dataset: {walletStep: step}, getAttribute: () => action_id}
  return {provider, clients, callbacks, events, el, window,
    click: () => click({target: {closest: (s: string) => s === selector ? button : null}}),
    dispose: () => definition.destroyed!.call(hook as any),
    disconnect: () => {disconnected = true},
    update: () => definition.updated?.call(hook as any),
    send: () => callbacks.get("wallet-press:send")!(events.find(([n]) => n === "wallet_press_dispatch")![1]),
  }
}
for (const entry of kinds) {
  it(`${entry[0]} refuses clicks when the mounted component has no owning scope`, async () => {
    const f = fixture(entry, "")
    await f.click()
    expect(f.events.some(([name]) => name === "wallet_press_dispatch")).toBe(false)
  })
  it(`${entry[0]} production callback cannot dispatch after click preflight teardown`, async () => {
    const f = fixture(entry), gate = deferred<string[]>()
    f.provider.request.mockImplementation(() => gate.promise)
    const pending = f.click(); f.dispose(); gate.resolve([signer]); await pending
    expect(f.events.some(([name]) => name === "wallet_press_dispatch")).toBe(false)
  })
  for (const boundary of ["authorization", "first-chain", "accounts", "final-chain"] as const) {
    for (const loss of ["dispose", "provider", "address", "scope", "revocation", "wallet-away-back"] as const) {
      it(`${entry[0]} refuses ${loss} at ${boundary} through the real send helper`, async () => {
        const f = fixture(entry); await f.click()
        const gate = deferred<any>(); let pending: Promise<void> | undefined
        if (boundary !== "authorization") {
          if (boundary === "accounts") f.clients.getAddresses.mockImplementationOnce(() => gate.promise)
          else if (boundary === "first-chain") f.clients.getChainId.mockImplementationOnce(() => gate.promise)
          else f.clients.getChainId.mockResolvedValueOnce(8453).mockImplementationOnce(() => gate.promise)
          pending = f.send()
          await vi.waitFor(() => expect(boundary === "accounts" ? f.clients.getAddresses : f.clients.getChainId)
            .toHaveBeenCalledTimes(boundary === "final-chain" ? 2 : 1))
        }
        if (loss === "dispose") f.dispose()
        if (loss === "provider") replaceActiveEthereumWallet({address: signer, provider: {request: async () => [signer]}})
        if (loss === "address") replaceActiveEthereumWallet({address: other, provider: f.provider})
        if (loss === "scope") {f.el.dataset.walletScope = "scope-b"; f.update()}
        if (loss === "revocation") f.callbacks.get("wallet-press:invalidated")?.({component_id: "panel"})
        if (loss === "wallet-away-back") {
          replaceActiveEthereumWallet(null); f.window.dispatchEvent(new Event("autolaunch:wallet-state"))
          replaceActiveEthereumWallet({address: signer, provider: f.provider})
        }
        if (boundary === "authorization") pending = f.send()
        else gate.resolve(boundary === "accounts" ? [signer] : 8453)
        await pending
        expect(f.clients.sendTransaction).not.toHaveBeenCalled()
        expect(retainedReports(sessionStorage)).toEqual([expect.objectContaining({outcome: "not_started"})])
      })
    }
  }
  it(`${entry[0]} cannot switch chains after teardown during a chain read`, async () => {
    const f = fixture(entry), gate = deferred<number>()
    f.clients.getChainId.mockImplementationOnce(() => gate.promise)
    await f.click(); const pending = f.send()
    await vi.waitFor(() => expect(f.clients.getChainId).toHaveBeenCalledOnce())
    f.dispose(); gate.resolve(1); await pending
    expect(f.clients.switchChain).not.toHaveBeenCalled()
    expect(f.clients.sendTransaction).not.toHaveBeenCalled()
  })
  for (const outcome of ["hash", "reject", "unknown"] as const) {
    it(`${entry[0]} preserves eventual ${outcome} evidence after an issued send is destroyed`, async () => {
      const f = fixture(entry), gate = deferred<string>()
      f.clients.sendTransaction.mockImplementation(() => gate.promise)
      await f.click(); const pending = f.send()
      await vi.waitFor(() => expect(f.clients.sendTransaction).toHaveBeenCalledOnce())
      f.dispose(); f.disconnect()
      if (outcome === "hash") gate.resolve(hash)
      else gate.reject(outcome === "reject" ? {code: 4001} : new Error("unknown"))
      await pending
      expect(retainedReports(sessionStorage)).toEqual([expect.objectContaining(outcome === "hash"
        ? {transaction_hash: hash} : {outcome: outcome === "reject" ? "not_sent" : "submission_unknown"})])
    })
  }
}
