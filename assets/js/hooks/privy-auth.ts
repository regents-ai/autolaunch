import type { Hook } from "phoenix_live_view"

import { LocalStorage, Privy } from "../../vendor/privy-core.esm.js"
import {
  labelForUser,
  loginWithPrivyWallet,
  requireEthereumProvider,
  type PrivyLike,
  type PrivyUser,
  walletForUser,
  walletsForUser,
} from "./privy-wallet.ts"

const SESSION_ENDPOINT = "/api/auth/privy/session"

interface PrivyAuthRoot extends HTMLElement {
  _walletSwitchListener?: EventListener
}

function csrfHeaders(csrfToken: string): Record<string, string> {
  return csrfToken ? { "x-csrf-token": csrfToken } : {}
}

export const PrivyAuth: Hook = {
  async mounted() {
    const root = this.el as PrivyAuthRoot
    const button = this.el.querySelector<HTMLElement>("[data-privy-action='toggle']")
    const state = this.el.querySelector<HTMLElement>("[data-privy-state]")
    const appId = this.el.dataset.privyAppId || ""
    const sessionState = this.el.dataset.sessionState || "missing"

    if (!button || !state || appId.trim() === "") return

    const csrfToken =
      document.querySelector<HTMLMetaElement>("meta[name='csrf-token']")?.content?.trim() || ""

    const privy = new Privy({ appId, clientId: appId, storage: new LocalStorage() }) as unknown as PrivyLike

    const syncSession = async (user: PrivyUser) => {
      const token = await privy.getAccessToken()
      if (!token) return false

      const response = await fetch(SESSION_ENDPOINT, {
        method: "POST",
        headers: {
          accept: "application/json",
          "content-type": "application/json",
          authorization: `Bearer ${token}`,
          ...csrfHeaders(csrfToken),
        },
        credentials: "same-origin",
        body: JSON.stringify({
          display_name: labelForUser(user),
          wallet_address: walletForUser(user),
          wallet_addresses: walletsForUser(user),
        }),
      })

      return response.ok
    }

    const clearSession = async () => {
      await fetch(SESSION_ENDPOINT, {
        method: "DELETE",
        headers: {
          accept: "application/json",
          ...csrfHeaders(csrfToken),
        },
        credentials: "same-origin",
      })
    }

    const refreshState = async () => {
      const result = await privy.user.get()
      const user = result?.user as PrivyUser
      state.textContent = user ? labelForUser(user) : "guest"
      button.textContent = user ? "Disconnect wallet" : "Connect wallet"
      return user
    }

    const loginAndSync = async (expectedWallet?: string | null) => {
      const provider = await requireEthereumProvider()
      await loginWithPrivyWallet(privy, provider, expectedWallet)

      const next = await privy.user.get()
      const nextUser = next?.user as PrivyUser

      if (!nextUser?.id) {
        throw new Error("Privy wallet sign-in did not return a user.")
      }

      const synced = await syncSession(nextUser)
      if (!synced) {
        throw new Error("Wallet sign-in could not be saved.")
      }

      return nextUser
    }

    const toggleAuth = async () => {
      const current = await privy.user.get()
      const currentUser = current?.user as PrivyUser

      if (currentUser?.id) {
        await privy.auth.logout({ userId: currentUser.id })
        await clearSession()
        window.location.reload()
        return
      }

      const nextUser = await loginAndSync()
      if (nextUser.id || sessionState === "missing") {
        window.location.reload()
      }
    }

    const switchWallet = async (targetWallet: string) => {
      const current = await privy.user.get()
      const currentUser = current?.user as PrivyUser

      if (currentUser?.id) {
        await privy.auth.logout({ userId: currentUser.id })
        await clearSession()
      }

      await loginAndSync(targetWallet)
      window.location.reload()
    }

    const walletSwitchListener: EventListener = (event) => {
      const customEvent = event as CustomEvent<{ walletAddress?: string }>
      const targetWallet = customEvent.detail?.walletAddress?.trim().toLowerCase()

      if (!targetWallet) return

      state.textContent = `Switch to ${targetWallet} in your wallet to continue.`

      void switchWallet(targetWallet).catch((error) => {
        const message =
          error instanceof Error ? error.message : "Wallet switch could not be completed."

        state.textContent = message
        window.dispatchEvent(
          new CustomEvent("autolaunch:wallet-switch-error", { detail: { message } }),
        )
      })
    }

    root._walletSwitchListener = walletSwitchListener
    window.addEventListener("autolaunch:switch-wallet", walletSwitchListener)

    button.addEventListener("click", () => {
      void toggleAuth().catch((error) => {
        console.error("Privy wallet auth failed", error)
        state.textContent = error instanceof Error ? error.message : "Wallet sign-in failed."
      })
    })

    await privy.initialize()
    const user = await refreshState()

    if (user?.id) {
      const synced = await syncSession(user)
      if (synced && sessionState === "missing") {
        window.location.reload()
      }
    }
  },

  destroyed() {
    const root = this.el as PrivyAuthRoot

    if (root._walletSwitchListener) {
      window.removeEventListener("autolaunch:switch-wallet", root._walletSwitchListener)
    }
  },
}
