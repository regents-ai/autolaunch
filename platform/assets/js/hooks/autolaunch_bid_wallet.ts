import {installWalletPresses} from "./wallet_presses"
import {reportBrowserWallets} from "./browser_wallets"
import {builtFor, formOnScreen, type BidInputs} from "./bid_form_on_screen"
import type {Hook} from "../hook_composition"
import {sendBidStep, sendableStep, type BidOperation} from "../wallet_actions/autolaunch_bids"

type BidHook = Hook & {
  el: HTMLElement
  handleEvent(event: string, callback: (payload: unknown) => void): void
  pushEventTo(target: HTMLElement, event: string, payload: unknown): void
  removePressListener?: ReturnType<typeof installWalletPresses>
  stopReporting?: () => void
}

/**
 * The wallet side of one bid: this hook reports the connected wallets and sends
 * whichever reviewed step the server hands it. There is no encoder here; every
 * byte comes from the reviewed operation.
 */
export const AutolaunchBidWallet: Hook = {
  mounted(this: BidHook) {
    const push = (event: string, payload: unknown) => this.pushEventTo(this.el, event, payload)
    this.stopReporting = reportBrowserWallets(push)
    this.removePressListener = installWalletPresses<BidOperation & {inputs?: BidInputs}>(this, {
      prefix: "autolaunch-bid", selector: "[data-bid-send]",
      send: (operation, step, started, resolveWallet) => sendBidStep(operation,
        sendableStep(operation, operation.action_id, step), resolveWallet, started),
      // A bid form on screen that differs from the review held for it: the
      // server builds the bid for exactly these values and sends it back to press.
      claim: operation => {
        const form = formOnScreen(this.el)
        if (!form || builtFor(operation?.inputs, form)) return false
        push("prepare_and_send", {form})
        return true
      },
    })
  },

  updated(this: BidHook) {
    this.removePressListener?.checkScope()
  },

  destroyed(this: BidHook) {
    this.removePressListener?.()
    this.stopReporting?.()
  },
}
