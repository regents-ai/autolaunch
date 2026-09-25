import {installWalletPresses} from "./wallet_presses"
import {reportBrowserWallets} from "./browser_wallets"
import type {Hook} from "../hook_composition"
import {sendBidStep, sendableStep, type BidOperation} from "../wallet_actions/autolaunch_bids"

type SettlementHook = Hook & {
  el: HTMLElement
  handleEvent(event: string, callback: (payload: unknown) => void): void
  pushEventTo(target: HTMLElement, event: string, payload: unknown): void
  removePressListener?: ReturnType<typeof installWalletPresses>
  stopReporting?: () => void
}

/**
 * The wallet side of settling one bid position after its auction ended: the
 * server reviews the exit and claim steps, this hook reports the connected wallets
 * and sends whichever reviewed step the server hands it, exactly as a bid.
 * There is no encoder here; every byte comes from the reviewed operation.
 */
export const AutolaunchBidSettlement: Hook = {
  mounted(this: SettlementHook) {
    const push = (event: string, payload: unknown) => this.pushEventTo(this.el, event, payload)
    this.stopReporting = reportBrowserWallets(push)
    this.removePressListener = installWalletPresses<BidOperation>(this, {
      prefix: "autolaunch-settlement",
      selector: "[data-settlement-send]",
      send: (operation, step, started, resolveWallet) =>
        sendBidStep(operation, sendableStep(operation, operation.action_id, step), resolveWallet, started),
    })
  },

  updated(this: SettlementHook) {
    this.removePressListener?.checkScope()
  },

  destroyed(this: SettlementHook) {
    this.removePressListener?.()
    this.stopReporting?.()
  },
}
