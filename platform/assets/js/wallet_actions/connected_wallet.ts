export type EthereumProvider = {
  request(args: {method: string; params?: unknown[]}): Promise<unknown>
}

/**
 * One wallet Privy currently holds: the provider this page sends through, and
 * Privy's own way of letting go of it.
 */
export type ConnectedEthereumWallet = {provider: EthereumProvider; disconnect: () => void}

export type SelectedWallet = {address: string; provider: EthereumProvider}

// A visitor who chose Disconnect stays disconnected across reloads, whatever
// the wallet app still reports to Privy afterwards.
const disconnectedKey = "regent:wallet-disconnected:v1"
export const walletDisconnectedStorageKey = disconnectedKey
// This module already lives for one document, just like the provider maps below.
let disconnectedInDocument = false
let workEpoch = 0
export function walletWorkEpoch(): number { return workEpoch }
export function invalidateWalletWork(): void { workEpoch += 1 }

let connectedWallets = new Map<string, ConnectedEthereumWallet>()
let activeWallet: SelectedWallet | null = null

export function replaceConnectedEthereumWallets(
  wallets: ReadonlyArray<readonly [string, ConnectedEthereumWallet]>,
): void {
  connectedWallets = new Map(wallets.map(([address, wallet]) => [address.toLowerCase(), wallet]))
}

/**
 * The wallet Privy currently has selected, when that selection is an Ethereum
 * wallet that is still connected. Wallet actions read this and nothing else: an absent,
 * Solana or stale selection is no wallet, never a substitute one.
 */
export function replaceActiveEthereumWallet(wallet: SelectedWallet | null): void {
  activeWallet = wallet ? {address: wallet.address.toLowerCase(), provider: wallet.provider} : null
}

export function activeEthereumWallet(): SelectedWallet | null {
  if (walletDisconnected()) return null
  return activeWallet
}

/**
 * Whether Privy's selected wallet is an Ethereum wallet that is still among the
 * connected ones. A Solana selection and a selection the provider has dropped
 * are both ineligible rather than a reason to pick another wallet.
 */
export function eligibleActiveWallet<W extends {address: string; type?: string}>(
  active: W | null | undefined,
  wallets: ReadonlyArray<{address: string}>,
): W | null {
  if (!active || active.type !== "ethereum") return null
  const address = active.address.toLowerCase()
  return wallets.some(wallet => wallet.address.toLowerCase() === address) ? active : null
}

/**
 * Every wallet Privy holds stops being this page's wallet, and the wallet apps
 * themselves are asked to drop the site. The releases are sent before this page
 * forgets them, and the page is disconnected from that point whatever any of
 * them answers, so a wallet app that never answers cannot hold Disconnect open.
 */
export async function disconnectEveryEthereumWallet(walletEvents: EventTarget): Promise<void> {
  const released = [...connectedWallets.values()].flatMap(wallet => [
    Promise.resolve().then(() => wallet.disconnect()),
    Promise.resolve().then(() => revokeSitePermissions(wallet.provider)),
  ])

  replaceConnectedEthereumWallets([])
  replaceActiveEthereumWallet(null)
  rememberWalletDisconnected()
  walletEvents.dispatchEvent(new CustomEvent("autolaunch:wallet-state"))

  await Promise.allSettled(released)
}

// EIP-2255: the site asks the wallet app itself to take back the accounts it
// exposed. An app that refuses the request, or has never heard of it, is
// revoked as far as this page can take it.
function revokeSitePermissions(provider: EthereumProvider): Promise<unknown> {
  return provider.request({method: "wallet_revokePermissions", params: [{eth_accounts: {}}]})
}

export function walletDisconnected(): boolean {
  if (disconnectedInDocument) return true
  try {
    return disconnectedStorage()?.getItem(disconnectedKey) === "true"
  } catch {
    return false
  }
}

export function rememberWalletDisconnected(): void {
  disconnectedInDocument = true
  invalidateWalletWork()
  try {
    disconnectedStorage()?.setItem(disconnectedKey, "true")
  } catch {
    // A browser that refuses storage still disconnected everything above.
  }
}

export function forgetWalletDisconnected(): void {
  disconnectedInDocument = false
  try {
    disconnectedStorage()?.removeItem(disconnectedKey)
  } catch {
    // Nothing was remembered, so there is nothing to forget.
  }
}

function disconnectedStorage(): Pick<Storage, "getItem" | "setItem" | "removeItem"> | null {
  try {
    return window.localStorage ?? null
  } catch {
    return null
  }
}
