import type { Hook } from "phoenix_live_view"

import { animate, stagger } from "../../vendor/anime.esm.js"
import { LocalStorage, Privy } from "../../vendor/privy-core.esm.js"
import {
  labelForUser,
  loginWithPrivyWallet,
  requireEthereumProvider,
  signWithConnectedWallet,
  type PrivyLike,
  type PrivyUser,
  walletForUser,
  walletsForUser,
} from "./privy-wallet.ts"

interface XmtpRoomElement extends HTMLElement {
  _xmtpCleanup?: () => void
  _xmtpHeartbeat?: number
  _xmtpMounted?: boolean
  _xmtpSeenKeys?: Set<string>
  _xmtpResetUi?: () => void
}

function csrfHeaders(): Record<string, string> {
  const csrf =
    document.querySelector<HTMLMetaElement>("meta[name='csrf-token']")?.content?.trim() || ""

  return csrf ? { "x-csrf-token": csrf } : {}
}

function syncSession(privy: PrivyLike, user: PrivyUser) {
  return privy.getAccessToken().then(async (token) => {
    if (!token) return false

    const response = await fetch("/api/auth/privy/session", {
      method: "POST",
      headers: {
        accept: "application/json",
        "content-type": "application/json",
        authorization: `Bearer ${token}`,
        ...csrfHeaders(),
      },
      credentials: "same-origin",
      body: JSON.stringify({
        display_name: labelForUser(user),
        wallet_address: walletForUser(user),
        wallet_addresses: walletsForUser(user),
      }),
    })

    return response.ok
  })
}

async function clearSession() {
  await fetch("/api/auth/privy/session", {
    method: "DELETE",
    headers: {
      accept: "application/json",
      ...csrfHeaders(),
    },
    credentials: "same-origin",
  })
}

function boolAttr(value: string | undefined): boolean {
  return value === "true"
}

