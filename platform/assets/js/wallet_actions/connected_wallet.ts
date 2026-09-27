export type EthereumProvider = {
  request(args: {method: string; params?: unknown[]}): Promise<unknown>
}

export type SelectedWallet = {address: string; provider: EthereumProvider}

let activeWallet: SelectedWallet | null = null

declare global {
  interface Window {
    __autolaunchTestWallet?: SelectedWallet
  }
}

/**
 * The wallet Privy currently has selected, when that selection is an Ethereum
 * wallet that is still connected. Wallet actions read this and nothing else: an
 * absent, Solana or stale selection is no wallet, never a substitute one.
 */
export function replaceActiveEthereumWallet(wallet: SelectedWallet | null): void {
  activeWallet = wallet ? {address: wallet.address.toLowerCase(), provider: wallet.provider} : null
}

export function activeEthereumWallet(): SelectedWallet | null {
  const testWallet = testEthereumWallet()
  return testWallet ? {address: testWallet.address.toLowerCase(), provider: testWallet.provider} : activeWallet
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

// The browser test seam stands in for Privy's active wallet on the local
// check server only, so the same press runs there as in a real browser.
function testEthereumWallet(): SelectedWallet | null {
  return window.location.origin === "http://127.0.0.1:4050" && window.__autolaunchTestWallet
    ? window.__autolaunchTestWallet
    : null
}
