export interface EthereumProvider {
  request(args: { method: string; params?: unknown[] }): Promise<unknown>
}

export type PrivyUser = {
  id?: string
  wallet?: { address?: string }
  email?: { address?: string }
  linked_accounts?: Array<{ type?: string; address?: string; chain_type?: string }>
} | null

export interface PrivyWalletShape {
  address: `0x${string}`
  chainId: number
  walletClientType: "injected"
}

export interface PrivyLike {
  user: {
    get(): Promise<{ user?: PrivyUser }>
  }
  getAccessToken(): Promise<string | null>
  initialize(): Promise<void>
  auth: {
    logout(args: { userId: string }): Promise<void>
    siwe: {
      init(wallet: PrivyWalletShape, domain: string, uri: string): Promise<{ message: string }>
      loginWithSiwe(
        signature: string,
        wallet?: PrivyWalletShape,
        message?: string,
      ): Promise<unknown>
    }
  }
}

declare global {
  interface Window {
    ethereum?: EthereumProvider
  }
}

export function walletForUser(user: PrivyUser): string | null {
  if (!user) return null
  if (typeof user.wallet?.address === "string" && user.wallet.address.trim().length > 0) {
    return user.wallet.address.trim().toLowerCase()
  }

  const linkedAccount = (user.linked_accounts ?? []).find((account) => {
    return typeof account?.address === "string" && account.address.trim().length > 0
  })

  return linkedAccount?.address?.trim().toLowerCase() ?? null
}

export function walletsForUser(user: PrivyUser): string[] {
  const values = [user?.wallet?.address, ...(user?.linked_accounts ?? []).map((account) => account?.address)]

  return values
    .map((value) => (typeof value === "string" ? value.trim().toLowerCase() : ""))
    .filter((value): value is string => value.length > 0)
    .filter((value, index, array) => array.indexOf(value) === index)
}

export function labelForUser(user: PrivyUser): string {
  if (typeof user?.email?.address === "string" && user.email.address.trim().length > 0) {
    return user.email.address.trim()
  }

  const walletAddress = walletForUser(user)
  if (walletAddress) return shortenWallet(walletAddress)

  return user?.id?.trim() || "connected"
}

export function shortenWallet(walletAddress: string): string {
  const trimmed = walletAddress.trim()
  if (trimmed.length <= 12) return trimmed
  return `${trimmed.slice(0, 6)}...${trimmed.slice(-4)}`
}

export function parseChainId(value: unknown): number | null {
  if (typeof value === "number" && Number.isFinite(value)) return value
  if (typeof value !== "string") return null

  const normalized = value.startsWith("0x")
    ? Number.parseInt(value, 16)
    : Number.parseInt(value.replace(/^eip155:/, ""), 10)

  return Number.isFinite(normalized) ? normalized : null
}

export async function requireEthereumProvider(): Promise<EthereumProvider> {
  const provider = window.ethereum
  if (!provider || typeof provider.request !== "function") {
    throw new Error("Open a browser wallet before using Privy wallet connect.")
  }

  return provider
}

export async function buildPrivyWallet(
  provider: EthereumProvider,
  expectedAddress?: string | null,
): Promise<PrivyWalletShape> {
  const accounts = (await provider.request({ method: "eth_requestAccounts" })) as unknown
  const address = Array.isArray(accounts) ? String(accounts[0] ?? "").trim().toLowerCase() : ""
  const chainId = parseChainId(await provider.request({ method: "eth_chainId" }))

  if (!address.startsWith("0x") || address.length != 42) {
    throw new Error("Wallet connection was cancelled.")
  }

  if (!chainId) {
    throw new Error("The connected wallet did not report a usable chain id.")
  }

  if (
    typeof expectedAddress === "string" &&
    expectedAddress.trim().length > 0 &&
    address !== expectedAddress.trim().toLowerCase()
  ) {
    throw new Error(`Switch to wallet ${expectedAddress.trim()} before continuing.`)
  }

  return {
    address: address as `0x${string}`,
    chainId,
    walletClientType: "injected",
  }
}

export async function loginWithPrivyWallet(
  privy: PrivyLike,
  provider: EthereumProvider,
  expectedAddress?: string | null,
): Promise<void> {
  const wallet = await buildPrivyWallet(provider, expectedAddress)
  const { message } = await privy.auth.siwe.init(wallet, window.location.host, window.location.origin)
  const signature = await provider.request({
    method: "personal_sign",
    params: [message, wallet.address],
  })

  await privy.auth.siwe.loginWithSiwe(String(signature), wallet, message)
}

export async function signWithConnectedWallet(
  provider: EthereumProvider,
  message: string,
  expectedAddress?: string | null,
): Promise<{ signature: string; address: string }> {
  const wallet = await buildPrivyWallet(provider)

  if (
    typeof expectedAddress === "string" &&
    expectedAddress.trim().length > 0 &&
    wallet.address.toLowerCase() !== expectedAddress.trim().toLowerCase()
  ) {
    throw new Error("The connected wallet does not match the Privy wallet on this session.")
  }

  const signature = await provider.request({
    method: "personal_sign",
    params: [message, wallet.address],
  })

  return { signature: String(signature), address: wallet.address }
}
