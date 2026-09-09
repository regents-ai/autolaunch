import type {Hook} from "../hook_composition"
import {activeEthereumWallet} from "../wallet_actions/connected_wallet"

type ElementHook = Hook & {
  el: HTMLElement
  pushEventTo(target: HTMLElement, event: string, payload: unknown): void
  publishActiveWallet?: () => void
}

/** The browser's IANA time zone, or UTC when the browser will not say. */
export function browserTimeZone(resolved: () => string | undefined = () =>
  Intl.DateTimeFormat().resolvedOptions().timeZone): string {
  try {
    const zone = resolved()
    return typeof zone === "string" && zone !== "" ? zone : "Etc/UTC"
  } catch {
    return "Etc/UTC"
  }
}

/**
 * Fills the time-zone field beside the "Bidding opens" control with the
 * browser's zone when it is empty. A zone already typed or saved on the draft
 * is kept, so the stored instant never silently moves.
 */
export function fillZonedStart(root: ParentNode, zone: string): string {
  const field = root.querySelector<HTMLInputElement>("[data-zoned-start-timezone]")
  if (!field) return zone
  if (field.value === "") field.value = zone
  return field.value
}

export const AutolaunchZonedStart: Hook = {
  mounted(this: ElementHook) {
    fillZonedStart(this.el, browserTimeZone())
  },
  updated(this: ElementHook) {
    fillZonedStart(this.el, browserTimeZone())
  },
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
