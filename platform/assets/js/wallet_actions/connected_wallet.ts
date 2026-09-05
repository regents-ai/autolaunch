export type EthereumProvider = {
  request(args: {method: string; params?: unknown[]}): Promise<unknown>
}

export type SelectedWallet = {address: string; provider: EthereumProvider}

let connectedWallets = new Map<string, EthereumProvider>()
let activeWallet: SelectedWallet | null = null

declare global {
  interface Window {
    __autolaunchTestWallet?: {address: string; provider: EthereumProvider}
  }
}

export function replaceConnectedEthereumWallets(
  wallets: ReadonlyArray<readonly [string, EthereumProvider]>,
): void {
  connectedWallets = new Map(wallets.map(([address, provider]) => [address.toLowerCase(), provider]))
}

export function connectedEthereumWallet(expectedSigner?: string): SelectedWallet | null {
  const testWallet = testEthereumWallet()
  if (testWallet) {
    if (!expectedSigner || testWallet.address.toLowerCase() === expectedSigner.toLowerCase()) {
      return testWallet
    }
    return null
  }

  if (expectedSigner) {
    return selectConnectedEthereumWallet([...connectedWallets.entries()], expectedSigner)
  }

  const first = connectedWallets.entries().next().value as [string, EthereumProvider] | undefined
  return first ? {address: first[0], provider: first[1]} : null
}

export function selectConnectedEthereumWallet(
  wallets: ReadonlyArray<readonly [string, EthereumProvider]>,
  expectedSigner: string,
): SelectedWallet | null {
  const expected = expectedSigner.toLowerCase()
  const selected = wallets.find(([address]) => address.toLowerCase() === expected)
  return selected ? {address: selected[0], provider: selected[1]} : null
}

/**
 * The wallet Privy currently has selected, when that selection is an Ethereum
 * wallet that is still connected. Stake reads this and nothing else: an absent,
 * Solana or stale selection is no wallet, never a substitute one.
 */
export function replaceActiveEthereumWallet(wallet: SelectedWallet | null): void {
  activeWallet = wallet ? {address: wallet.address.toLowerCase(), provider: wallet.provider} : null
}

export function activeEthereumWallet(): SelectedWallet | null {
  return testEthereumWallet() ?? activeWallet
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

// The browser test seam stands in for Privy's selection as well as for the
// connected set, so the same wallet drives Stake there as in a real browser.
function testEthereumWallet(): SelectedWallet | null {
  return window.location.origin === "http://127.0.0.1:4050" && window.__autolaunchTestWallet
    ? window.__autolaunchTestWallet
    : null
}
