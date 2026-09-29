import {activeEthereumWallet} from "../wallet_actions/connected_wallet"
import {userRejected} from "../wallet_actions/autolaunch_bids"

type Review = {action_id: string; signer: string; terminal: boolean; step?: string}
type Report = {component_id: string; action_id: string; press_id: string; step: string;
  transaction_hash?: string; outcome?: string}
type Hook = {el: HTMLElement; handleEvent(name: string, callback: (payload: any) => void): void;
  pushEventTo(target: HTMLElement, name: string, payload: unknown): void}
const key = "regent:autolaunch:wallet-reports:v2"

export function retainedReports(storage: Storage): Report[] {
  try { const reports = JSON.parse(storage.getItem(key) || "{}"); return Object.values(reports) }
  catch { return [] }
}
export function retainReport(report: Report, storage: Storage): void {
  try { const all = Object.fromEntries(retainedReports(storage).map(r => [r.press_id, r]));
    all[report.press_id] = report; storage.setItem(key, JSON.stringify(all)) } catch { /* connected report still sent */ }
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
  send(operation: O, step: string, started: () => void): Promise<string>;
}) {
  const operations = new Map<string, O>()
  const historyKey = `${key}:reviews:${hook.el.id}`
  let reviews: string[] = []
  try { reviews = JSON.parse(sessionStorage.getItem(historyKey) || "[]") } catch { /* no hints */ }
  const presses = new Map<string, {operation: O; step: string; sent: boolean}>()
  const push = (event: string, payload: unknown) => hook.pushEventTo(hook.el, event, payload)
  const mine = (p: {component_id?: string}) => !p.component_id || p.component_id === hook.el.id
  const report = (r: Report) => { retainReport(r, sessionStorage); push("wallet_press_report", r) }
  hook.handleEvent(`${config.prefix}:operation`, (op: O & {component_id?: string}) => {
    if (!mine(op)) return
    operations.set(op.action_id, structuredClone(op))
    if (!reviews.includes(op.action_id)) {
      reviews.push(op.action_id)
      try { sessionStorage.setItem(historyKey, JSON.stringify(reviews)) } catch { /* connected history remains */ }
    }
    push("wallet_press_restore", {action_id: op.action_id})
  })
  hook.handleEvent("wallet-press:durable", (r: Report) => { if (mine(r)) releaseReport(r, sessionStorage) })
  for (const action_id of reviews) push("wallet_press_restore", {action_id})
  for (const r of retainedReports(sessionStorage)) if (mine(r)) push("wallet_press_report", r)

  const clicked = async (event: Event) => {
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
    presses.set(pressId, {operation: held, step, sent: false})
    const selected = activeEthereumWallet()
    if (!selected || selected.address.toLowerCase() !== held.signer.toLowerCase()) return
    const accounts = await selected.provider.request({method: "eth_accounts"}).catch(() => null)
    if (!Array.isArray(accounts) || typeof accounts[0] !== "string" || accounts[0].toLowerCase() !== held.signer.toLowerCase()) return
    if (activeEthereumWallet()?.provider !== selected.provider) return
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
      const hash = await config.send(held.operation, held.step, () => { started = true })
      report({...base, transaction_hash: hash})
    } catch (error) {
      report({...base, outcome: !started ? "not_started" : userRejected(error) ? "not_sent" : "submission_unknown"})
    }
  })
  return () => hook.el.removeEventListener("click", clicked)
}
