import type { Hook } from "phoenix_live_view"

import { LocalStorage, Privy } from "../../vendor/privy-core.esm.js"
import {
  labelForUser,
  loginWithPrivyWallet,
  requireEthereumProvider,
  type PrivyLike,
  type PrivyUser,
  walletForUser,
} from "./privy-wallet.ts"

const SESSION_ENDPOINT = "/api/auth/privy/session"

function csrfHeaders(csrfToken: string): Record<string, string> {
  return csrfToken ? { "x-csrf-token": csrfToken } : {}
}

export const PrivyAuth: Hook = {
  async mounted() {
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

    const toggleAuth = async () => {
      const current = await privy.user.get()
      const currentUser = current?.user as PrivyUser

      if (currentUser?.id) {
        await privy.auth.logout({ userId: currentUser.id })
        await clearSession()
        window.location.reload()
        return
      }

      const provider = await requireEthereumProvider()
      await loginWithPrivyWallet(privy, provider)
      const next = await privy.user.get()
      const nextUser = next?.user as PrivyUser

      if (!nextUser?.id) {
        throw new Error("Privy wallet sign-in did not return a user.")
      }

      const synced = await syncSession(nextUser)
      if (synced || sessionState === "missing") {
        window.location.reload()
      }
    }

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
}
