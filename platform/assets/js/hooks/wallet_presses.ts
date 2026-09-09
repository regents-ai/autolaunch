import {activeEthereumWallet, type SelectedWallet} from "../wallet_actions/connected_wallet"
import {userRejected} from "../wallet_actions/autolaunch_bids"

type Review = {action_id: string; signer: string; terminal: boolean; step?: string}
type Report = {component_id: string; action_id: string; press_id: string; step: string;
  transaction_hash?: string; outcome?: string}
type Hook = {el: HTMLElement; handleEvent(name: string, callback: (payload: any) => void): void;
  pushEventTo(target: HTMLElement, name: string, payload: unknown): void}
const key = "regent:autolaunch:wallet-reports:v2"

const uuid = (value: unknown): value is string => typeof value === "string" &&
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value)
const actionId = (value: unknown): value is string => typeof value === "string" && /^[0-9a-f]{64}$/.test(value)
const object = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null && !Array.isArray(value)

function wholeReport(value: unknown): Report | null {
  if (!object(value)) return null
  const {component_id, action_id, press_id, step, transaction_hash, outcome} = value
  if (typeof component_id !== "string" || !/^[a-zA-Z0-9_:-]{1,200}$/.test(component_id) ||
      !actionId(action_id) || !uuid(press_id) || typeof step !== "string" ||
      !["token_approval", "permit2_approval", "bid", "usdc_approval", "usdc_bid", "approval", "launch", "action", "exit", "claim"].includes(step)) return null
  const base = {component_id, action_id, press_id, step}
  if (typeof transaction_hash === "string" && /^0x[0-9a-f]{64}$/i.test(transaction_hash) && outcome === undefined)
    return {...base, transaction_hash}
  if (transaction_hash === undefined && typeof outcome === "string" &&
      ["not_started", "not_sent", "submission_unknown"].includes(outcome)) return {...base, outcome}
  return null
}

export function retainedReports(storage: Storage): Report[] {
  try {
    const reports: unknown = JSON.parse(storage.getItem(key) || "{}")
    if (!object(reports)) return []
    return Object.values(reports).flatMap(value => { const report = wholeReport(value); return report ? [report] : [] })
  } catch { return [] }
}
export function retainReport(report: Report, storage: Storage): void {
  const valid = wholeReport(report)
  if (!valid) return
  try { const all = Object.fromEntries(retainedReports(storage).map(r => [r.press_id, r]));
    all[report.press_id] = valid; storage.setItem(key, JSON.stringify(all)) } catch { /* connected report still sent */ }
}
export function releaseReport(report: Report, storage: Storage): void {
  try { const all = Object.fromEntries(retainedReports(storage).map(r => [r.press_id, r]));
    const held = all[report.press_id]
    if (!held || held.action_id !== report.action_id || held.component_id !== report.component_id ||
        held.step !== report.step || held.transaction_hash !== report.transaction_hash || held.outcome !== report.outcome) return
    delete all[report.press_id]; storage.setItem(key, JSON.stringify(all)) } catch { /* replay is harmless */ }
}

/** A click captures review + step before any await. Only that click can consume
 * its authorization. Reload replays reports, never dispatch requests or sends. */