export const PrivyXmtpRoom: Hook = {
  mounted() {
    const root = this.el as XmtpRoomElement
    root._xmtpMounted = true

    const authButton = root.querySelector<HTMLButtonElement>("[data-xmtp-auth]")
    const joinButton = root.querySelector<HTMLButtonElement>("[data-xmtp-join]")
    const sendButton = root.querySelector<HTMLButtonElement>("[data-xmtp-send]")
    const input = root.querySelector<HTMLInputElement>("[data-xmtp-input]")
    const state = root.querySelector<HTMLElement>("[data-xmtp-state]")
    const appId = root.dataset.privyAppId?.trim() || ""

    if (!authButton || !sendButton || !input || !state || appId.length === 0) return

    const privy = new Privy({ appId, clientId: appId, storage: new LocalStorage() }) as unknown as PrivyLike
    let currentUser: PrivyUser = null
    let joining = false
    let sending = false

    const setState = (message: string) => {
      if (!root._xmtpMounted || state.textContent === message) return
      state.textContent = message
      animate(state, {
        opacity: [0.55, 1],
        translateY: [-3, 0],
        duration: 260,
        ease: "outQuad",
      })
    }

    const sessionReady = () => {
      return typeof root.dataset.connectedWallet === "string" && root.dataset.connectedWallet.length > 0
    }

    const canJoin = () => boolAttr(root.dataset.canJoin)
    const canSend = () => boolAttr(root.dataset.canSend)
    const membershipState = () => root.dataset.membershipState || "view_only"

    const stopHeartbeat = () => {
      if (root._xmtpHeartbeat) {
        window.clearInterval(root._xmtpHeartbeat)
        delete root._xmtpHeartbeat
      }
    }

    const syncHeartbeat = () => {
      if (membershipState() !== "joined") {
        stopHeartbeat()
        return
      }

      if (root._xmtpHeartbeat) return

      this.pushEvent("xmtp_heartbeat", {})
      root._xmtpHeartbeat = window.setInterval(() => {
        if (!root._xmtpMounted) return
        this.pushEvent("xmtp_heartbeat", {})
      }, 30_000)
    }

    const syncUiState = () => {
      const authenticated = Boolean(currentUser?.id)
      authButton.disabled = false
      authButton.textContent = authenticated ? `Disconnect ${labelForUser(currentUser)}` : "Connect wallet with Privy"

      if (joinButton) {
        joinButton.disabled = !sessionReady() || !canJoin() || joining
        joinButton.textContent = joining ? "Joining chat..." : "Join Chat"
      }

      input.disabled = !canSend() || sending
      sendButton.disabled = !canSend() || sending || input.value.trim().length === 0
      sendButton.textContent = sending ? "Sending to XMTP..." : "Send to the Autolaunch wire"
      syncHeartbeat()
    }

    root._xmtpResetUi = () => {
      joining = false
      sending = false
      syncUiState()
    }

    const refreshUser = async () => {
      const result = await privy.user.get()
      currentUser = (result?.user as PrivyUser) || null
      syncUiState()
    }

    const toggleAuth = async () => {
      const result = await privy.user.get()
      const user = (result?.user as PrivyUser) || null

      if (user?.id) {
        await privy.auth.logout({ userId: user.id })
        await clearSession()
        window.location.reload()
        return
      }

      const provider = await requireEthereumProvider()
      setState("Requesting your Privy wallet sign-in...")
      await loginWithPrivyWallet(privy, provider)
      const refreshed = await privy.user.get()
      const refreshedUser = (refreshed?.user as PrivyUser) || null

      if (!refreshedUser?.id) {
        throw new Error("Privy wallet sign-in did not return a user.")
      }

      await syncSession(privy, refreshedUser)
      window.location.reload()
    }

    const requestJoin = async () => {
      if (joining || !canJoin()) {
        syncUiState()
        return
      }

      joining = true
      setState("Checking seat availability in the private room...")
      syncUiState()
      this.pushEvent("xmtp_join", {})
    }

    const sendMessage = async () => {
      const body = input.value.trim()
      if (body.length === 0 || sending || !canSend()) {
        syncUiState()
        return
      }

      sending = true
      setState("Sending into the private XMTP room...")
      syncUiState()
      this.pushEvent("xmtp_send", { body })
    }

    this.handleEvent("xmtp:sign-request", async (payload) => {
      const { request_id, signature_text, wallet_address } = payload as {
        request_id: string
        signature_text: string
        wallet_address?: string | null
      }

      try {
        setState("Sign the XMTP identity message in your wallet.")
        const provider = await requireEthereumProvider()
        const { signature } = await signWithConnectedWallet(
          provider,
          String(signature_text ?? ""),
          typeof wallet_address === "string" ? wallet_address : null,
        )
        setState("Signature accepted. Joining the private room...")
        this.pushEvent("xmtp_join_signature_signed", {
          request_id,
          signature,
        })
      } catch (error) {
        const message =
          error instanceof Error ? error.message : "Wallet signing failed before XMTP could start."
        setState(message)
        joining = false
        syncUiState()
        this.pushEvent("xmtp_join_signature_failed", { message })
      }
    })

    const animateEntries = (initial: boolean) => {
      const seenKeys = root._xmtpSeenKeys ?? new Set<string>()
      const entries = Array.from(root.querySelectorAll<HTMLElement>("[data-xmtp-entry]"))
      const newEntries = entries.filter((entry) => {
        const key = entry.dataset.messageKey || entry.id
        if (seenKeys.has(key)) return false
        seenKeys.add(key)
        return true
      })

      root._xmtpSeenKeys = seenKeys

      if (!initial && newEntries.length > 0) {
        animate(newEntries, {
          opacity: [0, 1],
          translateY: [18, 0],
          scale: [0.97, 1],
          delay: stagger(70),
          duration: 520,
          ease: "outExpo",
        })
      }
    }

    const onInput = () => syncUiState()
    const onAuth = () => void toggleAuth().catch((error) => setState(error instanceof Error ? error.message : "Wallet sign-in failed."))
    const onJoin = () => void requestJoin()
    const onSend = () => void sendMessage()
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key !== "Enter" || event.shiftKey) return
      event.preventDefault()
      void sendMessage()
    }

    input.addEventListener("input", onInput)
    input.addEventListener("keydown", onKeyDown)
    authButton.addEventListener("click", onAuth)
    joinButton?.addEventListener("click", onJoin)
    sendButton.addEventListener("click", onSend)

    void (async () => {
      await privy.initialize()
      await refreshUser()
      animateEntries(true)
    })()
      .catch((error) => setState(error instanceof Error ? error.message : "Privy is unavailable."))
      .finally(() => syncUiState())

    root._xmtpCleanup = () => {
      root._xmtpMounted = false
      stopHeartbeat()
      input.removeEventListener("input", onInput)
      input.removeEventListener("keydown", onKeyDown)
      authButton.removeEventListener("click", onAuth)
      joinButton?.removeEventListener("click", onJoin)
      sendButton.removeEventListener("click", onSend)
    }
  },

  updated() {
    const root = this.el as XmtpRoomElement
    root._xmtpResetUi?.()
    const seenKeys = root._xmtpSeenKeys ?? new Set<string>()
    root._xmtpSeenKeys = seenKeys

    const entries = Array.from(root.querySelectorAll<HTMLElement>("[data-xmtp-entry]"))
    const newEntries = entries.filter((entry) => {
      const key = entry.dataset.messageKey || entry.id
      if (seenKeys.has(key)) return false
      seenKeys.add(key)
      return true
    })

    if (newEntries.length > 0) {
      animate(newEntries, {
        opacity: [0, 1],
        translateY: [18, 0],
        scale: [0.97, 1],
        delay: stagger(70),
        duration: 520,
        ease: "outExpo",
      })
    }
  },

  destroyed() {
    const root = this.el as XmtpRoomElement
    root._xmtpCleanup?.()
  },
}
