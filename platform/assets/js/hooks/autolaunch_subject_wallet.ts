import {installWalletPresses} from "./wallet_presses"
import type {Hook} from "../hook_composition"
import {activeEthereumWallet} from "../wallet_actions/connected_wallet"
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
  publishActiveWallet?: () => void
}

/**
 * The wallet side of one subject action: this hook reports the active wallet
 * and sends whichever reviewed step the server hands it. There is no encoder
 * here; every byte comes from the reviewed operation.
 */
export const AutolaunchSubjectWallet: Hook = {
  mounted(this: SubjectWalletHook) {
    const push = (event: string, payload: unknown) => this.pushEventTo(this.el, event, payload)
    this.publishActiveWallet = () => push("subject_active_wallet", {address: activeEthereumWallet()?.address ?? null})
    window.addEventListener("autolaunch:wallet-state", this.publishActiveWallet)
    this.publishActiveWallet()
    this.removePressListener = installWalletPresses<SubjectWalletOperation>(this, {
      prefix: "autolaunch-subject-wallet", selector: "[data-subject-wallet-send]", connect: "[data-subject-wallet-connect]",
      send: (operation, step, started, resolveWallet) => sendSubjectStep(operation,
        sendableStep(operation, operation.action_id, step), resolveWallet, started),
    })
  },

  updated(this: SubjectWalletHook) {
    this.removePressListener?.checkScope()
  },

  destroyed(this: SubjectWalletHook) {
    this.removePressListener?.()
    if (this.publishActiveWallet) {
      window.removeEventListener("autolaunch:wallet-state", this.publishActiveWallet)
    }
  },
}
