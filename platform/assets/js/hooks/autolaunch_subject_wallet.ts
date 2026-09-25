import {installWalletPresses} from "./wallet_presses"
import {reportBrowserWallets} from "./browser_wallets"
import type {Hook} from "../hook_composition"
import {
  sendSubjectStep,
  sendableStep,
  type SubjectWalletOperation,
} from "../wallet_actions/autolaunch_subject_wallet"

type SubjectWalletHook = Hook & {
  el: HTMLElement
  handleEvent(event: string, callback: (payload: unknown) => void): void
  pushEventTo(target: HTMLElement, event: string, payload: unknown): void
  removePressListener?: ReturnType<typeof installWalletPresses>
  stopReporting?: () => void
}

/**
 * The wallet side of one subject action: this hook reports the connected wallets
 * and sends whichever reviewed step the server hands it. There is no encoder
 * here; every byte comes from the reviewed operation.
 */
export const AutolaunchSubjectWallet: Hook = {
  mounted(this: SubjectWalletHook) {
    const push = (event: string, payload: unknown) => this.pushEventTo(this.el, event, payload)
    this.stopReporting = reportBrowserWallets(push)
    this.removePressListener = installWalletPresses<SubjectWalletOperation>(this, {
      prefix: "autolaunch-subject-wallet", selector: "[data-subject-wallet-send]",
      send: (operation, step, started, resolveWallet) => sendSubjectStep(operation,
        sendableStep(operation, operation.action_id, step), resolveWallet, started),
    })
  },

  updated(this: SubjectWalletHook) {
    this.removePressListener?.checkScope()
  },

  destroyed(this: SubjectWalletHook) {
    this.removePressListener?.()
    this.stopReporting?.()
  },
}
