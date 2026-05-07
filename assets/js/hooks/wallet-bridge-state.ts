import type { WalletClient } from "viem"

import type { PrivyEthereumWalletLike } from "./wallet-bridge-privy"

export type WalletNoticeTone = "error" | "info"

export type WalletBridgeState = {
  privyReady: boolean
  authenticated: boolean
  isModalOpen: boolean
  account: `0x${string}` | null
  chainId: number | null
  privyId: string | null
  wallet: PrivyEthereumWalletLike | null
  walletClient: WalletClient | null
  displayName: string | null
  identityToken: string | null
  linkedWalletAddresses: readonly `0x${string}`[]
  login: (() => void) | null
  linkWallet: (() => void) | null
  logout: (() => void) | null
  refreshUser: (() => Promise<unknown>) | null
}

export function emptyWalletBridgeState(): WalletBridgeState {
  return {
    privyReady: false,
    authenticated: false,
    isModalOpen: false,
    account: null,
    chainId: null,
    privyId: null,
    wallet: null,
    walletClient: null,
    displayName: null,
    identityToken: null,
    linkedWalletAddresses: [],
    login: null,
    linkWallet: null,
    logout: null,
    refreshUser: null,
  }
}

export function disconnectFailureNotice(args: {
  clearedServerSession: boolean
  fallbackMessage: string
}): { message: string; tone: WalletNoticeTone } {
  if (args.clearedServerSession) {
    return {
      message:
        "Signed out here. Your wallet app is still connected, so disconnect it there if you want to fully close it.",
      tone: "info",
    }
  }

  return { message: args.fallbackMessage, tone: "error" }
}