export function installWalletPresses<O extends Review>(hook: Hook, config: {
  prefix: string; selector: string; connect: string;
  send(operation: O, step: string, started: () => void, resolveWallet: () => SelectedWallet | null): Promise<string>;
}) {
  let disposed = false
  let scope = hook.el.dataset?.walletScope
  const operations = new Map<string, O>()
  const historyKey = `${key}:reviews:${hook.el.id}`
  let reviews: string[] = []
  try {
    const hints: unknown = JSON.parse(sessionStorage.getItem(historyKey) || "[]")
    if (Array.isArray(hints)) reviews = [...new Set(hints.filter(actionId))]
  } catch { /* no hints */ }
  const presses = new Map<string, {operation: O; step: string; sent: boolean;
    selected: SelectedWallet; invalid: boolean}>()
  const invalidate = () => {
    operations.clear()
    for (const press of presses.values()) press.invalid = true
  }
  const checkScope = () => {
    if (hook.el.dataset?.walletScope !== scope) {
      invalidate()
      scope = hook.el.dataset?.walletScope
    }
  }
  const resolve = (press: {selected: SelectedWallet; invalid: boolean}) => {
    checkScope()
    const current = activeEthereumWallet()
    if (disposed || !scope || press.invalid || !current || current.provider !== press.selected.provider ||
        current.address.toLowerCase() !== press.selected.address.toLowerCase()) {
      press.invalid = true
      return null
    }
    return press.selected
  }
  const walletChanged = () => { for (const press of presses.values()) resolve(press) }
  window.addEventListener("autolaunch:wallet-state", walletChanged)
  const push = (event: string, payload: unknown) => hook.pushEventTo(hook.el, event, payload)
  const mine = (p: {component_id?: string}) => !p.component_id || p.component_id === hook.el.id
  const report = (r: Report) => {
    retainReport(r, sessionStorage)
    try { push("wallet_press_report", r) } catch { /* replay evidence after reconnect, never downgrade it */ }
  }
  hook.handleEvent(`${config.prefix}:operation`, (op: O & {component_id?: string}) => {
    if (disposed || !mine(op)) return
    checkScope()
    operations.set(op.action_id, structuredClone(op))
    if (!reviews.includes(op.action_id)) {
      reviews.push(op.action_id)
      try { sessionStorage.setItem(historyKey, JSON.stringify(reviews)) } catch { /* connected history remains */ }
    }
    push("wallet_press_restore", {action_id: op.action_id})
  })
  hook.handleEvent("wallet-press:invalidated", p => { if (mine(p)) invalidate() })
  hook.handleEvent("wallet-press:durable", (r: Report) => { if (mine(r)) releaseReport(r, sessionStorage) })
  for (const action_id of reviews) push("wallet_press_restore", {action_id})
  for (const r of retainedReports(sessionStorage)) if (mine(r)) push("wallet_press_report", r)

  const clicked = async (event: Event) => {
    if (disposed) return
    checkScope()
    if (!scope) return
    const target = event.target as HTMLElement | null
    if (target?.closest(config.connect)) { window.dispatchEvent(new CustomEvent("autolaunch:wallet-connect")); return }
    const button = target?.closest<HTMLElement>(config.selector)
    if (!button) return
    const actionId = button.getAttribute(config.selector.slice(1, -1))
    const op = actionId && operations.get(actionId)
    const step = button.dataset.walletStep
    if (!op || !step || op.terminal) return
    const pressId = crypto.randomUUID()
    const held = structuredClone(op)
    const selected = activeEthereumWallet()
    if (!selected || selected.address.toLowerCase() !== held.signer.toLowerCase()) return
    const press = {operation: held, step, sent: false, selected: {...selected}, invalid: false}
    presses.set(pressId, press)
    const accounts = await selected.provider.request({method: "eth_accounts"}).catch(() => null)
    if (!Array.isArray(accounts) || typeof accounts[0] !== "string" || accounts[0].toLowerCase() !== held.signer.toLowerCase()) return
    if (!resolve(press)) return
    push("wallet_press_dispatch", {action_id: held.action_id, press_id: pressId, step, signer: held.signer})
  }
  hook.el.addEventListener("click", clicked)
  hook.handleEvent("wallet-press:send", async (p: Report) => {
    if (!mine(p)) return
    const held = presses.get(p.press_id)
    if (!held || held.sent || held.operation.action_id !== p.action_id || held.step !== p.step) return
    held.sent = true // duplicate delivery of THIS press only, not a wallet latch
    let started = false
    const base = {component_id: hook.el.id, action_id: p.action_id, press_id: p.press_id, step: p.step}
    // Durable browser uncertainty before the provider call, including a reload
    // while its prompt is open. Later hash/rejection replaces only this press.
    retainReport({...base, outcome: "submission_unknown"}, sessionStorage)
    try {
      const hash = await config.send(held.operation, held.step, () => {
        if (!resolve(held)) throw new Error("Wallet press is no longer current")
        started = true
      }, () => resolve(held))
      report({...base, transaction_hash: hash})
    } catch (error) {
      report({...base, outcome: !started ? "not_started" : userRejected(error) ? "not_sent" : "submission_unknown"})
    }
  })
  const cleanup = () => {
    disposed = true
    invalidate()
    hook.el.removeEventListener("click", clicked)
    window.removeEventListener("autolaunch:wallet-state", walletChanged)
  }
  return Object.assign(cleanup, {checkScope})
}
