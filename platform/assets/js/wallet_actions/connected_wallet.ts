export type EthereumProvider = {
  request(args: {method: string; params?: unknown[]}): Promise<unknown>
}

export type SelectedWallet = {address: string; provider: EthereumProvider}

let connectedWallets = new Map<string, EthereumProvider>()
let selectedAddress: string | null = null

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

/** The signed-in wallet's provider, when this tab has that wallet connected. */
export function connectedEthereumWallet(signer: string): SelectedWallet | null {
  const expected = signer.toLowerCase()
  const testWallet = testEthereumWallet()
  if (testWallet) return testWallet.address.toLowerCase() === expected ? testWallet : null

  const provider = connectedWallets.get(expected)
  return provider ? {address: expected, provider} : null
}

/**
 * The signed-in wallet as this tab has it connected. When it is not connected
 * here, Privy's connect step opens instead and the customer presses again once
 * it is: a press never sends from any other wallet.
 */
export function signerWalletOrConnect(signer: string): SelectedWallet | null {
  const wallet = connectedEthereumWallet(signer)
  if (!wallet) window.dispatchEvent(new CustomEvent("autolaunch:wallet-connect"))
  return wallet
}

/**
 * The account each connected Ethereum wallet is on right now, Privy's selected
 * one first. A browser wallet holding several accounts is on only one of them,
 * whatever Privy has connected. Panels are told this only to name the browser's
 * wallet beside their buttons when it is not the signed-in one; it never
 * chooses the wallet a panel acts for.
 */
export async function currentAddresses(): Promise<string[]> {
  const testWallet = testEthereumWallet()
  const listed = testWallet
    ? [testWallet.address.toLowerCase()]
    : [...new Set([...(selectedAddress ? [selectedAddress] : []), ...connectedWallets.keys()])]
  const current = await Promise.all(
    listed.map(address => currentAccount(connectedEthereumWallet(address)?.provider)),
  )
  return [...new Set(current.flatMap(address => (address ? [address] : [])))]
}

/** The account a wallet is on, lowercase, or null when it does not say. */
export async function currentAccount(provider: EthereumProvider | undefined): Promise<string | null> {
  const accounts = await provider?.request({method: "eth_accounts"}).catch(() => null)
  return Array.isArray(accounts) && typeof accounts[0] === "string" ? accounts[0].toLowerCase() : null
}

/**
 * The address Privy currently has selected, when that selection is an Ethereum
 * wallet that is still connected. It only orders the browser's report.
 */
export function replaceSelectedEthereumAddress(address: string | null): void {
  selectedAddress = address?.toLowerCase() ?? null
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

// The browser test seam stands in for the connected set, so the same wallet
// presses there as in a real browser.
function testEthereumWallet(): SelectedWallet | null {
  return window.location.origin === "http://127.0.0.1:4050" && window.__autolaunchTestWallet
    ? window.__autolaunchTestWallet
    : null
}
