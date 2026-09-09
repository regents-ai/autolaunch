import {installWalletPresses} from "./wallet_presses"
import type {Hook} from "../hook_composition"
import {activeEthereumWallet} from "../wallet_actions/connected_wallet"
import {sendBidStep, sendableStep, type BidOperation} from "../wallet_actions/autolaunch_bids"

type SettlementHook = Hook & {
  el: HTMLElement
  handleEvent(event: string, callback: (payload: unknown) => void): void
  pushEventTo(target: HTMLElement, event: string, payload: unknown): void
  removePressListener?: ReturnType<typeof installWalletPresses>
  publishActiveWallet?: () => void
}

/**
 * The wallet side of settling one bid position after its auction ended: the
 * server reviews the exit and claim steps, this hook reports the active wallet
 * and sends whichever reviewed step the server hands it, exactly as a bid.
 * There is no encoder here; every byte comes from the reviewed operation.
 */
export const AutolaunchBidSettlement: Hook = {
  mounted(this: SettlementHook) {
    const push = (event: string, payload: unknown) => this.pushEventTo(this.el, event, payload)
    this.publishActiveWallet = () =>
      push("settlement_active_wallet", {address: activeEthereumWallet()?.address ?? null})
    window.addEventListener("autolaunch:wallet-state", this.publishActiveWallet)
    this.publishActiveWallet()
    this.removePressListener = installWalletPresses<BidOperation>(this, {
      prefix: "autolaunch-settlement",
      selector: "[data-settlement-send]",
      connect: "[data-settlement-connect]",
      send: (operation, step, started, resolveWallet) =>
        sendBidStep(operation, sendableStep(operation, operation.action_id, step), resolveWallet, started),
    })
  },

  updated(this: SettlementHook) {
    this.removePressListener?.checkScope()
  },

  destroyed(this: SettlementHook) {
    this.removePressListener?.()
    if (this.publishActiveWallet) {
      window.removeEventListener("autolaunch:wallet-state", this.publishActiveWallet)
    }
  },
}
