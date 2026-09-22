import {installWalletPresses} from "./wallet_presses"
import type {Hook} from "../hook_composition"
import {activeEthereumWallet} from "../wallet_actions/connected_wallet"
import {sendLaunchStep, sendableStep, type LaunchOperation} from "../wallet_actions/autolaunch_launch"

type LaunchWalletHook = Hook & {
  el: HTMLElement
  handleEvent(event: string, callback: (payload: unknown) => void): void
  pushEventTo(target: HTMLElement, event: string, payload: unknown): void
  removePressListener?: ReturnType<typeof installWalletPresses>
  publishActiveWallet?: () => void
}

/**
 * The wallet side of one launch: this hook reports the active wallet and sends
 * the reviewed launch step the server hands it. There is no encoder here; every
 * byte comes from the reviewed operation.
 */
export const AutolaunchLaunchWallet: Hook = {
  mounted(this: LaunchWalletHook) {
    const push = (event: string, payload: unknown) => this.pushEventTo(this.el, event, payload)
    this.publishActiveWallet = () => push("launch_active_wallet", {address: activeEthereumWallet()?.address ?? null})
    window.addEventListener("autolaunch:wallet-state", this.publishActiveWallet)
    this.publishActiveWallet()
    this.removePressListener = installWalletPresses<LaunchOperation>(this, {
      prefix: "autolaunch-launch", selector: "[data-launch-wallet-send]", connect: "[data-launch-wallet-connect]",
      send: (operation, step, started, resolveWallet) => sendLaunchStep(operation,
        sendableStep(operation, operation.action_id, step), resolveWallet, started),
    })
  },

  updated(this: LaunchWalletHook) {
    this.removePressListener?.checkScope()
  },

  destroyed(this: LaunchWalletHook) {
    this.removePressListener?.()
    if (this.publishActiveWallet) {
      window.removeEventListener("autolaunch:wallet-state", this.publishActiveWallet)
    }
  },
}
