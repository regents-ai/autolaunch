import {installWalletPresses} from "./wallet_presses"
import type {Hook} from "../hook_composition"
import {activeEthereumWallet} from "../wallet_actions/connected_wallet"
import {
  sendLabTransaction,
  type AutolaunchLabAnchor,
  type AutolaunchLabBinding,
  type WalletResolver,
} from "../wallet_actions/autolaunch_network"
import type {Address, Hash, Hex} from "viem"

const pendingKey = "regent:autolaunch-fee-admin:open"

/**
 * The reviewed fee-administration action exactly as the server wrote it: one
 * `action` step on the local lab. The browser holds it only to check that what
 * it is asked to send belongs to this review; there is no encoder here.
 */
export type FeeAdminOperation = {
  action_id: string
  signer: Address
  chain_id: number
  lab: AutolaunchLabBinding | null
  lab_anchor: AutolaunchLabAnchor | null
  terminal: boolean
  steps: {step: string; to: Address; data: Hex}[]
}

type FeeAdminHook = Hook & {
  el: HTMLElement
  handleEvent(event: string, callback: (payload: unknown) => void): void
  pushEventTo(target: HTMLElement, event: string, payload: unknown): void
  removePressListener?: ReturnType<typeof installWalletPresses>
  publishActiveWallet?: () => void
}

export const AutolaunchFeeAdminWallet: Hook = {
  mounted(this: FeeAdminHook) {
    const push = (event: string, payload: unknown) => this.pushEventTo(this.el, event, payload)
    this.publishActiveWallet = () =>
      push("fee_admin_active_wallet", {address: activeEthereumWallet()?.address ?? null})
    window.addEventListener("autolaunch:wallet-state", this.publishActiveWallet)
    this.publishActiveWallet()
    if (stored(pendingKey)) push("restore_fee_admin_operation", {})
    this.removePressListener = installWalletPresses<FeeAdminOperation>(this, {
      prefix: "autolaunch-fee-admin",
      selector: "[data-fee-admin-send]",
      connect: "[data-fee-admin-connect]",
      send: (operation, step, started, resolveWallet) =>
        sendFeeAdminStep(operation, step, resolveWallet, started),
    })
    this.handleEvent("autolaunch-fee-admin:operation", payload => {
      const op = payload as FeeAdminOperation & {component_id?: string}
      if (!op.component_id || op.component_id === this.el.id) rememberOperation(op)
    })
  },

  updated(this: FeeAdminHook) {
    this.removePressListener?.checkScope()
  },

  destroyed(this: FeeAdminHook) {
    this.removePressListener?.()
    if (this.publishActiveWallet) {
      window.removeEventListener("autolaunch:wallet-state", this.publishActiveWallet)
    }
  },
}

/** Sends the one reviewed step through the selected wallet on the local lab. */
export function sendFeeAdminStep(
  operation: FeeAdminOperation,
  stepName: string,
  resolveWallet: WalletResolver,
  onSendStarted: () => void,
): Promise<Hash> {
  if (operation.terminal) throw new Error("This action has already finished.")
  const step = operation.steps.find(candidate => candidate.step === stepName)
  if (!step) throw new Error("This step is not part of the reviewed action.")
  if (!/^0x[0-9a-f]+$/.test(step.data)) throw new Error("The reviewed transaction changed.")
  return sendLabTransaction(operation, step, resolveWallet, onSendStarted)
}

/** The recovery hint only: which review a reload should ask the server about. */
function rememberOperation(operation: FeeAdminOperation): void {
  try {
    if (operation.terminal) sessionStorage.removeItem(pendingKey)
    else sessionStorage.setItem(pendingKey, operation.action_id)
  } catch {
    // The connected LiveView already holds the operation; this is refresh only.
  }
}

function stored(key: string): string | null {
  try {
    return sessionStorage.getItem(key)
  } catch {
    return null
  }
}
