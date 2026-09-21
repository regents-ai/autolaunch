import type {Hook} from "../hook_composition"
import {activeEthereumWallet} from "../wallet_actions/connected_wallet"

type ElementHook = Hook & {
  el: HTMLElement
  pushEventTo(target: HTMLElement, event: string, payload: unknown): void
  publishActiveWallet?: () => void
}

/** Tells the test-funds panel which wallet is selected, whenever that changes. */
export const AutolaunchTestFunds: Hook = {
  mounted(this: ElementHook) {
    this.publishActiveWallet = () =>
      this.pushEventTo(this.el, "test_funds_wallet", {address: activeEthereumWallet()?.address ?? null})
    window.addEventListener("autolaunch:wallet-state", this.publishActiveWallet)
    this.publishActiveWallet()
  },
  destroyed(this: ElementHook) {
    if (this.publishActiveWallet) {
      window.removeEventListener("autolaunch:wallet-state", this.publishActiveWallet)
    }
  },
}
