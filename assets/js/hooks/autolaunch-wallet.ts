import type { Hook } from "phoenix_live_view"

import { formatPrivySessionErrorMessage } from "./wallet-bridge-privy"
import {
  disconnectFailureNotice,
  type WalletNoticeTone,
} from "./wallet-bridge-state"
import {
  clearPrivySession,
  getWalletBridgeState,
  syncPrivySessionOnce,
  walletReadyForBridgeSession,
  WALLET_EXTENSION_ACCOUNT_CHANGED_EVENT,
  WALLET_SIGNATURE_REQUEST_EVENT,
  WALLET_STATE_EVENT,
} from "./wallet-bridge-runtime"
import {
  getErrorMessage,
  normalizeWalletAddress,
  parseConfig,
  privyDebugLog,
  redactWalletForDebug,
  shortWallet,
} from "./wallet-bridge-shared"

interface AutolaunchWalletElement extends HTMLElement {
  __autolaunchWalletCleanup?: () => void
}

type BridgeEventDetail = {
  privyReady?: boolean
  authenticated?: boolean
  isModalOpen?: boolean
  account?: string | null
  chainId?: number | null
}

export const AutolaunchWallet: Hook = {
  mounted() {
    mountWalletController(this.el as AutolaunchWalletElement)
  },

  updated() {
    mountWalletController(this.el as AutolaunchWalletElement)
  },

  destroyed() {
    const el = this.el as AutolaunchWalletElement
    el.__autolaunchWalletCleanup?.()
    el.__autolaunchWalletCleanup = undefined
  },
}

function mountWalletController(el: AutolaunchWalletElement) {
  el.__autolaunchWalletCleanup?.()
  el.__autolaunchWalletCleanup = bindAutolaunchWallet(el)
}

