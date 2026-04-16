import type { Hook } from "phoenix_live_view"

interface WalletSwitchRoot extends HTMLElement {
  _walletSwitchContinue?: (event: Event) => void
  _walletSwitchError?: EventListener
}

function statusNode(root: HTMLElement): HTMLElement | null {
  return root.querySelector<HTMLElement>("[data-wallet-switch-status]")
}

export const WalletSwitchModal: Hook = {
  mounted() {
    const root = this.el as WalletSwitchRoot
    const targetWallet = root.dataset.walletSwitchAddress?.trim().toLowerCase()
    const continueButton = root.querySelector<HTMLButtonElement>("[data-wallet-switch-continue]")

    if (!targetWallet || !continueButton) return

    const onContinue = () => {
      statusNode(root)?.replaceChildren("Open your wallet and confirm the switch to continue.")
      window.dispatchEvent(
        new CustomEvent("autolaunch:switch-wallet", { detail: { walletAddress: targetWallet } }),
      )
    }

    const onError: EventListener = (event) => {
      const customEvent = event as CustomEvent<{ message?: string }>
      const message = customEvent.detail?.message?.trim()
      if (message) statusNode(root)?.replaceChildren(message)
    }

    root._walletSwitchContinue = onContinue
    root._walletSwitchError = onError

    continueButton.addEventListener("click", onContinue)
    window.addEventListener("autolaunch:wallet-switch-error", onError)
  },

  destroyed() {
    const root = this.el as WalletSwitchRoot
    const continueButton = root.querySelector<HTMLButtonElement>("[data-wallet-switch-continue]")

    if (root._walletSwitchContinue && continueButton) {
      continueButton.removeEventListener("click", root._walletSwitchContinue)
    }

    if (root._walletSwitchError) {
      window.removeEventListener("autolaunch:wallet-switch-error", root._walletSwitchError)
    }
  },
}
