import type { Hook } from "phoenix_live_view"
import {
  PrivyProvider,
  type PrivyClientConfig,
  useIdentityToken,
  usePrivy,
  useUser,
} from "@privy-io/react-auth"
import React from "react"
import { createRoot, type Root } from "react-dom/client"

import {
  getLinkedWalletAddressesFromPrivyUser,
  usePrivyWalletClient,
} from "./wallet-bridge-privy"
import {
  getPrivyDisplayName,
  parseConfig,
  privyDebugLog,
  redactWalletForDebug,
} from "./wallet-bridge-shared"
import {
  createWalletBridgeDispatchKey,
  emitWalletBridgeState,
  emitWalletExtensionAccountChanged,
  resetWalletBridgeState,
  setWalletBridgeState,
} from "./wallet-bridge-runtime"
import type { WalletBridgeState } from "./wallet-bridge-state"

const BRIDGE_ROOT_ID = "autolaunch-privy-root"
const AUTOLAUNCH_PRIVY_CONFIG: PrivyClientConfig = {
  loginMethods: ["wallet"],
  appearance: {
    walletChainType: "ethereum-only",
    walletList: ["metamask", "coinbase_wallet", "rainbow", "wallet_connect"],
  },
}

let lastWalletBridgeDispatchKey: string | null = null
let bridgeRoot: Root | null = null
let bridgeConfigKey: string | null = null

function bridgeHost(): HTMLElement {
  const existing = document.getElementById(BRIDGE_ROOT_ID)
  if (existing) return existing

  const host = document.createElement("div")
  host.id = BRIDGE_ROOT_ID
  host.className = "contents"
  host.setAttribute("data-background-suppress", "")
  document.body.appendChild(host)
  return host
}

function AutolaunchPrivyBridgeRoot() {
  const { ready, authenticated, isModalOpen, login, linkWallet, logout, user } = usePrivy()
  const { identityToken } = useIdentityToken()
  const { refreshUser } = useUser()
  const { account, chainId, privyId, wallet, walletClient } = usePrivyWalletClient({
    onAccountChanged: emitWalletExtensionAccountChanged,
  })
  const linkedWalletAddresses = React.useMemo(
    () => getLinkedWalletAddressesFromPrivyUser(user),
    [user],
  )

  React.useEffect(() => {
    const nextWalletBridgeState: WalletBridgeState = {
      privyReady: ready,
      authenticated,
      isModalOpen,
      account,
      chainId,
      privyId,
      wallet,
      walletClient,
      displayName: getPrivyDisplayName(user),
      identityToken,
      linkedWalletAddresses,
      login,
      linkWallet,
      logout,
      refreshUser,
    }

    setWalletBridgeState(nextWalletBridgeState)

    const nextDispatchKey = createWalletBridgeDispatchKey(nextWalletBridgeState)
    if (nextDispatchKey === lastWalletBridgeDispatchKey) return

    lastWalletBridgeDispatchKey = nextDispatchKey

    privyDebugLog("info", "bridge-state", {
      ready,
      authenticated,
      isModalOpen,
      account: redactWalletForDebug(account),
      chainId,
      privyId,
      hasIdentityToken: Boolean(identityToken),
      linkedWalletAddresses: linkedWalletAddresses.map(redactWalletForDebug),
      hasWalletClient: Boolean(walletClient),
    })

    emitWalletBridgeState()
  }, [
    account,
    authenticated,
    isModalOpen,
    chainId,
    identityToken,
    linkedWalletAddresses,
    login,
    linkWallet,
    logout,
    privyId,
    refreshUser,
    ready,
    user,
    wallet,
    walletClient,
  ])

  return null
}

export function mountAutolaunchPrivyBridge(el: Element): void {
  const config = parseConfig(el.getAttribute("data-autolaunch-config"))

  if (!config?.privyAppId) {
    bridgeRoot?.unmount()
    bridgeRoot = null
    bridgeConfigKey = null
    resetWalletBridgeState()
    lastWalletBridgeDispatchKey = null
    emitWalletBridgeState()
    return
  }

  if (bridgeRoot && bridgeConfigKey === config.privyAppId) return

  bridgeRoot?.unmount()

  const root = createRoot(bridgeHost())
  bridgeRoot = root
  bridgeConfigKey = config.privyAppId

  root.render(
    <PrivyProvider appId={config.privyAppId} config={AUTOLAUNCH_PRIVY_CONFIG}>
      <AutolaunchPrivyBridgeRoot />
    </PrivyProvider>,
  )
}

export function unmountAutolaunchPrivyBridge(_el: Element): void {
  // Keep the Privy provider mounted across LiveView navigation. The bridge owns
  // wallet listeners for the whole browser session.
}

export const AutolaunchPrivyBridge: Hook = {
  mounted() {
    mountAutolaunchPrivyBridge(this.el)
  },
  destroyed() {
    unmountAutolaunchPrivyBridge(this.el)
  },
}