function bindAutolaunchWallet(el: HTMLElement): () => void {
  const config = parseConfig(el.dataset.autolaunchConfig)
  const connectButtons = Array.from(el.querySelectorAll<HTMLButtonElement>("[data-wallet-connect]"))
  const disconnectButtons = Array.from(
    el.querySelectorAll<HTMLButtonElement>("[data-wallet-disconnect]"),
  )
  const labels = Array.from(el.querySelectorAll<HTMLElement>("[data-wallet-label]"))
  const notices = Array.from(el.querySelectorAll<HTMLElement>("[data-wallet-notice]"))

  let serverSessionActive = el.dataset.walletSignedIn === "true"
  let serverAddress = normalizeWalletAddress(el.dataset.walletAddress)
  let pendingConnect = false
  let disconnecting = false
  let sessionSyncing = false

  const showNotice = (message: string, tone: WalletNoticeTone = "info") => {
    notices.forEach((notice) => {
      notice.hidden = false
      notice.textContent = message
      notice.dataset.tone = tone
    })
  }

  const clearNotice = () => {
    notices.forEach((notice) => {
      notice.hidden = true
      notice.textContent = ""
      delete notice.dataset.tone
    })
  }

  const setButtonsBusy = (busy: boolean) => {
    connectButtons.forEach((button) => {
      button.disabled = busy
    })
    disconnectButtons.forEach((button) => {
      button.disabled = busy
    })
  }

  const renderWalletState = (detail?: BridgeEventDetail) => {
    const walletState = getWalletBridgeState()
    const browserAddress =
      normalizeWalletAddress(detail?.account ?? null) ?? normalizeWalletAddress(walletState.account)
    const labelAddress = serverAddress ?? browserAddress

    labels.forEach((label) => {
      label.textContent = labelAddress ? shortWallet(labelAddress) : "Wallet"
    })

    if ((serverSessionActive || walletState.authenticated) && !disconnecting) {
      clearNotice()
    }
  }

  const syncSessionAndReload = async (label: string) => {
    if (!config?.privySession || sessionSyncing) return
    sessionSyncing = true
    setButtonsBusy(true)
    showNotice(label, "info")

    try {
      const session = await syncPrivySessionOnce(config.privySession)
      serverSessionActive = true
      serverAddress =
        normalizeWalletAddress(session.human?.wallet_address ?? null) ??
        normalizeWalletAddress(getWalletBridgeState().account)
      window.location.reload()
    } catch (error) {
      sessionSyncing = false
      pendingConnect = false
      setButtonsBusy(false)
      showNotice(formatPrivySessionErrorMessage(error), "error")
    }
  }

  const maybeSyncSession = async () => {
    if (serverSessionActive || disconnecting || !walletReadyForBridgeSession()) return
    await syncSessionAndReload(pendingConnect ? "Finishing sign in..." : "Restoring sign in...")
  }

  const onState = (event: Event) => {
    const detail = (event as CustomEvent<BridgeEventDetail>).detail
    const walletState = getWalletBridgeState()
    const eventAccount =
      normalizeWalletAddress(detail?.account ?? null) ?? normalizeWalletAddress(walletState.account)

    privyDebugLog("info", "wallet-state-event", {
      serverSignedIn: serverSessionActive,
      account: redactWalletForDebug(eventAccount),
      authenticated: detail?.authenticated,
    })

    if (
      serverSessionActive &&
      serverAddress &&
      eventAccount &&
      serverAddress.toLowerCase() !== eventAccount.toLowerCase() &&
      !disconnecting
    ) {
      void disconnectForWalletSwitch(eventAccount)
      return
    }

    renderWalletState(detail)
    void maybeSyncSession()
  }

  const onWalletExtensionAccountChanged = (event: Event) => {
    const detail = (event as CustomEvent<{ account: string | null }>).detail
    const account = normalizeWalletAddress(detail?.account)

    if (
      serverSessionActive &&
      serverAddress &&
      account &&
      serverAddress.toLowerCase() !== account.toLowerCase()
    ) {
      void disconnectForWalletSwitch(account)
    }
  }

  const onConnectClick = () => {
    const walletState = getWalletBridgeState()
    clearNotice()

    if (walletReadyForBridgeSession()) {
      pendingConnect = true
      void syncSessionAndReload(serverSessionActive ? "Refreshing sign in..." : "Finishing sign in...")
      return
    }

    if (walletState.authenticated && !walletReadyForBridgeSession()) {
      if (!walletState.linkWallet) {
        showNotice("Wallet sign-in is not ready yet.", "error")
        return
      }

      pendingConnect = true
      showNotice("Confirm your wallet to finish sign in...", "info")
      walletState.linkWallet()
      return
    }

    if (!walletState.login) {
      showNotice("Wallet sign-in is not ready yet.", "error")
      return
    }

    pendingConnect = true
    showNotice("Waiting for wallet confirmation...", "info")
    walletState.login()
  }

  const onDisconnectClick = () => {
    void disconnectCurrentWallet()
  }

  async function disconnectCurrentWallet() {
    let clearedServerSession = false

    try {
      disconnecting = true
      pendingConnect = false
      setButtonsBusy(true)
      renderWalletState()
      showNotice("Signing out...", "info")

      if (config?.privySession) {
        await clearPrivySession(config.privySession)
        serverSessionActive = false
        clearedServerSession = true
      }

      await Promise.resolve(getWalletBridgeState().logout?.())
      window.location.reload()
    } catch (error) {
      disconnecting = false
      setButtonsBusy(false)
      renderWalletState()

      const notice = disconnectFailureNotice({
        clearedServerSession,
        fallbackMessage: getErrorMessage(error, "Could not disconnect this wallet."),
      })

      showNotice(notice.message, notice.tone)
    }
  }

  async function disconnectForWalletSwitch(account: string | null) {
    if (disconnecting) return

    disconnecting = true
    pendingConnect = false
    showNotice("Wallet changed. Reconnect to continue.", "info")

    try {
      if (config?.privySession) {
        await clearPrivySession(config.privySession)
      }

      serverSessionActive = false
      await Promise.resolve(getWalletBridgeState().logout?.())
      window.location.reload()
    } catch (error) {
      disconnecting = false
      showNotice(getErrorMessage(error, "Could not disconnect this wallet."), "error")
      privyDebugLog("error", "wallet-switch:disconnect-failed", {
        account: redactWalletForDebug(account),
      })
    }
  }

  connectButtons.forEach((button) => button.addEventListener("click", onConnectClick))
  disconnectButtons.forEach((button) => button.addEventListener("click", onDisconnectClick))
  window.addEventListener(WALLET_STATE_EVENT, onState)
  window.addEventListener(WALLET_SIGNATURE_REQUEST_EVENT, onConnectClick)
  window.addEventListener(WALLET_EXTENSION_ACCOUNT_CHANGED_EVENT, onWalletExtensionAccountChanged)
  renderWalletState()
  void maybeSyncSession()

  return () => {
    connectButtons.forEach((button) => button.removeEventListener("click", onConnectClick))
    disconnectButtons.forEach((button) => button.removeEventListener("click", onDisconnectClick))
    window.removeEventListener(WALLET_STATE_EVENT, onState)
    window.removeEventListener(WALLET_SIGNATURE_REQUEST_EVENT, onConnectClick)
    window.removeEventListener(
      WALLET_EXTENSION_ACCOUNT_CHANGED_EVENT,
      onWalletExtensionAccountChanged,
    )
  }
}
