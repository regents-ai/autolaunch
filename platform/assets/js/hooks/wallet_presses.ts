import {activeEthereumWallet, type SelectedWallet} from "../wallet_actions/connected_wallet"
import {userRejected} from "../wallet_actions/autolaunch_bids"

type Review = {action_id: string; signer: string; terminal: boolean; step?: string}
type Report = {component_id: string; action_id: string; press_id: string; step: string;
  transaction_hash?: string; outcome?: string}
type Hook = {el: HTMLElement; handleEvent(name: string, callback: (payload: any) => void): void;
  pushEventTo(target: HTMLElement, name: string, payload: unknown): void}

/** A click captures review + step before any await. Only that click can consume
 * its authorization. Nothing is kept in the browser: a reload starts from the
 * server's own record and never replays a report or a send. */
export function installWalletPresses<O extends Review>(hook: Hook, config: {
  prefix: string; selector: string; connect: string;
  send(operation: O, step: string, started: () => void, resolveWallet: () => SelectedWallet | null): Promise<string>;
}) {
  let disposed = false
  let scope = hook.el.dataset?.walletScope
  const operations = new Map<string, O>()
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
  const report = (r: Report) => push("wallet_press_report", r)
  hook.handleEvent(`${config.prefix}:operation`, (op: O & {component_id?: string}) => {
    if (disposed || !mine(op)) return
    checkScope()
    operations.set(op.action_id, structuredClone(op))
  })
  hook.handleEvent("wallet-press:invalidated", p => { if (mine(p)) invalidate() })

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
